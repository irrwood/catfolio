import XCTest
@testable import CatfolioIOS

/// The figures the home page, the 今日 page and the heatmap all read from one
/// place. The cases that matter are the ones that used to differ between
/// copies: a holding that fell by everything, and inputs that are not numbers.
final class PortfolioMathTests: XCTestCase {
    func testDayContributionIsTheValueTodaysMoveAccountsFor() throws {
        // £110 now after +10%: £100 yesterday, so £10 of today's value is today's.
        let amount = PortfolioMath.dayContribution(marketValue: 110, changePercent: 10)
        XCTAssertEqual(try XCTUnwrap(amount), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(PortfolioMath.previousValue(marketValue: 110, changePercent: 10)),
                       100, accuracy: 1e-9)
    }

    func testDayContributionIsNegativeOnADownMove() throws {
        let amount = try XCTUnwrap(PortfolioMath.dayContribution(marketValue: 90, changePercent: -10))
        XCTAssertEqual(amount, -10, accuracy: 1e-9)
    }

    func testFlatDayContributesNothing() throws {
        XCTAssertEqual(try XCTUnwrap(PortfolioMath.dayContribution(marketValue: 250, changePercent: 0)), 0)
    }

    /// The drift this type exists to end: one screen dropped a holding that
    /// had fallen by 100% or more, the other printed a positive amount for it.
    func testAMoveOfMinus100OrWorseHasNoAnswer() {
        XCTAssertNil(PortfolioMath.previousValue(marketValue: 100, changePercent: -100))
        XCTAssertNil(PortfolioMath.dayContribution(marketValue: 100, changePercent: -100))
        XCTAssertNil(PortfolioMath.dayContribution(marketValue: 100, changePercent: -150))
    }

    func testNonNumbersHaveNoAnswer() {
        XCTAssertNil(PortfolioMath.dayContribution(marketValue: .nan, changePercent: 5))
        XCTAssertNil(PortfolioMath.dayContribution(marketValue: 100, changePercent: .nan))
        XCTAssertNil(PortfolioMath.dayContribution(marketValue: .infinity, changePercent: 5))
        XCTAssertNil(PortfolioMath.costBasis(marketValue: 100, unrealized: .nan))
    }

    func testCostBasisIsValueLessTheGainInIt() throws {
        XCTAssertEqual(try XCTUnwrap(PortfolioMath.costBasis(marketValue: 1_250, unrealized: 250)), 1_000)
        // A loss leaves a cost above today's value.
        XCTAssertEqual(try XCTUnwrap(PortfolioMath.costBasis(marketValue: 800, unrealized: -200)), 1_000)
    }

    func testDrawdownIsZeroAtTheHighAndNegativeBelowIt() {
        XCTAssertEqual(PortfolioMath.drawdown(value: 100, peak: 100), 0)
        XCTAssertEqual(PortfolioMath.drawdown(value: 80, peak: 100), -0.2, accuracy: 1e-9)
        // Above its own high is a new high, not a positive drawdown.
        XCTAssertEqual(PortfolioMath.drawdown(value: 120, peak: 100), 0)
    }

    func testDrawdownWithoutAUsableHighIsZero() {
        XCTAssertEqual(PortfolioMath.drawdown(value: 80, peak: 0), 0)
        XCTAssertEqual(PortfolioMath.drawdown(value: 80, peak: -100), 0)
        XCTAssertEqual(PortfolioMath.drawdown(value: .nan, peak: 100), 0)
    }

    func testGainToRecoverUndoesTheDrawdown() {
        // Down 20% needs +25% to be whole again.
        XCTAssertEqual(PortfolioMath.gainToRecover(drawdown: -0.2), 0.25, accuracy: 1e-9)
        XCTAssertEqual(PortfolioMath.gainToRecover(drawdown: 0), 0, accuracy: 1e-9)
        XCTAssertTrue(PortfolioMath.gainToRecover(drawdown: -1).isInfinite)
    }
}

/// Profit already taken, as the home page adds it up: the broker's own result
/// on each sale, converted from the currency it was reported in.
final class RealisedProfitTests: XCTestCase {
    private func sale(_ result: Double?, _ currency: String?) -> LocalTransactionRecord {
        LocalTransactionRecord(date: "2026-01-02", action: "SELL", ticker: "TEST", quantity: 1,
                               price: 100, currency: "USD", source: "CSV", accountID: nil, accountName: nil,
                               realisedProfitLoss: result, realisedProfitLossCurrency: currency)
    }

    func testResultsInOneCurrencyAddUp() throws {
        let summary = LocalBrokerResultSummary(transactions: [sale(120, "USD"), sale(-20, "USD")])
        XCTAssertEqual(try XCTUnwrap(summary.usdTotal()), 100, accuracy: 1e-6)
        XCTAssertEqual(summary.missingCount, 0)
    }

    func testResultsInSeveralCurrenciesConvert() throws {
        let pounds = try LocalPortfolioEngine.usd(50, currency: "GBP")
        let summary = LocalBrokerResultSummary(transactions: [sale(120, "USD"), sale(50, "GBP")])
        XCTAssertEqual(try XCTUnwrap(summary.usdTotal()), 120 + pounds, accuracy: 1e-6)
    }

    /// No sale with a result is not the same as no profit, so there is no
    /// total to show rather than a zero.
    func testNoResultsHasNoTotal() {
        XCTAssertNil(LocalBrokerResultSummary(transactions: []).usdTotal())
        XCTAssertNil(LocalBrokerResultSummary(transactions: [sale(nil, nil)]).usdTotal())
    }

    /// A sale the broker gave no result for is counted as a gap, so the home
    /// page can say the total is short rather than showing it as complete.
    func testSalesWithoutAResultAreCountedAsGaps() throws {
        let summary = LocalBrokerResultSummary(transactions: [sale(120, "USD"), sale(nil, nil)])
        XCTAssertEqual(summary.missingCount, 1)
        XCTAssertEqual(try XCTUnwrap(summary.usdTotal()), 120, accuracy: 1e-6)
    }

    func testAnUnknownCurrencyLeavesNoTotal() {
        XCTAssertNil(LocalBrokerResultSummary(transactions: [sale(10, "ZZZ")]).usdTotal())
    }
}
