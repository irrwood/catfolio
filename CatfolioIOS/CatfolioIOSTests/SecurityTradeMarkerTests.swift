import XCTest
@testable import CatfolioIOS

/// Trades on the security chart: recent fills, today's fills, closed positions.
final class SecurityTradeMarkerTests: XCTestCase {
    private func trade(_ date: String, _ action: String = "BUY", executedAt: Date? = nil) -> SecurityTrade {
        SecurityTrade(dateText: date, action: action, quantity: 1, tradeCount: 1, accountKeys: ["a"],
            executions: [.init(accountKey: "a", quantity: 1, amount: 100, currency: "USD", profit: nil,
                               profitCurrency: nil, executedAt: executedAt)])
    }

    private func history(trades: [SecurityTrade], minutes: [SecurityPricePoint] = []) -> SecurityPriceHistory {
        SecurityPriceHistory(ticker: "TEST", currency: "USD",
            points: [("2026-09-14", 100), ("2026-09-15", 101), ("2026-09-16", 102), ("2026-09-17", 103),
                     ("2026-09-18", 104)].map { SecurityPricePoint(dateText: $0.0, close: $0.1) },
            intradayPoints: minutes, trades: trades)
    }

    func testFillNewerThanTheLastDailyCloseIsMarkedOnTheLatestPoint() {
        let data = SecurityPriceRangeData(history: history(trades: [trade("2026-09-21"), trade("2026-10-30")]),
            range: .oneMonth, averageCost: nil, selectedAccountKeys: ["a"])
        XCTAssertEqual(data.trades.map(\.trade.dateText), ["2026-09-21"])
        XCTAssertEqual(data.trades.first?.point.dateText, "2026-09-18")
    }

    func testTodaysFillIsDrawnOnTheIntradayLineAtItsExecutionTime() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-21T13:30:00Z"))
        let minutes = (0..<60).map { index in
            let time = start.addingTimeInterval(Double(index) * 300)
            return SecurityPricePoint(dateText: String(Int(time.timeIntervalSince1970)), close: 104 + Double(index) / 10,
                                      timestamp: time)
        }
        let executed = start.addingTimeInterval(3_000)
        let data = SecurityPriceRangeData(
            history: history(trades: [trade("2026-09-21", executedAt: executed), trade("2026-09-18")], minutes: minutes),
            range: .oneDay, averageCost: nil, selectedAccountKeys: ["a"])
        XCTAssertEqual(data.trades.count, 1)
        XCTAssertEqual(data.trades.first?.point.date, executed)
    }

    func testExecutionTimeIsReadFromTheLedger() throws {
        let row = LocalTransactionRecord(date: "2026-09-21", action: "BUY", ticker: "TEST", quantity: 2, price: 10,
            currency: "USD", source: "Trading 212", accountID: "account-1", accountName: "A",
            executedAt: "2026-09-21T14:05:00.123Z")
        let grouped = SecurityTrade.grouped([row])
        XCTAssertEqual(try XCTUnwrap(grouped.first?.executedAt).timeIntervalSince1970,
                       try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-21T14:05:00Z")).timeIntervalSince1970 + 0.123,
                       accuracy: 0.001)
    }
}

final class LedgerRowGainTests: XCTestCase {
    func testEverySaleCarriesItsTransaction() {
        let rows = [
            LocalTransactionRecord(date: "2026-01-02", action: "BUY", ticker: "AAA", quantity: 2, price: 10,
                currency: "USD", source: "CSV", accountID: "one", accountName: "One"),
            LocalTransactionRecord(date: "2026-02-02", action: "SELL", ticker: "AAA", quantity: 2, price: 15,
                currency: "USD", source: "CSV", accountID: "one", accountName: "One"),
        ]
        let sales = RealisedProfitCalculator.sales(transactions: rows)
        XCTAssertEqual(sales.map(\.transactionID), [rows[1].id])
        let gain = HistoryRowGain(sales[0].outcome)
        XCTAssertEqual(gain?.value ?? .nan, 10, accuracy: 1e-9)
        XCTAssertNil(HistoryRowGain(.unavailable))
    }
}

final class SecurityBrokerLinkTests: XCTestCase {
    func testUSListingOpensTrading212AndUSBrokers() {
        let links = SecurityBrokerLink.links(for: "nvda")
        XCTAssertEqual(links.first?.url.absoluteString, "https://www.trading212.com/trading-instruments/invest/NVDA.US")
        XCTAssertEqual(links.map(\.title), ["Trading 212", "Moomoo", "Robinhood", "TradingView", "Yahoo Finance"])
        XCTAssertEqual(links[3].url.absoluteString, "https://www.tradingview.com/chart/?symbol=NVDA")
    }

    func testLondonListingSkipsUSOnlyBrokers() {
        let london = SecurityBrokerLink.links(for: "VUSA.L")
        XCTAssertEqual(london.map(\.title), ["Trading 212", "TradingView", "Yahoo Finance"])
        XCTAssertEqual(london[0].url.absoluteString, "https://www.trading212.com/trading-instruments/invest/VUSA.GB")
        XCTAssertEqual(SecurityBrokerLink.trading212Path("ASML.AS", isUS: false), "ASML.NL")
        XCTAssertEqual(SecurityBrokerLink.trading212Path("SAP.DE", isUS: false), "SAP.DE")
        XCTAssertNil(SecurityBrokerLink.trading212Path("0700.HK", isUS: false))
        XCTAssertEqual(london[1].url.absoluteString, "https://www.tradingview.com/chart/?symbol=LSE:VUSA")
        XCTAssertTrue(SecurityBrokerLink.links(for: "CASH").isEmpty)
    }
}

final class IndustrySentimentCoverageTests: XCTestCase {
    func testEveryGICSSectorHasAMarket() {
        let keys = Set(IndustrySentimentEngine.sectors.map(\.key))
        for key in ["technology", "financials", "health-care", "energy", "industrials", "consumer-discretionary",
                    "consumer-staples", "utilities", "materials", "real-estate", "communication-services"] {
            XCTAssertTrue(keys.contains(key), key)
        }
        XCTAssertEqual(keys.count, IndustrySentimentEngine.sectors.count)
    }

    func testRealisedVolatilityIsAnnualisedPercent() throws {
        // Alternating ±1% days: a daily deviation of about 1%, about 16% a year.
        var close = 100.0
        let prices = (0..<60).map { index -> IndustrySentimentEngine.PriceDay in
            close *= index.isMultiple(of: 2) ? 1.01 : 1 / 1.01
            let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: index,
                to: DayDateCodec.date(from: "2026-01-01")!)!
            return .init(date: DayDateCodec.string(from: date), open: close, high: close, low: close, close: close, volume: 1)
        }
        let series = IndustrySentimentEngine.realizedVolatility(prices)
        XCTAssertEqual(series.count, 40)
        XCTAssertEqual(try XCTUnwrap(series.last).close, 0.01 * 252.0.squareRoot() * 100, accuracy: 0.6)
    }
}

/// One account sold out of a security another account still holds.
final class ClosedAccountTradeTests: XCTestCase {
    private func row(_ action: String, _ account: String, price: Double, date: String) -> LocalTransactionRecord {
        LocalTransactionRecord(date: date, action: action, ticker: "AAA", quantity: 2, price: price,
            currency: "USD", source: "CSV", accountID: account, accountName: account)
    }

    private func context() -> (HoldingDetailAccountContext, held: String, closed: String) {
        let rows = [row("BUY", "held", price: 10, date: "2026-01-02"),
                    row("BUY", "closed", price: 10, date: "2026-01-05"),
                    row("SELL", "closed", price: 15, date: "2026-03-02")]
        var document = LocalPortfolioDocument.empty
        document.transactions = rows
        let held = rows[0].accountKey
        let context = HoldingDetailAccountContext(ticker: "aaa", document: document, options: [
            HoldingDetailAccountOption(id: held, displayName: "held", marketValue: 0, currency: "USD", marketValueUSD: 0)
        ])
        return (context, held, rows[1].accountKey)
    }

    func testAllAccountsIncludesTheSoldOutAccountsTrades() {
        let (context, held, closed) = context()
        XCTAssertEqual(context.closedAccountKeys, [closed])
        XCTAssertEqual(context.tradeAccountKeys(for: [held]), [held, closed])
        XCTAssertEqual(SecurityTrade.grouped(context.document.scoped(to: context.tradeAccountKeys(for: [held]))
            .transactions ?? []).filter(\.isSell).count, 1)
    }

    func testRealisedProfitUnderAllAccountsCountsTheSoldOutAccount() {
        let (context, held, _) = context()
        XCTAssertEqual(HoldingDetailRealisedProfitRequest(context: context, accountKeys: [held]).summary()?.combinedUSD ?? .nan,
                       10, accuracy: 1e-9)
        XCTAssertTrue(context.tradeAccountKeys(for: []).isEmpty)
    }
}

final class HoldingVolumeRangeTests: XCTestCase {
    private func holding(_ ticker: String, price: Double, cost: Double) -> Holding {
        Holding(ticker: ticker, logoSymbol: nil, displayName: ticker, sector: nil, source: nil, shares: 1,
            averageCost: cost, costCurrency: "USD", quotePrice: price, quoteCurrency: "USD", todayChangePercent: nil,
            marketValue: price, weight: 0.5, unrealized: 0, unrealizedPercent: 0, fxPnl: nil, fxPnlPercent: nil,
            fxPnlStatus: nil, fxPnlSource: nil)
    }

    private let range = HoldingVolumeRange(
        bins: [.init(low: 90, high: 100, volume: 5), .init(low: 100, high: 110, volume: 20), .init(low: 110, high: 120, volume: 3)],
        valueAreaLow: 95, pointOfControl: 105, valueAreaHigh: 115, currency: "USD")

    func testPriceAndCostArePlacedInTheValueArea() {
        let prices = HoldingVolumePrices(holding: holding("A", price: 115, cost: 95), range: range)
        XCTAssertEqual(prices.current, 115)
        XCTAssertEqual(prices.cost, 95)
        XCTAssertEqual(prices.valueAreaPosition, 1)
        XCTAssertEqual(range.valueAreaPosition(of: 95), 0)
        XCTAssertEqual(range.valueAreaPosition(of: 125), 1.5)
        XCTAssertNil(range.valueAreaPosition(of: nil))
    }

    func testValueAreaPositionSortsTheList() {
        let items = PortfolioHoldingListItem.make(holdings: [holding("A", price: 100, cost: 90), holding("B", price: 118, cost: 90)],
                                                  period: .today, dailyChanges: [:])
        XCTAssertEqual(PortfolioHoldingListItem.sorted(items, by: .volumeArea, ascending: false,
                                                       volumeRanges: ["A": range, "B": range]).map(\.ticker), ["B", "A"])
    }
}
