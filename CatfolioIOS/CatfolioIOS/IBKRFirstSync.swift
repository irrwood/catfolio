import Foundation
import Observation

/// Where the IBKR Flex credentials live in the Keychain.
///
/// An account's credentials are kept under its IBKR account ID, but that ID
/// only arrives with the first report. Until then they are parked under fixed
/// keys, beside a placeholder account that stands in for the real ones.
enum IBKRFlexKeys {
    static let source = "IBKR Flex"
    static let pendingAccountID = "ibkr-flex-pending"
    static let pendingToken = "ibkr.flex.pending.token"
    static let pendingQueryID = "ibkr.flex.pending.query-id"

    static func token(accountID: String) -> String { "ibkr.flex.account.\(accountID).token" }
    static func queryID(accountID: String) -> String { "ibkr.flex.account.\(accountID).query-id" }

    static var pendingTokenValue: String { KeychainStore.string(for: pendingToken) ?? "" }
    static var pendingQueryIDValue: String { KeychainStore.string(for: pendingQueryID) ?? "" }

    static func clearPending() {
        try? KeychainStore.set("", for: pendingToken)
        try? KeychainStore.set("", for: pendingQueryID)
    }
}

/// The first sync of a newly added IBKR account, run after its sheet closes.
///
/// Saving the account used to stop at the placeholder: the report IBKR builds
/// can take minutes, so the sheet no longer waited for it — but then nothing
/// fetched it at all, and the account sat at "awaiting first sync" until the
/// reader thought to reopen it. This owns that wait instead. It outlives the
/// sheet, reports how long IBKR has been working so the account row is not
/// silent, and picks the job up again after a relaunch.
@MainActor @Observable
final class IBKRFirstSync {
    static let shared = IBKRFirstSync()

    enum Phase: Equatable {
        /// IBKR is still generating the report.
        case waiting(seconds: Int)
        case importing
        case failed(String)
    }

    private(set) var phase: Phase?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Starts the first sync if a placeholder is waiting for one and it is not
    /// already running. Safe to call as often as the account list changes.
    func startIfNeeded(model: AppModel) {
        guard task == nil,
              let placeholder = model.accounts.first(where: { $0.id == IBKRFlexKeys.pendingAccountID }) else { return }
        let credentials: IBKRFlexCredentials
        do {
            credentials = try IBKRFlexCredentials(token: IBKRFlexKeys.pendingTokenValue,
                                                  queryID: IBKRFlexKeys.pendingQueryIDValue)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .waiting(seconds: 0)
        let nickname = placeholder.name
        task = Task { [weak self] in
            await self?.run(model: model, nickname: nickname, credentials: credentials)
            self?.task = nil
        }
    }

    /// For the IBKR sheet: the reader is about to run a sync by hand, so the
    /// background one steps aside rather than import the same report twice.
    func cancel() {
        task?.cancel()
        task = nil
        phase = nil
    }

    private func run(model: AppModel, nickname: String, credentials: IBKRFlexCredentials) async {
        do {
            let fetched = try await IBKRFlexClient().fetchOpenPositions(
                credentials: credentials,
                onProgress: { [weak self] seconds in
                    Task { @MainActor [weak self] in
                        guard let self, case .waiting = self.phase else { return }
                        self.phase = .waiting(seconds: seconds)
                    }
                }
            )
            try Task.checkCancellation()

            // Only accounts not already in Catfolio: the placeholder stands
            // for new ones, and existing IBKR accounts sync on their own.
            let existing = Set(model.accounts.filter { $0.source == IBKRFlexKeys.source }.compactMap(\.accountID))
            let snapshot = fetched.restricted(excluding: existing)
            let accountIDs = snapshot.syncedPositionAccountIDs
                .union(snapshot.transactions.map(\.accountID))
                .subtracting([""])
            guard !snapshot.syncedPositionAccountIDs.isEmpty else {
                phase = .failed(L10n.text("Flex 报表中没有可新建的 IBKR 账户。"))
                return
            }

            phase = .importing
            for accountID in accountIDs {
                try KeychainStore.set(credentials.token, for: IBKRFlexKeys.token(accountID: accountID))
                try KeychainStore.set(credentials.queryID, for: IBKRFlexKeys.queryID(accountID: accountID))
            }
            let names = model.accountNames(source: IBKRFlexKeys.source, accountIDs: accountIDs.sorted(),
                                           preferredNickname: nickname)
            _ = try await model.importIBKR(snapshot, accountNames: names, replacingAccountsOnly: true)
            IBKRFlexKeys.clearPending()
            // The real accounts are in under their own IDs; the placeholder
            // has nothing left to stand for.
            try? await model.deleteAccount(IBKRFlexKeys.pendingAccountID)
            phase = nil
        } catch is CancellationError {
            phase = nil
        } catch {
            guard !Task.isCancelled else { phase = nil; return }
            phase = .failed(error.localizedDescription)
        }
    }
}

extension IBKRFlexSnapshot {
    /// The report without the accounts in `excluded`.
    func restricted(excluding excluded: Set<String>) -> IBKRFlexSnapshot {
        let allowed = syncedPositionAccountIDs.union(transactions.map(\.accountID)).subtracting(excluded)
        return IBKRFlexSnapshot(
            positions: positions.filter { allowed.contains($0.accountID) },
            transactions: transactions.filter { allowed.contains($0.accountID) },
            accountCurrencies: accountCurrencies.filter { allowed.contains($0.key) },
            accountNames: accountNames.filter { allowed.contains($0.key) },
            reportDate: reportDate,
            positionAccountIDs: positionAccountIDs.intersection(allowed)
        )
    }
}
