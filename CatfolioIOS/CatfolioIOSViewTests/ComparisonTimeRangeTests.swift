import XCTest
@testable import CatfolioIOS

final class ComparisonTimeRangeTests: XCTestCase {
    func testSevenVisibleSlotsPreserveEveryChartRange() {
        let groups = ChartTimeRange.comparisonChoiceGroups
        let ranges = groups.flatMap { $0 }

        XCTAssertEqual(groups.map { $0[0].rawValue }, ["1D", "1W", "1M", "3M", "YTD", "1Y", "MAX"])
        XCTAssertEqual(Set(ranges), Set(ChartTimeRange.allCases))
        XCTAssertEqual(ranges.count, Set(ranges).count)
    }

    func testThreeMonthRangeUsesCalendarMonths() throws {
        let calendar = ChartTimeRange.financeCalendar
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24)))
        let firstIncluded = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 24)))
        let previousDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 23)))

        XCTAssertTrue(ChartTimeRange.threeMonths.includes(firstIncluded, through: end, calendar: calendar))
        XCTAssertFalse(ChartTimeRange.threeMonths.includes(previousDay, through: end, calendar: calendar))
    }
}
