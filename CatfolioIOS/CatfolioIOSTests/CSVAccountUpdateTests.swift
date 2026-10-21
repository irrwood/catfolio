import XCTest
@testable import CatfolioIOS

final class CSVAccountUpdateTests: XCTestCase {
    private let header = "Date,Action,Ticker,Quantity,Price,Currency,Reference\n"

    private func records(_ text: String, account: String = "A") throws -> [LocalTransactionRecord] {
        try LocalCSVImporter.parse(Data((header + text).utf8), rebuildPositions: false).1.map {
            $0.assignedAccount(id: account, name: account, source: "CSV")
        }
    }

    private func document(_ text: String, account: String = "A") throws -> LocalPortfolioDocument {
        let rows = try records(text, account: account)
        let positions = try LocalCSVImporter.positions(from: rows, splitCatalog: nil).map {
            $0.assignedAccount(id: account, name: account)
        }
        return LocalPortfolioDocument(source: "CSV", updatedAt: Date(), positions: positions,
                                      snapshots: [], transactions: rows)
    }

    private func plan(_ text: String, previous: LocalPortfolioDocument, mode: CSVImportMode = .merge,
                      info: CSVImportInfo? = nil, sourceAccountID: String? = nil) throws -> CSVAccountUpdatePlan {
        let data = Data((header + text).utf8)
        let (_, rows, parsed) = try LocalCSVImporter.parse(data, rebuildPositions: false)
        return .init(baseline: CSVAccountState(document: previous, key: "CSV|A"), accountKey: "CSV|A",
            incoming: rows.map { $0.assignedAccount(id: "A", name: "A") }, names: [:], parsedResult: parsed,
            filename: "activity.csv", format: "交易记录 CSV", fileHash: CSVTransactionMerger.digest(data),
            sourceAccountID: sourceAccountID, previousInfo: info, mode: mode)
    }

    func testRepeatedFullExportAndIncrementalSellProduceSameLedger() throws {
        let old = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        let full = try plan("2025-01-02,BUY,TEST,10,100,USD,b1\n2025-02-03,SELL,TEST,3,130,USD,s1", previous: old).preview(splitCatalog: nil)
        let incremental = try plan("2025-02-03,SELL,TEST,3,130,USD,s1", previous: old).preview(splitCatalog: nil)
        XCTAssertTrue(full.canCommit)
        XCTAssertTrue(incremental.canCommit, incremental.problem ?? "")
        XCTAssertEqual(full.transactions, incremental.transactions)
        XCTAssertEqual(full.positions.first?.shares, 7)
        XCTAssertEqual(full.positions.first?.averageCost, 100)
        XCTAssertEqual(full.counts?.duplicate, 1)
        XCTAssertEqual(full.counts?.added, 1)
        XCTAssertEqual(incremental.counts?.added, 1)
    }

    func testProviderIDCorrectionRequiresExplicitChoice() throws {
        let old = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        let update = try plan("2025-01-02,BUY,TEST,12,110,USD,b1", previous: old)
        let unresolved = update.preview(splitCatalog: nil)
        XCTAssertFalse(unresolved.canCommit)
        XCTAssertEqual(unresolved.conflicts.count, 1)
        XCTAssertFalse(unresolved.conflicts[0].ambiguous)
        let kept = update.preview(choices: ["row-0": .keepExisting], splitCatalog: nil)
        XCTAssertEqual(kept.positions.first?.shares, 10)
        let corrected = update.preview(choices: ["row-0": .useIncoming], splitCatalog: nil)
        XCTAssertTrue(corrected.canCommit)
        XCTAssertEqual(corrected.positions.first?.shares, 12)
        XCTAssertEqual(corrected.positions.first?.averageCost, 110)
        XCTAssertEqual(corrected.counts?.updated, 1)
        XCTAssertEqual(corrected.transactions.first?.id, old.transactions?.first?.id)
    }

    func testIdenticalFillsWithDifferentProviderIDsAreBothRetained() throws {
        let old = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        let preview = try plan("2025-01-02,BUY,TEST,10,100,USD,b2", previous: old).preview(splitCatalog: nil)
        XCTAssertTrue(preview.canCommit)
        XCTAssertEqual(preview.positions.first?.shares, 20)
        XCTAssertEqual(preview.transactions.count, 2)
    }

    func testRowsWithoutProviderIDsAreNotSilentlyCollapsed() throws {
        let text = "2025-01-02,BUY,TEST,10,100,USD,\n2025-01-02,BUY,TEST,10,100,USD,"
        let old = try document(text)
        XCTAssertEqual(old.positions.first?.shares, 20)
        let update = try plan(text, previous: old)
        XCTAssertFalse(update.preview(splitCatalog: nil).canCommit)
        let kept = update.preview(choices: ["row-0": .keepExisting, "row-1": .keepExisting], splitCatalog: nil)
        XCTAssertEqual(kept.positions.first?.shares, 20)
        let both = update.preview(choices: ["row-0": .addBoth, "row-1": .addBoth], splitCatalog: nil)
        XCTAssertEqual(both.positions.first?.shares, 40)
        XCTAssertEqual(Set(both.transactions.map(\.id)).count, 4)
        let info = CSVImportInfo(importedAt: Date(), filename: "activity.csv", format: "交易记录 CSV",
            fileHash: update.fileHash, sourceAccountID: nil, firstDate: "2025-01-02", lastDate: "2025-01-02",
            counts: CSVImportCounts())
        let repeated = try plan(text, previous: old, info: info).preview(splitCatalog: nil)
        XCTAssertTrue(repeated.canCommit)
        XCTAssertEqual(repeated.counts?.duplicate, 2)
        XCTAssertEqual(repeated.positions.first?.shares, 20)
    }

    func testManualTransactionsSurviveMergeAndFullRebuild() throws {
        var old = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        let manual = LocalTransactionRecord(date: "2025-02-03", action: "BUY", ticker: "MANUAL",
            quantity: 2, price: 30, currency: "USD", source: "CSV", accountID: "A", accountName: "A", entryMethod: "manual")
        old.transactions?.append(manual)
        for mode in CSVImportMode.allCases {
            let preview = try plan("2025-03-03,BUY,NEW,1,20,USD,b2", previous: old, mode: mode).preview(splitCatalog: nil)
            XCTAssertTrue(preview.canCommit)
            XCTAssertTrue(preview.transactions.contains(manual))
            XCTAssertEqual(preview.positions.first(where: { $0.ticker == "MANUAL" })?.shares, 2)
            XCTAssertEqual(preview.transactions.contains { $0.tradeID == "b1" }, mode == .merge)
        }
    }

    func testSkippedRowsAreAllowedInMergeButPreventFullRebuild() throws {
        let old = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        let text = "2025-02-03,BUY,NEW,1,20,USD,b2\n2025-02-04,BUY,TEST,invalid,100,USD,b3"
        let merged = try plan(text, previous: old).preview(splitCatalog: nil)
        XCTAssertTrue(merged.canCommit)
        XCTAssertEqual(merged.result.skippedRowCount, 1)
        XCTAssertEqual(merged.positions.first(where: { $0.ticker == "TEST" })?.shares, 10)
        XCTAssertFalse(try plan(text, previous: old, mode: .rebuild).preview(splitCatalog: nil).canCommit)
    }

    func testOversellIsRejectedAfterCombiningWithOldTransactions() throws {
        let old = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        let preview = try plan("2025-02-03,SELL,TEST,11,120,USD,s1", previous: old).preview(splitCatalog: nil)
        XCTAssertFalse(preview.canCommit)
        XCTAssertNotNil(preview.problem)
    }

    func testCashCorrectionCountsAsAConflictEvenWithUnchangedPrice() throws {
        let old = try records("2025-01-02,BUY,TEST,10,100,USD,b1")
        var corrected = old[0]
        corrected.cashPostings = [.init(currency: "USD", amount: -1_005)]
        let result = CSVTransactionMerger.merge(existing: old, incoming: [corrected], mode: .merge)
        XCTAssertTrue(result.unresolved)
        XCTAssertEqual(result.conflicts.count, 1)
    }

    func testPartialExistingLedgerCannotEraseSnapshotHoldings() throws {
        var old = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        old.transactions = try records("2025-01-02,BUY,TEST,5,100,USD,b0")
        let incremental = try plan("2025-02-03,BUY,NEW,1,20,USD,b2", previous: old).preview(splitCatalog: nil)
        XCTAssertFalse(incremental.canCommit)
        let rebuilt = try plan("2025-01-02,BUY,TEST,10,100,USD,b1\n2025-02-03,BUY,NEW,1,20,USD,b2",
                               previous: old, mode: .rebuild).preview(splitCatalog: nil)
        XCTAssertTrue(rebuilt.canCommit)
        XCTAssertEqual(rebuilt.positions.first { $0.ticker == "TEST" }?.shares, 10)
    }

    private func store() throws -> (LocalPortfolioStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("csv-update-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (LocalPortfolioStore(fileURL: folder.appendingPathComponent("portfolio.json")), folder)
    }

    func testCommitPersistsReceiptAndUndoPreservesAnotherAccount() async throws {
        let (store, folder) = try store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        _ = try await store.replace(positions: original.positions, source: "CSV", transactions: original.transactions)
        let before = try await store.load()
        let preview = try plan("2025-02-03,SELL,TEST,3,120,USD,s1", previous: before).preview(splitCatalog: nil)
        let (_, result) = try await store.commitCSVPreview(preview, accountName: "A")
        let receipt = try await store.csvImportJournal(accountKey: "CSV|A")
        XCTAssertEqual(receipt?.info?.firstDate, "2025-01-02")
        XCTAssertEqual(receipt?.info?.lastDate, "2025-02-03")
        XCTAssertEqual(receipt?.info?.counts.added, 1)
        XCTAssertEqual(result.backupCreated, true)

        let other = try document("2025-03-03,BUY,OTHER,4,20,USD,other", account: "B")
        _ = try await store.replace(positions: other.positions, source: "CSV",
                                   transactions: other.transactions, replacingAccountsOnly: true)
        let restored = try await store.undoCSVImport(accountKey: "CSV|A", id: XCTUnwrap(result.undoID))
        XCTAssertEqual(restored.positions.first { $0.accountID == "A" }?.shares, 10)
        XCTAssertEqual(restored.positions.first { $0.accountID == "B" }?.shares, 4)
        XCTAssertEqual(restored.transactions?.filter { $0.accountID == "A" }, original.transactions)
        let afterUndo = try await store.csvImportJournal(accountKey: "CSV|A")
        XCTAssertNil(afterUndo?.undo)
    }

    func testStalePreviewAndUndoCannotOverwriteLaterLedgerEdits() async throws {
        let (store, folder) = try store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        _ = try await store.replace(positions: original.positions, source: "CSV", transactions: original.transactions)
        let before = try await store.load()
        let preview = try plan("2025-02-03,BUY,NEW,1,20,USD,b2", previous: before).preview(splitCatalog: nil)
        let (_, result) = try await store.commitCSVPreview(preview, accountName: "A")
        do {
            _ = try await store.commitCSVPreview(preview, accountName: "A")
            XCTFail("A stale preview must not be committed")
        } catch CSVUpdateError.accountChanged {}
        _ = try await store.appendHistoricalTransaction(LocalTransactionRecord(
            date: "2025-03-03", action: "BUY", ticker: "MANUAL", quantity: 1, price: 20,
            currency: "USD", source: "CSV", accountID: "A", accountName: "A", entryMethod: "manual"))
        do {
            _ = try await store.undoCSVImport(accountKey: "CSV|A", id: XCTUnwrap(result.undoID))
            XCTFail("Undo must not erase later manual entries")
        } catch CSVUpdateError.undoUnavailable {}
    }

    func testQuoteRefreshDoesNotInvalidatePreviewOrUndoAndKeepsLatestPrice() async throws {
        let (store, folder) = try store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        _ = try await store.replace(positions: original.positions, source: "CSV", transactions: original.transactions)
        let before = try await store.load()
        let preview = try plan("2025-02-03,SELL,TEST,3,120,USD,s1", previous: before).preview(splitCatalog: nil)
        let observed = Date()
        _ = try await store.updateMarketQuotes(["TEST|USD": .init(price: 150, observedAt: observed)])
        let (saved, result) = try await store.commitCSVPreview(preview, accountName: "A")
        XCTAssertEqual(saved.positions.first?.shares, 7)
        XCTAssertEqual(saved.positions.first?.quotePrice, 150)
        let newer = observed.addingTimeInterval(1)
        _ = try await store.updateMarketQuotes(["TEST|USD": .init(price: 155, observedAt: newer)])
        let undone = try await store.undoCSVImport(accountKey: "CSV|A", id: XCTUnwrap(result.undoID))
        XCTAssertEqual(undone.positions.first?.shares, 10)
        XCTAssertEqual(undone.positions.first?.quotePrice, 155)
    }

    func testFirstImportCreatesOneAccountAndRejectsAnotherBrokerAccountID() async throws {
        let (store, folder) = try store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let initial = try plan("2025-01-02,BUY,TEST,10,100,USD,b1", previous: .empty,
                               sourceAccountID: "broker-A").preview(splitCatalog: nil)
        let (created, result) = try await store.commitCSVPreview(initial, accountName: "My account")
        XCTAssertEqual(created.accounts.count, 1)
        XCTAssertEqual(created.accounts.first?.name, "My account")
        let wrong = try plan("2025-02-03,BUY,NEW,1,20,USD,b2", previous: created,
                            sourceAccountID: "broker-B").preview(splitCatalog: nil)
        do {
            _ = try await store.commitCSVPreview(wrong, accountName: "My account")
            XCTFail("A different broker account must not be merged")
        } catch CSVUpdateError.wrongAccount {}
        let undone = try await store.undoCSVImport(accountKey: "CSV|A", id: XCTUnwrap(result.undoID))
        XCTAssertTrue(undone.accounts.isEmpty)
        XCTAssertTrue(undone.transactions?.isEmpty ?? true)
    }

    func testSourceAccountIDHandlesBOMAndLegacyDefaultAccountStaysTheSame() async throws {
        let data = Data("\u{feff}Account,Date,Action,Ticker,Quantity,Price,Currency,Reference\nbroker-A,2025-01-02,BUY,TEST,10,100,USD,b1".utf8)
        XCTAssertEqual(LocalCSVImporter.sourceAccountID(in: data), "broker-A")
        let (store, folder) = try store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (positions, rows, parsed) = try LocalCSVImporter.parse(data, splitCatalog: nil)
        let saved = try await store.replace(positions: positions, source: "CSV", transactions: rows)
        let plan = CSVAccountUpdatePlan(baseline: .init(document: saved, key: "CSV|default"),
            accountKey: "CSV|default", incoming: rows, names: parsed.securityNames, parsedResult: parsed,
            filename: "again.csv", format: "交易记录 CSV", fileHash: CSVTransactionMerger.digest(data),
            sourceAccountID: "broker-A", previousInfo: nil)
        let (updated, result) = try await store.commitCSVPreview(plan.preview(splitCatalog: nil), accountName: "CSV")
        XCTAssertEqual(updated.accounts.map(\.id), ["CSV|default"])
        XCTAssertEqual(result.importCounts?.duplicate, 1)
        XCTAssertEqual(updated.positions.first?.shares, 10)
    }

    func testSellingTheLastHoldingKeepsAccountAndCSVSource() async throws {
        let (store, folder) = try store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try document("2025-01-02,BUY,TEST,10,100,USD,b1")
        _ = try await store.replace(positions: original.positions, source: "CSV", transactions: original.transactions)
        let before = try await store.load()
        let preview = try plan("2025-02-03,SELL,TEST,10,120,USD,s1", previous: before).preview(splitCatalog: nil)
        let (closed, _) = try await store.commitCSVPreview(preview, accountName: "A")
        XCTAssertTrue(closed.positions.isEmpty)
        XCTAssertEqual(closed.transactions?.count, 2)
        XCTAssertEqual(closed.accounts.map(\.id), ["CSV|A"])
        XCTAssertEqual(closed.source, "CSV")
    }
}
