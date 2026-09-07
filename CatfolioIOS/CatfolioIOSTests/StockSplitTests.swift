import XCTest
@testable import CatfolioIOS

/// Splits are the one corporate action that silently breaks lot matching: the
/// broker reports post-split share counts while the ledger holds pre-split
/// purchases, so FIFO finds nothing and reports a real disposal as having no
/// cost basis.
final class StockSplitCatalogTests: XCTestCase {

    private func catalog() throws -> StockSplitCatalog {
        try StockSplitCatalog.bundled.get()
    }

    func testCatalogCoversTheWholeMarketNotOnePortfolio() throws {
        let catalog = try catalog()

        XCTAssertGreaterThan(catalog.tickerCount, 15_000)
        XCTAssertGreaterThan(catalog.eventCount, 25_000)
    }

    /// Known splits, checkable against public record.
    func testWellKnownSplitsAreRecorded() throws {
        let catalog = try catalog()

        let nvda = catalog.events(ticker: "NVDA", after: "2000-01-01")
        XCTAssertTrue(nvda.contains { $0.d == "2024-06-10" && $0.f == 1 && $0.t == 10 })
        XCTAssertTrue(nvda.contains { $0.d == "2021-07-20" && $0.f == 1 && $0.t == 4 })

        let aapl = catalog.events(ticker: "AAPL", after: "2010-01-01")
        XCTAssertTrue(aapl.contains { $0.d == "2020-08-31" && $0.t == 4 })
        XCTAssertTrue(aapl.contains { $0.d == "2014-06-09" && $0.t == 7 })
    }

    /// GE consolidated 8 shares into 1. A factor above 1 here would multiply
    /// a holding eightfold instead of dividing it.
    func testReverseSplitProducesAFactorBelowOne() throws {
        let catalog = try catalog()
        let ge = try XCTUnwrap(
            catalog.events(ticker: "GE", after: "2021-01-01").first { $0.d == "2021-08-02" }
        )

        XCTAssertTrue(ge.isReverse)
        XCTAssertEqual(try XCTUnwrap(ge.factor), 0.125, accuracy: 1e-9)
    }

    /// Spin-off adjustments arrive as awkward ratios like 1000 → 1281 rather
    /// than round multiples, so nothing may assume an integer factor.
    func testNonIntegerRatiosSurvive() throws {
        let catalog = try catalog()
        let ge = try XCTUnwrap(
            catalog.events(ticker: "GE", after: "2022-06-01").first { $0.d == "2023-01-04" }
        )

        XCTAssertEqual(try XCTUnwrap(ge.factor), 1.281, accuracy: 1e-9)
    }

    /// Only splits after a purchase apply to it. One that happened before is
    /// already reflected in the quantity the broker reported.
    func testOnlyLaterSplitsApply() throws {
        let catalog = try catalog()

        XCTAssertEqual(catalog.adjustment(ticker: "NVDA", from: "2025-01-01"), 1)
        XCTAssertEqual(try XCTUnwrap(catalog.adjustment(ticker: "NVDA", from: "2024-01-01")), 10, accuracy: 1e-9)
        // Both the 2021 4-for-1 and the 2024 10-for-1.
        XCTAssertEqual(try XCTUnwrap(catalog.adjustment(ticker: "NVDA", from: "2021-01-01")), 40, accuracy: 1e-9)
    }

    func testUnknownTickerNeedsNoAdjustment() throws {
        XCTAssertEqual(try catalog().adjustment(ticker: "NOTREAL", from: "2000-01-01"), 1)
    }

    /// The catalogue is US-only. A suffixed symbol must not be matched against
    /// a same-named US ticker — NG.L is National Grid, NG is NovaGold.
    func testSuffixedSymbolsDoNotMatchUSTickers() throws {
        let catalog = try catalog()

        XCTAssertTrue(catalog.events(ticker: "NG.L", after: "1900-01-01").isEmpty)
        XCTAssertTrue(catalog.events(ticker: "BA.L", after: "1900-01-01").isEmpty)
    }
}

/// The reason the catalogue exists.
final class RealisedProfitSplitTests: XCTestCase {

    private func trade(
        _ action: String, _ ticker: String, date: String, quantity: Double, price: Double
    ) -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date, action: action, ticker: ticker, quantity: quantity, price: price,
            currency: "USD", source: "test", accountID: "a", accountName: "a", tradeID: "\(date)\(action)"
        )
    }

    /// Bought 100 NVDA before the 2024 10-for-1, sold the resulting 1000.
    /// Without adjustment FIFO sees 1000 sold against 100 held and reports no
    /// cost basis; the profit is simply lost.
    func testSaleAfterAForwardSplitMatchesItsPurchase() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "NVDA", date: "2024-01-02", quantity: 100, price: 500),
            trade("SELL", "NVDA", date: "2025-01-02", quantity: 1_000, price: 60),
        ])

        XCTAssertEqual(summary.unavailableCount, 0, "the split should have been applied")
        XCTAssertEqual(summary.estimatedCount, 1)
        // Cost 100 × 500 = 50,000; proceeds 1000 × 60 = 60,000.
        XCTAssertEqual(summary.estimatedUSD, 10_000, accuracy: 1e-6)
    }

    /// GE's 8-into-1 consolidation runs the other way.
    func testSaleAfterAReverseSplitMatchesItsPurchase() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "GE", date: "2021-01-04", quantity: 80, price: 10),
            trade("SELL", "GE", date: "2021-09-01", quantity: 10, price: 100),
        ])

        XCTAssertEqual(summary.unavailableCount, 0)
        // Cost 80 × 10 = 800; proceeds 10 × 100 = 1,000.
        XCTAssertEqual(summary.estimatedUSD, 200, accuracy: 1e-6)
    }

    /// A purchase after the split needs no adjustment, and must not receive one.
    func testPurchaseAfterTheSplitIsUntouched() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "NVDA", date: "2024-08-01", quantity: 100, price: 100),
            trade("SELL", "NVDA", date: "2025-01-02", quantity: 100, price: 130),
        ])

        XCTAssertEqual(summary.estimatedUSD, 3_000, accuracy: 1e-6)
    }

    /// Two splits between purchase and sale compound.
    func testSuccessiveSplitsCompound() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "NVDA", date: "2021-01-04", quantity: 10, price: 4_000),
            trade("SELL", "NVDA", date: "2025-01-02", quantity: 400, price: 120),
        ])

        XCTAssertEqual(summary.unavailableCount, 0, "4-for-1 then 10-for-1 is 40x")
        // Cost 10 × 4,000 = 40,000; proceeds 400 × 120 = 48,000.
        XCTAssertEqual(summary.estimatedUSD, 8_000, accuracy: 1e-6)
    }

    /// A holding with no split in the catalogue must be unaffected.
    func testUnsplitHoldingIsUnchanged() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "KO", date: "2024-01-02", quantity: 100, price: 60),
            trade("SELL", "KO", date: "2025-01-02", quantity: 100, price: 70),
        ])

        XCTAssertEqual(summary.estimatedUSD, 1_000, accuracy: 1e-6)
    }
}
