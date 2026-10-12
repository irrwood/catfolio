// Audit-only reproductions. Copy into CatfolioIOSViewTests to run; these
// assertions describe the proposed safe behavior and fail on the audit build.
import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class AppAuditReproductionTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testStaleYahooSuccessShouldTryNewerMassiveData() async throws {
        let cache = LocalIntradayPriceCache(cacheURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-intraday-\(UUID()).json"), writeData: { _, _ in })
        let old = MarketIntradayBar(timestamp: date("2026-10-09T15:55:00-04:00"), close: 100)
        let current = MarketIntradayBar(timestamp: date("2026-10-12T08:00:00-04:00"), close: 105)
        var usedMassive = false
        let bars = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL", forceRefresh: true,
            includingExtendedHours: true, cache: cache, yahoo: { [old] }, massive: {
                usedMassive = true
                return [current]
            })
        XCTAssertTrue(usedMassive, "A successful response containing only old regular bars bypasses fallback")
        XCTAssertEqual(bars.last?.close, 105)
    }

    func testHeaderAndChartShouldAgreeWhenRegularSessionHasNoNewPrint() {
        let post = date("2026-10-09T19:55:00-04:00")
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-10-08", close: 95), .init(dateText: "2026-10-09", close: 100)],
            intradayPoints: [], trades: [],
            extendedHoursPoints: [.init(dateText: String(Int(post.timeIntervalSince1970)), close: 110, timestamp: post)])
        let now = date("2026-10-12T10:00:00-04:00")
        let headerPrice = history.extendedHoursQuote(at: now)?.price ?? history.latestAvailablePrice
        XCTAssertEqual(headerPrice, history.chartDailyDisplayPoints.last?.close,
            "At regular-session open the header drops the post-market quote but the chart keeps it")
    }

    func testInvalidCSVRowShouldNotEraseAnExistingPosition() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-ledger-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalPortfolioStore(fileURL: url)
        let header = "Date,Action,Ticker,Quantity,Price,Currency\n"
        let initial = header + "2026-10-01,BUY,AAPL,10,100,USD\n2026-10-01,BUY,MSFT,5,200,USD\n"
        let partial = header + "2026-10-01,BUY,AAPL,broken,100,USD\n2026-10-01,BUY,MSFT,5,200,USD\n"
        func parsed(_ text: String) throws -> ([LocalPositionRecord], [LocalTransactionRecord], CSVImportResult) {
            let (positions, transactions, result) = try LocalCSVImporter.parse(Data(text.utf8), splitCatalog: nil)
            return (positions.map { $0.assignedAccount(id: "audit", name: "Audit", source: "CSV") },
                    transactions.map { $0.assignedAccount(id: "audit", name: "Audit", source: "CSV") }, result)
        }
        let first = try parsed(initial)
        _ = try await store.replace(positions: first.0, source: "CSV", transactions: first.1,
                                    replacingAccountsOnly: true)
        let second = try parsed(partial)
        XCTAssertFalse(second.2.warnings.isEmpty)
        // This is the same unconditional parse -> replace path as AppModel.importCSV.
        let saved = try await store.replace(positions: second.0, source: "CSV", transactions: second.1,
                                            replacingAccountsOnly: true)
        XCTAssertTrue(saved.positions.contains { $0.ticker == "AAPL" },
            "The skipped AAPL row deleted the original position before the warning is shown")
    }

    func testHongKongOrdinaryStockShouldBeClosedDuringLunch() {
        XCTAssertFalse(MarketHours.isOpen(ticker: "0700.HK", at: date("2026-10-12T12:30:00+08:00")))
    }

    func testNYSEShouldBeClosedOnChristmasAndAfterEarlyClose() {
        XCTAssertFalse(MarketHours.isOpen(ticker: "AAPL", at: date("2026-12-25T10:00:00-05:00")))
        XCTAssertFalse(MarketHours.isOpen(ticker: "AAPL", at: date("2026-11-27T14:00:00-05:00")))
    }
}
