import Foundation

/// One ledger snapshot and up to four account/locale scopes, shared by the
/// overview and history page. Replaced transactions invalidate every scope.
@MainActor
final class HistoryPreparationCache {
    private struct Scope: Hashable {
        let accounts: Set<String>
        let locale: String
        let ticker: String?
    }
    private struct Entry {
        let id = UUID()
        let scope: Scope
        let task: Task<HistoryPreparedLedger, Error>
    }
    private var snapshot: PortfolioActivityLedger?
    private var entries: [Entry] = []

    func prepared(ledger: PortfolioActivityLedger, accountIDs: Set<String>, locale: Locale,
                  ticker: String? = nil) async throws -> HistoryPreparedLedger {
        if snapshot != ledger {
            snapshot = ledger
            entries.removeAll()
        }
        let scope = Scope(accounts: accountIDs, locale: locale.identifier,
                          ticker: ticker?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        let entry: Entry
        if let existing = entries.first(where: { $0.scope == scope }) {
            entry = existing
        } else {
            entry = Entry(scope: scope, task: Task.detached(priority: .userInitiated) {
                try HistoryPreparedLedger.build(ledger: ledger, accountIDs: accountIDs,
                                                locale: locale, ticker: scope.ticker)
            })
            entries.append(entry)
            if entries.count > 4 { entries.removeFirst() }
        }
        do {
            let result = try await entry.task.value
            try Task.checkCancellation()
            return result
        } catch {
            // A caller leaving a page must not discard another caller's result.
            if !Task.isCancelled { entries.removeAll { $0.id == entry.id } }
            throw error
        }
    }
}
