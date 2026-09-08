import Foundation

/// Combines two copies of the portfolio document that were written on
/// different devices.
///
/// The point of syncing the ledger is to read a portfolio on a device that
/// has no broker credentials. That is normally one writer and several
/// readers, which cannot conflict — but "normally" is not a guarantee, and a
/// second device that later gets credentials would start writing too.
///
/// So this never replaces one document with another. The two kinds of content
/// in it fail differently, and are treated differently:
///
/// - **Transactions are a log.** They only ever accumulate, each carries a
///   stable identity, and losing one is invisible: the remaining rows still
///   look correct, and only a reconciliation against the broker's holdings
///   ever notices. They are unioned, never dropped.
/// - **Positions are a photograph.** There is no sense in which two devices'
///   position lists combine; one was simply taken later. The newer document's
///   wins wholesale.
///
/// Getting that backwards — merging positions, replacing transactions — would
/// produce a document that looks fine and is quietly missing history. This
/// app has already shipped one ledger with that shape.
enum PortfolioDocumentMerge {

    /// Which document to believe about point-in-time state.
    private static func newer(
        _ lhs: LocalPortfolioDocument, _ rhs: LocalPortfolioDocument
    ) -> LocalPortfolioDocument {
        lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }

    /// Merges `remote` into `local`.
    ///
    /// Returns nil when the two are not comparable — a schema this build does
    /// not know how to combine. Silently mixing two shapes is worse than
    /// declining to.
    static func merge(
        local: LocalPortfolioDocument,
        remote: LocalPortfolioDocument
    ) -> LocalPortfolioDocument? {
        guard local.schemaVersion == remote.schemaVersion else { return nil }

        let latest = newer(local, remote)
        var merged = latest

        // Union by the identity the local store already deduplicates on, so a
        // transaction seen by both devices stays one row. Where both hold the
        // same id, the newer document's copy wins: a broker can restate a
        // fill, and the later read is the better one.
        var transactions: [String: LocalTransactionRecord] = [:]
        let older = latest == local ? remote : local
        for record in older.transactions ?? [] { transactions[record.id] = record }
        for record in latest.transactions ?? [] { transactions[record.id] = record }
        merged.transactions = transactions.values.sorted {
            ($0.date, $0.id) < ($1.date, $1.id)
        }

        // One point per date. Both devices computed the same series from the
        // same trades, so disagreement means one of them ran later.
        var snapshots: [String: LocalPortfolioSnapshotRecord] = [:]
        for record in older.snapshots { snapshots[record.date] = record }
        for record in latest.snapshots { snapshots[record.date] = record }
        merged.snapshots = snapshots.values.sorted { $0.date < $1.date }

        // An account connected on either device should be known to both, and
        // a nickname edited on the newer one should stick.
        var accounts: [String: PortfolioAccount] = [:]
        for account in older.knownAccounts ?? [] { accounts[account.id] = account }
        for account in latest.knownAccounts ?? [] { accounts[account.id] = account }
        merged.knownAccounts = accounts.isEmpty ? nil : accounts.values.sorted { $0.id < $1.id }

        // Positions and the quote timestamp come from the later document
        // whole. They are already `latest`'s, and are left alone deliberately.
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        merged.marketDataUpdatedAt = [local.marketDataUpdatedAt, remote.marketDataUpdatedAt]
            .compactMap { $0 }.max()
        return merged
    }

    /// Whether a document is one this device should upload.
    ///
    /// Three independent reasons to refuse, because the cost of being wrong
    /// is replacing someone's real portfolio on another device with invented
    /// numbers:
    ///
    /// 1. The producer said so. Generators set `isSynthetic`.
    /// 2. A position carries a public disclosure rather than a real holding,
    ///    which is what a 13F-derived portfolio looks like.
    /// 3. The source names itself as invented — kept only as a backstop, and
    ///    explicitly not the primary check. An earlier version relied on it
    ///    alone and passed the demo document straight through, because that
    ///    document calls itself "假数据（…）" and the check was looking for
    ///    "demo" and "fake".
    static func isUploadable(_ document: LocalPortfolioDocument) -> Bool {
        guard document.isSynthetic != true else { return false }
        guard document.positions.allSatisfy({ $0.publicDisclosure == nil }) else { return false }
        let source = document.source.lowercased()
        return !["demo", "fake", "simulation", "investor", "假数据", "模拟"]
            .contains { source.contains($0) }
    }
}
