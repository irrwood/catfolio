import XCTest
@testable import CatfolioIOS

final class HoldingLossRankingTests: XCTestCase {
    func testLatestLossRanksOnlyCurrentLosersAndPreservesHistoryTotals() throws {
        let history = recoveryHistory()
        let peak = HoldingLossStack(history: history, range: .oneYear)
        let current = HoldingLossStack(history: history, range: .oneYear, sortOrder: .currentLoss)
        XCTAssertEqual(named(peak), ["A", "B", "C", "D"])
        XCTAssertEqual(named(current), ["C", "B", "D"])
        XCTAssertEqual(current.deepest["C"], 500)
        XCTAssertEqual(current.rows.map(\.totalLoss), peak.rows.map(\.totalLoss))
        XCTAssertEqual(current.rows.map(\.netGain), peak.rows.map(\.netGain))
        XCTAssertEqual(current.rows.map(\.losingCount), peak.rows.map(\.losingCount))
        XCTAssertEqual(current.rows[1].bands[0], 900, "A's recovered loss remains in the historical others band")
        XCTAssertEqual(current.rows.last?.bands[0], 0)
        XCTAssertEqual(try XCTUnwrap(current.rows.last).totalLoss, 650)
    }

    func testLatestRankingUsesAmountsRatherThanPercentagesAndBreaksTiesByTicker() {
        let costs = ["A": 100.0, "B": 1000.0, "C": 1000.0]
        let history = HoldingValueHistory(rows: [
            .init(dateText: "2026-10-09", cost: 2100,
                  values: ["A": 50, "B": 900, "C": 900], costs: costs)
        ], costs: costs, names: [:])
        let stack = HoldingLossStack(history: history, range: .maximum, sortOrder: .currentLoss)
        XCTAssertEqual(named(stack), ["B", "C", "A"], "A's larger percentage loss is a smaller money loss")
    }

    func testSoldHoldingHasNoCurrentLossButRetainsHistoricalLoss() {
        let costs = ["LIVE": 1000.0, "SOLD": 1000.0]
        let history = HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: 2000,
                  values: ["LIVE": 900, "SOLD": 200], costs: costs),
            .init(dateText: "2026-10-09", cost: 1000,
                  values: ["LIVE": 900], costs: ["LIVE": 1000])
        ], costs: costs, names: [:])
        let peak = HoldingLossStack(history: history, range: .maximum, sortOrder: .maximumLoss)
        let current = HoldingLossStack(history: history, range: .maximum, sortOrder: .currentLoss)
        XCTAssertEqual(named(peak), ["SOLD", "LIVE"])
        XCTAssertEqual(named(current), ["LIVE"])
        XCTAssertEqual(current.rows.map(\.totalLoss), [900, 100])
    }

    func testHiddenRowsKeepIdentityAndFinancialRankWithinEitherSortOrder() throws {
        for order in HoldingLossSortOrder.allCases {
            let original = HoldingLossStack(history: recoveryHistory(), range: .oneYear, sortOrder: order)
            let hidden = HoldingLossStack(history: recoveryHistory(), range: .oneYear,
                                          hiding: ["B"], sortOrder: order)
            XCTAssertEqual(hidden.holdingRanks, original.holdingRanks)
            XCTAssertEqual(hidden.legendItems.map(\.id), original.legendItems.map(\.id))
            XCTAssertNil(try XCTUnwrap(hidden.legendItems.first { $0.id == "B" }).index)
            XCTAssertEqual(hidden.rows.map(\.totalLoss), original.rows.map(\.totalLoss))
        }
    }

    func testCurrentRankingPromotesNextLoserWhenOneOfSevenNamedHoldingsIsHidden() {
        let symbols = (1...9).map { "G\($0)" }
        let costs = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 1000.0) })
        let values = Dictionary(uniqueKeysWithValues: symbols.enumerated().map {
            ($0.element, Double($0.offset + 1) * 100)
        })
        let history = HoldingValueHistory(rows: [
            .init(dateText: "2026-10-09", cost: 9000, values: values, costs: costs)
        ], costs: costs, names: [:])
        let original = HoldingLossStack(history: history, range: .maximum, sortOrder: .currentLoss)
        let hidden = HoldingLossStack(history: history, range: .maximum,
                                      hiding: ["G2"], sortOrder: .currentLoss)
        XCTAssertEqual(named(original), Array(symbols.prefix(7)))
        XCTAssertEqual(named(hidden), ["G1", "G3", "G4", "G5", "G6", "G7", "G8"])
        XCTAssertEqual(hidden.holdingRanks["G8"], 8)
        XCTAssertEqual(hidden.rows.map(\.totalLoss), original.rows.map(\.totalLoss))
    }

    func testPreparedRangesProvideBothSortOrdersAndPeakRankingRespectsRange() throws {
        let history = recoveryHistory()
        let prepared = try HoldingLossRanges(history: history, hiding: ["B"])
        for range in ChartTimeRange.allCases {
            for order in HoldingLossSortOrder.allCases {
                let actual = try XCTUnwrap(prepared[range, order])
                let expected = HoldingLossStack(history: history, range: range, hiding: ["B"], sortOrder: order)
                XCTAssertEqual(actual.bands.map(\.id), expected.bands.map(\.id))
                XCTAssertEqual(actual.holdingRanks, expected.holdingRanks)
                XCTAssertEqual(actual.rows.map(\.bands), expected.rows.map(\.bands))
            }
        }
        XCTAssertEqual(try XCTUnwrap(prepared[.oneYear]).bands.last?.title, "A")
        XCTAssertEqual(try XCTUnwrap(prepared[.oneWeek]).bands.last?.title, "C")
        XCTAssertEqual(named(try XCTUnwrap(prepared[.oneYear, .currentLoss])),
                       named(try XCTUnwrap(prepared[.oneWeek, .currentLoss])))
    }

    func testEmptyAndFullyRecoveredHistoriesHaveNoCurrentNamedLosers() {
        let empty = HoldingLossStack(history: .init(rows: [], costs: [:], names: [:]),
                                     range: .maximum, sortOrder: .currentLoss)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertTrue(named(empty).isEmpty)
        let recovered = HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: 1000, values: ["A": 100], costs: ["A": 1000]),
            .init(dateText: "2026-10-09", cost: 1000, values: ["A": 1100], costs: ["A": 1000])
        ], costs: ["A": 1000], names: [:])
        let current = HoldingLossStack(history: recovered, range: .maximum, sortOrder: .currentLoss)
        XCTAssertTrue(named(current).isEmpty)
        XCTAssertEqual(current.rows.map(\.totalLoss), [900, 0])
        XCTAssertEqual(current.legendItems.map(\.id), ["loss-others"])
    }

    private func named(_ stack: HoldingLossStack) -> [String] {
        stack.bands.reversed().filter { $0.kind != .others }.map(\.title)
    }

    private func recoveryHistory() -> HoldingValueHistory {
        let costs = ["A": 1000.0, "B": 1000.0, "C": 1000.0, "D": 1000.0]
        return HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: 4000, values: costs, costs: costs),
            .init(dateText: "2026-04-02", cost: 4000,
                  values: ["A": 100, "B": 200, "C": 500, "D": 900], costs: costs),
            .init(dateText: "2026-10-09", cost: 4000,
                  values: ["A": 1100, "B": 900, "C": 500, "D": 950], costs: costs)
        ], costs: costs, names: [:])
    }
}
