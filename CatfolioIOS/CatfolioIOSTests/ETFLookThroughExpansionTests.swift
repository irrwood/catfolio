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

extension ETFLookThroughExpansionTests {
    private func mergedFixture() throws -> (ETFLookThroughResponse, [String: Holding]) {
        var document = LocalPortfolioDocument.empty
        document.positions = [
            pricedPosition("SPY", market: 1200, cost: 900),
            pricedPosition("VOO", market: 600, cost: 800),
            pricedPosition("NVDA", market: 1000, cost: 500),
            pricedPosition("UNSUPPORTED.L", market: 350, cost: 400),
        ]
        let holdings = try LocalPortfolioEngine.presentation(for: document).2
        return (try LocalETFLookThrough.make(document: document, basis: .market),
                Dictionary(uniqueKeysWithValues: holdings.map { ($0.ticker, $0) }))
    }

    func testMergedModeConservesMarketCostAndHoldingProfitAcrossOverlappingFunds() throws {
        let (response, holdings) = try mergedFixture()
        XCTAssertFalse(response.rows.contains { $0.ticker == "SPY" || $0.ticker == "VOO" })
        XCTAssertEqual(response.rows.filter { $0.ticker == "NVDA" }.count, 1)
        XCTAssertEqual(response.rows.reduce(0) { $0 + $1.totalUSD }, 3150, accuracy: 1e-7)
        XCTAssertEqual(response.rows.compactMap(\.allocatedCostUSD).reduce(0, +), 2600, accuracy: 1e-7)
        let performances = try response.rows.map {
            try XCTUnwrap($0.mergedPerformance(for: .holdingPeriod, holdings: holdings, dailyChanges: [:]))
        }
        XCTAssertEqual(performances.reduce(0) { $0 + $1.amount }, 550, accuracy: 1e-7)
        for row in response.rows {
            XCTAssertEqual((row.fundMarketValues ?? [:]).values.reduce(0, +), row.fromETFUSD, accuracy: 1e-7)
        }
    }

    func testMergedDailyProfitAllocatesFundReturnsRatherThanConstituentReturns() throws {
        let (response, holdings) = try mergedFixture()
        let changes = ["SPY": 1.0, "VOO": -2.0, "NVDA": 10.0, "UNSUPPORTED.L": -3.0]
        let results = try response.rows.map {
            try XCTUnwrap($0.mergedPerformance(for: .today, holdings: holdings, dailyChanges: changes))
        }
        let original = holdings.values.compactMap {
            $0.performanceValues(for: .today, dailyChangePercent: changes[$0.ticker])?.amount
        }.reduce(0, +)
        XCTAssertEqual(results.reduce(0) { $0 + $1.amount }, original, accuracy: 1e-8)
        let nvda = try XCTUnwrap(response.rows.first { $0.ticker == "NVDA" })
        let merged = try XCTUnwrap(nvda.mergedPerformance(for: .today, holdings: holdings, dailyChanges: changes))
        let expected = try XCTUnwrap(PortfolioMath.dayContribution(marketValue: 1000, changePercent: 10))
            + (nvda.fundMarketValues ?? [:]).reduce(0) {
                $0 + (PortfolioMath.dayContribution(marketValue: $1.value, changePercent: changes[$1.key]!) ?? 0)
            }
        XCTAssertEqual(merged.amount, expected, accuracy: 1e-8)
        XCTAssertEqual(merged.percent, expected / (nvda.totalUSD - expected) * 100, accuracy: 1e-8)
        XCTAssertNotEqual(merged.percent, 10, "Indirect NVDA carries the allocated fund P/L, not a fabricated stock return")
    }

    func testMergedDailyMissingOneFundDoesNotShowPartialProfit() throws {
        let (response, holdings) = try mergedFixture()
        let nvda = try XCTUnwrap(response.rows.first { $0.ticker == "NVDA" })
        XCTAssertNil(nvda.mergedPerformance(for: .today, holdings: holdings, dailyChanges: ["SPY": 1, "NVDA": 2]))
        XCTAssertNil(nvda.mergedPerformance(for: .today, holdings: holdings, dailyChanges: ["SPY": 1, "VOO": 2]))
        let direct = try XCTUnwrap(response.rows.first { $0.ticker == "UNSUPPORTED.L" })
        XCTAssertNotNil(direct.mergedPerformance(for: .today, holdings: holdings, dailyChanges: ["UNSUPPORTED.L": -3]))
    }

    func testMergedMissingCostDoesNotHideKnownMarketValueOrInventProfit() throws {
        var document = LocalPortfolioDocument.empty
        document.positions = [pricedPosition("SPY", market: 1000, cost: 0), pricedPosition("NVDA", market: 100, cost: 80)]
        let response = try LocalETFLookThrough.make(document: document, basis: .market)
        let values = try LocalPortfolioEngine.presentation(for: document).2
        let holdings = Dictionary(uniqueKeysWithValues: values.map { ($0.ticker, $0) })
        XCTAssertEqual(response.rows.reduce(0) { $0 + $1.totalUSD }, 1100, accuracy: 1e-8)
        for row in response.rows where row.fromETFUSD > 0 {
            XCTAssertNil(row.mergedPerformance(for: .holdingPeriod, holdings: holdings, dailyChanges: [:]))
        }
    }

    func testMergedRemainderKeepsFundCostAndDailyProfit() throws {
        // A focused residual row models cash, derivatives and the unrecognised tail.
        let row = ETFLookThroughRow(ticker: "ETF 其他", logoSymbol: nil, name: "Other", directUSD: 0,
            fromETFUSD: 110, totalUSD: 110, etfWeightPercent: 10, sector: nil,
            allocatedCostUSD: 100, fundMarketValues: ["SPY": 110])
        let holding = try XCTUnwrap(row.mergedPerformance(for: .holdingPeriod, holdings: [:], dailyChanges: [:]))
        XCTAssertEqual(holding.amount, 10)
        XCTAssertEqual(holding.percent, 10)
        let daily = try XCTUnwrap(row.mergedPerformance(for: .today, holdings: [:], dailyChanges: ["SPY": 10]))
        XCTAssertEqual(daily.amount, 10, accuracy: 1e-9)
    }

    func testMergedForeignCurrencyMarketAndCostStayInUSD() throws {
        var document = LocalPortfolioDocument.empty
        document.positions = [
            LocalPositionRecord(ticker: "VUAG.L", name: "Vanguard", shares: 10, averageCost: 15,
                currency: "GBP", quotePrice: 2000, quoteCurrency: "GBp", source: "test", openedDate: nil),
            pricedPosition("NVDA", market: 1000, cost: 800)]
        let presentation = try LocalPortfolioEngine.presentation(for: document)
        let response = try LocalETFLookThrough.make(document: document, basis: .market)
        XCTAssertEqual(response.rows.reduce(0) { $0 + $1.totalUSD }, presentation.0.summary.marketValue, accuracy: 1e-7)
        XCTAssertEqual(response.rows.compactMap(\.allocatedCostUSD).reduce(0, +), presentation.0.summary.totalCost, accuracy: 1e-7)
    }

    func testMergedMultiAccountFundAllocationsCombineOnce() throws {
        var document = LocalPortfolioDocument.empty
        document.positions = [pricedPosition("SPY", market: 1000, cost: 800), pricedPosition("SPY", market: 500, cost: 450)]
        let response = try LocalETFLookThrough.make(document: document, basis: .market)
        XCTAssertEqual(response.rows.reduce(0) { $0 + ($1.fundMarketValues?["SPY"] ?? 0) }, 1500, accuracy: 1e-7)
        XCTAssertEqual(response.rows.compactMap(\.allocatedCostUSD).reduce(0, +), 1250, accuracy: 1e-7)
    }

    func testOldExposureRowsDecodeWithoutInventingNewAllocationData() throws {
        let data = Data(#"{"ticker":"NVDA","name":"NVIDIA","direct_usd":0,"from_etf_usd":100,"total_usd":100,"etf_weight_percent":1}"#.utf8)
        let row = try JSONDecoder().decode(ETFLookThroughRow.self, from: data)
        XCTAssertNil(row.allocatedCostUSD)
        XCTAssertNil(row.fundMarketValues)
        XCTAssertNil(row.mergedPerformance(for: .today, holdings: [:], dailyChanges: ["NVDA": 10]))
    }
}
