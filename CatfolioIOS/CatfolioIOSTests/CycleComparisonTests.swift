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

    func testPortfolioKeepsItsFirstPartialYearAlongsideLaterYears() throws {
        let result = CycleComparison.make(closes: closes(from: "2024-06-17", to: "2026-09-12", daily: 0.01),
                                          length: 1, lookback: 5, today: today, allowsLateStart: true)
        XCTAssertEqual(result.cycles.map(\.startYear), [2024, 2025, 2026])
        let first = try XCTUnwrap(result.cycles.first)
        XCTAssertEqual(first.joined, "2024-06-17")
        XCTAssertEqual(first.points.first?.value, 0)
        let fraction = DayDateCodec.date(from: "2024-06-17")!.timeIntervalSince(DayDateCodec.date(from: "2024-01-01")!)
            / DayDateCodec.date(from: "2025-01-01")!.timeIntervalSince(DayDateCodec.date(from: "2024-01-01")!)
        XCTAssertEqual(try XCTUnwrap(first.points.first?.fraction), fraction, accuracy: 1e-9)
        XCTAssertEqual(first.points.last?.fraction, 1)
        XCTAssertNil(first.ended)
        XCTAssertEqual(result.completePastCycles.map(\.startYear), [2025], "a midyear baseline must not enter the yearly mean")
    }

    func testPastPortfolioYearStopsAtTheActualLastDay() throws {
        let result = CycleComparison.make(closes: closes(from: "2024-03-02", to: "2024-10-18", daily: 0.01),
                                          length: 1, lookback: 5, today: today, allowsLateStart: true)
        XCTAssertEqual(result.cycles.map(\.startYear), [2024], "do not invent later years from a stale close")
        let cycle = try XCTUnwrap(result.cycles.first)
        XCTAssertEqual(cycle.joined, "2024-03-02")
        XCTAssertEqual(cycle.ended, "2024-10-18")
        let expected = DayDateCodec.date(from: "2024-10-18")!.timeIntervalSince(DayDateCodec.date(from: "2024-01-01")!)
            / DayDateCodec.date(from: "2025-01-01")!.timeIntervalSince(DayDateCodec.date(from: "2024-01-01")!)
        XCTAssertEqual(try XCTUnwrap(cycle.points.last?.fraction), expected, accuracy: 1e-9)
        XCTAssertTrue(result.completePastCycles.isEmpty)
    }

    func testAnEarlyEndingYearIsExcludedFromTheMeanEvenWithAnOpeningBaseline() throws {
        let result = CycleComparison.make(closes: closes(from: "2022-12-20", to: "2025-06-20"),
                                          length: 1, lookback: 3, today: today, allowsLateStart: true)
        XCTAssertEqual(result.cycles.map(\.startYear), [2023, 2024, 2025])
        XCTAssertEqual(result.completePastCycles.map(\.startYear), [2023, 2024])
        let last = try XCTUnwrap(result.cycles.last)
        XCTAssertNil(last.joined)
        XCTAssertEqual(last.ended, "2025-06-20")
    }

    func testIndexStillRequiresACompletePastYear() {
        let result = CycleComparison.make(closes: closes(from: "2024-06-17", to: "2026-09-12"),
                                          length: 1, lookback: 5, today: today)
        XCTAssertEqual(result.cycles.map(\.startYear), [2025, 2026])
        XCTAssertTrue(result.cycles.allSatisfy { $0.joined == nil })
    }

    func testTwoDayPartialPortfolioYearStillHasBothEndpoints() throws {
        let result = CycleComparison.make(closes: ["2024-06-17": 100, "2024-06-18": 110],
                                          length: 1, lookback: 5, today: today, allowsLateStart: true)
        let cycle = try XCTUnwrap(result.cycles.first)
        XCTAssertEqual(cycle.points.count, 2)
        XCTAssertEqual(try XCTUnwrap(cycle.points.last?.value), 10, accuracy: 1e-9)
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

    func testCyclesCanStartInAnyMonth() {
        // 12 September: an April year has been running since April.
        let result = CycleComparison.make(closes: closes(from: "2019-12-01", to: "2026-09-12"),
                                          length: 1, lookback: 2, today: today, startMonth: 4)
        XCTAssertEqual(result.cycles.map(\.startYear), [2024, 2025, 2026])
        XCTAssertEqual(result.current?.title, "2026/27")
        XCTAssertEqual(result.cycles.first?.title, "2024/25")
        // Five and a half months of twelve.
        XCTAssertEqual(result.current?.points.last?.fraction ?? 0, 0.45, accuracy: 0.02)
        XCTAssertEqual(result.completePastCycles.count, 2)

        // Before November comes round, a November year is last year's.
        let november = CycleComparison.make(closes: closes(from: "2019-12-01", to: "2026-09-12"),
                                            length: 1, lookback: 1, today: today, startMonth: 11)
        XCTAssertEqual(november.current?.startYear, 2025)
    }
}
