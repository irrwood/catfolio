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
    func testDirectInternationalHoldingsRetainKnownSectorsAfterLookThrough() throws {
        let result = try response(["SPY", "ASML.AS", "SAP.DE", "AZN.L", "0388.HK", "NOTREAL.XX"])
        for (ticker, sector) in ["ASML.AS": PortfolioSector.technology, "SAP.DE": .technology,
                                 "AZN.L": .healthcare, "0388.HK": .financials] {
            let row = try XCTUnwrap(result.rows.first { $0.ticker == ticker })
            XCTAssertEqual(PortfolioSector(sourceName: row.sector), sector, ticker)
            XCTAssertEqual(row.directUSD, 1000)
        }
        XCTAssertNil(result.rows.first { $0.ticker == "NOTREAL.XX" }?.sector)
        XCTAssertEqual(result.rows.reduce(0) { $0 + $1.totalUSD }, 6000, accuracy: 0.01)
    }

    func testExactFundSnapshotOverridesIndexProxyAndLegacyStillWorks() throws {
        let ivv = try response(["IVV"])
        XCTAssertEqual(ivv.holdingsSource, "iShares official holdings")
        XCTAssertTrue(ivv.holdingsAsOf?.contains("IVV") == true)
        XCTAssertGreaterThan(try response(["VUAG.L"]).constituentCount, 400)
        XCTAssertGreaterThan(try response(["EQQQ.L"]).constituentCount, 90)
        XCTAssertThrowsError(try response(["ACWI.L"]))
    }
    private func pricedPosition(_ ticker: String, market: Double, cost: Double) -> LocalPositionRecord {
        LocalPositionRecord(ticker: ticker, name: ticker, shares: 1, averageCost: cost,
                            currency: "USD", quotePrice: market, quoteCurrency: "USD",
                            source: "test", openedDate: nil)
    }

    func testHoldingPeriodPercentUsesExistingAllocatedCostAndMarket() throws {
        var document = LocalPortfolioDocument.empty
        document.positions = [pricedPosition("SPY", market: 1000, cost: 800)]
        let market = try LocalETFLookThrough.make(document: document, basis: .market)
        let cost = try LocalETFLookThrough.make(document: document, basis: .cost)
        XCTAssertEqual(market.rows.reduce(0) { $0 + $1.totalUSD }, 1000, accuracy: 0.01)
        XCTAssertEqual(cost.rows.reduce(0) { $0 + $1.totalUSD }, 800, accuracy: 0.01)
        for row in market.rows where row.fromETFUSD > 0 {
            XCTAssertEqual(try XCTUnwrap(row.estimatedHoldingPeriodPercent), 25, accuracy: 0.000001)
        }
        XCTAssertTrue(cost.rows.allSatisfy { $0.estimatedHoldingPeriodPercent == nil })
    }

    func testHoldingPeriodCombinesFundAndDirectCostsBeforeDividing() throws {
        var document = LocalPortfolioDocument.empty
        document.positions = [
            pricedPosition("SPY", market: 1200, cost: 1000),
            pricedPosition("VOO", market: 600, cost: 800),
            pricedPosition("NVDA", market: 1000, cost: 500),
        ]
        let response = try LocalETFLookThrough.make(document: document, basis: .market)
        let nvda = try XCTUnwrap(response.rows.first { $0.ticker == "NVDA" })
        // SPY and VOO use the same snapshot; their combined allocated gain is
        // zero, while the directly held NVDA has a $500 gain.
        let expected = 500 / (nvda.fromETFUSD + 500) * 100
        XCTAssertEqual(try XCTUnwrap(nvda.estimatedHoldingPeriodPercent), expected, accuracy: 0.000001)
        XCTAssertEqual(response.rows.reduce(0) { $0 + $1.totalUSD }, 2800, accuracy: 0.01)
        let indirectOnly = try XCTUnwrap(response.rows.first { $0.fromETFUSD > 0 && $0.directUSD == 0 })
        XCTAssertEqual(try XCTUnwrap(indirectOnly.estimatedHoldingPeriodPercent), 0, accuracy: 0.000001)
    }

    func testMissingCostDoesNotCreatePartialOrInfiniteReturn() throws {
        for positions in [
            [pricedPosition("SPY", market: 1000, cost: 0)],
            [pricedPosition("SPY", market: 1000, cost: 800), pricedPosition("VOO", market: 1000, cost: 0)],
        ] {
            var document = LocalPortfolioDocument.empty
            document.positions = positions
            let response = try LocalETFLookThrough.make(document: document, basis: .market)
            XCTAssertTrue(response.rows.filter { $0.fromETFUSD > 0 }.allSatisfy { $0.estimatedHoldingPeriodPercent == nil })
        }
        var document = LocalPortfolioDocument.empty
        document.positions = [pricedPosition("SPY", market: 1000, cost: 800), pricedPosition("NVDA", market: 1000, cost: 0)]
        let response = try LocalETFLookThrough.make(document: document, basis: .market)
        XCTAssertNil(response.rows.first { $0.ticker == "NVDA" }?.estimatedHoldingPeriodPercent)
    }

}
