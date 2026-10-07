import XCTest
@testable import CatfolioIOS

/// The security page's latest price: a newer minute quote extends the daily
/// line by one day, a same-day one updates it, and an older or invalid one
/// never replaces the close.
final class SecurityLatestPriceTests: XCTestCase {
    private func minute(_ day: String, _ price: Double) -> SecurityPricePoint {
        let date = DayDateCodec.date(from: day)!.addingTimeInterval(15 * 3_600)
        return .init(dateText: String(Int(date.timeIntervalSince1970)), close: price, timestamp: date)
    }

    private func history(_ daily: [SecurityPricePoint], _ minutes: [SecurityPricePoint]) -> SecurityPriceHistory {
        .init(ticker: "TEST", currency: "USD", points: daily, intradayPoints: minutes, trades: [])
    }

    private let daily: [SecurityPricePoint] = [.init(dateText: "2026-09-04", close: 100),
                                               .init(dateText: "2026-09-07", close: 110)]

    func testANewerMinuteQuoteAddsTodayWithoutMovingThePreviousClose() {
        let current = history(daily, [minute("2026-09-08", 120)])
        XCTAssertEqual(current.latestAvailablePrice, 120)
        XCTAssertEqual(current.chartDailyPoints.last?.dateText, "2026-09-08")
        XCTAssertEqual(current.chartDailyPoints.count, 3)
        XCTAssertEqual(current.points.last?.close, 110, "The previous-close baseline is not overwritten")
    }

    func testASameDayQuoteUpdatesThatDay() {
        let sameDay = history(daily, [minute("2026-09-07", 115)])
        XCTAssertEqual(sameDay.chartDailyPoints.count, 2)
        XCTAssertEqual(sameDay.latestAvailablePrice, 115)
    }

    func testOldMissingOrInvalidQuotesKeepTheClose() {
        XCTAssertEqual(history(daily, [minute("2026-09-04", 90)]).latestAvailablePrice, 110)
        XCTAssertEqual(history([daily[0]], [minute("2026-09-04", 105)]).chartDailyPoints.last?.dateText, "2026-09-04",
                       "No invented weekend day")
        XCTAssertEqual(history(daily, []).latestAvailablePrice, 110)
        XCTAssertEqual(history(daily, [minute("2026-09-08", .nan)]).latestAvailablePrice, 110)
        XCTAssertNil(history([], []).latestAvailablePrice)
    }
}
