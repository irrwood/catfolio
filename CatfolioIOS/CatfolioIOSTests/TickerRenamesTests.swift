import XCTest
@testable import CatfolioIOS

final class TickerRenamesTests: XCTestCase {
    func testFormerLondonExchangeCodeRequestsCurrentMarketData() {
        for currency in ["GBP", "GBX", "GBp"] {
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "LSE", currency: currency), "LSEG.L")
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "LSE.L", currency: currency), "LSEG.L")
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "LSEG.L", currency: currency), "LSEG.L")
        }
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "LSE.L", currency: "USD"), "LSEG.L")
        XCTAssertEqual(TickerRenames.equivalents(of: " lse.l "), ["LSE.L", "LSEG.L"])
        XCTAssertEqual(TickerRenames.equivalents(of: "LSEG.L"), ["LSEG.L", "LSE.L"])
    }

    func testLondonRenameDoesNotChangeUnrelatedListings() throws {
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "LSE", currency: "USD"), "LSE")
        XCTAssertEqual(TickerRenames.currentSymbol(for: "LSE"), "LSE")
        XCTAssertEqual(TickerRenames.currentSymbol(for: "LSE.DE"), "LSE.DE")
        let entry = try CompanyReferenceCatalog.bundled.get().entry(brokerSymbol: "LSE")
        XCTAssertEqual(entry?.market, "US")
        XCTAssertEqual(entry?.symbol, "LSE")
    }

    func testBothLondonCodesResolveTheSameCompany() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        for code in ["LSE.L", "LSEG.L"] {
            let entry = try XCTUnwrap(catalog.entry(brokerSymbol: code))
            XCTAssertEqual(entry.market, "GB")
            XCTAssertEqual(entry.symbol, "LSEG")
            XCTAssertEqual(catalog.brokerSymbol(for: entry), "LSEG.L")
        }
    }

    func testOtherVerifiedRenamesRequestCurrentMarketData() {
        let listings = [("FP.PA", "TTE.PA", "EUR"),
                        ("SOHO.L", "LIVE.L", "GBX"),
                        ("GRIL", "SDOT", "USD")]
        for (old, current, currency) in listings {
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: old, currency: currency), current)
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: current, currency: currency), current)
            XCTAssertEqual(TickerRenames.equivalents(of: old), [old, current])
            XCTAssertEqual(TickerRenames.equivalents(of: current), [current, old])
        }
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "SOHO", currency: "GBp"), "LIVE.L")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "SOHO", currency: "USD"), "SOHO")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "FP", currency: "USD"), "FP")
    }

    func testRenamedStocksReuseTheBundledCompanyReference() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        for (old, current, market, symbol) in [("FP.PA", "TTE.PA", "FR", "TTE"),
                                               ("GRIL", "SDOT", "US", "SDOT")] {
            for code in [old, current] {
                let entry = try XCTUnwrap(catalog.entry(brokerSymbol: code))
                XCTAssertEqual(entry.market, market)
                XCTAssertEqual(entry.symbol, symbol)
                XCTAssertEqual(catalog.brokerSymbol(for: entry), current)
            }
        }
        // The bundled snapshot lacks Living REIT; US:LIVE is a different company.
        XCTAssertNil(catalog.entry(brokerSymbol: "SOHO.L"))
        XCTAssertNil(catalog.entry(brokerSymbol: "LIVE.L"))
        XCTAssertEqual(catalog.entry(brokerSymbol: "LIVE")?.market, "US")
    }

    func testEnelProviderAliasKeepsPortfolioIdentityAndCurrencyBoundary() {
        for code in ["ENL1", "ENL1.DE"] {
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: code, currency: "EUR"), "ENL.DE")
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: code, currency: "USD"), code)
            XCTAssertEqual(TickerRenames.currentSymbol(for: code), code)
        }
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "enl1.de", currency: "eur"), "ENL.DE")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "ENL.DE", currency: "EUR"), "ENL.DE")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "ENL1.F", currency: "EUR"), "ENL1.F")
    }

    func testRetainedPostMergerCodesUseTheFinalQuoteSymbol() {
        for ticker in ["BRLI", "NUKK", "DFNS"] {
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: ticker, currency: "USD"), "DFNS")
            XCTAssertEqual(Set(TickerRenames.equivalents(of: ticker)), Set(["BRLI", "NUKK", "DFNS"]))
        }
        XCTAssertEqual(TickerRenames.equivalents(of: "DFNS"), ["DFNS", "BRLI", "NUKK"])
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "PMO.L", currency: "GBX"), "HBR.L")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "PMO", currency: "GBp"), "HBR.L")
        for ticker in ["BRLIU", "BRLIR", "BRLIW", "PMO", "CYBR"] {
            XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: ticker, currency: "USD"), ticker)
        }
    }

    func testExistingPositionsAndTradesKeepTheirValuesWhenRenamed() {
        var original = LocalPortfolioDocument.empty
        let codes = ["LSE.L", "LSEG.L", "LSE", "FP.PA", "SOHO.L", "GRIL", "ENL1.DE", "BRLI", "NUKK", "PMO.L"]
        original.positions = codes.map { ticker in
            LocalPositionRecord(ticker: ticker, name: "Fixture", shares: 3,
                                averageCost: 80, currency: "GBP", quotePrice: 8500,
                                quoteCurrency: "GBX", source: "CSV", openedDate: "2020-01-02")
        }
        original.transactions = codes.map { ticker in
            LocalTransactionRecord(date: "2020-01-02", action: "BUY", ticker: ticker,
                                   quantity: 3, price: 80, currency: "GBP", source: "CSV",
                                   accountID: nil, accountName: nil)
        }
        var expected = original
        for (index, current) in [(0, "LSEG.L"), (3, "TTE.PA"), (4, "LIVE.L"), (5, "SDOT"),
                                 (7, "DFNS"), (8, "DFNS"), (9, "HBR.L")] {
            expected.positions[index].ticker = current
            expected.transactions?[index].ticker = current
        }
        let migrated = LocalPortfolioStore.currentTickers(in: original)
        XCTAssertEqual(migrated, expected, "Only verified former listing codes should change")
        let repeated = LocalPortfolioStore.currentTickers(in: migrated)
        XCTAssertEqual(repeated, migrated)
    }
}
