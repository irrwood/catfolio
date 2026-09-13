import XCTest
@testable import CatfolioIOS

final class CycleComparisonTests: XCTestCase {
    /// A close every day from `from` to `to`, rising by `daily` percent.
    private func closes(from: String, to: String, daily: Double = 0) -> [String: Double] {
        var result: [String: Double] = [:]
        var day = DayDateCodec.date(from: from)!
        let end = DayDateCodec.date(from: to)!
        var value = 100.0
        while day <= end {
            result[DayDateCodec.string(from: day)] = value
            value *= 1 + daily / 100
            day = day.addingTimeInterval(86_400)
        }
        return result
    }

    private let today = DayDateCodec.date(from: "2026-09-13")!

    func testCyclesStartOnYearsDivisibleByTheirLength() {
        let result = CycleComparison.make(closes: closes(from: "1999-12-01", to: "2026-09-12"),
                                          length: 5, lookback: 20, today: today)
        XCTAssertEqual(result.cycles.map(\.startYear), [2005, 2010, 2015, 2020, 2025])
        XCTAssertEqual(result.current?.startYear, 2025)
    }

    func testPastCyclesAreWholeAndTheCurrentOneStopsAtTheLatestClose() {
        let result = CycleComparison.make(closes: closes(from: "2019-12-01", to: "2026-09-12"),
                                          length: 2, lookback: 5, today: today)
        let past = result.cycles.filter { !$0.isCurrent }
        XCTAssertEqual(past.map(\.startYear), [2022, 2024])
        XCTAssertTrue(past.allSatisfy { $0.points.count == CycleComparison.steps + 1 && $0.points.last?.fraction == 1 })
        let current = try! XCTUnwrap(result.current)
        let expected = DayDateCodec.date(from: "2026-09-12")!.timeIntervalSince(DayDateCodec.date(from: "2026-01-01")!)
            / DayDateCodec.date(from: "2028-01-01")!.timeIntervalSince(DayDateCodec.date(from: "2026-01-01")!)
        XCTAssertEqual(current.points.last?.fraction ?? 0, expected, accuracy: 1e-9, "the ring sits on the latest close")
    }

    func testEachCycleIsMeasuredFromTheCloseBeforeItBegan() {
        // Flat until the last day of 2023, then 10% higher from 2024 on.
        var values = closes(from: "2022-12-01", to: "2026-09-12")
        for (day, _) in values where day >= "2024-01-01" { values[day] = 110 }
        let result = CycleComparison.make(closes: values, length: 2, lookback: 2, today: today)
        let cycle = try! XCTUnwrap(result.cycles.first { $0.startYear == 2024 })
        XCTAssertEqual(cycle.points.first?.value, 0)
        XCTAssertEqual(cycle.points[1].value, 10, accuracy: 1e-9, "the jump into the cycle counts, from the close before it")
    }

    func testACycleWithoutACloseBeforeItIsLeftOut() {
        let result = CycleComparison.make(closes: closes(from: "2024-03-01", to: "2026-09-12"),
                                          length: 2, lookback: 5, today: today)
        XCTAssertEqual(result.cycles.map(\.startYear), [2026], "2024 began before the history did")
    }

    func testAnAccountOpenedPartWayThroughStartsFromItsFirstDay() {
        let values = closes(from: "2026-03-02", to: "2026-09-12", daily: 0.1)
        XCTAssertNil(CycleComparison.make(closes: values, length: 2, lookback: 0, today: today).current,
                     "an index needs the close before the cycle")
        let current = try! XCTUnwrap(CycleComparison.make(closes: values, length: 2, lookback: 0, today: today,
                                                          allowsLateStart: true).current)
        XCTAssertEqual(current.joined, "2026-03-02")
        XCTAssertEqual(current.points.first?.value, 0)
        XCTAssertGreaterThan(current.points.first?.fraction ?? 0, 0.07, "it begins where the account did, not at the cycle's start")
    }

    func testALookbackShorterThanACycleHoldsOnlyTheCurrentOne() {
        let result = CycleComparison.make(closes: closes(from: "1999-12-01", to: "2026-09-12"),
                                          length: 10, lookback: 5, today: today)
        XCTAssertEqual(result.cycles.map(\.startYear), [2020])
    }

    func testTheAxisStepIsARoundNumberCoveringTheWidestMove() {
        XCTAssertEqual(CycleComparison.roundStep(7.3), 10)
        XCTAssertEqual(CycleComparison.roundStep(2.1), 2.5)
        XCTAssertEqual(CycleComparison.roundStep(0.2), 1, "never finer than one point")
        XCTAssertEqual(CycleComparison.roundStep(34), 50)
    }
}
