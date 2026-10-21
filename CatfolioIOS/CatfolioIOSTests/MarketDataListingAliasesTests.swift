import XCTest
@testable import CatfolioIOS

final class MarketDataListingAliasesTests: XCTestCase {
    func testSpanishBrokerPositionsRouteToTheirEuroListing() throws {
        for (raw, ticker, market) in [("ANAe_EQ", "ANAE", "ANA.MC"),
                                      ("IBEe_EQ", "IBEE", "IBE.MC")] {
            for instrumentCurrency in ["", #", "currencyCode": "EUR""#] {
                let json = #"{"instrument":{"ticker":"\#(raw)"\#(instrumentCurrency)},"quantity":3,"currentPrice":20,"walletImpact":{"currency":"GBP"}}"#
                let position = try JSONDecoder().decode(Trading212Position.self, from: Data(json.utf8))
                XCTAssertEqual(position.ticker, ticker)
                XCTAssertEqual(position.currency, "EUR")
                XCTAssertEqual(position.accountCurrency, "GBP")
                XCTAssertEqual(position.quantity, 3)
                XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: position.ticker, currency: position.currency), market)
                XCTAssertFalse(LocalMarketDataClient.supportsMassiveStockSymbol(market))
                XCTAssertEqual(LocalMarketDataClient.priceScale(ticker: ticker, currency: "EUR", referencePrice: 20, marketPrice: 20), 1)
            }
        }
    }

    func testQuoteAliasesRespectCurrencyAndExactListing() {
        let pairs = [("ANAE", "ANA.MC"), ("IBEE", "IBE.MC"), ("DHER", "DHER.DE"), ("MIH.DE", "MIH.F"),
                     ("FOT.DE", "FOT.F"), ("SDV1.DE", "SDV1.F")]
        for (broker, market) in pairs {
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: broker, currency: "EUR"), market)
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: market, currency: "EUR"), market)
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: broker, currency: "USD"), broker)
            XCTAssertEqual(TickerRenames.currentSymbol(for: broker), broker)
        }
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: " ibee ", currency: " eur "), "IBE.MC")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "ANAE", currency: "GBP"), "ANAE.L")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "ANAE.L", currency: "EUR"), "ANAE.L")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "IBE", currency: "USD"), "IBE")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "ANA", currency: "USD"), "ANA")
        XCTAssertEqual(Trading212Position.currency("USD", rawTicker: "IBEe_EQ"), "USD")
        XCTAssertEqual(Trading212Position.currency(nil, rawTicker: "OTHER_e_EQ"), "USD")
    }

    func testLegacyTrading212FillCurrencyIsRepairedWithoutChangingCashOrResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("portfolio.json")
        func trade(_ ticker: String, source: String, currency: String, action: String = "SELL") -> LocalTransactionRecord {
            LocalTransactionRecord(date: "2024-01-02", action: action, ticker: ticker,
                quantity: 3, price: 25, currency: currency, source: source, accountID: "fixture",
                accountName: "Fixture", tradeID: ticker + source + action, brokerFXRate: 0.86,
                realisedProfitLoss: 4.5, realisedProfitLossCurrency: "GBP", executedAt: "2024-01-02T12:00:00Z",
                cashPostings: [.init(currency: "GBP", amount: Decimal(string: "64.5")!)])
        }
        var original = LocalPortfolioDocument.empty
        original.transactions = [trade("DHER", source: "Trading 212", currency: "USD"),
                                 trade("ANAE", source: "Trading 212", currency: "USD"),
                                 trade("IBEE", source: "Trading 212", currency: "USD"),
                                 trade("DHER", source: "CSV", currency: "USD"),
                                 trade("DHER", source: "Trading 212", currency: "GBP", action: "DIVIDEND")]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(original).write(to: file)
        let store = LocalPortfolioStore(fileURL: file)
        let migrated = try await store.load()
        for (index, ticker) in ["DHER", "ANAE", "IBEE"].enumerated() {
            XCTAssertEqual(migrated.transactions?[index], trade(ticker, source: "Trading 212", currency: "EUR"))
        }
        XCTAssertEqual(migrated.transactions?[3], original.transactions?[3])
        XCTAssertEqual(migrated.transactions?[4], original.transactions?[4])
        let saved = try Data(contentsOf: file)
        let loadedAgain = try await store.load()
        XCTAssertEqual(loadedAgain.transactions, migrated.transactions)
        XCTAssertEqual(loadedAgain.snapshots, migrated.snapshots)
        XCTAssertEqual(try Data(contentsOf: file), saved, "A second load must not rewrite the migration")
        XCTAssertEqual(Trading212Position.currency(nil, rawTicker: "DHER_EQ"), "EUR")
        XCTAssertEqual(Trading212Position.currency("USD", rawTicker: "DHER_US_EQ"), "USD")
    }

    func testProviderQuotesMatchOriginalHoldingsWithoutRenamingTheLedger() {
        let observed = Date(timeIntervalSince1970: 1_792_411_200)
        let day = LocalMarketDataClient.sessionKey(for: observed, symbol: "ANA.MC")
        var document = LocalPortfolioDocument.empty
        for ticker in ["ANAE", "IBEE", "FOT.DE", "MIH.DE", "SDV1.DE"] {
            document.positions.append(LocalPositionRecord(ticker: ticker, name: "Fixture", shares: 3,
                averageCost: 18, currency: "EUR", quotePrice: 20, quoteCurrency: "EUR",
                source: "Trading 212", openedDate: "2025-08-15", quoteObservedAt: observed))
            document.transactions = (document.transactions ?? []) + [LocalTransactionRecord(
                date: "2025-08-15", action: "BUY", ticker: ticker, quantity: 3, price: 18,
                currency: "EUR", source: "Trading 212", accountID: nil, accountName: nil)]
        }
        XCTAssertEqual(LocalPortfolioStore.currentTickers(in: document), document)
        for position in document.positions {
            let symbol = LocalMarketDataClient.yahooSymbol(ticker: position.ticker, currency: position.quoteCurrency)
            let closes = LocalMarketDataClient.homeCloses([day: 19], symbol: symbol, currency: "EUR",
                positions: [position], through: day, now: observed)
            XCTAssertEqual(closes[day], 20, position.ticker)
            let wrongCurrency = LocalMarketDataClient.homeCloses([day: 19], symbol: symbol, currency: "USD",
                positions: [position], through: day, now: observed)
            XCTAssertEqual(wrongCurrency[day], 19)
        }
    }
}
