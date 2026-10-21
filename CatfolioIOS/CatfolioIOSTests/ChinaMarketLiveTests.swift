import XCTest
@testable import CatfolioIOS

/// Opt-in integration coverage: TEST_RUNNER_CATFOLIO_TEST_CN_LIVE=1 xcodebuild test ...
final class ChinaMarketLiveTests: XCTestCase {
    func testPublicQuoteSearchDailyAndIntraday() async throws {
        guard ProcessInfo.processInfo.environment["CATFOLIO_TEST_CN_LIVE"] == "1" else {
            throw XCTSkip("Live public-feed test is opt-in")
        }
        let client = AKShareMarketDataClient()
        for code in ["600519.SH", "000001.SZ", "510300.SH"] {
            var stage = "quote"
            do {
            let security = try XCTUnwrap(ChinaSecurity(code))
            let quote = try await client.quote(security)
            XCTAssertGreaterThan(quote.price, 0)
            XCTAssertLessThanOrEqual(quote.observedAt, Date().addingTimeInterval(60))
            stage = "search"
            let results = try await client.search(security.code)
            XCTAssertTrue(results.contains { $0.ticker == security.ticker })
            stage = "daily"
            let bars = try await client.daily(security, from: ChinaSecurity.day(Date().addingTimeInterval(-60 * 86400)),
                to: ChinaSecurity.day(.now), adjusted: false)
            XCTAssertGreaterThan(bars.count, 2)
            stage = "intraday"
            let minutes = try await client.intraday(security)
            XCTAssertFalse(minutes.isEmpty)
            } catch {
                XCTFail("\(code) \(stage): \(error.localizedDescription)")
                throw error
            }
        }
    }
}
