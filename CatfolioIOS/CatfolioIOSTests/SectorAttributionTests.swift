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

    func testEverySectorHasADisplayNameAndSymbol() {
        for sector in PortfolioSector.allCases {
            XCTAssertFalse(sector.displayName.isEmpty)
            XCTAssertFalse(sector.symbolName.isEmpty)
        }
    }
}

/// The hand-written table for listings the generated US reference misses.
final class SectorOverrideTests: XCTestCase {

    func testBundledOverridesLoad() {
        XCTAssertGreaterThan(SectorOverrides.shared.count, 30, "resource missing from the bundle?")
    }

    /// Spot checks across each market the table exists to cover. A wrong
    /// sector here is silent, so the obvious ones are pinned.
    func testKnownListingsResolve() {
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
            XCTAssertEqual(SectorOverrides.shared.sector(for: symbol), sector, symbol)
        }
    }

    func testLookupIsCaseInsensitive() {
        XCTAssertEqual(SectorOverrides.shared.sector(for: "azn.l"), .healthcare)
    }

    func testUnknownSymbolReturnsNil() {
        XCTAssertNil(SectorOverrides.shared.sector(for: "NOTATICKER.XX"))
    }

    /// The generated reference is authoritative; the hand-written table only
    /// fills gaps. If it ever shadowed a covered symbol, a stale hand entry
    /// would quietly outrank fresher data.
    func testOverridesDoNotShadowTheGeneratedReference() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        for symbol in ["AAPL", "AMD", "KO", "XOM", "WMT"] {
            if catalog.entry(symbol: symbol, market: "US")?.sector != nil {
                XCTAssertNil(
                    SectorOverrides.shared.sector(for: symbol),
                    "\(symbol) is already covered upstream and must not be hand-assigned"
                )
            }
        }
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
