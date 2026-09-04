import XCTest
@testable import CatfolioIOS

/// The money-weighted return drives the Returns tab's headline number, so the
/// Newton solver and its bisection fallback are pinned to hand-checkable cases.
final class MoneyWeightedReturnCalculatorTests: XCTestCase {

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
