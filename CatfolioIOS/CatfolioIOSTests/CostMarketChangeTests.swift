import XCTest
@testable import CatfolioIOS

/// The home chart's change over a selected range: money paid in is not a
/// gain, and the percentage is of the starting value.
final class CostMarketChangeTests: XCTestCase {
    private func change(_ startValue: Double, _ startCost: Double, _ endValue: Double, _ endCost: Double)
        -> (amount: Double, percentage: Double) {
        let day = Date(timeIntervalSince1970: 0)
        return costMarketChange(from: .init(dateText: "a", date: day, marketValue: startValue, cost: startCost),
                                to: .init(dateText: "b", date: day, marketValue: endValue, cost: endCost))
    }

    func testDepositsAreNotGains() {
        let deposit = change(100, 80, 150, 130)
        XCTAssertEqual(deposit.amount, 0, accuracy: 1e-9, "A deposit raises value and cost alike")
        XCTAssertEqual(deposit.percentage, 0, accuracy: 1e-9)
        let gain = change(100, 80, 160, 130)
        XCTAssertEqual(gain.amount, 10, accuracy: 1e-9)
        XCTAssertEqual(gain.percentage, 10, accuracy: 1e-9)
    }

    func testLossesKeepTheirSignAndEdgesStayFinite() {
        let loss = change(100, 80, 60, 50)
        XCTAssertEqual(loss.amount, -10, accuracy: 1e-9)
        XCTAssertEqual(loss.percentage, -10, accuracy: 1e-9)
        XCTAssertEqual(change(100, 80, 100, 80).amount, 0)
        let fromNothing = change(0, 0, 50, 50)
        XCTAssertEqual(fromNothing.amount, 0)
        XCTAssertEqual(fromNothing.percentage, 0, "No starting value gives no percentage, not infinity")
    }

    func testScalingBothEndsToAnotherCurrencyKeepsThePercentage() {
        let scaled = change(125, 100, 200, 162.5)
        XCTAssertEqual(scaled.amount, 12.5, accuracy: 1e-9)
        XCTAssertEqual(scaled.percentage, 10, accuracy: 1e-9)
    }
}
