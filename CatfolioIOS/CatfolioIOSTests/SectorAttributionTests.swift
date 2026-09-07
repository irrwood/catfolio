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
