import XCTest
@testable import CatfolioIOS

/// A refreshed fill arrives without the Result the earlier sync already had.
/// Losing it would silently drop a sale out of the broker-reconciled total.
final class BrokerResultPreservationTests: XCTestCase {

    private func trade(
        _ result: Double?, _ currency: String?, account: String = "A"
    ) -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: "2026-01-02", action: "SELL", ticker: "TEST", quantity: 2,
            price: 100, currency: "USD", source: "Trading 212", accountID: account,
            accountName: account, tradeID: "fill-1",
            realisedProfitLoss: result, realisedProfitLossCurrency: currency)
    }

    func testAnEmptyRefreshInheritsThePreviousResult() {
        let enriched = trade(nil, nil).preservingBrokerResult(from: trade(12.34, "GBP"))

        XCTAssertEqual(enriched.realisedProfitLoss, 12.34)
        XCTAssertEqual(enriched.realisedProfitLossCurrency, "GBP")
    }

    /// Zero is a real Result, not a missing one.
    func testAZeroResultIsKeptRatherThanBackfilled() {
        let enriched = trade(0, "GBP").preservingBrokerResult(from: trade(12.34, "GBP"))

        XCTAssertEqual(enriched.realisedProfitLoss, 0)
    }

    func testAFreshResultIsNotOverwrittenByTheOldOne() {
        let enriched = trade(-4.25, "EUR").preservingBrokerResult(from: trade(12.34, "GBP"))

        XCTAssertEqual(enriched.realisedProfitLoss, -4.25)
        XCTAssertEqual(enriched.realisedProfitLossCurrency, "EUR")
    }

    /// Results must never migrate between accounts.
    func testADifferentAccountDoesNotDonateItsResult() {
        let enriched = trade(nil, nil, account: "B")
            .preservingBrokerResult(from: trade(12.34, "GBP"))

        XCTAssertNil(enriched.realisedProfitLoss)
    }

    func testNoPreviousFillLeavesTheTradeUntouched() {
        XCTAssertNil(trade(nil, nil).preservingBrokerResult(from: nil).realisedProfitLoss)
    }
}
