import XCTest
@testable import CatfolioIOS

/// A security sold out entirely has no live price, so "what if" and the
/// after-sale timing used to leave it out. Its latest close now stands in.
final class TradingInsightsClosedPositionTests: XCTestCase {
    private func trade(_ action: String, _ ticker: String, _ quantity: Double, _ price: Double,
                       on date: String, currency: String = "USD") -> LocalTransactionRecord {
        LocalTransactionRecord(date: date, action: action, ticker: ticker, quantity: quantity, price: price,
                               currency: currency, source: "CSV", accountID: "A", accountName: "A",
                               tradeID: "\(ticker)-\(action)-\(date)")
    }

    func testSoldOutSecuritiesAreTheOnesThatNeedAPrice() {
        let transactions = [
            trade("BUY", "AAPL", 10, 100, on: "2025-01-02"),
            trade("BUY", "ROKU", 5, 60, on: "2025-01-03"),
            trade("SELL", "ROKU", 5, 70, on: "2025-03-03"),
            trade("BUY", "EQQQ.L", 10, 40, on: "2025-01-04", currency: "GBP"),
            trade("SELL", "EQQQ.L", 10, 45, on: "2025-02-04", currency: "GBP"),
            trade("DIVIDEND", "KO", 1, 3, on: "2025-04-01"),
        ]
        let held = ["AAPL": TradingInsights.Quote(price: 120, currency: "USD")]
        let missing = TradingInsights.tickersNeedingQuotes(transactions: transactions, quotes: held)
        XCTAssertEqual(missing, ["ROKU": "USD", "EQQQ.L": "GBP"],
                       "Held securities have prices; a dividend alone is not a trade")
    }

    func testTheLatestCloseIsUsedInTheTradedCurrency() throws {
        let closes = ["2025-06-02": 80.0, "2025-06-04": 82.0, "2025-06-03": 81.0]
        XCTAssertEqual(TradingInsights.quote(fromCloses: closes, ticker: "ROKU", currency: "USD"),
                       .init(price: 82, currency: "USD"))
        // EQQQ.L is quoted in pence and was traded in pounds.
        let london = try XCTUnwrap(TradingInsights.quote(fromCloses: ["2025-06-04": 4_500], ticker: "EQQQ.L",
                                                          currency: "GBP"))
        XCTAssertEqual(london.price, 45, accuracy: 1e-9)
        XCTAssertNil(TradingInsights.quote(fromCloses: [:], ticker: "ROKU", currency: "USD"))
        XCTAssertNil(TradingInsights.quote(fromCloses: ["2025-06-04": .nan], ticker: "ROKU", currency: "USD"))
    }

    func testASoldOutSecurityCountsForWhatIfOnceItHasAPrice() {
        let transactions = [
            trade("BUY", "ROKU", 5, 60, on: "2025-01-03"),
            trade("SELL", "ROKU", 5, 70, on: "2025-03-03"),
        ]
        let rate: (String) -> Double? = { _ in 1 }
        let none: (String, String) -> Double? = { _, _ in 1 }
        let withoutPrice = TradingInsights.build(transactions: transactions, usdRate: rate, splitAdjustment: none)
        XCTAssertNil(withoutPrice.soldTooEarly, "Without a price it cannot be compared")
        XCTAssertEqual(withoutPrice.sellCount, 1, "The trade itself always counted")

        let withPrice = TradingInsights.build(transactions: transactions,
                                              quotes: ["ROKU": .init(price: 91, currency: "USD")],
                                              usdRate: rate, splitAdjustment: none)
        XCTAssertEqual(withPrice.soldTooEarly?.ticker, "ROKU")
        XCTAssertEqual(withPrice.soldTooEarly?.changePercent ?? 0, 30, accuracy: 1e-9)
    }
}
