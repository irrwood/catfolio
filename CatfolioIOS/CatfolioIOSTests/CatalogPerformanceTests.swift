import XCTest
@testable import CatfolioIOS

/// What the holding detail page pays while it is being scrolled.
final class CatalogPerformanceTests: XCTestCase {

    /// `rows` is a computed property read from a view body, so this runs once
    /// per frame. Before the ticker index it walked all 1,477 listings,
    /// upper-cased each one's ticker and sorted the survivors.
    func testFeeLookupIsCheapEnoughForAViewBody() throws {
        let catalog = try ETFReferenceCatalog.bundled.get()
        let symbols = ["VUAG.L", "VOO", "SPY", "AAPL", "EQQQ.L", "NOTAFUND"]

        let start = Date()
        for _ in 0..<600 {
            for symbol in symbols { _ = catalog.expenseRatio(brokerSymbol: symbol) }
        }
        let perLookup = Date().timeIntervalSince(start) / Double(600 * symbols.count)

        // A 120 Hz frame is 8.3 ms and holds far more than one lookup.
        XCTAssertLessThan(
            perLookup, 0.0002,
            "a fee lookup costs \(String(format: "%.4f", perLookup * 1000)) ms — too much per frame"
        )
    }

    /// The index has to find the same listings the scan did, or it is fast
    /// and wrong.
    func testIndexAgreesWithAnExhaustiveScan() throws {
        let catalog = try ETFReferenceCatalog.bundled.get()
        for listing in catalog.listings.values {
            guard let ticker = listing.ticker.verifiedValue else { continue }
            let scanned = catalog.listings.values
                .filter { $0.ticker.verifiedValue?.uppercased() == ticker.uppercased() }
                .map(\.id).sorted()
            let indexed = catalog.matches(symbol: ticker).map(\.id).sorted()
            XCTAssertEqual(indexed, scanned, ticker)
        }
    }

    /// Provider aliases have no index and still scan. That path must keep
    /// working, since it is what a search field uses.
    func testProviderLookupStillResolves() throws {
        let catalog = try ETFReferenceCatalog.bundled.get()
        XCTAssertTrue(catalog.matches(symbol: "NOTAPROVIDERTICKER", provider: "ric").isEmpty)
    }
}
