import Foundation

/// Holdings are a complete snapshot per account. Trades are individual
/// records. Each has its own clock, so refreshing account A cannot erase
/// account B or make an old trade override a correction on another device.
enum PortfolioDocumentMerge {
    static func merge(
        local: LocalPortfolioDocument,
        remote: LocalPortfolioDocument
    ) -> LocalPortfolioDocument? {
        guard (1...4).contains(local.schemaVersion), (1...4).contains(remote.schemaVersion),
              isUploadable(local), isUploadable(remote) else { return nil }
        for (key, binding) in local.syncMetadata?.accountBindings ?? [:] {
            if let other = remote.syncMetadata?.accountBindings?[key], other != binding { return nil }
        }
        let lhs = normalized(local)
        let rhs = normalized(remote)
        let lm = lhs.syncMetadata!
        let rm = rhs.syncMetadata!
        var metadata = combined(lm, rm)
        let reset = metadata.resetAt ?? -.infinity
        func accountThreshold(_ key: String) -> TimeInterval {
            max(reset, metadata.deletedAccounts[key] ?? -.infinity)
        }

        let lp = Dictionary(grouping: lhs.positions, by: \.accountKey)
        let rp = Dictionary(grouping: rhs.positions, by: \.accountKey)
        let positionKeys = Set(lm.positionsUpdatedAt.keys).union(rm.positionsUpdatedAt.keys)
        var positions: [LocalPositionRecord] = []
        for key in positionKeys.sorted() {
            let lv = lm.positionsUpdatedAt[key] ?? -.infinity
            let rv = rm.positionsUpdatedAt[key] ?? -.infinity
            guard max(lv, rv) > accountThreshold(key) else { continue }
            let left = sortedPositions(lp[key] ?? [])
            let right = sortedPositions(rp[key] ?? [])
            positions += preferred(left, at: lv, right, at: rv)
        }

        let la = accountRecords(lhs)
        let ra = accountRecords(rhs)
        var accounts: [PortfolioAccount] = []
        for key in Set(la.keys).union(ra.keys).sorted() {
            let lv = lm.accountsUpdatedAt[key] ?? -.infinity
            let rv = rm.accountsUpdatedAt[key] ?? -.infinity
            guard max(lv, rv) > accountThreshold(key),
                  let account = preferredOptional(la[key], at: lv, ra[key], at: rv) else { continue }
            accounts.append(account)
        }
        // A rename is independent of a holdings refresh. Project its latest
        // name onto both positions and trades, because presentation reads it there.
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        positions = positions.map { position in
            accountNames[position.accountKey].map { position.renamedAccount(to: $0) } ?? position
        }
        let lt = transactionRecords(lhs)
        let rt = transactionRecords(rhs)
        var transactions: [LocalTransactionRecord] = []
        for key in Set(lt.keys).union(rt.keys).sorted() {
            let lv = lm.transactionsUpdatedAt[key] ?? -.infinity
            let rv = rm.transactionsUpdatedAt[key] ?? -.infinity
            guard var row = preferredOptional(lt[key], at: lv, rt[key], at: rv),
                  max(lv, rv) > max(accountThreshold(row.accountKey), metadata.deletedTransactions[key] ?? -.infinity)
            else { continue }
            // Lightweight broker refreshes omit settlement Result fields.
            // Keep the known amount/currency pair unless the newer record
            // supplies its own authoritative correction, matching local merge.
            let alternate = row == lt[key] ? rt[key] : lt[key]
            row = row.preservingBrokerResult(from: alternate)
            if let name = accountNames[row.accountKey] { row = row.renamedAccount(to: name) }
            transactions.append(row)
        }
        // The broker's stable fill ID replaces a v3 fingerprint. Keeping both
        // after a cloud union would count the same historical fill twice.
        let migratedIDs = Set(transactions.compactMap(\.legacyTrading212ID))
        transactions.removeAll { $0.tradeID == nil && migratedIDs.contains($0.id) }
        transactions.sort { ($0.date, $0.id) < ($1.date, $1.id) }

        let ls = snapshotRecords(lhs)
        let rs = snapshotRecords(rhs)
        var daily: [String: [String: LocalAccountSnapshotTotals]] = [:]
        for key in Set(ls.keys).union(rs.keys).sorted() {
            let parts = key.components(separatedBy: snapshotSeparator)
            guard parts.count == 2 else { continue }
            let lv = lm.snapshotsUpdatedAt[key] ?? -.infinity
            let rv = rm.snapshotsUpdatedAt[key] ?? -.infinity
            guard max(lv, rv) > accountThreshold(parts[1]),
                  let totals = preferredOptional(ls[key], at: lv, rs[key], at: rv) else { continue }
            daily[parts[0], default: [:]][parts[1]] = totals
        }
        var snapshots = daily.keys.sorted().map { day in
            let totals = daily[day]!
            return LocalPortfolioSnapshotRecord(date: day,
                marketValueUSD: totals.values.reduce(0) { $0 + $1.marketValueUSD },
                costUSD: totals.values.reduce(0) { $0 + $1.costUSD }, accountTotals: totals)
        }
        // Older files contain aggregate history without account allocation.
        // Preserve it verbatim until we have complete per-account totals for
        // that day; splitting it across accounts would invent history.
        let legacyLeft = legacySnapshots(lhs)
        let legacyRight = legacySnapshots(rhs)
        let currentAccountKeys = Set(accounts.map(\.id)).union(positions.map(\.accountKey))
        let deletionThreshold = max(reset, metadata.deletedAccounts.values.max() ?? -.infinity)
        for day in Set(legacyLeft.keys).union(legacyRight.keys) {
            let key = day + snapshotSeparator
            let lv = lm.snapshotsUpdatedAt[key] ?? -.infinity
            let rv = rm.snapshotsUpdatedAt[key] ?? -.infinity
            guard max(lv, rv) > deletionThreshold,
                  let legacy = preferredOptional(legacyLeft[day], at: lv, legacyRight[day], at: rv) else { continue }
            let scopedKeys = Set(daily[day]?.keys.map { $0 } ?? [])
            if scopedKeys.isEmpty || !currentAccountKeys.isSubset(of: scopedKeys) {
                snapshots.removeAll { $0.date == day }
                snapshots.append(legacy)
            }
        }
        snapshots = Array(snapshots.sorted { $0.date < $1.date }.suffix(730))
        // Retain clocks for an empty account snapshot: selling the final
        // holding must not allow an older position to reappear.
        metadata.resetAt = [lm.resetAt, rm.resetAt].compactMap { $0 }.max()
        var result = LocalPortfolioDocument(
            schemaVersion: max(local.schemaVersion, remote.schemaVersion),
            source: Set(positions.map(\.source) + accounts.map(\.source)).sorted().joined(separator: " + "),
            updatedAt: max(local.updatedAt, remote.updatedAt),
            marketDataUpdatedAt: positions.isEmpty ? nil : (positions.allSatisfy { $0.quoteObservedAt != nil }
                ? positions.compactMap(\.quoteObservedAt).min() : nil),
            positions: positions, snapshots: snapshots, transactions: transactions,
            knownAccounts: accounts, syncMetadata: metadata
        )
        result.knownAccounts = result.accounts.sorted { $0.id < $1.id }
        return result
    }

    /// Stamp only records whose content changed in a local commit. Cloud
    /// imports skip this step, otherwise each download creates a fresh edit.
    static func recordingChanges(
        from previous: LocalPortfolioDocument, to document: LocalPortfolioDocument,
        at date: Date = Date()
    ) -> LocalPortfolioDocument {
        let old = normalized(previous)
        var result = document
        var metadata = combined(old.syncMetadata!, document.syncMetadata ?? LocalPortfolioSyncMetadata())
        let time = nextModificationDate(after: old, proposed: max(date, document.updatedAt)).timeIntervalSince1970
        if document.syncMetadata?.resetAt != nil && document.syncMetadata?.resetAt != old.syncMetadata?.resetAt {
            metadata.resetAt = time
        }
        let oldPositions = Dictionary(grouping: old.positions, by: \.accountKey)
        let newPositions = Dictionary(grouping: document.positions, by: \.accountKey)
        for key in Set(oldPositions.keys).union(newPositions.keys) {
            if sortedPositions((oldPositions[key] ?? []).map { $0.renamedAccount(to: "") })
                != sortedPositions((newPositions[key] ?? []).map { $0.renamedAccount(to: "") }) {
                metadata.positionsUpdatedAt[key] = time
            }
        }
        for (key, value) in document.syncMetadata?.positionsUpdatedAt ?? [:]
            where value != old.syncMetadata?.positionsUpdatedAt[key] {
            metadata.positionsUpdatedAt[key] = time
        }
        let oldAccounts = accountRecords(old)
        let newAccounts = accountRecords(document)
        for key in Set(oldAccounts.keys).union(newAccounts.keys) {
            if let account = newAccounts[key] {
                if oldAccounts[key] == nil, metadata.deletedAccounts[key] != nil {
                    // Reusing a removed device-local slot may mean a wholly
                    // different broker account. Preparation must bind it anew.
                    metadata.accountBindings?.removeValue(forKey: key)
                }
                if accountIdentity(account) != oldAccounts[key].map(accountIdentity) {
                    metadata.accountsUpdatedAt[key] = time
                }
            } else {
                metadata.deletedAccounts[key] = time
            }
        }
        let oldTransactions = transactionRecords(old)
        let newTransactions = transactionRecords(document)
        for key in Set(oldTransactions.keys).union(newTransactions.keys) {
            if let row = newTransactions[key] {
                if row.renamedAccount(to: "") != oldTransactions[key]?.renamedAccount(to: "") {
                    metadata.transactionsUpdatedAt[key] = time
                }
            } else {
                metadata.deletedTransactions[key] = time
            }
        }
        let oldSnapshots = snapshotRecords(old)
        for (key, value) in snapshotRecords(document) where value != oldSnapshots[key] {
            metadata.snapshotsUpdatedAt[key] = time
        }
        for (day, value) in legacySnapshots(document) where value != legacySnapshots(old)[day] {
            metadata.snapshotsUpdatedAt[day + snapshotSeparator] = time
        }
        result.syncMetadata = metadata
        if metadata != old.syncMetadata { result.updatedAt = Date(timeIntervalSince1970: time) }
        return result
    }

    static func nextModificationDate(after document: LocalPortfolioDocument, proposed: Date = Date()) -> Date {
        let metadata = document.syncMetadata ?? LocalPortfolioSyncMetadata()
        var lastClock: TimeInterval = document.updatedAt.timeIntervalSince1970
        lastClock = max(lastClock, metadata.resetAt ?? -.infinity)
        let recordClocks: [[String: TimeInterval]] = [
            metadata.positionsUpdatedAt, metadata.accountsUpdatedAt,
            metadata.transactionsUpdatedAt, metadata.snapshotsUpdatedAt,
            metadata.deletedAccounts, metadata.deletedTransactions,
        ]
        for clocks in recordClocks {
            if let latest = clocks.values.max() { lastClock = max(lastClock, latest) }
        }
        // A millisecond survives Date's conversion between Unix and reference
        // epochs, including old imported timestamps near 1970.
        return Date(timeIntervalSince1970: max(proposed.timeIntervalSince1970, lastClock + 0.001))
    }

    static func normalized(_ document: LocalPortfolioDocument) -> LocalPortfolioDocument {
        var result = document
        var metadata = document.syncMetadata ?? LocalPortfolioSyncMetadata()
        let time = document.updatedAt.timeIntervalSince1970
        for key in Set(document.positions.map(\.accountKey)) {
            if metadata.positionsUpdatedAt[key] == nil { metadata.positionsUpdatedAt[key] = time }
        }
        for key in accountRecords(document).keys {
            if metadata.accountsUpdatedAt[key] == nil { metadata.accountsUpdatedAt[key] = time }
            // In legacy files an empty account is still a full snapshot. In
            // new files a registered, not-yet-fetched account has no snapshot.
            if document.syncMetadata == nil && metadata.positionsUpdatedAt[key] == nil {
                metadata.positionsUpdatedAt[key] = time
            }
        }
        for row in document.transactions ?? [] where metadata.transactionsUpdatedAt[row.id] == nil {
            metadata.transactionsUpdatedAt[row.id] = time
        }
        for key in snapshotRecords(document).keys where metadata.snapshotsUpdatedAt[key] == nil {
            metadata.snapshotsUpdatedAt[key] = time
        }
        for day in legacySnapshots(document).keys where metadata.snapshotsUpdatedAt[day + snapshotSeparator] == nil {
            metadata.snapshotsUpdatedAt[day + snapshotSeparator] = time
        }
        result.syncMetadata = metadata
        return result
    }

    static func isUploadable(_ document: LocalPortfolioDocument) -> Bool {
        guard document.isSynthetic != true, !document.isPublicDisclosure else { return false }
        let sources = [document.source] + document.positions.map(\.source)
            + (document.transactions ?? []).map(\.source) + (document.knownAccounts ?? []).map(\.source)
        return sources.allSatisfy { source in
            !["demo", "fake", "simulation", "investor", "假数据", "模拟", PublicInvestorAccountAdapter.source]
                .contains { source.lowercased().contains($0.lowercased()) }
        }
    }

    private static func combined(_ lhs: LocalPortfolioSyncMetadata, _ rhs: LocalPortfolioSyncMetadata) -> LocalPortfolioSyncMetadata {
        LocalPortfolioSyncMetadata(
            positionsUpdatedAt: lhs.positionsUpdatedAt.merging(rhs.positionsUpdatedAt, uniquingKeysWith: max),
            accountsUpdatedAt: lhs.accountsUpdatedAt.merging(rhs.accountsUpdatedAt, uniquingKeysWith: max),
            transactionsUpdatedAt: lhs.transactionsUpdatedAt.merging(rhs.transactionsUpdatedAt, uniquingKeysWith: max),
            snapshotsUpdatedAt: lhs.snapshotsUpdatedAt.merging(rhs.snapshotsUpdatedAt, uniquingKeysWith: max),
            deletedAccounts: lhs.deletedAccounts.merging(rhs.deletedAccounts, uniquingKeysWith: max),
            deletedTransactions: lhs.deletedTransactions.merging(rhs.deletedTransactions, uniquingKeysWith: max),
            accountBindings: (lhs.accountBindings ?? [:]).merging(rhs.accountBindings ?? [:], uniquingKeysWith: { min($0, $1) }),
            resetAt: [lhs.resetAt, rhs.resetAt].compactMap { $0 }.max()
        )
    }

    private static func accountRecords(_ document: LocalPortfolioDocument) -> [String: PortfolioAccount] {
        Dictionary(document.accounts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    private static func accountIdentity(_ account: PortfolioAccount) -> [String] {
        [account.id, account.accountID ?? "", account.source, account.name,
         account.baseCurrency, account.accountTypeOverride ?? ""]
    }

    private static func transactionRecords(_ document: LocalPortfolioDocument) -> [String: LocalTransactionRecord] {
        Dictionary((document.transactions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    private static let snapshotSeparator = "\u{1f}"
    private static func legacySnapshots(_ document: LocalPortfolioDocument) -> [String: LocalPortfolioSnapshotRecord] {
        Dictionary(document.snapshots.filter { $0.accountTotals == nil }.map { ($0.date, $0) },
            uniquingKeysWith: { _, last in last })
    }
    private static func snapshotRecords(_ document: LocalPortfolioDocument) -> [String: LocalAccountSnapshotTotals] {
        var records: [String: LocalAccountSnapshotTotals] = [:]
        let accounts = Set(document.positions.map(\.accountKey))
            .union((document.knownAccounts ?? []).map(\.id)).union((document.transactions ?? []).map(\.accountKey))
        for snapshot in document.snapshots {
            if let totals = snapshot.accountTotals {
                for (key, total) in totals { records[snapshot.date + snapshotSeparator + key] = total }
            } else if accounts.count == 1, let key = accounts.first {
                records[snapshot.date + snapshotSeparator + key] = LocalAccountSnapshotTotals(
                    marketValueUSD: snapshot.marketValueUSD, costUSD: snapshot.costUSD)
            }
        }
        return records
    }

    private static func sortedPositions(_ rows: [LocalPositionRecord]) -> [LocalPositionRecord] {
        rows.sorted { canonical($0) < canonical($1) }
    }

    private static func preferred<T: Encodable>(_ lhs: T, at left: TimeInterval, _ rhs: T, at right: TimeInterval) -> T {
        if left != right { return left > right ? lhs : rhs }
        // Equal clocks can happen during concurrent edits. A stable content
        // ordering makes both directions converge instead of bouncing forever.
        return canonical(lhs) >= canonical(rhs) ? lhs : rhs
    }

    private static func preferredOptional<T: Encodable>(_ lhs: T?, at left: TimeInterval, _ rhs: T?, at right: TimeInterval) -> T? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return preferred(lhs, at: left, rhs, at: right)
    }

    private static func canonical<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
