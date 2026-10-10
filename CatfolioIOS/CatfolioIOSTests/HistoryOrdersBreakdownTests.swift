import XCTest
@testable import CatfolioIOS

final class HistoryOrdersBreakdownTests: XCTestCase {
    private func trade(_ action: String, ticker: String, date: String = "2026-06-01",
                       price: Double = 100, account: String = "one", currency: String = "USD",
                       result: Double? = nil) -> LocalTransactionRecord {
        .init(date: date, action: action, ticker: ticker, quantity: 1, price: price,
              currency: currency, source: "CSV", accountID: account, accountName: account,
              realisedProfitLoss: result, realisedProfitLossCurrency: result == nil ? nil : currency)
    }

    private func prepared(_ trades: [LocalTransactionRecord], accounts: Set<String>? = nil) throws -> HistoryPreparedLedger {
        try HistoryPreparedLedger.build(ledger: .init(accounts: [], transactions: trades, securityNames: [:]),
            accountIDs: accounts ?? Set(trades.map(\.accountKey)), locale: Locale(identifier: "en_GB"))
    }

    func testRingUsesRealisedResultsInsteadOfTradeProceedsAndRetainsLossSigns() throws {
        let trades = [trade("SELL", ticker: "AAA", price: 10_000, result: 100),
                      trade("SELL", ticker: "BBB", price: 20_000, result: -25),
                      trade("BUY", ticker: "OPEN", price: 500),
                      trade("DIVIDEND", ticker: "AAA", price: 999)]
        let history = try prepared(trades)
        let page = history.page(category: .orders, basis: .calendar, year: nil)
        let ring = page.ordersBreakdown
        XCTAssertEqual(ring.rows.map(\.id), ["AAA", "BBB", "OPEN"])
        XCTAssertEqual(ring.rows.map(\.orderCount), [1, 1, 1])
        XCTAssertEqual(ring.magnitudeUSD, 125)
        XCTAssertTrue(ring.hasLosses)
        XCTAssertEqual(ring.share(for: ring.rows[0]), 0.8)
        XCTAssertEqual(ring.share(for: ring.rows[1]), 0.2)
        XCTAssertEqual(ring.rows[1].amountUSD, -25)
        XCTAssertNil(ring.rows[2].amountUSD)
        XCTAssertNil(ring.share(for: ring.rows[2]))
        XCTAssertEqual(ring.rows.compactMap(\.amountUSD).reduce(0, +), history.realisedTotal.combinedUSD)
    }

    func testYearFilteringKeepsPriorYearCostBasisAndAccountScope() throws {
        let trades = [trade("BUY", ticker: "AAA", date: "2025-12-01", price: 100),
                      trade("SELL", ticker: "AAA", date: "2026-06-01", price: 140),
                      trade("SELL", ticker: "AAA", account: "other", result: 999)]
        let history = try prepared(trades, accounts: [trades[0].accountKey])
        for (basis, year) in [(TaxYearBasis.calendar, "2026"), (.uk, "2026/27")] {
            let page = history.page(category: .orders, basis: basis, year: year)
            let row = try XCTUnwrap(page.ordersBreakdown.rows.first)
            XCTAssertEqual(row.orderCount, 1)
            XCTAssertEqual(row.calculation.estimatedCount, 1)
            XCTAssertEqual(row.amountUSD, 40)
            XCTAssertEqual(row.dates.map(\.id), ["2026-06-01"])
            XCTAssertTrue(row.dates.flatMap(\.activities).allSatisfy { $0.transaction.accountKey == trades[0].accountKey })
        }
    }

    func testGroupingCombinesCaseVariantsAndPreservesEveryOrderInDateOrder() throws {
        let trades = [trade("BUY", ticker: "aaa", date: "2026-01-01"),
                      trade("SELL", ticker: "AAA", date: "2026-03-01", result: 12),
                      trade("BUY", ticker: "BBB", date: "2026-02-01")]
        let page = try prepared(trades).page(category: .orders, basis: .calendar, year: nil)
        let rows = page.ordersBreakdown.rows
        XCTAssertEqual(rows.count, 2)
        let a = try XCTUnwrap(rows.first { $0.id == "AAA" })
        XCTAssertEqual(a.orderCount, 2)
        XCTAssertEqual(a.dates.map(\.id), ["2026-03-01", "2026-01-01"])
        XCTAssertEqual(Set(rows.flatMap(\.dates).flatMap(\.activities).map(\.id)), Set(page.activities.map(\.id)))
    }

    func testMissingCostsOrExchangeRatesSuppressPercentagesWithoutDroppingOrders() throws {
        for missing in [trade("SELL", ticker: "UNKNOWN"),
                        trade("SELL", ticker: "UNKNOWN", currency: "XYZ", result: 20)] {
            let page = try prepared([trade("SELL", ticker: "KNOWN", result: 100), missing])
                .page(category: .orders, basis: .calendar, year: nil)
            let ring = page.ordersBreakdown
            XCTAssertEqual(ring.rows.count, 2)
            XCTAssertFalse(ring.isComplete)
            XCTAssertTrue(ring.rows.allSatisfy { ring.share(for: $0) == nil })
            XCTAssertNil(ring.rows.first { $0.id == "UNKNOWN" }?.amountUSD)
        }
    }

    func testEmptyAndBreakEvenResultsDoNotProduceInvalidShares() throws {
        for trades in [[], [trade("SELL", ticker: "ZERO", result: 0)]] {
            let ring = try prepared(trades).page(category: .orders, basis: .calendar, year: nil).ordersBreakdown
            XCTAssertTrue(ring.isComplete)
            XCTAssertEqual(ring.magnitudeUSD, 0)
            XCTAssertTrue(ring.rows.allSatisfy { ring.share(for: $0) == nil })
        }
    }
}
