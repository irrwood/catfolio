import XCTest
@testable import CatfolioIOS

/// The gain-sources chart: principal at the bottom, then the others, then one
/// band per big gainer, and the stack always adds up to the day's value.
final class HoldingContributionTests: XCTestCase {
    private static let tickers = ["A", "B", "C", "D", "E", "F"]
    private static let costs = Dictionary(uniqueKeysWithValues: tickers.map { ($0, 100.0) })

    private func history() -> HoldingValueHistory {
        HoldingValueHistory(
            rows: [
                .init(dateText: "2026-01-02", cost: 600,
                      values: Dictionary(uniqueKeysWithValues: Self.tickers.map { ($0, 100.0) }), costs: Self.costs),
                .init(dateText: "2026-09-11", cost: 600,
                      values: ["A": 400, "B": 150, "C": 300, "D": 90, "E": 200, "F": 120], costs: Self.costs),
            ],
            costs: Self.costs,
            names: ["A": "Alpha", "C": "Gamma"]
        )
    }

    func testBigGainersGetBandsUntilTheNextIsASmallShare() {
        let stack = HoldingContributionStack(history: history())
        // Gains: A 300, C 200, E 100, B 50, F 20, D -10. F is 3% of the 670
        // gained, under the 6% bar, so it and D stay in the others.
        XCTAssertEqual(stack.bands.map(\.title), [L10n.text("本金"), L10n.text("其他收益"), "B", "E", "C", "A"])
        XCTAssertEqual(stack.bands[0].kind, .principal)
        XCTAssertEqual(stack.bands[1].kind, .others)
        XCTAssertEqual(stack.bands.last?.kind, .holding(colour: 0))
        XCTAssertEqual(stack.bands.last?.subtitle, "Alpha")
        XCTAssertTrue(stack.hidden.isEmpty)
    }

    func testBandsAddUpToEachDaysValue() throws {
        let stack = HoldingContributionStack(history: history())
        for (row, source) in zip(stack.rows, history().rows) {
            XCTAssertEqual(row.total, source.total, accuracy: 0.0001)
            XCTAssertEqual(row.principal, source.cost)
        }
        let last = try XCTUnwrap(stack.rows.last)
        XCTAssertEqual(last.bands, [600, 10, 50, 100, 200, 300])
        XCTAssertEqual(last.othersGain, 20 - 10, accuracy: 0.0001)
    }

    func testAHiddenHoldingJoinsTheOthersAndTheNextTakesItsPlace() throws {
        let stack = HoldingContributionStack(history: history(), hiding: ["A"])
        // Without A: C 200, E 100, B 50, F 20 of 370 gained. F is 5.4%, still
        // under the bar.
        XCTAssertEqual(stack.bands.map(\.title), [L10n.text("本金"), L10n.text("其他收益"), "B", "E", "C"])
        // The rest keep their colours: C 1, E 2, B 3.
        XCTAssertEqual(stack.bands.dropFirst(2).map(\.kind), [.holding(colour: 3), .holding(colour: 2), .holding(colour: 1)])
        XCTAssertEqual(stack.hidden.map(\.ticker), ["A"])
        XCTAssertEqual(stack.hidden.first?.name, "Alpha")
        let last = try XCTUnwrap(stack.rows.last)
        XCTAssertEqual(last.othersGain, 300 + 20 - 10, accuracy: 0.0001)
        XCTAssertEqual(last.total, 1260, accuracy: 0.0001)
    }

    func testAHoldingSteppingInTakesTheFreedColour() {
        // Seven even gainers: the six-band cap leaves G7 out until G2 is hidden.
        let tickers = (1...7).map { "G\($0)" }
        let costs = Dictionary(uniqueKeysWithValues: tickers.map { ($0, 100.0) })
        let even = HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: 700, values: costs, costs: costs),
            .init(dateText: "2026-01-05", cost: 700, values: costs.mapValues { $0 + 10 }, costs: costs),
        ], costs: costs, names: [:])
        XCTAssertFalse(HoldingContributionStack(history: even).bands.map(\.title).contains("G7"))

        let stack = HoldingContributionStack(history: even, hiding: ["G2"])
        let colours = Dictionary(uniqueKeysWithValues: stack.bands.dropFirst(2).map { ($0.title, $0.kind) })
        XCTAssertEqual(colours["G7"], .holding(colour: 1), "G7 takes G2's colour")
        XCTAssertEqual(colours["G1"], .holding(colour: 0))
        XCTAssertEqual(colours["G3"], .holding(colour: 2))
        XCTAssertNil(colours["G2"])
    }

    func testHidingSomethingNotHeldChangesNothing() {
        let stack = HoldingContributionStack(history: history(), hiding: ["ZZZ"])
        XCTAssertTrue(stack.hidden.isEmpty)
        XCTAssertEqual(stack.bands.count, 6)
    }

    func testTheOthersLossesComeOutOfThePrincipalBand() throws {
        let losing = HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: 200, values: ["A": 100, "B": 100], costs: ["A": 100, "B": 100]),
            .init(dateText: "2026-01-05", cost: 200, values: ["A": 200, "B": 50], costs: ["A": 100, "B": 100]),
        ], costs: ["A": 100, "B": 100], names: [:])
        let stack = HoldingContributionStack(history: losing)
        XCTAssertEqual(stack.bands.map(\.title), [L10n.text("本金"), L10n.text("其他收益"), "A"])
        let last = try XCTUnwrap(stack.rows.last)
        XCTAssertEqual(last.bands, [150, 0, 100])
        XCTAssertEqual(last.principal, 200)
        XCTAssertEqual(last.othersGain, -50)
        XCTAssertEqual(last.total, 250)
    }

    func testNamedCount() {
        XCTAssertEqual(HoldingContributionStack.namedCount([]), 0)
        XCTAssertEqual(HoldingContributionStack.namedCount([-5, 0]), 0)
        XCTAssertEqual(HoldingContributionStack.namedCount([1, 100]), 1, "The first always counts; 1% does not")
        XCTAssertEqual(HoldingContributionStack.namedCount(Array(repeating: 10, count: 10)), 6)
    }
}
