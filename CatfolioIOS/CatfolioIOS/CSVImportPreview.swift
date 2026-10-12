import Foundation

/// A parsed CSV before anything is written: what it would put in the account,
/// which rows it could not read, and how the account's holdings would change.
/// Nothing reaches the portfolio until the reader has seen this and confirmed.
struct CSVImportPreview {
    struct Change: Identifiable, Equatable {
        enum Kind: Equatable { case added, removed, changed }
        let ticker: String
        let sharesBefore: Double?
        let sharesAfter: Double?

        var id: String { ticker }
        var kind: Kind {
            switch (sharesBefore, sharesAfter) {
            case (nil, _): .added
            case (_, nil): .removed
            default: .changed
            }
        }
    }

    let positions: [LocalPositionRecord]
    let transactions: [LocalTransactionRecord]
    let result: CSVImportResult
    /// The account the import replaces, `source|accountID`.
    let accountKey: String
    /// Holdings that appear, disappear or change their share count.
    let changes: [Change]
    let unchangedCount: Int

    var removedCount: Int { changes.filter { $0.kind == .removed }.count }

    /// Holdings compared by ticker, shares summed across lots and currencies.
    /// A change smaller than a millionth of a share is not a change.
    static func changes(previous: [LocalPositionRecord],
                        incoming: [LocalPositionRecord]) -> (changes: [Change], unchanged: Int) {
        func shares(_ positions: [LocalPositionRecord]) -> [String: Double] {
            positions.reduce(into: [:]) { $0[$1.ticker, default: 0] += $1.shares }
        }
        let before = shares(previous)
        let after = shares(incoming)
        var changes: [Change] = []
        var unchanged = 0
        for ticker in Set(before.keys).union(after.keys).sorted() {
            let old = before[ticker], new = after[ticker]
            if let old, let new, abs(old - new) <= max(1e-6, abs(old) * 1e-9) {
                unchanged += 1
            } else {
                changes.append(Change(ticker: ticker, sharesBefore: old, sharesAfter: new))
            }
        }
        // Removals first: they are what an incomplete file costs.
        let order: [Change.Kind] = [.removed, .changed, .added]
        changes.sort { (order.firstIndex(of: $0.kind)!, $0.ticker) < (order.firstIndex(of: $1.kind)!, $1.ticker) }
        return (changes, unchanged)
    }
}
