import XCTest
@testable import CatfolioIOS

/// Closed-position profit is the one number a user can check against their
/// broker statement, so each source of it is pinned separately here.
final class RealisedProfitCalculatorTests: XCTestCase {

    private func trade(
        _ action: String,
        _ ticker: String = "AAA",
        date: String,
        quantity: Double,
        price: Double,
        currency: String = "USD",
        source: String = "Trading 212",
        tradeID: String? = nil,
        result: Double? = nil,
        resultCurrency: String? = nil
    ) -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date,
            action: action,
            ticker: ticker,
            quantity: quantity,
            price: price,
            currency: currency,
            source: source,
            accountID: "acct-1",
            accountName: "Test",
            tradeID: tradeID,
            realisedProfitLoss: result,
            realisedProfitLossCurrency: resultCurrency
        )
    }

    // MARK: - Broker Results stay exact and unconverted

    func testBrokerResultIsKeptInItsOwnCurrency() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 120,
                  result: 42.50, resultCurrency: "GBP"),
        ])

        XCTAssertEqual(summary.brokerCount, 1)
        XCTAssertEqual(summary.brokerTotals["GBP"], Decimal(string: "42.5"))
        // A broker figure must never leak into the estimate.
        XCTAssertEqual(summary.estimatedCount, 0)
        XCTAssertEqual(summary.estimatedUSD, 0)
    }

    func testBrokerResultsAccumulatePerCurrency() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "AAA", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "AAA", date: "2024-06-01", quantity: 10, price: 120,
                  result: 10, resultCurrency: "GBP"),
            trade("BUY", "BBB", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "BBB", date: "2024-06-01", quantity: 10, price: 120,
                  result: 5, resultCurrency: "GBP"),
            trade("BUY", "CCC", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "CCC", date: "2024-06-01", quantity: 10, price: 120,
                  result: 7, resultCurrency: "USD"),
        ])

        XCTAssertEqual(summary.brokerTotals["GBP"], Decimal(15))
        XCTAssertEqual(summary.brokerTotals["USD"], Decimal(7))
        XCTAssertEqual(summary.brokerCount, 3)
    }

    /// A Result with no usable currency cannot be shown and must not be
    /// assumed to be USD — but the sale is still reconstructable.
    func testResultWithoutAValidCurrencyFallsBackToTheLocalEstimate() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 120,
                  result: 200, resultCurrency: ""),
        ])

        XCTAssertEqual(summary.brokerCount, 0)
        XCTAssertEqual(summary.estimatedCount, 1)
        XCTAssertEqual(summary.estimatedUSD, 200, accuracy: 1e-9)
    }

    // MARK: - The regression this fix exists for

    /// Trading 212 sales awaiting a backfilled Result used to be discarded
    /// outright, collapsing the whole row to a dash even with a complete
    /// purchase history on hand.
    func testTrading212SaleWithoutAResultIsStillEstimated() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100, source: "Trading 212"),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 130, source: "Trading 212"),
        ])

        XCTAssertEqual(summary.estimatedCount, 1)
        XCTAssertEqual(summary.estimatedUSD, 300, accuracy: 1e-9)
        XCTAssertEqual(summary.unavailableCount, 0)
    }

    func testPartiallyBackfilledHistoryReportsBothSourcesSideBySide() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "AAA", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "AAA", date: "2024-06-01", quantity: 10, price: 120,
                  result: 200, resultCurrency: "USD"),
            trade("BUY", "BBB", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "BBB", date: "2024-06-01", quantity: 10, price: 150),
        ])

        XCTAssertEqual(summary.brokerCount, 1)
        XCTAssertEqual(summary.brokerTotals["USD"], Decimal(200))
        XCTAssertEqual(summary.estimatedCount, 1)
        XCTAssertEqual(summary.estimatedUSD, 500, accuracy: 1e-9)
        XCTAssertEqual(summary.saleCount, 2)
    }

    // MARK: - FIFO

    func testFIFOMatchesTheOldestLotFirst() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100, tradeID: "1"),
            trade("BUY", date: "2024-02-01", quantity: 10, price: 200, tradeID: "2"),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 150, tradeID: "3"),
        ])

        // Sold against the 100 lot, not the 200 lot, and not an average.
        XCTAssertEqual(summary.estimatedUSD, 500, accuracy: 1e-9)
    }

    func testSaleSpanningTwoLotsUsesBothCostBases() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100, tradeID: "1"),
            trade("BUY", date: "2024-02-01", quantity: 10, price: 200, tradeID: "2"),
            trade("SELL", date: "2024-06-01", quantity: 15, price: 250, tradeID: "3"),
        ])

        // Proceeds 15*250 = 3750; cost 10*100 + 5*200 = 2000.
        XCTAssertEqual(summary.estimatedUSD, 1_750, accuracy: 1e-9)
    }

    func testSameDayBuyThenSellFindsItsLot() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("SELL", date: "2024-01-01", quantity: 10, price: 120, tradeID: "b"),
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100, tradeID: "a"),
        ])

        XCTAssertEqual(summary.estimatedCount, 1)
        XCTAssertEqual(summary.estimatedUSD, 200, accuracy: 1e-9)
    }

    func testLotsAreTrackedPerTickerNotPooled() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "AAA", date: "2024-01-01", quantity: 10, price: 100),
            trade("BUY", "BBB", date: "2024-01-01", quantity: 10, price: 500),
            trade("SELL", "AAA", date: "2024-06-01", quantity: 10, price: 120),
        ])

        // Must use AAA's 100 basis, never BBB's 500.
        XCTAssertEqual(summary.estimatedUSD, 200, accuracy: 1e-9)
    }

    /// A broker-reported sale still has to move the FIFO cursor, or the next
    /// sale reuses lots that were already disposed of.
    func testBrokerReportedSaleStillConsumesItsLots() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100, tradeID: "1"),
            trade("BUY", date: "2024-02-01", quantity: 10, price: 200, tradeID: "2"),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 150, tradeID: "3",
                  result: 999, resultCurrency: "USD"),
            trade("SELL", date: "2024-07-01", quantity: 10, price: 300, tradeID: "4"),
        ])

        XCTAssertEqual(summary.brokerCount, 1)
        // The second sale must price against the 200 lot: 10*300 - 10*200.
        XCTAssertEqual(summary.estimatedUSD, 1_000, accuracy: 1e-9)
    }

    // MARK: - Refusals

    /// Never extrapolate from a purchase history that does not cover the sale.
    func testSaleWithNoImportedPurchaseIsUnavailableNotProfit() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("SELL", date: "2024-06-01", quantity: 10, price: 120)
        ])

        XCTAssertEqual(summary.unavailableCount, 1)
        XCTAssertEqual(summary.estimatedCount, 0)
        // Gross proceeds must never be mistaken for profit.
        XCTAssertEqual(summary.estimatedUSD, 0)
    }

    func testSaleLargerThanTheImportedBasisIsUnavailable() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 5, price: 100),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 120),
        ])

        XCTAssertEqual(summary.unavailableCount, 1)
        XCTAssertEqual(summary.estimatedUSD, 0)
    }

    func testUnconvertibleCurrencyIsReportedRatherThanPricedAtParity() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100, currency: "ZZZ"),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 120, currency: "ZZZ"),
        ])

        XCTAssertEqual(summary.unavailableCount, 1)
        XCTAssertEqual(summary.estimatedUSD, 0)
        XCTAssertTrue(summary.estimatedUSD.isFinite)
    }

    func testPenceQuotedSaleIsConvertedNotTakenAtFaceValue() throws {
        let penceRate = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBX"))
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 1_000, currency: "GBX"),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 1_500, currency: "GBX"),
        ])

        XCTAssertEqual(summary.estimatedUSD, 5_000 * penceRate, accuracy: 1e-6)
    }

    // MARK: - The combined total

    /// The headline figure has to convert, so it exists even when the broker
    /// and local sources are denominated differently.
    func testCombinedTotalAddsBrokerAndEstimatedSales() throws {
        let gbpRate = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBP"))
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "AAA", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "AAA", date: "2024-06-01", quantity: 10, price: 120,
                  result: 100, resultCurrency: "GBP"),
            trade("BUY", "BBB", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "BBB", date: "2024-06-01", quantity: 10, price: 150),
        ])

        XCTAssertEqual(summary.brokerUSD, 100 * gbpRate, accuracy: 1e-6)
        XCTAssertEqual(summary.estimatedUSD, 500, accuracy: 1e-9)
        XCTAssertEqual(summary.combinedUSD, 100 * gbpRate + 500, accuracy: 1e-6)
    }

    /// Converting for the total must not disturb the exact per-currency
    /// figures that are shown unconverted.
    func testConvertingForTheTotalLeavesBrokerCurrencyFiguresIntact() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 120,
                  result: 42.50, resultCurrency: "GBP"),
        ])

        XCTAssertEqual(summary.brokerTotals["GBP"], Decimal(string: "42.5"))
        XCTAssertNotEqual(summary.brokerUSD, 42.5, "GBP must not be taken as USD")
    }

    func testUnconvertibleBrokerCurrencyIsExcludedFromTheTotalAndFlagged() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 120,
                  result: 75, resultCurrency: "ZZZ"),
        ])

        XCTAssertEqual(summary.brokerTotals["ZZZ"], Decimal(75), "still reported")
        XCTAssertEqual(summary.brokerUSD, 0, "but never converted at parity")
        XCTAssertTrue(summary.unconvertibleCurrencies.contains("ZZZ"))
        XCTAssertFalse(summary.isComplete)
    }

    func testNegativeResultsReduceTheTotal() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "AAA", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "AAA", date: "2024-06-01", quantity: 10, price: 120,
                  result: -50, resultCurrency: "USD"),
            trade("BUY", "BBB", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "BBB", date: "2024-06-01", quantity: 10, price: 80),
        ])

        // -50 broker, -200 estimated.
        XCTAssertEqual(summary.combinedUSD, -250, accuracy: 1e-9)
    }

    func testACleanRunIsReportedComplete() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", date: "2024-06-01", quantity: 10, price: 120,
                  result: 200, resultCurrency: "USD"),
        ])

        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.combinedUSD, 200, accuracy: 1e-9)
    }

    func testSalesWithNoBasisLeaveTheTotalUnchangedButMarkItIncomplete() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "AAA", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "AAA", date: "2024-06-01", quantity: 10, price: 130),
            trade("SELL", "BBB", date: "2024-06-01", quantity: 10, price: 500),
        ])

        XCTAssertEqual(summary.combinedUSD, 300, accuracy: 1e-9)
        XCTAssertEqual(summary.unavailableCount, 1)
        XCTAssertFalse(summary.isComplete)
    }

    // MARK: - Classification and shape

    func testNonTradeActivityIsIgnored() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("DIVIDEND", date: "2024-01-01", quantity: 1, price: 50),
            trade("INTEREST", date: "2024-02-01", quantity: 1, price: 5),
            trade("DEPOSIT", date: "2024-03-01", quantity: 1, price: 1_000),
        ])

        XCTAssertEqual(summary.saleCount, 0)
        XCTAssertTrue(summary.brokerTotals.isEmpty)
    }

    func testActionMatchingToleratesCasingAndSeparators() {
        XCTAssertTrue(RealisedProfitCalculator.isBuy("buy"))
        XCTAssertTrue(RealisedProfitCalculator.isBuy(" Buy-Back "))
        XCTAssertTrue(RealisedProfitCalculator.isSell("sell_short"))
        XCTAssertTrue(RealisedProfitCalculator.isSell("Sell Short"))
        XCTAssertFalse(RealisedProfitCalculator.isSell("DIVIDEND"))
    }

    func testEmptyInputProducesAnEmptySummary() {
        let summary = RealisedProfitCalculator.summarize(transactions: [])

        XCTAssertEqual(summary.saleCount, 0)
        XCTAssertEqual(summary.estimatedUSD, 0)
    }

    func testSaleCountCoversEveryDisposal() {
        let summary = RealisedProfitCalculator.summarize(transactions: [
            trade("BUY", "AAA", date: "2024-01-01", quantity: 10, price: 100),
            trade("SELL", "AAA", date: "2024-06-01", quantity: 5, price: 120,
                  result: 1, resultCurrency: "USD"),
            trade("SELL", "AAA", date: "2024-07-01", quantity: 5, price: 130),
            trade("SELL", "BBB", date: "2024-08-01", quantity: 5, price: 130),
        ])

        XCTAssertEqual(summary.brokerCount, 1)
        XCTAssertEqual(summary.estimatedCount, 1)
        XCTAssertEqual(summary.unavailableCount, 1)
        XCTAssertEqual(summary.saleCount, 3)
    }
}
