import Foundation
import XCTest
@testable import CatfolioIOS

final class MarketCacheFreshnessTests: XCTestCase {
    func testEachCacheKeepsItsExistingLifetimeAndExpiresAtTheBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for lifetime in [MarketCacheFreshness.intraday, MarketCacheFreshness.history, MarketCacheFreshness.volume] {
            XCTAssertTrue(MarketCacheFreshness.isFresh(fetchedAt: now, lifetime: lifetime, now: now))
            XCTAssertTrue(MarketCacheFreshness.isFresh(fetchedAt: now.addingTimeInterval(-lifetime + 1), lifetime: lifetime, now: now))
            XCTAssertFalse(MarketCacheFreshness.isFresh(fetchedAt: now.addingTimeInterval(-lifetime), lifetime: lifetime, now: now))
            XCTAssertFalse(MarketCacheFreshness.isFresh(fetchedAt: now.addingTimeInterval(1), lifetime: lifetime, now: now))
        }
        XCTAssertEqual(MarketCacheFreshness.intraday, 300)
        XCTAssertEqual(MarketCacheFreshness.history, 43_200)
        XCTAssertEqual(MarketCacheFreshness.volume, 86_400)
    }

    func testFutureDatedDiskCacheKeepsBarsButDoesNotReportThemFresh() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        struct Entry: Encodable {
            let fetchedAt: Date
            let bars: [MarketIntradayBar]
        }
        let future = Date().addingTimeInterval(3600)
        let bars = [MarketIntradayBar(timestamp: future, close: 100),
                    MarketIntradayBar(timestamp: future.addingTimeInterval(60), close: 101)]
        try JSONEncoder().encode(["AAA": Entry(fetchedAt: future, bars: bars)]).write(to: url)
        let cache = LocalIntradayPriceCache(cacheURL: url)
        let hit = await cache.lookup(symbol: "AAA")
        XCTAssertEqual(hit?.bars.count, 2, "Offline fallback data must remain available")
        XCTAssertEqual(hit?.isFresh, false)
    }
}
