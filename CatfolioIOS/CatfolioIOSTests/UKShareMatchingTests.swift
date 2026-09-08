import XCTest
@testable import CatfolioIOS

/// UK share matching: same day, then the 30 days after, then the pool.
final class UKShareMatchingTests: XCTestCase {

    private func tx(_ action: String, _ date: String, _ qty: Double, price: Double = 10)
        -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date, action: action, ticker: "TEST", quantity: qty,
            price: price, currency: "GBP", source: "test",
            accountID: nil, accountName: nil
        )
    }

    /// Day 30 is inside the window and day 31 is outside. Getting this
    /// boundary wrong by one is the whole feature.
    func testWindowEndsThirtyDaysAfterTheDisposal() {
        XCTAssertEqual(UKShareMatching.windowEnd(after: "2026-09-08"), "2026-10-08")
        XCTAssertEqual(UKShareMatching.windowDays, 30)
    }

    /// The window is calendar days, so it crosses month and year ends without
    /// changing length.
    func testWindowCrossesMonthAndYearBoundaries() {
        XCTAssertEqual(UKShareMatching.windowEnd(after: "2026-12-20"), "2027-01-19")
        // 2028 is a leap year: February has 29 days.
        XCTAssertEqual(UKShareMatching.windowEnd(after: "2028-02-10"), "2028-03-11")
    }

    /// Nothing bought back, so the disposal comes out of the pool — the
    /// ordinary case, and the one people expect.
    func testAPlainSaleComesEntirelyFromThePool() {
        let disposals = UKShareMatching.disposals(ticker: "TEST", transactions: [
            tx("BUY", "2024-01-10", 1_000),
            tx("SELL", "2026-05-01", 400),
        ])
        XCTAssertEqual(disposals.count, 1)
        XCTAssertEqual(disposals[0].matches, [.init(rule: .section104, quantity: 400)])
        XCTAssertTrue(disposals[0].isFullyFromPool)
    }

    /// Sold and bought back a fortnight later. The disposal is matched
    /// against the repurchase, not the pool — this is the case the feature
    /// exists to show.
    func testRepurchaseInsideTheWindowIsMatchedAheadOfThePool() {
        let disposals = UKShareMatching.disposals(ticker: "TEST", transactions: [
            tx("BUY", "2024-01-10", 1_000),
            tx("SELL", "2026-05-01", 500),
            tx("BUY", "2026-05-15", 200),
        ])
        XCTAssertEqual(disposals[0].matches, [
            .init(rule: .thirtyDay(acquired: "2026-05-15"), quantity: 200),
            .init(rule: .section104, quantity: 300),
        ])
        XCTAssertEqual(disposals[0].matchedToAcquisitions, 200)
        XCTAssertFalse(disposals[0].isFullyFromPool)
    }

    /// One day past the window and the repurchase does not match. This is the
    /// difference the dates make, and the reason the end date is worth
    /// showing at all.
    func testRepurchaseTheDayAfterTheWindowDoesNotMatch() {
        let inside = UKShareMatching.disposals(ticker: "TEST", transactions: [
            tx("BUY", "2024-01-10", 1_000),
            tx("SELL", "2026-05-01", 500),
            tx("BUY", "2026-05-31", 500),
        ])
        let outside = UKShareMatching.disposals(ticker: "TEST", transactions: [
            tx("BUY", "2024-01-10", 1_000),
            tx("SELL", "2026-05-01", 500),
            tx("BUY", "2026-06-01", 500),
        ])
        XCTAssertEqual(inside[0].matchedToAcquisitions, 500, "2026-05-31 is day 30, inside")
        XCTAssertTrue(outside[0].isFullyFromPool, "2026-06-01 is day 31, outside")
    }

    /// Same-day acquisitions are matched before the 30-day ones, whatever
    /// order the ledger happens to list them in.
    func testSameDayIsMatchedBeforeTheFollowingDays() {
        let disposals = UKShareMatching.disposals(ticker: "TEST", transactions: [
            tx("BUY", "2024-01-10", 1_000),
            tx("BUY", "2026-05-08", 300),
            tx("SELL", "2026-05-01", 500),
            tx("BUY", "2026-05-01", 100),
        ])
        XCTAssertEqual(disposals[0].matches, [
            .init(rule: .sameDay, quantity: 100),
            .init(rule: .thirtyDay(acquired: "2026-05-08"), quantity: 300),
            .init(rule: .section104, quantity: 100),
        ])
    }

    /// An acquisition already matched to one disposal cannot also serve the
    /// next one.
    func testAnAcquisitionIsSpentOnce() {
        let disposals = UKShareMatching.disposals(ticker: "TEST", transactions: [
            tx("BUY", "2024-01-10", 1_000),
            tx("SELL", "2026-05-01", 100),
            tx("SELL", "2026-05-02", 100),
            tx("BUY", "2026-05-05", 100),
        ])
        XCTAssertEqual(disposals[0].matchedToAcquisitions, 100, "first disposal takes the repurchase")
        XCTAssertTrue(disposals[1].isFullyFromPool, "nothing left for the second")
    }

    /// Matching runs forward from the disposal. An acquisition *before* it is
    /// pool stock, however recent.
    func testAcquisitionsBeforeTheDisposalAreNotMatched() {
        let disposals = UKShareMatching.disposals(ticker: "TEST", transactions: [
            tx("BUY", "2026-04-25", 500),
            tx("SELL", "2026-05-01", 500),
        ])
        XCTAssertTrue(disposals[0].isFullyFromPool)
    }

    /// Share counts are normalised before matching, so a split between the
    /// purchase and the sale cannot make a disposal look larger than the
    /// acquisitions it should match.
    func testSplitsAreNormalisedBeforeMatching() throws {
        let splits = try StockSplitCatalog.bundled.get()
        let disposals = UKShareMatching.disposals(ticker: "NVDA", transactions: [
            LocalTransactionRecord(
                date: "2024-01-10", action: "BUY", ticker: "NVDA", quantity: 10,
                price: 500, currency: "USD", source: "test", accountID: nil, accountName: nil
            ),
            LocalTransactionRecord(
                date: "2026-05-01", action: "SELL", ticker: "NVDA", quantity: 100,
                price: 100, currency: "USD", source: "test", accountID: nil, accountName: nil
            ),
        ], splits: splits)
        // The 2024 ten-for-one makes the earlier purchase 100 of today's
        // shares, so the sale is fully covered by the pool.
        XCTAssertEqual(disposals[0].quantity, 100, accuracy: 0.001)
        XCTAssertTrue(disposals[0].isFullyFromPool)
    }

    func testNoDisposalsMeansNothingToReport() {
        XCTAssertTrue(UKShareMatching.disposals(ticker: "TEST", transactions: [
            tx("BUY", "2024-01-10", 100),
        ]).isEmpty)
        XCTAssertTrue(UKShareMatching.disposals(ticker: "TEST", transactions: []).isEmpty)
    }

    /// Only the security asked about. A repurchase of something else in the
    /// same window is irrelevant.
    func testOtherSecuritiesDoNotMatch() {
        let other = LocalTransactionRecord(
            date: "2026-05-10", action: "BUY", ticker: "OTHER", quantity: 500,
            price: 10, currency: "GBP", source: "test", accountID: nil, accountName: nil
        )
        let disposals = UKShareMatching.disposals(ticker: "TEST", transactions: [
            tx("BUY", "2024-01-10", 1_000),
            tx("SELL", "2026-05-01", 500),
            other,
        ])
        XCTAssertTrue(disposals[0].isFullyFromPool)
    }
}
