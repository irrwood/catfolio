import XCTest
@testable import CatfolioIOS

/// A CSV is read and compared with its account before anything is written,
/// and the portfolio is copied before an import replaces part of it. A row the
/// importer cannot read used to drop that holding from the account silently.
final class CSVImportPreviewTests: XCTestCase {
    private func position(_ ticker: String, shares: Double, account: String = "A") -> LocalPositionRecord {
        LocalPositionRecord(ticker: ticker, name: ticker, shares: shares, averageCost: 10, currency: "USD",
                            quotePrice: 10, quoteCurrency: "USD", source: "CSV", openedDate: "2024-01-02",
                            accountID: account, accountName: account, accountCurrency: "USD", brokerPnl: nil,
                            brokerPnlCurrency: nil, brokerFxPnl: nil, brokerFxPnlCurrency: nil, fxPnl: nil,
                            fxPnlCurrency: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }

    func testAnUnreadableRowIsCountedAndItsHoldingShowsAsRemoved() throws {
        let csv = """
        Date,Action,Ticker,Quantity,Price,Currency
        2025-01-02,BUY,AAPL,10,150,USD
        2025-01-03,BUY,MSFT,abc,300,USD
        2025-01-06,BUY,NVDA,5,500,USD
        """
        let (incoming, _, result) = try LocalCSVImporter.parse(Data(csv.utf8))
        XCTAssertEqual(result.skippedRowCount, 1)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.backupCreated, false, "Parsing alone backs nothing up")

        let previous = [position("AAPL", shares: 10), position("MSFT", shares: 4), position("NVDA", shares: 5)]
        let comparison = CSVImportPreview.changes(previous: previous, incoming: incoming)
        XCTAssertEqual(comparison.unchanged, 2)
        XCTAssertEqual(comparison.changes, [.init(ticker: "MSFT", sharesBefore: 4, sharesAfter: nil)])
        XCTAssertEqual(comparison.changes.first?.kind, .removed)
    }

    func testChangesListRemovalsFirstThenChangesThenAdditions() {
        let previous = [position("AAA", shares: 1), position("BBB", shares: 2), position("CCC", shares: 3)]
        let incoming = [position("BBB", shares: 2.5), position("CCC", shares: 3), position("DDD", shares: 4)]
        let comparison = CSVImportPreview.changes(previous: previous, incoming: incoming)
        XCTAssertEqual(comparison.changes.map(\.ticker), ["AAA", "BBB", "DDD"])
        XCTAssertEqual(comparison.changes.map(\.kind), [.removed, .changed, .added])
        XCTAssertEqual(comparison.unchanged, 1)
    }

    func testLotsOfOneTickerAreComparedTogether() {
        let previous = [position("AAPL", shares: 4), position("AAPL", shares: 6)]
        let comparison = CSVImportPreview.changes(previous: previous, incoming: [position("AAPL", shares: 10)])
        XCTAssertTrue(comparison.changes.isEmpty)
        XCTAssertEqual(comparison.unchanged, 1)
    }

    func testBackupCopiesThePortfolioAndLeavesItInPlace() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("csv-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("portfolio.json")
        let store = LocalPortfolioStore(fileURL: url)

        let nothingYet = try await store.backupPortfolio(reason: "before-csv")
        XCTAssertNil(nothingYet, "No saved portfolio, nothing to back up")

        _ = try await store.replace(positions: [position("AAPL", shares: 10), position("TSLA", shares: 1, account: "B")],
                                    source: "CSV")
        let original = try Data(contentsOf: url)
        let backup = try await XCTUnwrapAsync(try await store.backupPortfolio(reason: "before-csv"))
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try Data(contentsOf: url), original, "The live portfolio stays where it was")
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("portfolio-before-csv-"))

        let accountA = try await store.positions(accountKey: "CSV|A")
        XCTAssertEqual(accountA.map(\.ticker), ["AAPL"])
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
