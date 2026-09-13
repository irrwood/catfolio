import XCTest
@testable import CatfolioIOS

/// The underwater analysis: a value's fall from its high, and the
/// portfolio's fall taken apart by holding.
final class UnderwaterAnalysisTests: XCTestCase {
    private let days = ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-07", "2026-09-08"]

    private func history(_ values: [String: [Double]]) -> HoldingValueHistory {
        HoldingValueHistory(
            rows: days.indices.map { index in
                .init(dateText: days[index], cost: 0, values: values.mapValues { $0[index] })
            },
            costs: [:],
            names: ["A": "Alpha"]
        )
    }

    func testTheCurveMeasuresFromTheHighSoFar() {
        let series = UnderwaterSeries(dates: days.map { ($0, DayDateCodec.date(from: $0)!) }, values: [100, 120, 90, 96, 120, 110])
        for (point, expected) in zip(series.points, [0, 0, -0.25, -0.2, 0, 110.0 / 120 - 1]) {
            XCTAssertEqual(point.drawdown, expected, accuracy: 1e-12)
        }
        XCTAssertEqual(series.maxDrawdown, -0.25, accuracy: 1e-12)
        XCTAssertEqual(series.trough?.dateText, "2026-09-03")
        XCTAssertEqual(series.recovery?.dateText, "2026-09-07", "back to 120 on the 7th")
        XCTAssertEqual(series.daysUnderwater, 1, "a day below the 7th's high")
        XCTAssertEqual(series.longestUnderwaterDays, 5, "from the 2nd's high to the 7th")
        XCTAssertEqual(UnderwaterSeries.gainToRecover(-0.2), 0.25, accuracy: 1e-12)
    }

    func testThePartsAddUpToThePortfolioDrawdown() {
        // A falls hard, B a little, C rises: the parts are exact.
        let stack = UnderwaterStack(history: history([
            "A": [100, 100, 60, 70, 80, 90],
            "B": [100, 100, 95, 95, 97, 99],
            "C": [100, 100, 110, 112, 108, 105],
        ]), range: .maximum)
        for row in stack.rows {
            XCTAssertEqual(row.parts.values.reduce(0, +), row.drawdown, accuracy: 1e-12)
        }
        let deepest = stack.rows[2]
        XCTAssertEqual(deepest.drawdown, (265.0 - 300) / 300, accuracy: 1e-12)
        XCTAssertEqual(deepest.parts["A"] ?? 0, -40.0 / 300, accuracy: 1e-12)
        XCTAssertEqual(deepest.parts["C"] ?? 0, 10.0 / 300, accuracy: 1e-12)
        // Bands only pull down; C's rise shows as the line above them.
        XCTAssertTrue(stack.rows.allSatisfy { row in row.bands.allSatisfy { $0 <= 0 } })
        XCTAssertGreaterThan(deepest.drawdown, deepest.gross)
    }

    func testTheBiggestPullsAtTheDeepestPointGetBands() {
        // At the trough: A -40, B -5, C +10 of 300. B is 11% of the pull.
        let stack = UnderwaterStack(history: history([
            "A": [100, 100, 60, 70, 80, 90],
            "B": [100, 100, 95, 95, 97, 99],
            "C": [100, 100, 110, 112, 108, 105],
        ]), range: .maximum)
        XCTAssertEqual(stack.bands.map(\.ticker), [nil, "B", "A"], "others nearest the axis, the largest deepest")
        XCTAssertEqual(stack.bands.last?.colour, 0)
        XCTAssertEqual(stack.bands.last?.subtitle, "Alpha")
        XCTAssertEqual(stack.rankedAtTrough.map(\.ticker), ["A", "B", "C"])
        XCTAssertEqual(stack.othersPart(stack.rows[2]), 10.0 / 300, accuracy: 1e-12, "C rose: an offset, not a pull")
    }

    func testEachHoldingHasItsOwnCurve() {
        let stack = UnderwaterStack(history: history([
            "A": [100, 100, 60, 70, 80, 90],
            "B": [100, 100, 95, 95, 97, 99],
        ]), range: .maximum)
        XCTAssertEqual(stack.holdings["A"]?.maxDrawdown ?? 0, -0.4, accuracy: 1e-12)
        XCTAssertNil(stack.holdings["A"]?.recovery)
        XCTAssertEqual(stack.holdings["B"]?.maxDrawdown ?? 0, -0.05, accuracy: 1e-12)
    }

    func testAPortfolioThatOnlyRoseHasNothingUnderwater() {
        let stack = UnderwaterStack(history: history(["A": [100, 101, 102, 103, 104, 105]]), range: .maximum)
        XCTAssertEqual(stack.total.maxDrawdown, 0)
        XCTAssertEqual(stack.bands.map(\.ticker), [nil])
        XCTAssertNil(stack.total.recovery)
        XCTAssertEqual(stack.total.longestUnderwaterDays, 0)
    }
}
