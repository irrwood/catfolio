import XCTest
@testable import CatfolioIOS

final class CorporateEventsTests: XCTestCase {
    func testCalendarModuleGivesEarningsExDateAndPayDate() {
        let json = """
        {"quoteSummary":{"result":[{"calendarEvents":{"earnings":{"earningsDate":[{"raw":1793104200},{"raw":1793500000}],
        "isEarningsDateEstimate":true},"exDividendDate":{"raw":1789430400},"dividendDate":{"raw":1790812800}}}],"error":null}}
        """
        let events = CorporateEventSchedule.calendarEvents(Data(json.utf8), ticker: "KO")
        XCTAssertEqual(events.map(\.kind), [.earnings, .exDividend, .dividendPayment])
        XCTAssertEqual(events[0].date, "2026-10-27")
        XCTAssertTrue(events[0].isEstimate)
        XCTAssertEqual(events[1].date, "2026-09-15")
        XCTAssertEqual(events[2].date, "2026-10-01")
    }

    func testAnnouncedExDateReplacesTheProjectedOneAndKeepsItsAmount() throws {
        let today = try XCTUnwrap(DayDateCodec.date(from: "2026-10-03"))
        let payments: [DividendForecast.Payment] = [
            .init(exDate: "2025-11-28", perShare: 0.51, currency: "USD"),
            .init(exDate: "2026-09-15", perShare: 0.53, currency: "USD"),
        ]
        let announced = CorporateEvent(ticker: "KO", kind: .exDividend, date: "2026-12-01",
                                       isEstimate: false, amount: nil, currency: nil)
        let events = CorporateEventSchedule.merge(calendar: [announced], payments: payments, ticker: "KO", today: today)
        let future = events.filter { $0.date > "2026-10-03" && $0.date < "2027-01-01" }
        XCTAssertEqual(future.count, 1)
        XCTAssertEqual(future[0].date, "2026-12-01")
        XCTAssertFalse(future[0].isEstimate)
        XCTAssertEqual(future[0].amount, 0.51)
    }

    func testPaidDividendsProjectOneYearOn() throws {
        let today = try XCTUnwrap(DayDateCodec.date(from: "2026-10-03"))
        let events = CorporateEventSchedule.merge(calendar: [], payments: [
            .init(exDate: "2026-03-13", perShare: 0.25, currency: "GBP"),
        ], ticker: "X.L", today: today)
        XCTAssertEqual(events.map(\.date), ["2026-03-13", "2027-03-13"])
        XCTAssertEqual(events.last?.isEstimate, true)
    }
}
