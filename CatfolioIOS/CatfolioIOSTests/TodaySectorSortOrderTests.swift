import XCTest
@testable import CatfolioIOS

final class TodaySectorSortOrderTests: XCTestCase {
    private struct Row {
        let id: String
        let amount: Double
    }

    private let rows = [
        Row(id: "loss-large", amount: -100), Row(id: "gain-small", amount: 5),
        Row(id: "zero", amount: 0), Row(id: "gain-large", amount: 80),
        Row(id: "loss-small", amount: -3), Row(id: "unclassified", amount: 90)
    ]

    func testAutomaticOrderUsesProfitTotalEvenWhenMoreSectorsLose() {
        XCTAssertEqual(TodaySectorSortOrder.automatic(for: [100, -20, -20, 0]), .gains)
    }

    func testAutomaticOrderUsesLossTotalEvenWhenMoreSectorsGain() {
        XCTAssertEqual(TodaySectorSortOrder.automatic(for: [-100, 20, 20, 0]), .losses)
    }

    func testAutomaticOrderDefaultsToGainsForBalancedAndEmptyDays() {
        for amounts in [[100.0, -100], [0, 0], []] {
            XCTAssertEqual(TodaySectorSortOrder.automatic(for: amounts), .gains)
        }
    }

    func testGainsOrderUsesSignedAmountAndIncludesEverySector() {
        let sorted = TodaySectorSortOrder.gains.sorted(rows, amount: \.amount, id: \.id)
        XCTAssertEqual(sorted.map(\.id),
            ["unclassified", "gain-large", "gain-small", "zero", "loss-small", "loss-large"])
    }

    func testLossesOrderPutsLargestLossFirst() {
        let sorted = TodaySectorSortOrder.losses.sorted(rows, amount: \.amount, id: \.id)
        XCTAssertEqual(sorted.map(\.id),
            ["loss-large", "loss-small", "zero", "gain-small", "gain-large", "unclassified"])
    }

    func testEqualAmountsKeepDeterministicOrderInBothModes() {
        let tied = [Row(id: "b", amount: 10), Row(id: "a", amount: 10)]
        for order in TodaySectorSortOrder.allCases {
            XCTAssertEqual(order.sorted(tied, amount: \.amount, id: \.id).map(\.id), ["a", "b"])
            XCTAssertTrue(order.sorted([Row](), amount: \.amount, id: \.id).isEmpty)
        }
    }
}
