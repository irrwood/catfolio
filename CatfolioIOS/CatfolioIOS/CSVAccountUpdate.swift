import Foundation
import CryptoKit

enum CSVImportMode: String, CaseIterable {
    case merge, rebuild
}

enum CSVConflictChoice: String {
    case keepExisting, useIncoming, addBoth
}

struct CSVTransactionConflict: Identifiable {
    let id: String
    let existing: [LocalTransactionRecord]
    let incoming: LocalTransactionRecord
    let ambiguous: Bool
    let choice: CSVConflictChoice?

    var allowsReplacement: Bool {
        existing.count == 1 && existing.first?.entryMethod != "manual"
    }
}

struct CSVImportCounts: Codable, Equatable {
    var added = 0
    var duplicate = 0
    var updated = 0
    var retained = 0
}

enum CSVTransactionMerger {
    struct Result {
        var transactions: [LocalTransactionRecord]
        var conflicts: [CSVTransactionConflict]
        var counts: CSVImportCounts
        var unresolved: Bool { conflicts.contains { $0.choice == nil } }
    }

    /// Provider IDs identify fills. Generated CSV IDs identify rows, so an
    /// overlap without a provider ID needs a decision unless this exact file
    /// was already imported. Occurrences within a file are never collapsed.
    static func merge(existing: [LocalTransactionRecord], incoming: [LocalTransactionRecord],
                      mode: CSVImportMode, sameFile: Bool = false,
                      choices: [String: CSVConflictChoice] = [:]) -> Result {
        var rows = mode == .merge ? existing : existing.filter { $0.entryMethod == "manual" }
        var ids = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let buckets = Dictionary(grouping: rows.indices, by: { bucket(rows[$0]) })
        var consumed = Set<Int>()
        var conflicts: [CSVTransactionConflict] = []
        var counts = CSVImportCounts()

        func append(_ row: LocalTransactionRecord, occurrence: Int) {
            var candidate = row
            if ids[candidate.id] != nil {
                var suffix = occurrence
                repeat {
                    candidate = row.csvCopy(tradeID: "csv-added-\(fingerprint(row))-\(suffix)")
                    suffix += 1
                } while ids[candidate.id] != nil
            }
            ids[candidate.id] = rows.count
            rows.append(candidate)
            counts.added += 1
        }

        for (offset, row) in incoming.enumerated() {
            let explicit = hasProviderID(row)
            var candidates: [Int] = []
            if explicit, let index = ids[row.id] {
                candidates = [index]
                if equivalent(rows[index], row), rows[index].entryMethod != "manual" {
                    counts.duplicate += 1
                    consumed.insert(index)
                    continue
                }
            } else {
                let possible = (buckets[bucket(row)] ?? []).filter {
                    !consumed.contains($0) && (!explicit || !hasProviderID(rows[$0]) || rows[$0].entryMethod == "manual")
                }
                let exact = possible.filter { equivalent(rows[$0], row) }
                candidates = exact.isEmpty ? possible : [exact[0]]
                if sameFile, let index = candidates.first, equivalent(rows[index], row),
                   rows[index].entryMethod != "manual" {
                    counts.duplicate += 1
                    consumed.insert(index)
                    continue
                }
            }
            guard !candidates.isEmpty else {
                append(row, occurrence: offset)
                continue
            }
            let key = "row-\(offset)"
            let ambiguous = !explicit || candidates.contains { !hasProviderID(rows[$0]) || rows[$0].entryMethod == "manual" }
            let canReplace = candidates.count == 1 && rows[candidates[0]].entryMethod != "manual"
            var choice = choices[key]
            if choice == .useIncoming && !canReplace { choice = nil }
            if choice == .addBoth && !ambiguous { choice = nil }
            conflicts.append(.init(id: key, existing: candidates.map { rows[$0] }, incoming: row,
                                   ambiguous: ambiguous, choice: choice))
            switch choice {
            case .keepExisting:
                counts.retained += 1
                candidates.forEach { consumed.insert($0) }
            case .useIncoming:
                let index = candidates[0]
                // Keep the persisted identity so cloud merging sees a revision.
                rows[index] = row.csvCopy(tradeID: rows[index].tradeID)
                counts.updated += 1
                consumed.insert(index)
            case .addBoth:
                append(row, occurrence: offset)
                candidates.forEach { consumed.insert($0) }
            case nil:
                // Provisional only; unresolved previews cannot be committed.
                candidates.forEach { consumed.insert($0) }
            }
        }
        // Avoid disturbing the order or identities of retained manual entries.
        return .init(transactions: rows, conflicts: conflicts, counts: counts)
    }

    static func hasProviderID(_ row: LocalTransactionRecord) -> Bool {
        guard let id = row.tradeID, !id.isEmpty else { return false }
        return !id.hasPrefix("csv-") && row.entryMethod != "manual"
    }

    static func equivalent(_ lhs: LocalTransactionRecord, _ rhs: LocalTransactionRecord) -> Bool {
        fingerprint(lhs) == fingerprint(rhs)
    }

    static func fingerprint(_ row: LocalTransactionRecord) -> String {
        // Explicitly omit import identity and account nickname.
        let values: [String] = [row.date, row.executedAt ?? "", row.action.uppercased(), row.ticker.uppercased(),
                      String(row.quantity), String(row.price), row.currency.uppercased(),
                      row.brokerFXRate.map { String($0) } ?? "",
                      row.realisedProfitLoss.map { String($0) } ?? "", row.realisedProfitLossCurrency ?? ""]
        let cash = (row.cashPostings ?? []).map { "\($0.currency):\($0.amount)" }.sorted()
        return digest((values + cash).map { "\($0.utf8.count):\($0)" }.joined())
    }

    private static func bucket(_ row: LocalTransactionRecord) -> String {
        [row.date, row.action.uppercased(), row.ticker.uppercased(), row.currency.uppercased()].joined(separator: "|")
    }

    static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension LocalTransactionRecord {
    fileprivate func csvCopy(tradeID: String?) -> Self {
        .init(date: date, action: action, ticker: ticker, quantity: quantity, price: price,
              currency: currency, source: source, accountID: accountID, accountName: accountName,
              tradeID: tradeID, brokerFXRate: brokerFXRate, entryMethod: entryMethod,
              realisedProfitLoss: realisedProfitLoss, realisedProfitLossCurrency: realisedProfitLossCurrency,
              executedAt: executedAt, cashPostings: cashPostings)
    }
}

/// Account-scoped optimistic concurrency: refreshing market prices is safe;
/// another import, manual edit, rename or account deletion invalidates a preview.
struct CSVAccountState: Codable {
    let positions: [LocalPositionRecord]
    let transactions: [LocalTransactionRecord]
    let account: PortfolioAccount?

    init(document: LocalPortfolioDocument, key: String) {
        positions = document.positions.filter { $0.accountKey == key }
        transactions = (document.transactions ?? []).filter { $0.accountKey == key }
        account = document.accounts.first { $0.id == key }
    }

    var fingerprint: String {
        let positions = positions.map {
            [$0.ticker, String($0.shares), String($0.averageCost), $0.currency,
             $0.accountName ?? "", $0.openedDate ?? ""].joined(separator: "|")
        }.sorted()
        let transactions = transactions.map {
            $0.id + "|" + ($0.entryMethod ?? "") + "|" + CSVTransactionMerger.fingerprint($0)
        }.sorted()
        let account = [account?.id ?? "", account?.name ?? "", account?.accountTypeOverride ?? ""]
        return CSVTransactionMerger.digest((positions + transactions + account).joined(separator: "\n"))
    }
}

struct CSVImportInfo: Codable {
    let importedAt: Date
    let filename: String
    let format: String
    let fileHash: String
    let sourceAccountID: String?
    let firstDate: String?
    let lastDate: String?
    let counts: CSVImportCounts
}

struct CSVImportUndo: Codable {
    let id: UUID
    let accountKey: String
    let before: CSVAccountState
    let afterFingerprint: String
    let info: CSVImportInfo
    let previousInfo: CSVImportInfo?
}

struct CSVImportJournal: Codable {
    var info: CSVImportInfo?
    var undo: CSVImportUndo?
}

struct CSVAccountUpdatePlan {
    let baseline: CSVAccountState
    let accountKey: String
    let incoming: [LocalTransactionRecord]
    let names: [String: String]
    let parsedResult: CSVImportResult
    let filename: String
    let format: String
    let fileHash: String
    let sourceAccountID: String?
    let previousInfo: CSVImportInfo?
    var mode: CSVImportMode = .merge

    func preview(choices: [String: CSVConflictChoice] = [:],
                 splitCatalog: StockSplitCatalog? = try? StockSplitCatalog.bundled.get()) -> CSVImportPreview {
        let merged = CSVTransactionMerger.merge(existing: baseline.transactions, incoming: incoming,
            mode: mode, sameFile: previousInfo?.fileHash == fileHash, choices: choices)
        var problem: String?
        var positions = baseline.positions
        if !merged.unresolved {
            do {
                if mode == .merge && !baseline.positions.isEmpty {
                    // A broker snapshot may predate the available fills.
                    // Missing opening trades must not make held shares vanish.
                    // Manual historical supplements may intentionally differ
                    // from the unchanged broker snapshot.
                    let all = try? LocalCSVImporter.positions(from: baseline.transactions, splitCatalog: splitCatalog)
                    let imported = try? LocalCSVImporter.positions(
                        from: baseline.transactions.filter { $0.entryMethod != "manual" }, splitCatalog: splitCatalog)
                    if !Self.sameBalances(all ?? [], baseline.positions)
                        && !Self.sameBalances(imported ?? [], baseline.positions) {
                        throw LocalPortfolioError.invalidCSV(L10n.text("已有交易记录无法重建当前持仓，请导入完整交易历史并选择完整重建。"))
                    }
                }
                positions = try LocalCSVImporter.positions(from: merged.transactions, names: names, splitCatalog: splitCatalog)
                let account = baseline.account
                let reference = incoming.first
                positions = positions.map { position in
                    let assigned = position.assignedAccount(id: account?.accountID ?? reference?.accountID,
                        name: account?.name ?? reference?.accountName ?? "CSV", source: account?.source ?? reference?.source ?? "CSV")
                    if let old = baseline.positions.first(where: {
                        $0.ticker == assigned.ticker && $0.quoteCurrency == assigned.quoteCurrency
                    }), let observed = old.quoteObservedAt {
                        return assigned.withQuotePrice(old.quotePrice, observedAt: observed)
                    }
                    return assigned
                }
            } catch { problem = error.localizedDescription }
        }
        if mode == .rebuild && parsedResult.skippedRowCount > 0 {
            problem = L10n.text("完整重建要求所有记录均可读取，请先修正文件中的无效行。")
        }
        let difference = CSVImportPreview.changes(previous: baseline.positions, incoming: positions)
        let result = CSVImportResult(ok: true, holdingsCount: positions.count, transactionsCount: merged.transactions.count,
            backupCreated: false, warnings: parsedResult.warnings,
            holdings: positions.map { .init(ticker: $0.ticker, name: $0.name, shares: $0.shares, averageCost: $0.averageCost, currency: $0.currency) },
            skippedRowCount: parsedResult.skippedRowCount)
        return CSVImportPreview(positions: positions, transactions: merged.transactions, result: result,
            accountKey: accountKey, changes: merged.unresolved ? [] : difference.changes,
            unchangedCount: merged.unresolved ? 0 : difference.unchanged,
            updatePlan: self, conflicts: merged.conflicts, counts: merged.counts, problem: problem)
    }

    private static func sameBalances(_ lhs: [LocalPositionRecord], _ rhs: [LocalPositionRecord]) -> Bool {
        func amounts(_ rows: [LocalPositionRecord]) -> [String: Double] {
            rows.reduce(into: [:]) { $0["\($1.ticker)|\($1.currency)", default: 0] += $1.shares }
        }
        let left = amounts(lhs), right = amounts(rhs)
        return Set(left.keys).union(right.keys).allSatisfy {
            abs((left[$0] ?? 0) - (right[$0] ?? 0)) <= max(1e-6, abs(right[$0] ?? 0) * 1e-8)
        }
    }
}

enum CSVUpdateError: LocalizedError {
    case reviewRequired, accountChanged, wrongAccount, undoUnavailable

    var errorDescription: String? {
        switch self {
        case .reviewRequired: L10n.text("请先处理待确认记录，再导入。")
        case .accountChanged: L10n.text("账户记录已发生变化，请重新选择文件并检查预览。")
        case .wrongAccount: L10n.text("CSV 的账户编号与此前导入不一致，请选择对应账户。")
        case .undoUnavailable: L10n.text("此账户在导入后已有其他修改，无法直接撤销。导入前的备份仍保留在本机。")
        }
    }
}
