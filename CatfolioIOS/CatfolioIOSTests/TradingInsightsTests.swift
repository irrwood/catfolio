import XCTest
@testable import CatfolioIOS

/// The insights page's figures, from a small ledger whose answers are known.
final class TradingInsightsTests: XCTestCase {

    private func row(_ date: String, _ action: String, _ ticker: String, _ quantity: Double, _ price: Double,
                     currency: String = "USD", result: Double? = nil, id: String) -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date, action: action, ticker: ticker, quantity: quantity, price: price,
            currency: currency, source: "Test", accountID: "A", accountName: "A", tradeID: id,
            realisedProfitLoss: result, realisedProfitLossCurrency: result == nil ? nil : currency)
    }

    private func build(_ rows: [LocalTransactionRecord],
                       quotes: [String: TradingInsights.Quote] = [:]) -> TradingInsights {
        TradingInsights.build(transactions: rows, quotes: quotes,
                              usdRate: { $0 == "USD" ? 1 : nil }, splitAdjustment: { _, _ in 1 })
    }

    private var ledger: [LocalTransactionRecord] {
        [
            row("2024-01-02", "BUY", "WIN", 10, 100, id: "1"),
            row("2024-01-02", "BUY", "LOSE", 10, 50, id: "2"),
            row("2024-02-01", "BUY", "LOSE", 10, 40, id: "3"),
            row("2024-04-01", "SELL", "WIN", 10, 150, id: "4"),
            row("2024-07-01", "SELL", "LOSE", 20, 30, id: "5"),
            row("2024-07-15", "DIVIDEND", "WIN", 1, 12, id: "6"),
        ]
    }

    func testBestAndWorstTradesAndTheirReturns() throws {
        let insights = build(ledger)

        XCTAssertEqual(insights.trades.count, 2)
        let best = try XCTUnwrap(insights.bestTrade)
        XCTAssertEqual(best.ticker, "WIN")
        XCTAssertEqual(try XCTUnwrap(best.profitUSD), 500, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(best.returnPercent), 50, accuracy: 0.001)

        let worst = try XCTUnwrap(insights.worstTrade)
        XCTAssertEqual(worst.ticker, "LOSE")
        // Cost 500 + 400, proceeds 600.
        XCTAssertEqual(try XCTUnwrap(worst.profitUSD), -300, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(worst.returnPercent), -100.0 / 3, accuracy: 0.001)
        XCTAssertEqual(insights.winRate, 0.5)
    }

    func testHoldingDaysAreWeightedByTheSharesEachLotGave() throws {
        let insights = build(ledger)
        let lose = try XCTUnwrap(insights.trades.first { $0.ticker == "LOSE" })
        // 10 shares held 181 days, 10 held 151 days.
        XCTAssertEqual(try XCTUnwrap(lose.holdingDays), 166, accuracy: 0.001)
        XCTAssertEqual(insights.quickestRoundTrip?.ticker, "WIN")
        XCTAssertEqual(insights.longestHold?.ticker, "LOSE")
    }

    func testTheBrokerResultWinsOverTheRebuiltOne() throws {
        let rows = [
            row("2024-01-02", "BUY", "X", 1, 100, id: "1"),
            row("2024-03-02", "SELL", "X", 1, 120, result: 15, id: "2"),
        ]
        let trade = try XCTUnwrap(build(rows).trades.first)
        XCTAssertEqual(trade.profitUSD, 15)
        XCTAssertFalse(trade.isEstimated)
    }

    func testASaleWithoutItsPurchasesHasNoReturn() {
        let insights = build([row("2024-03-02", "SELL", "X", 1, 120, id: "1")])
        XCTAssertNil(insights.trades.first?.profitUSD)
        XCTAssertNil(insights.winRate)
    }

    func testDipBuysCountPurchasesTenPercentUnderTheLast() {
        let insights = build(ledger)
        XCTAssertEqual(insights.dipBuyCount, 1)
        XCTAssertEqual(insights.mostDipBought?.key, "LOSE")
    }

    func testDividendsAndActivity() {
        let insights = build(ledger)
        XCTAssertEqual(insights.topDividend?.ticker, "WIN")
        XCTAssertEqual(insights.dividendTotalUSD, 12, accuracy: 0.001)
        XCTAssertEqual(insights.buyCount, 3)
        XCTAssertEqual(insights.sellCount, 2)
        XCTAssertEqual(insights.firstTrade?.date, "2024-01-02")
        XCTAssertEqual(insights.busiestDay?.key, "2024-01-02")
        XCTAssertEqual(insights.busiestDay?.count, 2)
    }

    func testSoldTooEarlyComparesTheLastSaleWithTodaysPrice() throws {
        let insights = build(ledger, quotes: ["WIN": .init(price: 300, currency: "USD")])
        let early = try XCTUnwrap(insights.soldTooEarly)
        XCTAssertEqual(early.ticker, "WIN")
        XCTAssertEqual(early.changePercent, 100, accuracy: 0.001)
        XCTAssertNil(insights.soldJustInTime)
    }

    func testStreaksFollowTheOrderOfSales() {
        let rows = [
            row("2024-01-01", "BUY", "A", 3, 10, id: "1"),
            row("2024-02-01", "SELL", "A", 1, 12, id: "2"),
            row("2024-02-02", "SELL", "A", 1, 13, id: "3"),
            row("2024-02-03", "SELL", "A", 1, 8, id: "4"),
        ]
        let insights = build(rows)
        XCTAssertEqual(insights.longestWinStreak, 2)
        XCTAssertEqual(insights.longestLossStreak, 1)
    }
}
