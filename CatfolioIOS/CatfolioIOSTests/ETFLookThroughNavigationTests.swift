import XCTest
@testable import CatfolioIOS

final class ETFLookThroughNavigationTests: XCTestCase {
    private func row(_ ticker: String = "NVDA") -> ETFLookThroughRow {
        ETFLookThroughRow(ticker: ticker, logoSymbol: ticker, name: "NVIDIA", directUSD: 100,
            fromETFUSD: 50, totalUSD: 150, etfWeightPercent: 5, sector: "Technology",
            allocatedCostUSD: 120, fundMarketValues: ["VUAG.L": 50])
    }

    func testDirectPositionKeepsItsOwnSharesCostAndProfitWhenOpenedFromMergedRow() throws {
        let holding = Holding(ticker: "NVDA", logoSymbol: "NVDA", displayName: "NVIDIA",
            sector: "Technology", source: "test", shares: 1, averageCost: 80, costCurrency: "USD",
            quotePrice: 100, quoteCurrency: "USD", todayChangePercent: 1, marketValue: 100,
            weight: 0.1, unrealized: 20, unrealizedPercent: 25,
            fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
        XCTAssertEqual(row().detailHolding(directHolding: holding, portfolioFraction: 0.15), holding)
    }

    func testETFOnlyConstituentCanOpenWithoutInventingSharesOrAllocatedCostBasis() throws {
        let holding = try XCTUnwrap(row().detailHolding(directHolding: nil, portfolioFraction: 0.15))
        XCTAssertEqual(holding.ticker, "NVDA")
        XCTAssertEqual(holding.shares, 0)
        XCTAssertEqual(holding.averageCost, 0)
        XCTAssertNil(holding.costCurrency)
        XCTAssertEqual(holding.marketValue, 150)
        XCTAssertEqual(holding.weight, 0.15)
        XCTAssertNil(holding.todayChangePercent)
    }

    func testResidualBucketHasNoIndividualSecurityPage() {
        XCTAssertNil(row("ETF 其他").detailHolding(directHolding: nil, portfolioFraction: 0.15))
        XCTAssertNil(row("").detailHolding(directHolding: nil, portfolioFraction: 0.15))
    }
}
