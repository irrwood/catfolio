import XCTest
@testable import CatfolioIOS

final class CompanyReferenceSearchTests: XCTestCase {
    /// The byte-buffer search must rank exactly as a plain scan of every
    /// entry with `String` matching does.
    func testSearchMatchesReferenceScan() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        func fold(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        for query in ["a", "ap", "apple", "micro", "bank", "腾讯", "银行", "nestle", "7203", "brk", "zzzz"] {
            for market in [nil, "US", "JP"] as [String?] {
                let needle = fold(query)
                let exactKeys = Set(catalog.aliases.filter {
                    fold($0.key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "") == needle
                }.map(\.value))
                let expected = catalog.entries.compactMap { key, entry -> (Int, String, CompanyReferenceCatalog.Entry)? in
                    if let market, entry.market != market { return nil }
                    let symbol = fold(entry.symbol), name = fold(entry.name ?? "")
                    let rank: Int
                    if symbol == needle || exactKeys.contains(key) { rank = 0 }
                    else if symbol.hasPrefix(needle) { rank = 1 }
                    else if name.hasPrefix(needle) { rank = 2 }
                    else if name.contains(needle) { rank = 3 }
                    else { return nil }
                    return (rank, key, entry)
                }.sorted { lhs, rhs in
                    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                    let lhsUS = lhs.2.market == "US", rhsUS = rhs.2.market == "US"
                    if lhsUS != rhsUS { return lhsUS }
                    if lhs.2.symbol.count != rhs.2.symbol.count { return lhs.2.symbol.count < rhs.2.symbol.count }
                    return lhs.1 < rhs.1
                }.prefix(16).map(\.1)
                let actual = catalog.search(query, market: market, limit: 16).map { "\($0.market):\($0.symbol)" }
                XCTAssertEqual(actual, Array(expected), "\(query) \(market ?? "all")")
            }
        }
    }

    func testExactSymbolRanksFirst() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        XCTAssertEqual(catalog.search("AAPL", limit: 5).first?.symbol, "AAPL")
        XCTAssertEqual(catalog.search("aapl", market: "US", limit: 5).first?.market, "US")
    }

    func testCancelledSearchReturnsNothing() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        XCTAssertTrue(catalog.search("zq", limit: 40, shouldCancel: { true }).isEmpty)
    }
}

final class CompanyReferenceSearchTimingTests: XCTestCase {
    /// Prints per-query search cost; the budget is a few milliseconds on a
    /// device, and the simulator on a Mac runs faster than that.
    func testSearchTiming() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let prepare = ContinuousClock().measure { catalog.prepareSearch() }
        print("search.prepare \(prepare)")
        for query in ["a", "ap", "app", "apple", "micro", "腾讯", "银行", "zzzz"] {
            let clock = ContinuousClock()
            var elapsed: Duration = .zero
            for _ in 0..<20 { elapsed += clock.measure { _ = catalog.search(query, limit: 16) } }
            print("search.query \(query) \(elapsed / 20)")
        }
    }
}
