import Foundation
import CryptoKit

struct LocalPortfolioDocument: Codable, Equatable {
    var schemaVersion = 1
    var source: String
    var updatedAt: Date
    var marketDataUpdatedAt: Date? = nil
    var positions: [LocalPositionRecord]
    var snapshots: [LocalPortfolioSnapshotRecord]
    var transactions: [LocalTransactionRecord]? = nil
    var knownAccounts: [PortfolioAccount]? = nil
    /// Set by the generators that invent a portfolio — demo mode, the
    /// public-investor simulation. Nothing marked this way may leave the
    /// device.
    ///
    /// A flag rather than an inspection of `source`: the demo document calls
    /// itself "假数据（Trading 212 + Moomoo + IBKR）", which a check for
    /// "demo" or "fake" sails straight past. Provenance is something a
    /// producer states, not something a reader guesses.
    var isSynthetic: Bool? = nil
    /// Optional so documents saved before iCloud sync still decode. Record
    /// clocks survive unrelated edits; absence from another device is never
    /// interpreted as a deletion.
    var syncMetadata: LocalPortfolioSyncMetadata? = nil

    static let empty = LocalPortfolioDocument(
        source: "local",
        updatedAt: .distantPast,
        positions: [],
        snapshots: []
    )
}

struct LocalPortfolioSyncMetadata: Codable, Equatable {
    // Numeric timestamps preserve subsecond ordering even when the document's
    // legacy ISO-8601 updatedAt is encoded with whole-second precision.
    var positionsUpdatedAt: [String: TimeInterval] = [:]
    var accountsUpdatedAt: [String: TimeInterval] = [:]
    var transactionsUpdatedAt: [String: TimeInterval] = [:]
    var snapshotsUpdatedAt: [String: TimeInterval] = [:]
    var deletedAccounts: [String: TimeInterval] = [:]
    var deletedTransactions: [String: TimeInterval] = [:]
    /// A Trading 212 slot is local to a device, not a broker account ID.
    /// Bindings prevent unrelated accounts occupying slot 1 from combining.
    var accountBindings: [String: String]? = nil
    /// Also deletes records on an offline device that this device never saw.
    var resetAt: TimeInterval? = nil
}

extension LocalPortfolioDocument {
    var isPublicDisclosure: Bool { source == PublicInvestorAccountAdapter.source || positions.contains { $0.publicDisclosure != nil } }

    var accounts: [PortfolioAccount] {
        let grouped = Dictionary(grouping: positions, by: \.accountKey)
        let history = Dictionary(grouping: transactions ?? [], by: \.accountKey)
        let saved = Dictionary((knownAccounts ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return Set(grouped.keys).union(history.keys).union(saved.keys)
            .map { key in
                let accountPositions = grouped[key] ?? []
                let firstPosition = accountPositions.first
                // `history` already groups every transaction by account. Re-scanning
                // the whole ledger for each account made this O(accounts x ledger).
                let accountTransactions = history[key] ?? []
                let transaction = accountTransactions.first
                let fallbackCurrency = firstPosition?.source == "Trading 212" ? "GBP" : (firstPosition?.currency ?? "USD")
                return PortfolioAccount(
                    id: key,
                    accountID: firstPosition?.accountID ?? saved[key]?.accountID ?? transaction?.accountID,
                    source: firstPosition?.source ?? saved[key]?.source ?? transaction?.source ?? "本机",
                    name: firstPosition?.resolvedAccountName ?? saved[key]?.name ?? transaction?.accountName ?? "本机账户",
                    baseCurrency: firstPosition?.accountCurrency ?? saved[key]?.baseCurrency ?? transaction?.realisedProfitLossCurrency ?? fallbackCurrency,
                    positionCount: accountPositions.count,
                    transactionCount: accountTransactions.count,
                    manualTransactionCount: accountTransactions.filter {
                        $0.entryMethod == "manual"
                    }.count,
                    hasCSVImport: firstPosition?.source == "CSV" || accountTransactions.contains {
                        $0.entryMethod == "csv"
                    },
                    marketValueUSD: (try? LocalPortfolioEngine.totals(for: accountPositions).marketValue) ?? 0,
                    // Positions carry the account's name and currency; only the
                    // chosen broker product lives in the saved account list.
                    accountTypeOverride: saved[key]?.accountTypeOverride
                )
            }
            .sorted {
                if $0.source == $1.source { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.source.localizedStandardCompare($1.source) == .orderedAscending
            }
    }

    func scoped(to selectedAccountKeys: Set<String>) -> LocalPortfolioDocument {
        scoped(to: selectedAccountKeys, availableAccounts: accounts)
    }

    /// Reuse an account index already prepared for this document. Building
    /// `accounts` groups the complete transaction history, so callers that
    /// also need the account list should do that work only once.
    func scoped(to selectedAccountKeys: Set<String>, availableAccounts: [PortfolioAccount]) -> LocalPortfolioDocument {
        let availableKeys = Set(availableAccounts.map(\.id))
        let effectiveKeys = selectedAccountKeys.intersection(availableKeys)
        let selectedPositions = positions.filter { effectiveKeys.contains($0.accountKey) }
        let selectedTransactions = transactions?.filter { effectiveKeys.contains($0.accountKey) }
        let isAllAccounts = effectiveKeys == availableKeys
        let selectedSnapshots = snapshots.compactMap { snapshot -> LocalPortfolioSnapshotRecord? in
            guard let accountTotals = snapshot.accountTotals else {
                // A legacy aggregate snapshot cannot be assigned to the
                // current account set once more than one account exists. If
                // retained, adding an account looks like a sell followed by a
                // buy and inflates cash-flow-matched portfolio value.
                return isAllAccounts && availableKeys.count == 1 ? snapshot : nil
            }
            let totals = effectiveKeys.compactMap { accountTotals[$0] }
            guard !totals.isEmpty else { return nil }
            return LocalPortfolioSnapshotRecord(
                date: snapshot.date,
                marketValueUSD: totals.reduce(0) { $0 + $1.marketValueUSD },
                costUSD: totals.reduce(0) { $0 + $1.costUSD },
                accountTotals: Dictionary(uniqueKeysWithValues: effectiveKeys.compactMap { key in
                    accountTotals[key].map { (key, $0) }
                })
            )
        }
        let selectedSources = Set(selectedPositions.map(\.source)).sorted()
        return LocalPortfolioDocument(
            schemaVersion: schemaVersion,
            source: isPublicDisclosure ? PublicInvestorAccountAdapter.source : selectedSources.joined(separator: " + "),
            updatedAt: updatedAt,
            marketDataUpdatedAt: marketDataUpdatedAt,
            positions: selectedPositions,
            snapshots: selectedSnapshots,
            transactions: selectedTransactions,
            knownAccounts: availableAccounts.filter { effectiveKeys.contains($0.id) },
            isSynthetic: isSynthetic
        )
    }
}

enum LocalPortfolioError: LocalizedError {
    case noPortfolio
    case invalidCSV(String)
    case unsupportedCurrency(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noPortfolio:
            L10n.text("手机中还没有组合数据，请先直连券商或导入 CSV")
        case let .invalidCSV(message):
            L10n.text("CSV 无法导入：\(message)")
        case let .unsupportedCurrency(currency):
            L10n.text("暂不支持 \(currency) 换算为 USD")
        case .writeFailed:
            L10n.text("无法保存到 iPhone 本地存储")
        }
    }
}
