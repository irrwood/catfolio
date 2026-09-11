import XCTest
@testable import CatfolioIOS

/// Two bundled sources name sectors differently. Everything downstream adds
/// figures across both, so the normalisation is the contract.
final class PortfolioSectorTests: XCTestCase {

    func testGICSAndFMPNamesReachTheSameSector() {
        // Left is the ETF snapshots' vocabulary, right is the company reference's.
        let equivalents = [
            ("Information Technology", "Technology"),
            ("Health Care", "Healthcare"),
            ("Consumer Discretionary", "Consumer Cyclical"),
            ("Consumer Staples", "Consumer Defensive"),
            ("Financials", "Financial Services"),
            ("Materials", "Basic Materials"),
        ]
        for (gics, fmp) in equivalents {
            XCTAssertEqual(
                PortfolioSector(sourceName: gics), PortfolioSector(sourceName: fmp),
                "\(gics) and \(fmp) are the same sector"
            )
            XCTAssertNotNil(PortfolioSector(sourceName: gics))
        }
    }

    func testNamesSharedByBothVocabulariesResolve() {
        for name in ["Energy", "Industrials", "Real Estate", "Utilities", "Communication Services"] {
            XCTAssertNotNil(PortfolioSector(sourceName: name), name)
        }
    }

    func testCasingAndWhitespaceTolerated() {
        XCTAssertEqual(PortfolioSector(sourceName: "  technology "), .technology)
        XCTAssertEqual(PortfolioSector(sourceName: "HEALTH CARE"), .healthcare)
    }

    /// An unrecognised label must not be folded into a neighbouring sector —
    /// it belongs in the unclassified bucket where it can be seen.
    func testUnknownLabelsStayUnclassified() {
        XCTAssertNil(PortfolioSector(sourceName: "ETF / Other"))
        XCTAssertNil(PortfolioSector(sourceName: "Miscellaneous"))
        XCTAssertNil(PortfolioSector(sourceName: ""))
        XCTAssertNil(PortfolioSector(sourceName: nil))
    }

    func testPersistedDisplayNamesAndSnapshotCommunicationResolve() {
        for sector in PortfolioSector.allCases {
            XCTAssertEqual(PortfolioSector(sourceName: sector.displayName), sector)
            XCTAssertEqual(PortfolioSector(sourceName: sector.rawValue), sector)
        }
        XCTAssertEqual(PortfolioSector(sourceName: "Communication"), .communication)
    }

    func testMissingOrStaleUnclassifiedLabelsUseExistingCompanyData() {
        for label in [nil, "", "未分类", "Unclassified", "Unknown"] as [String?] {
            XCTAssertEqual(SectorAttribution.resolvedSector(ticker: "ASML.AS", reportedSector: label), .technology)
            XCTAssertEqual(SectorAttribution.resolvedSector(ticker: "AZN.L", reportedSector: label), .healthcare)
            XCTAssertNil(SectorAttribution.resolvedSector(ticker: "NOTREAL.XX", reportedSector: label))
        }
    }

    func testEverySectorHasADisplayNameAndSymbol() {
        for sector in PortfolioSector.allCases {
            XCTAssertFalse(sector.displayName.isEmpty)
            XCTAssertFalse(sector.symbolName.isEmpty)
        }
    }
}

/// Non-US listings, resolved through the broker-facing alias table rather
/// than a hand-written stopgap.
final class InternationalListingTests: XCTestCase {

    private func sector(_ symbol: String) throws -> PortfolioSector? {
        let entry = try CompanyReferenceCatalog.bundled.get().entry(brokerSymbol: symbol)
        return PortfolioSector(sourceName: entry?.sector)
    }

    /// Spot checks across the markets the reference claims to cover. A wrong
    /// sector here is silent, so the obvious ones are pinned.
    func testKnownListingsResolve() throws {
        let expected: [String: PortfolioSector] = [
            "AZN.L": .healthcare,
            "SHEL.L": .energy,
            "HSBA.L": .financials,
            "ULVR.L": .consumerDefensive,
            "NG.L": .utilities,
            "RIO.L": .materials,
            "ASML.AS": .technology,
            "SAP.DE": .technology,
            "SIE.DE": .industrials,
            "MC.PA": .consumerCyclical,
            "7203.T": .consumerCyclical,
            // GICS and iShares ACWI both place Sony in Consumer Discretionary,
            // not Technology, which is where a first pass had put it.
            "6758.T": .consumerCyclical,
            "0388.HK": .financials,
            "D05.SI": .financials,
            "BHP.AX": .materials,
            "CSL.AX": .healthcare,
            "RY.TO": .financials,
            "CNQ.TO": .energy,
        ]
        for (symbol, sector) in expected {
            XCTAssertEqual(try self.sector(symbol), sector, symbol)
        }
    }

    /// The reason the alias table exists. Several London and Toronto tickers
    /// spell the same letters as an unrelated US listing, and resolving one to
    /// the other misfiles the position without any visible failure.
    func testSuffixedTickersDoNotCollideWithUSListings() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let collisions: [(broker: String, key: String, us: String)] = [
            ("NG.L", "GB:NG", "US:NG"),        // National Grid vs NovaGold
            ("BA.L", "GB:BA", "US:BA"),        // BAE Systems vs Boeing
            ("RY.TO", "CA:RY", "US:RY"),       // Royal Bank vs Ryman Hospitality
            ("BHP.AX", "AU:BHP", "US:BHP"),    // the Australian line, not the ADR
        ]
        for case let (broker, key, us) in collisions {
            let entry = catalog.entry(brokerSymbol: broker)
            XCTAssertEqual(entry.map { "\($0.market):\($0.symbol)" }, key, broker)
            XCTAssertNotNil(catalog.entries[us], "\(us) should still exist in its own right")
            XCTAssertNil(catalog.entries["US:\(broker)"], "\(broker) must not be filed as a US key")
        }
    }

    func testLookupIsCaseInsensitive() throws {
        XCTAssertEqual(try sector("azn.l"), .healthcare)
    }

    func testUnknownSymbolReturnsNil() throws {
        XCTAssertNil(try sector("NOTATICKER.XX"))
    }

    /// An unsuffixed symbol must stay an exact US lookup rather than having a
    /// market guessed for it.
    func testBareSymbolsResolveAsUSListings() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        for symbol in ["AAPL", "AMD", "KO", "XOM", "WMT"] {
            let entry = catalog.entry(brokerSymbol: symbol)
            XCTAssertEqual(entry?.market, "US", symbol)
            XCTAssertEqual(entry?.symbol, symbol, symbol)
        }
    }

    /// Coverage is a property of the shipped resource, not of one portfolio.
    /// If a rebuild silently narrowed to US-only again, this is what catches it.
    func testReferenceSpansManyMarkets() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let markets = Set(catalog.entries.values.map(\.market))
        XCTAssertGreaterThan(markets.count, 20, "reference narrowed back to a handful of markets")
        for market in ["GB", "JP", "HK", "DE", "FR", "CA", "AU", "NL", "SG", "CH"] {
            XCTAssertTrue(markets.contains(market), "no \(market) listings in the reference")
        }
        let classified = catalog.entries.values.filter { PortfolioSector(sourceName: $0.sector) != nil }
        XCTAssertGreaterThan(classified.count, 6000)
    }
}


/// `Holding.sector` was `nil` for every position, so anything downstream that
/// asked got nothing. These pin what the model now carries.
final class HoldingSectorTests: XCTestCase {

    private func position(_ ticker: String, currency: String = "USD") -> LocalPositionRecord {
        LocalPositionRecord(
            ticker: ticker, name: ticker, shares: 10, averageCost: 100,
            currency: currency, quotePrice: 110, quoteCurrency: currency,
            source: "test", openedDate: nil
        )
    }

    private func sector(for ticker: String, currency: String = "USD") throws -> String? {
        let document = LocalPortfolioDocument(
            schemaVersion: 4, source: "test", updatedAt: Date(), marketDataUpdatedAt: nil,
            positions: [position(ticker, currency: currency)], snapshots: [], transactions: []
        )
        let holdings = try LocalPortfolioEngine.presentation(for: document).2
        return try XCTUnwrap(holdings.first).sector
    }

    func testUSStockGetsItsSectorFromTheBundledReference() throws {
        XCTAssertEqual(try sector(for: "AMD"), "科技")
        XCTAssertEqual(try sector(for: "XOM"), "能源")
    }

    func testNonUSListingFallsBackToTheOverrideTable() throws {
        XCTAssertEqual(try sector(for: "AZN.L", currency: "GBX"), "医疗保健")
        XCTAssertEqual(try sector(for: "0388.HK", currency: "HKD"), "金融")
    }

    /// A fund is spread across sectors. Naming one of them on the holding
    /// would assert something untrue, so it stays empty and callers that want
    /// the spread ask SectorAttribution for it.
    func testFundHasNoSingleSector() throws {
        XCTAssertNil(try sector(for: "VOO"))
        XCTAssertNil(try sector(for: "SPY"))
    }

    func testUnknownSymbolStaysEmpty() throws {
        XCTAssertNil(try sector(for: "NOTREAL.XX"))
    }

    func testPrimarySectorAgreesWithTheSplitForSingleSectorHoldings() {
        for ticker in ["AMD", "KO", "AZN.L", "SAP.DE"] {
            let split = SectorAttribution.split(ticker: ticker, name: ticker)
            XCTAssertEqual(
                SectorAttribution.primarySector(ticker: ticker), split.weights.first?.key, ticker
            )
        }
    }
}


/// Look-through used to recognise eleven tickers, all of them ones a single
/// portfolio happened to hold. Coverage is now a data file keyed by index.
final class FundLookThroughTests: XCTestCase {

    private func split(_ ticker: String) -> SectorSplit {
        SectorAttribution.split(ticker: ticker, name: ticker)
    }

    func testFundsTrackingTheSameIndexResolveIdentically() {
        // S&P 500, across issuers, listings and share classes.
        let sp500 = ["SPY", "VOO", "IVV", "CSPX.L", "VUAG.L", "VUSA.L", "SXR8.DE"]
        let reference = split("VOO").weights
        XCTAssertFalse(reference.isEmpty)
        for ticker in sp500 {
            XCTAssertEqual(split(ticker).weights, reference, ticker)
        }
    }

    func testCoverageReachesBeyondOnePortfolio() {
        // None of these were recognised before; all are widely held.
        for ticker in ["QQQ", "VT", "VWRL.L", "IWDA.L", "VWCE.DE", "EEM", "VWO", "IWM", "IEFA", "IEMG"] {
            XCTAssertFalse(split(ticker).weights.isEmpty, "\(ticker) should look through")
            XCTAssertTrue(split(ticker).isLookThrough, ticker)
        }
    }

    func testDifferentIndicesDiffer() {
        XCTAssertNotEqual(split("VOO").weights, split("QQQ").weights, "S&P 500 is not the Nasdaq-100")
        XCTAssertNotEqual(split("IEMG").weights, split("IEFA").weights, "emerging is not developed")
    }

    /// The Nasdaq-100 is famously concentrated; the S&P 500 less so. A mix-up
    /// between indices would show up here.
    func testCompositionsLookLikeTheirIndex() throws {
        let ndx = try XCTUnwrap(split("QQQ").weights[.technology])
        let spx = try XCTUnwrap(split("VOO").weights[.technology])

        XCTAssertGreaterThan(ndx, 0.4)
        XCTAssertGreaterThan(ndx, spx)
    }

    /// Weights are normalised over the classified part, so they never exceed 1
    /// and the remainder is reported rather than absorbed.
    func testWeightsNeverExceedOne() {
        for ticker in ["VOO", "QQQ", "VT", "IEMG", "IWM"] {
            let split = split(ticker)
            XCTAssertLessThanOrEqual(split.classifiedFraction, 1.0001, ticker)
            XCTAssertGreaterThanOrEqual(split.unclassifiedFraction, -0.0001, ticker)
        }
    }

    /// A fund nobody has mapped resolves to nothing, not to a nearby index.
    func testUnknownFundDoesNotGuess() {
        XCTAssertTrue(split("NOTAFUND").weights.isEmpty)
        XCTAssertFalse(split("NOTAFUND").isLookThrough)
    }

    /// An individual stock must never be treated as a fund.
    func testStocksAreNotLookedThrough() {
        XCTAssertFalse(split("AMD").isLookThrough)
        XCTAssertEqual(split("AMD").weights.count, 1)
    }
}
