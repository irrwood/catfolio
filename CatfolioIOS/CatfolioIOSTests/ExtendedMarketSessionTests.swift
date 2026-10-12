import Foundation
import XCTest
@testable import CatfolioIOS

final class ExtendedMarketSessionTests: XCTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func bar(_ iso: String, _ price: Double) -> MarketIntradayBar {
        .init(timestamp: date(iso), close: price)
    }
    private func point(_ iso: String, _ price: Double) -> SecurityPricePoint {
        let time = date(iso)
        return .init(dateText: String(Int(time.timeIntervalSince1970)), close: price, timestamp: time)
    }

    func testSessionBoundariesFollowEasternDaylightAndStandardTime() {
        for (day, offset) in [("2026-10-12", "-04:00"), ("2026-11-02", "-05:00")] {
            for (time, expected) in [("03:59:00", USMarketSession.closed),
                ("04:00:00", .preMarket), ("09:29:59", .preMarket), ("09:30:00", .regular),
                ("15:59:59", .regular), ("16:00:00", .postMarket), ("19:59:59", .postMarket),
                ("20:00:00", .closed)] {
                XCTAssertEqual(USMarketSession.at(date("\(day)T\(time)\(offset)")), expected)
            }
        }
        XCTAssertEqual(USMarketSession.at(date("2026-10-11T08:00:00-04:00")), .closed)
        XCTAssertEqual(USMarketSession.dayKey(date("2026-11-02T19:30:00-05:00")), "2026-11-02")
    }

    func testYahooRequestEnablesExtendedHoursAndDecoderRetainsBothSessions() throws {
        let request = LocalMarketDataClient.yahooIntradayRequest(symbol: "AAPL", now: date("2026-10-12T18:00:00-04:00"))
        let items = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "includePrePost" }?.value, "true")
        let input = [bar("2026-10-12T08:00:00-04:00", 101), bar("2026-10-12T10:00:00-04:00", 102),
                     bar("2026-10-12T17:00:00-04:00", 103)]
        let payload: [String: Any] = ["chart": ["result": [["meta": ["currency": "USD"],
            "timestamp": input.map { Int($0.timestamp.timeIntervalSince1970) },
            "indicators": ["quote": [["close": input.map(\.close)]]]]]]]
        let decoded = try LocalMarketDataClient.decodeYahooIntradayBars(JSONSerialization.data(withJSONObject: payload), symbol: "AAPL")
        XCTAssertEqual(decoded.map(\.close), [101, 102, 103])
        XCTAssertEqual(try LocalMarketDataClient.latestMarketSession(from: decoded, symbol: "AAPL").map(\.close), [102])
        XCTAssertEqual(try LocalMarketDataClient.latestMarketSession(from: decoded, symbol: "AAPL", includingExtendedHours: true).map(\.close), [101, 102, 103])
    }

    func testFirstPremarketBarDoesNotReplacePreviousRegularSession() throws {
        let bars = [bar("2026-10-09T15:55:00-04:00", 100),
                    bar("2026-10-09T17:00:00-04:00", 105),
                    bar("2026-10-12T04:00:00-04:00", 110)]
        XCTAssertEqual(try LocalMarketDataClient.latestMarketSession(from: bars, symbol: "AAPL").map(\.close), [100])
        XCTAssertEqual(try LocalMarketDataClient.latestMarketSession(from: bars, symbol: "AAPL", includingExtendedHours: true).map(\.close), [110])
        XCTAssertThrowsError(try LocalMarketDataClient.latestMarketSession(from: [bars[2]], symbol: "AAPL"))
    }

    func testYahooEarlyCloseWindowClassifiesAfternoonAsAfterHours() throws {
        func epoch(_ time: String) -> Int { Int(date("2026-11-27T\(time)-05:00").timeIntervalSince1970) }
        let regular = ["start": epoch("09:30:00"), "end": epoch("13:00:00")]
        let post = ["start": epoch("13:00:00"), "end": epoch("17:00:00")]
        let payload: [String: Any] = ["chart": ["result": [[
            "meta": ["currency": "USD", "tradingPeriods": ["regular": [[regular]], "post": [[post]]]],
            "timestamp": [epoch("12:55:00"), epoch("13:30:00")],
            "indicators": ["quote": [["close": [100, 105]]]]]]]]
        let bars = try LocalMarketDataClient.decodeYahooIntradayBars(JSONSerialization.data(withJSONObject: payload), symbol: "AAPL")
        XCTAssertEqual(bars.map(\.marketSession), [.regular, .postMarket])
        XCTAssertEqual(try LocalMarketDataClient.latestMarketSession(from: bars, symbol: "AAPL").map(\.close), [100])
        let regularPoint = SecurityPricePoint(dateText: "regular", close: 100, timestamp: bars[0].timestamp, sessionWindow: bars[0].sessionWindow)
        let postPoint = SecurityPricePoint(dateText: "post", close: 105, timestamp: bars[1].timestamp, sessionWindow: bars[1].sessionWindow)
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-11-25", close: 98), .init(dateText: "2026-11-27", close: 100)],
            intradayPoints: [regularPoint], trades: [], extendedHoursPoints: [postPoint])
        let now = date("2026-11-27T13:35:00-05:00")
        let quote = try XCTUnwrap(history.extendedHoursQuote(at: now))
        XCTAssertEqual(quote.session, .postMarket)
        XCTAssertEqual(try XCTUnwrap(quote.changePercent), 5, accuracy: 1e-9)
        XCTAssertTrue(quote.isCurrentSession(at: now))
        XCTAssertFalse(quote.isCurrentSession(at: date("2026-11-27T17:00:00-05:00")))
    }

    func testDailyYahooMetadataStillAcceptsRegularPeriodsArray() throws {
        let window = ["start": Int(date("2026-10-12T09:30:00-04:00").timeIntervalSince1970),
                      "end": Int(date("2026-10-12T16:00:00-04:00").timeIntervalSince1970)]
        let payload: [String: Any] = ["chart": ["result": [[
            "meta": ["currency": "USD", "tradingPeriods": [[window]]],
            "timestamp": [window["start"]!], "indicators": ["quote": [["close": [100]]]]]]]]
        let bars = try LocalMarketDataClient.decodeYahooIntradayBars(JSONSerialization.data(withJSONObject: payload), symbol: "AAPL")
        XCTAssertEqual(bars.first?.marketSession, .regular)
    }

    func testInvalidOrOutOfSessionPricesCannotBecomeTheLatestQuote() throws {
        let bars = [bar("2026-10-12T08:00:00-04:00", 100), bar("2026-10-12T08:05:00-04:00", .nan),
                    bar("2026-10-12T08:10:00-04:00", 0), bar("2026-10-12T21:00:00-04:00", 200)]
        XCTAssertEqual(try LocalMarketDataClient.latestMarketSession(from: bars, symbol: "AAPL", includingExtendedHours: true).map(\.close), [100])
    }

    func testInternationalSessionIsNotFilteredThroughUSMarketHours() throws {
        let london = [bar("2026-10-12T08:00:00+01:00", 100), bar("2026-10-12T16:00:00+01:00", 101)]
        XCTAssertEqual(try LocalMarketDataClient.latestMarketSession(from: london, symbol: "VUAG.L").map(\.close), [100, 101])
    }

    func testPremarketQuoteUsesPreviousCloseWithoutChangingDailyPrices() throws {
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-10-08", close: 95), .init(dateText: "2026-10-09", close: 100)],
            intradayPoints: [], trades: [], extendedHoursPoints: [point("2026-10-12T08:00:00-04:00", 105)])
        let quote = try XCTUnwrap(history.extendedHoursQuote(at: date("2026-10-12T08:05:00-04:00")))
        XCTAssertEqual(quote.session, .preMarket)
        XCTAssertEqual(quote.price, 105)
        XCTAssertEqual(try XCTUnwrap(quote.changePercent), 5, accuracy: 1e-9)
        XCTAssertEqual(history.latestAvailablePrice, 100)
        XCTAssertEqual(history.latestMarketObservation?.price, 100)
        XCTAssertEqual(history.chartDailyPoints.count, 2)
        XCTAssertEqual(history.chartIntradayPoints.map(\.close), [105])
        XCTAssertTrue(quote.isCurrentSession(at: date("2026-10-12T08:05:00-04:00")))
        XCTAssertFalse(quote.isCurrentSession(at: date("2026-10-13T08:05:00-04:00")))
        XCTAssertNil(history.extendedHoursQuote(at: date("2026-10-12T10:00:00-04:00")))
        XCTAssertNil(history.extendedHoursQuote(at: date("2026-10-20T08:05:00-04:00")))
        XCTAssertNil(history.extendedHoursQuote(at: date("2026-10-12T07:55:00-04:00")))
    }

    func testAfterHoursUsesSameDayCloseEvenAcrossUTCMidnight() throws {
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-10-30", close: 100), .init(dateText: "2026-11-02", close: 120)],
            intradayPoints: [point("2026-11-02T15:55:00-05:00", 120)], trades: [],
            extendedHoursPoints: [point("2026-11-02T19:30:00-05:00", 126)])
        let quote = try XCTUnwrap(history.extendedHoursQuote(at: date("2026-11-02T19:35:00-05:00")))
        XCTAssertEqual(quote.session, .postMarket)
        XCTAssertEqual(try XCTUnwrap(quote.changePercent), 5, accuracy: 1e-9)
        XCTAssertEqual(history.latestAvailablePrice, 120)
        XCTAssertEqual(history.latestMarketObservation?.price, 120)
        XCTAssertEqual(history.chartDailyPoints.last?.dateText, "2026-11-02")
        XCTAssertEqual(history.chartIntradayPoints.map(\.close), [120, 126])
    }

    func testMissingBaselineDoesNotInventAChangeAndNonUSQuotesAreIgnored() throws {
        let extended = [point("2026-10-12T08:00:00-04:00", 105)]
        let us = SecurityPriceHistory(ticker: "AAPL", currency: "USD", points: [], intradayPoints: [], trades: [], extendedHoursPoints: extended)
        let now = date("2026-10-12T08:05:00-04:00")
        XCTAssertNil(try XCTUnwrap(us.extendedHoursQuote(at: now)).changePercent)
        let uk = SecurityPriceHistory(ticker: "VUAG.L", currency: "GBP", points: [], intradayPoints: [], trades: [], extendedHoursPoints: extended)
        XCTAssertNil(uk.extendedHoursQuote(at: now))
    }

    func testCacheRetainsSingleOpeningPrintAndBothSessions() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = LocalIntradayPriceCache(cacheURL: url, writeDelay: .milliseconds(10))
        await cache.save(symbol: "AAPL", bars: [bar("2026-10-12T04:00:00-04:00", 105)])
        let opening = await cache.lookup(symbol: "AAPL")
        XCTAssertEqual(opening?.bars.map(\.close), [105])
        await cache.save(symbol: "AAPL", bars: [bar("2026-10-12T04:00:00-04:00", 105), bar("2026-10-12T17:00:00-04:00", 110)])
        try await Task.sleep(for: .milliseconds(100))
        let restored = LocalIntradayPriceCache(cacheURL: url)
        let hit = await restored.lookup(symbol: "AAPL")
        XCTAssertEqual(hit?.bars.map(\.close), [105, 110])
    }

    func testPremarketExtendsDisplayRangesWithoutRewritingPreviousClose() {
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-10-08", close: 95), .init(dateText: "2026-10-09", close: 100)],
            intradayPoints: [point("2026-10-09T15:55:00-04:00", 100)], trades: [],
            extendedHoursPoints: [point("2026-10-09T17:00:00-04:00", 101),
                                 point("2026-10-12T04:00:00-04:00", 105)])
        XCTAssertEqual(history.chartIntradayPoints.map(\.close), [105], "1D starts over with the new market day")
        XCTAssertEqual(history.chartDailyDisplayPoints.map(\.close), [95, 100, 105])
        XCTAssertEqual(history.chartDailyDisplayPoints.last?.dateText, "2026-10-12")
        XCTAssertEqual(history.latestAvailablePrice, 100)
        XCTAssertEqual(history.latestMarketObservation?.price, 100)
    }

    func testAfterHoursUpdatesDisplayEndpointOnEasternDayAcrossUTCMidnight() {
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-10-30", close: 100), .init(dateText: "2026-11-02", close: 120)],
            intradayPoints: [point("2026-11-02T15:55:00-05:00", 120)], trades: [],
            extendedHoursPoints: [point("2026-11-02T08:00:00-05:00", 110),
                                 point("2026-11-02T19:30:00-05:00", 126)])
        XCTAssertEqual(history.chartIntradayPoints.map(\.close), [110, 120, 126])
        XCTAssertEqual(history.chartDailyDisplayPoints.map(\.close), [100, 126])
        XCTAssertEqual(history.chartDailyDisplayPoints.map(\.dateText), ["2026-10-30", "2026-11-02"])
        XCTAssertEqual(history.chartDailyPoints.map(\.close), [100, 120])
        XCTAssertEqual(history.latestMarketObservation?.price, 120)
    }

    func testNewerRegularPriceSupersedesExtendedDisplayEndpoint() {
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-10-09", close: 100)],
            intradayPoints: [point("2026-10-12T10:00:00-04:00", 110)], trades: [],
            extendedHoursPoints: [point("2026-10-12T08:00:00-04:00", 105)])
        XCTAssertEqual(history.chartDailyDisplayPoints.map(\.close), [100, 110])
        XCTAssertEqual(history.chartIntradayPoints.map(\.close), [105, 110])
    }

    func testDailyCloseWithoutMinuteDataSupersedesEarlierPremarketPrint() {
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-10-09", close: 100), .init(dateText: "2026-10-12", close: 110)],
            intradayPoints: [], trades: [], extendedHoursPoints: [point("2026-10-12T08:00:00-04:00", 105)])
        XCTAssertEqual(history.chartDailyDisplayPoints.map(\.close), [100, 110])
        XCTAssertNil(history.extendedHoursQuote(at: date("2026-10-12T17:00:00-04:00")))
    }
}
