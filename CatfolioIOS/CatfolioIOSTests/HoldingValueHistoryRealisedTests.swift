import XCTest
@testable import CatfolioIOS

/// The income-sources switch: sales put back into today's-holdings history.
final class HoldingValueHistoryRealisedTests: XCTestCase {

    private var history: HoldingValueHistory {
        HoldingValueHistory(rows: [
            .init(dateText: "2024-01-01", cost: 100, values: ["A": 110], costs: ["A": 100]),
            .init(dateText: "2024-02-01", cost: 100, values: ["A": 120], costs: ["A": 100]),
            .init(dateText: "2024-03-01", cost: 100, values: ["A": 130], costs: ["A": 100]),
        ], costs: ["A": 100], names: ["A": "Alpha"])
    }

    func testAPartSoldHoldingGainsItsRealisedResultFromTheSaleOn() {
        let merged = history.includingRealised([.init(ticker: "A", date: "2024-02-01", usd: 25)])
        XCTAssertEqual(merged.rows.map { $0.gain("A") }, [10, 45, 55])
        // The principal stays the cost of what is held now.
        XCTAssertEqual(merged.rows.map(\.cost), [100, 100, 100])
    }

    func testASoldOutSecurityBecomesItsOwnHoldingAtNoCost() {
        let merged = history.includingRealised([.init(ticker: "b", date: "2024-01-15", usd: -40)],
                                               names: ["B": "Beta"])
        XCTAssertEqual(merged.rows.map { $0.gain("B") }, [0, -40, -40])
        XCTAssertEqual(merged.gains["B"], -40)
        XCTAssertEqual(merged.names["B"], "Beta")
        XCTAssertEqual(merged.rows.last?.total, 90)
    }

    func testNoSalesLeavesTheHistoryAsItWas() {
        let merged = history.includingRealised([])
        XCTAssertEqual(merged.rows.map { $0.gain("A") }, [10, 20, 30])
    }
}
