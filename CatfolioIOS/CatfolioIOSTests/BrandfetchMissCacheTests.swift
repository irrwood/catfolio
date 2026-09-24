import XCTest
@testable import CatfolioIOS

final class BrandfetchMissCacheTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "BrandfetchMissCacheTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testMissExpiresAfterAWeekAndSurvivesRelaunch() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        BrandfetchMissCache(defaults: defaults).recordMissing(" zzzq ", now: start)
        let relaunched = BrandfetchMissCache(defaults: defaults)
        XCTAssertTrue(relaunched.isMissing("ZZZQ", now: start.addingTimeInterval(6 * 86_400)))
        XCTAssertFalse(relaunched.isMissing("ZZZQ", now: start.addingTimeInterval(7 * 86_400 + 1)))
        XCTAssertFalse(relaunched.isMissing("AAPL", now: start))
        relaunched.clear("zzzq")
        XCTAssertFalse(BrandfetchMissCache(defaults: defaults).isMissing("ZZZQ", now: start))
    }

    /// Regression: recordMissing wrote UserDefaults while holding its lock; the
    /// change notification redrew logos (via @AppStorage), which called
    /// isMissing on the same non-reentrant lock and froze the app.
    func testReadingDuringTheDefaultsChangeNotificationDoesNotDeadlock() {
        let cache = BrandfetchMissCache(defaults: defaults)
        var sawMiss = false
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in
            sawMiss = cache.isMissing("ZZZQ") || sawMiss
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let done = expectation(description: "recordMissing returns")
        DispatchQueue.global().async {
            cache.recordMissing("ZZZQ")
            cache.clear("ZZZQ")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(sawMiss)
    }

    func testOldestEntriesAreDroppedPastCapacity() {
        let cache = BrandfetchMissCache(defaults: defaults)
        let start = Date(timeIntervalSince1970: 2_000_000)
        for index in 0...BrandfetchMissCache.capacity {
            cache.recordMissing("T\(index)", now: start.addingTimeInterval(Double(index)))
        }
        let now = start.addingTimeInterval(Double(BrandfetchMissCache.capacity))
        XCTAssertFalse(cache.isMissing("T0", now: now))
        XCTAssertTrue(cache.isMissing("T\(BrandfetchMissCache.capacity)", now: now))
    }
}
