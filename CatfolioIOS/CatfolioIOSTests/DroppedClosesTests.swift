import XCTest
@testable import CatfolioIOS

/// Yahoo at times returns a past session with no close. A full refetch keeps
/// the close it had before, so the day is not carried from the one before and
/// counted with the next as one day's move.
final class DroppedClosesTests: XCTestCase {
    func testADroppedSessionKeepsItsSavedClose() {
        let saved = ["2026-10-05": 111.22, "2026-10-06": 111.82, "2026-10-07": 111.55]
        let fetched = ["2026-10-05": 111.22, "2026-10-06": 111.82, "2026-10-08": 111.67]
        let kept = LocalMarketDataClient.keepingDroppedCloses(fetched, saved: saved)
        XCTAssertEqual(kept["2026-10-07"], 111.55)
        XCTAssertEqual(kept["2026-10-08"], 111.67, "Fetched days are as fetched")
    }

    func testASavedCloseTakesTheFetchedBasis() throws {
        // A 2-for-1 split since: every fetched close is half the saved one.
        let saved = ["2026-10-05": 200.0, "2026-10-06": 210.0, "2026-10-07": 220.0]
        let fetched = ["2026-10-05": 100.0, "2026-10-06": 105.0, "2026-10-08": 112.0]
        let kept = LocalMarketDataClient.keepingDroppedCloses(fetched, saved: saved)
        XCTAssertEqual(try XCTUnwrap(kept["2026-10-07"]), 110, accuracy: 1e-9)
    }

    func testOnlyDaysInsideTheFetchedSpanAreKept() {
        let saved = ["2026-09-01": 90.0, "2026-10-06": 100.0, "2026-10-09": 101.0]
        let fetched = ["2026-10-06": 100.0, "2026-10-08": 102.0]
        let kept = LocalMarketDataClient.keepingDroppedCloses(fetched, saved: saved)
        XCTAssertEqual(kept, fetched, "Nothing before the first fetched day or after the last")
        XCTAssertEqual(LocalMarketDataClient.keepingDroppedCloses(fetched, saved: nil), fetched)
    }
}
