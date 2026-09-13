import XCTest
@testable import CatfolioIOS

/// The money-weighted return drives the Returns tab's headline number, so the
/// Newton solver and its bisection fallback are pinned to hand-checkable cases.
final class MoneyWeightedReturnCalculatorTests: XCTestCase {
    func testCashFlowComparisonCountsGrossSameDayFlowsAndRetainedCash() throws {
        let ledger = AccountMWRLedger(dates: ["2024-01-01", "2024-01-02", "2024-01-03"],
            cashFlows: [1000, 50, -200], values: [1000, 1150, 950], benchmarkValues: ["SPY": [1000, 1050, 850]],
            inflows: [1000, 100, 0], outflows: [0, 50, 200])
        let result = try XCTUnwrap(ledger.cashFlowComparison())
        XCTAssertEqual(result.portfolio, [1000, 1200, 1200])
        XCTAssertEqual(result.benchmarks["SPY"], [1000, 1100, 1100])
        XCTAssertEqual(try XCTUnwrap(result.portfolioReturns.last ?? nil), 100.0 / 1100, accuracy: 1e-10)
        XCTAssertEqual(result.benchmarkReturns["SPY"]?.last ?? nil, 0)
    }

    func testCashFlowComparisonDoesNotInventGrossFlowsOrReviveMissingBenchmark() throws {
        var ledger = AccountMWRLedger(dates: ["2024-01-01", "2024-01-02"], cashFlows: [100, -50],
            values: [100, 50], benchmarkValues: ["SPY": [100, nil]])
        XCTAssertNil(ledger.cashFlowComparison())
        ledger.inflows = [100, 0]; ledger.outflows = [0, 50]
        let result = try XCTUnwrap(ledger.cashFlowComparison())
        XCTAssertEqual(result.portfolio, [100, 100])
        XCTAssertNil(result.benchmarks["SPY"]?.last ?? nil)
        XCTAssertNil(result.benchmarkReturns["SPY"]?.last ?? nil)
        ledger.outflows = [0, 20]
        XCTAssertNil(ledger.cashFlowComparison())
    }

    func testCostSnapshotFallbackCannotReturnCashFlowComparison() throws {
        let response = try LocalPortfolioEngine.comparison(for: .empty)
        XCTAssertFalse(response.available)
        XCTAssertTrue(response.portfolio.isEmpty)
        XCTAssertNil(response.summary.portfolioReturn)
    }

    func testBenchmarkMissingFundedDateCannotShiftDepositToFuturePrice() {
        let result = AccountMWRLedger.mirror(cashFlows: [100, 0, 0], prices: [nil, 100, 110])
        XCTAssertTrue(result.allSatisfy { $0 == nil })
    }
    func testLedgerRangeUsesOpeningNAVAndDoesNotDoubleCountOpeningDeposit() throws {
        let ledger = AccountMWRLedger(dates: ["2024-01-01", "2024-07-01", "2025-01-01"],
            cashFlows: [100, 500, 0], values: [100, 610, 671], benchmarkValues: ["SPY": [100, 600, 600]])
        let interval = ledger.returns(startIndex: 1)
        XCTAssertEqual(try XCTUnwrap(interval.portfolio.last ?? nil), 0.10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(interval.benchmarks["SPY"]?.last ?? nil), 0, accuracy: 1e-9)
        XCTAssertNotEqual(try XCTUnwrap(ledger.returns().portfolio.last ?? nil), 0.10, accuracy: 1e-5)
    }

    func testLocalLedgerMWRIncludesUninvestedCashAndIgnoresTradingAsExternalFlow() throws {
        typealias T = DailyTimeWeightedReturn
        let result = try T.calculate(events: [
            T.Event(id: "deposit", date: "2024-01-01", account: "A", cash: [.init(currency: "USD", amount: 1000)], external: true),
            T.Event(id: "buy", date: "2024-01-02", account: "A", symbol: "X", quantity: 5, cash: [.init(currency: "USD", amount: -500)]),
            T.Event(id: "sell", date: "2025-01-01", account: "A", symbol: "X", quantity: -5, cash: [.init(currency: "USD", amount: 550)])
        ], days: [
            T.Day(date: "2024-01-01", quotes: [:], usdRates: [:]),
            T.Day(date: "2024-01-02", quotes: ["X": .init(price: 100, currency: "USD")], usdRates: [:]),
            T.Day(date: "2025-01-01", quotes: [:], usdRates: [:])
        ])
        let ledger = AccountMWRLedger(dates: result.points.map(\.date),
            cashFlows: result.points.map { NSDecimalNumber(decimal: $0.inflow - $0.outflow).doubleValue },
            values: result.points.map { NSDecimalNumber(decimal: $0.value).doubleValue }, benchmarkValues: [:])
        XCTAssertEqual(ledger.cashFlows, [1000, 0, 0])
        XCTAssertEqual(try XCTUnwrap(ledger.returns().portfolio.last ?? nil), 0.05, accuracy: 1e-9)
    }

    func testBenchmarkDoesNotPretendToFundImpossibleWithdrawal() {
        let values = AccountMWRLedger.mirror(cashFlows: [100, -150, 100], prices: [100, 100, 100])
        XCTAssertEqual(values[0], 100)
        XCTAssertNil(values[1])
        XCTAssertNil(values[2])
    }

    func testBenchmarkUsesActualFlowDates() throws {
        let flows = [100.0, 100, -50]
        let prices: [Double?] = [100, 200, 100]
        XCTAssertEqual(AccountMWRLedger.mirror(cashFlows: flows, prices: prices), [100, 300, 100])
    }

    func testPeriodMWRIsNotAnnualized() throws {
        let ledger = AccountMWRLedger(dates: ["2024-01-01", "2024-07-01"],
            cashFlows: [100, 0], values: [100, 110], benchmarkValues: [:])
        XCTAssertEqual(try XCTUnwrap(ledger.returns().portfolio.last ?? nil), 0.10, accuracy: 1e-9)
    }

    func testTotalLossIsMinusOneHundredPercent() throws {
        let result = MoneyWeightedReturnCalculator.rolling(dates: ["2024-01-01", "2025-01-01"], cashFlows: [100, 0], terminalValues: [100, 0])
        XCTAssertEqual(try XCTUnwrap(result.last ?? nil), -1)
    }

    func testBenchmarkCanStartAfterUnfundedBaselineWithoutQuote() {
        XCTAssertEqual(AccountMWRLedger.mirror(cashFlows: [0, 100, 0], prices: [nil, 100, 110]), [0, 100, 110])
    }

    func testMalformedLedgerAndMissingOpeningValueStayUnavailable() {
        var ledger = AccountMWRLedger(dates: ["2024-01-01", "2025-01-01"],
            cashFlows: [100], values: [100, 110], benchmarkValues: [:])
        XCTAssertTrue(ledger.returns().portfolio.isEmpty)
        ledger.cashFlows = [100, 0]
        ledger.values = [100, nil]
        XCTAssertTrue(ledger.returns(startIndex: 1).portfolio.allSatisfy { $0 == nil })
    }

    // MARK: - Known answers

    func testSingleContributionDoublingOverOneYearIsOneHundredPercent() {
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["2024-01-01", "2025-01-01"],
            cashFlows: [100, 0],
            terminalValues: [100, 200]
        )

        XCTAssertEqual(result.count, 2)
        // The opening point closes no cash-flow stream yet.
        XCTAssertNil(result[0])
        XCTAssertEqual(try XCTUnwrap(result[1]), 1.0, accuracy: 1e-6)
    }

    func testSingleContributionTenPercentGain() {
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["2024-01-01", "2025-01-01"],
            cashFlows: [100, 0],
            terminalValues: [100, 110]
        )

        XCTAssertEqual(try XCTUnwrap(result[1]), 0.10, accuracy: 1e-6)
    }

    /// 100 invested for a full year plus 100 invested for the final six months,
    /// ending at 230. Solving 100(1+r) + 100(1+r)^0.5 = 230 by hand gives
    /// r ≈ 0.2027, which is what separates a money-weighted return from a
    /// simple 15% total gain on 200 contributed.
    func testAdditionalContributionIsTimeWeightedByItsOwnHoldingPeriod() {
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["2024-01-01", "2024-07-01", "2025-01-01"],
            cashFlows: [100, 100, 0],
            terminalValues: [100, 200, 230]
        )

        XCTAssertEqual(try XCTUnwrap(result[2]), 0.2027, accuracy: 1e-3)
        XCTAssertLessThan(try XCTUnwrap(result[2]), 0.30)
    }

    /// A contribution that has not moved in value yet must read as flat, not as
    /// a gain manufactured by the contribution itself.
    func testContributionWithNoPriceMovementIsFlat() {
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["2024-01-01", "2024-07-01"],
            cashFlows: [100, 100],
            terminalValues: [100, 200]
        )

        XCTAssertEqual(try XCTUnwrap(result[1]), 0.0, accuracy: 1e-6)
    }

    func testWithdrawalIsTreatedAsANegativeCashFlow() {
        // Contribute 100, withdraw 50 at the halfway point, end holding 60.
        // The investor got 110 back out of 100 in, so the return is positive.
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["2024-01-01", "2024-07-01", "2025-01-01"],
            cashFlows: [100, -50, 0],
            terminalValues: [100, 60, 60]
        )

        XCTAssertGreaterThan(try XCTUnwrap(result[2]), 0)
    }

    func testLossProducesNegativeReturn() {
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["2024-01-01", "2025-01-01"],
            cashFlows: [100, 0],
            terminalValues: [100, 60]
        )

        XCTAssertEqual(try XCTUnwrap(result[1]), -0.40, accuracy: 1e-6)
    }

    // MARK: - Degenerate input must not crash or fabricate a number

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(
            MoneyWeightedReturnCalculator.rolling(
                dates: [], cashFlows: [], terminalValues: []
            ).isEmpty
        )
    }

    func testMismatchedArrayLengthsTruncateToTheShortest() {
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["2024-01-01", "2025-01-01"],
            cashFlows: [100],
            terminalValues: [100, 200]
        )

        XCTAssertEqual(result.count, 1)
    }

    func testUnparsableDateYieldsNilRatherThanACrash() {
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["not-a-date"],
            cashFlows: [100],
            terminalValues: [100]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0])
    }

    func testNoContributionYieldsNoReturn() {
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["2024-01-01", "2025-01-01"],
            cashFlows: [0, 0],
            terminalValues: [0, 0]
        )

        XCTAssertEqual(result.compactMap { $0 }.count, 0)
    }

    func testTotalLossToZeroDoesNotProduceAnInfiniteOrNaNRate() {
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: ["2024-01-01", "2025-01-01"],
            cashFlows: [100, 0],
            terminalValues: [100, 0]
        )

        if let rate = result[1] {
            XCTAssertTrue(rate.isFinite, "a wipeout must not yield inf/NaN")
        }
    }

    /// Irregular alternating deposits and withdrawals are what defeat Newton and
    /// push the solver onto its scan-and-bisect path. Whatever it returns there
    /// must still be a finite number in a sane range.
    func testIrregularFlowsStayFiniteOnTheBisectionFallback() {
        let dates = ["2024-01-01", "2024-03-01", "2024-06-01", "2024-09-01", "2025-01-01"]
        let result = MoneyWeightedReturnCalculator.rolling(
            dates: dates,
            cashFlows: [500, -300, 800, -600, 0],
            terminalValues: [500, 220, 1_020, 450, 500]
        )

        XCTAssertEqual(result.count, dates.count)
        for value in result.compactMap({ $0 }) {
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThan(value, -1.0)
        }
    }
}
