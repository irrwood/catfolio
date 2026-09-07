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
