import XCTest
@testable import CatfolioIOS

/// Scrubbing the stock page's chart redraws its header for every step of the
/// finger. What the header derives from the whole price history — the
/// after-hours quote, the day's move — is kept per history instead of being
/// worked out again each step, which made the readout stutter.
final class SecurityPriceHistoryMemoTests: XCTestCase {
    private let open = ISO8601DateFormatter().date(from: "2026-10-09T13:30:00Z")!
    private let post = ISO8601DateFormatter().date(from: "2026-10-09T21:30:00Z")!

    private func history(extendedCount: Int = 60) -> SecurityPriceHistory {
        let start = DayDateCodec.date(from: "2024-01-02")!
        let daily = (0..<500).map {
            SecurityPricePoint(dateText: DayDateCodec.string(from: start.addingTimeInterval(Double($0) * 86_400)),
                               close: 100 + Double($0 % 7))
        }
        let intraday = (0..<390).map {
            SecurityPricePoint(dateText: "m\($0)", close: 150, timestamp: open.addingTimeInterval(Double($0) * 60))
        }
        let extended = (0..<extendedCount).map {
            SecurityPricePoint(dateText: "p\($0)", close: 151, timestamp: post.addingTimeInterval(Double($0) * 60))
        }
        return SecurityPriceHistory(ticker: "AAPL", currency: "USD", points: daily, intradayPoints: intraday,
                                    trades: [], extendedHoursPoints: extended)
    }

    func testDailyClosesSortByTheirDayAsTheirDatesDo() {
        let days = ["2024-03-01", "2023-12-31", "2024-01-15", "2024-02-29"]
        let points = days.map { SecurityPricePoint(dateText: $0, close: 1) }
        XCTAssertEqual(SecurityPricePoint.sortedByDate(points).map(\.dateText),
                       points.sorted { $0.date < $1.date }.map(\.dateText))
        let timed = [SecurityPricePoint(dateText: "b", close: 1, timestamp: post),
                     SecurityPricePoint(dateText: "a", close: 1, timestamp: open)]
        XCTAssertEqual(SecurityPricePoint.sortedByDate(timed).map(\.dateText), ["a", "b"])
    }

    func testTheAfterHoursQuoteIsWorkedOutOncePerMinuteAndHistory() {
        let cache = ExtendedHoursQuoteCache()
        let base = history()
        let now = post.addingTimeInterval(3 * 3600)
        let first = cache.quote(for: base, at: now)
        XCTAssertEqual(first, base.extendedHoursQuote(at: now), "The cache returns what the history gives")
        for second in 1...30 { _ = cache.quote(for: base, at: now.addingTimeInterval(Double(second))) }
        XCTAssertEqual(cache.computations, 1, "Scrubbing within the minute reuses it")
        _ = cache.quote(for: base, at: now.addingTimeInterval(61))
        XCTAssertEqual(cache.computations, 2, "A new minute works it out again")
        _ = cache.quote(for: history(extendedCount: 61), at: now.addingTimeInterval(61))
        XCTAssertEqual(cache.computations, 3, "A new print works it out again")
    }

    func testAMemoKeepsItsValueUntilTheHistoryOrKeyChanges() {
        let memo = SecurityPriceHistoryMemo<String, Int>()
        let base = history()
        for _ in 0..<10 { XCTAssertEqual(memo.value(for: base, extra: "Apple") { $0.points.count }, 500) }
        XCTAssertEqual(memo.computations, 1)
        _ = memo.value(for: base, extra: "Apple Inc.") { $0.points.count }
        XCTAssertEqual(memo.computations, 2)
        _ = memo.value(for: history(extendedCount: 10), extra: "Apple Inc.") { $0.points.count }
        XCTAssertEqual(memo.computations, 3)
    }
}
