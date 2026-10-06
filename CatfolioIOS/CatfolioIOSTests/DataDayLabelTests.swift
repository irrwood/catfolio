import XCTest
@testable import CatfolioIOS

final class DataDayLabelTests: XCTestCase {
    private let zh = Locale(identifier: "zh-Hans")

    private func now(_ day: String) throws -> Date {
        try XCTUnwrap(DayDateCodec.date(from: day)).addingTimeInterval(12 * 3_600)
    }

    func testNamesTheDayTheFiguresAreFrom() throws {
        // 2026-10-04 is a Sunday; the last session was Friday the 2nd.
        let sunday = try now("2026-10-04")
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(DataDayLabel.text(for: "2026-10-04", locale: zh, now: sunday, timeZone: utc), L10n.text("今天"))
        XCTAssertEqual(DataDayLabel.text(for: "2026-10-03", locale: zh, now: sunday, timeZone: utc), L10n.text("昨天"))
        XCTAssertEqual(DataDayLabel.text(for: "2026-10-02", locale: zh, now: sunday, timeZone: utc), "周五")
    }

    func testOlderThanAWeekIsADate() throws {
        let label = DataDayLabel.text(for: "2026-09-20", locale: zh, now: try now("2026-10-04"),
                                      timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(label.contains("20"), label)
        XCTAssertFalse(label.contains("周"), label)
    }

    func testTodayIsTheReadersOwnDay() throws {
        // 22:13 UTC on Saturday is already Sunday in Paris.
        let lateSaturdayUTC = try XCTUnwrap(DayDateCodec.date(from: "2026-10-03")).addingTimeInterval(22 * 3_600 + 13 * 60)
        let paris = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        XCTAssertEqual(DataDayLabel.text(for: "2026-10-02", locale: zh, now: lateSaturdayUTC, timeZone: paris), "周五")
        XCTAssertEqual(DataDayLabel.text(for: "2026-10-02", locale: zh, now: lateSaturdayUTC,
                                         timeZone: TimeZone(secondsFromGMT: 0)!), L10n.text("昨天"))
    }

    func testAWeekendSnapshotCountsAsFridaysSession() {
        XCTAssertEqual(DataDayLabel.latestSession(in: ["2026-10-01", "2026-10-02", "2026-10-03"]), "2026-10-02")
    }

    func testNoHoldingsIsNeverLive() {
        XCTAssertFalse(DataDayLabel.isLive([]))
    }

    func testLatestAvailableFridayKeepsHomeTitleOverTheWeekend() throws {
        let sunday = try now("2026-10-04")
        let utc = TimeZone(secondsFromGMT: 0)!
        for displayed in [nil, "2026-10-02", "2026-10-03"] as [String?] {
            XCTAssertEqual(DataDayLabel.homeTitle(displayedDay: displayed, latestDay: "2026-10-02",
                locale: zh, now: sunday, timeZone: utc), "CATFOLIO")
        }
    }

    func testHistoricalSelectionShowsItsOwnDateInsteadOfLastSession() throws {
        let sunday = try now("2026-10-04")
        let utc = TimeZone(secondsFromGMT: 0)!
        let label = DataDayLabel.homeTitle(displayedDay: "2026-10-01", latestDay: "2026-10-02",
            locale: zh, now: sunday, timeZone: utc)
        XCTAssertEqual(label, DataDayLabel.text(for: "2026-10-01", locale: zh, now: sunday, timeZone: utc))
        XCTAssertNotEqual(label, "CATFOLIO")
    }

}
