import XCTest
@testable import CatfolioIOS

/// Financial statements need a ticker's CIK. That lookup used to require a
/// multi-megabyte download from sec.gov before it could answer anything.
final class CompanyCIKSeedTests: XCTestCase {

    func testBundleCarriesVerifiedCIKs() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let verified = catalog.entries.values.filter { $0.verifiedCIK != nil }

        XCTAssertGreaterThan(verified.count, 8_000, "the SEC-verified subset is missing")
    }

    /// Only SEC-directory-verified numbers are usable — an unverified or
    /// conflicting CIK sends the statements request to the wrong company.
    func testUnverifiedCIKsAreNotOffered() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        for entry in catalog.entries.values where entry.cikStatus != "SEC_DIRECTORY_VERIFIED" {
            XCTAssertNil(entry.verifiedCIK, "\(entry.symbol) is \(entry.cikStatus)")
        }
    }

    func testWellKnownTickersResolveOffline() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        // Apple's CIK is a stable, publicly known value.
        XCTAssertEqual(catalog.entry(symbol: "AAPL", market: "US")?.verifiedCIK, 320193)
        for symbol in ["MSFT", "AMD", "KO", "XOM"] {
            XCTAssertNotNil(
                catalog.entry(symbol: symbol, market: "US")?.verifiedCIK, symbol
            )
        }
    }
}

/// Research searches the whole offline directory and opens any result in the
/// security sheet, so a result has to carry the ticker and currency the
/// quote sources expect.
final class MarketSecuritySearchTests: XCTestCase {
    func testAnExactSymbolComesFirstAndUSListingsLeadTheirRank() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let results = MarketSecurityResult.search("aapl", in: catalog)
        XCTAssertEqual(results.first?.ticker, "AAPL")
        XCTAssertEqual(results.first?.currency, "USD")
        let prefixes = catalog.search("to", limit: 200).filter { $0.symbol.uppercased().hasPrefix("TO") }
        let firstOverseas = prefixes.firstIndex { $0.market != "US" } ?? prefixes.endIndex
        XCTAssertFalse(prefixes[firstOverseas...].contains { $0.market == "US" })
    }

    func testAnOverseasListingOpensUnderItsBrokerTickerAndCurrency() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let toyota = try XCTUnwrap(MarketSecurityResult.search("7203", in: catalog).first { $0.market == "JP" })
        XCTAssertEqual(toyota.ticker, "7203.T")
        XCTAssertEqual(toyota.currency, "JPY")
        XCTAssertEqual(toyota.venue, "JP")

        let holding = toyota.holding
        XCTAssertEqual(holding.shares, 0, "nothing held, so the sheet leaves its position blocks out")
        XCTAssertEqual(holding.quoteCurrency, "JPY")
    }

    func testFundsAreMarked() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let spy = try XCTUnwrap(MarketSecurityResult.search("SPY", in: catalog).first)
        XCTAssertEqual(spy.ticker, "SPY")
        XCTAssertTrue(spy.isFund)
        XCTAssertTrue(spy.venue.hasPrefix("ETF · "))
    }
}
