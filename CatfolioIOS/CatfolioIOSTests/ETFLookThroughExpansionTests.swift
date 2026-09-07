import XCTest
@testable import CatfolioIOS

final class ETFLookThroughExpansionTests: XCTestCase {
    private func position(_ ticker: String, value: Double = 1000) -> LocalPositionRecord {
        LocalPositionRecord(ticker: ticker, name: ticker, shares: 1, averageCost: value,
                            currency: "USD", quotePrice: value, quoteCurrency: "USD",
                            source: "test", openedDate: nil)
    }
    private func response(_ tickers: [String]) throws -> ETFLookThroughResponse {
        var document = LocalPortfolioDocument.empty
        document.positions = tickers.map { position($0) }
        return try LocalETFLookThrough.make(document: document, basis: .market)
    }
    func testBroadFundCoverageAndValueConservation() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "etf_holdings", withExtension: "json"))
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let funds = try XCTUnwrap(data["funds"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(funds.count, 60)
        for ticker in funds.keys {
            let result = try response([ticker])
            XCTAssertEqual(result.etfTickers, [ticker])
            XCTAssertGreaterThan(result.constituentCount, 0)
            XCTAssertEqual(result.rows.reduce(0) { $0 + $1.totalUSD }, 1000, accuracy: 0.01, ticker)
        }
    }
    func testInternationalListingKeysDoNotCollideWithUS() throws {
        let result = try response(["ACWI", "NG"])
        XCTAssertTrue(result.rows.contains { $0.ticker == "NG.L" && $0.fromETFUSD > 0 && $0.directUSD == 0 })
        XCTAssertTrue(result.rows.contains { $0.ticker == "NG" && $0.directUSD == 1000 })
        XCTAssertTrue(result.rows.contains { $0.ticker == "6758.T" })
        XCTAssertTrue(result.rows.contains { $0.ticker == "0388.HK" })
    }
    func testDirectAndIndirectHoldingsMergeWithoutLosingUnsupportedFund() throws {
        let result = try response(["ACWI", "NVDA", "UNSUPPORTED.L"])
        let nvda = try XCTUnwrap(result.rows.first { $0.ticker == "NVDA" })
        XCTAssertEqual(nvda.directUSD, 1000)
        XCTAssertGreaterThan(nvda.fromETFUSD, 0)
        XCTAssertEqual(result.rows.first { $0.ticker == "UNSUPPORTED.L" }?.directUSD, 1000)
        XCTAssertEqual(result.etfTickers, ["ACWI"])
        XCTAssertEqual(result.rows.reduce(0) { $0 + $1.totalUSD }, 3000, accuracy: 0.01)
    }
    func testExactFundSnapshotOverridesIndexProxyAndLegacyStillWorks() throws {
        let ivv = try response(["IVV"])
        XCTAssertEqual(ivv.holdingsSource, "iShares official holdings")
        XCTAssertTrue(ivv.holdingsAsOf?.contains("IVV") == true)
        XCTAssertGreaterThan(try response(["VUAG.L"]).constituentCount, 400)
        XCTAssertGreaterThan(try response(["EQQQ.L"]).constituentCount, 90)
        XCTAssertThrowsError(try response(["ACWI.L"]))
    }
}
