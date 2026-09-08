import XCTest
@testable import CatfolioIOS

/// Every row in a sector sheet opens.
///
/// A row was a `Button` only when `item.holding` was non-nil, and for a
/// look-through constituent that resolves to `directHolding` — nil for anything
/// held only inside an ETF. Those rows rendered through the same `detailRow`
/// and did nothing, so which rows responded looked arbitrary.
///
/// `detailHolding` fills the gap without inventing a position: real ticker,
/// name, sector and exposure; zero shares and zero cost, which is what tells
/// the detail sheet to leave its position blocks out.
final class HeatmapRowTapTargetTests: XCTestCase {

    private func exposure(directHolding: Holding?) -> HoldingsHeatmapTile.Model {
        let row = ETFLookThroughRow(
            ticker: "NVDA", logoSymbol: "NVDA", name: "NVIDIA Corporation",
            directUSD: directHolding == nil ? 0 : 400,
            fromETFUSD: 1_200, totalUSD: 1_600,
            etfWeightPercent: 6.5, sector: "Technology"
        )
        return HoldingsHeatmapTile.Model(
            id: row.ticker, content: .exposure(row, directHolding: directHolding),
            marketValue: row.totalUSD, portfolioFraction: 0.016, changePercent: 2.5,
            performanceTitle: "今日", performancePeriod: .today
        )
    }

    private var directHolding: Holding {
        Holding(
            ticker: "NVDA", logoSymbol: "NVDA", displayName: "NVIDIA Corporation",
            sector: "Technology", source: "test", shares: 3, averageCost: 100,
            costCurrency: "USD", quotePrice: 130, quoteCurrency: "USD",
            todayChangePercent: 2.5, marketValue: 390, weight: 0.004,
            unrealized: 90, unrealizedPercent: 30,
            fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil
        )
    }

    func testAnETFOnlyConstituentStillResolvesToSomethingOpenable() throws {
        let item = exposure(directHolding: nil)

        XCTAssertNil(item.holding, "there is no direct position, and that is unchanged")
        let opened = try XCTUnwrap(item.detailHolding, "the row must still open")
        XCTAssertEqual(opened.ticker, "NVDA")
        XCTAssertEqual(opened.displayName, "NVIDIA Corporation")
        XCTAssertEqual(opened.sector, "Technology")
        XCTAssertEqual(opened.logoSymbol, "NVDA")
        XCTAssertEqual(opened.todayChangePercent, 2.5)
        XCTAssertEqual(opened.marketValue, 1_600, "the look-through exposure is real")
    }

    /// The load-bearing part: nothing invents a cost basis.
    func testAnETFOnlyConstituentCarriesNoPositionAndNoCost() throws {
        let opened = try XCTUnwrap(exposure(directHolding: nil).detailHolding)

        XCTAssertEqual(opened.shares, 0, "zero shares is what hides the position blocks")
        XCTAssertEqual(opened.averageCost, 0)
        XCTAssertEqual(opened.unrealized, 0)
        XCTAssertEqual(opened.unrealizedPercent, 0)
        XCTAssertNil(opened.costCurrency)
        XCTAssertNil(opened.fxPnl)
    }

    func testARealPositionIsPreferredWheneverThereIsOne() throws {
        let item = exposure(directHolding: directHolding)
        let opened = try XCTUnwrap(item.detailHolding)

        XCTAssertEqual(opened.shares, 3, "a direct position must not be replaced by the stub")
        XCTAssertEqual(opened.averageCost, 100)
        XCTAssertEqual(opened, try XCTUnwrap(item.holding))
    }

    func testADirectHoldingRowIsUnaffected() throws {
        let item = HoldingsHeatmapTile.Model(
            id: "NVDA", content: .holding(directHolding), marketValue: 390,
            portfolioFraction: 0.004, changePercent: 2.5,
            performanceTitle: "今日", performancePeriod: .today
        )
        XCTAssertEqual(try XCTUnwrap(item.detailHolding), directHolding)
    }

    /// A holding-period row must not carry a daily change into today's field.
    func testHoldingPeriodReturnIsNotPassedOffAsATodayChange() throws {
        let row = ETFLookThroughRow(
            ticker: "AVGO", logoSymbol: nil, name: "Broadcom", directUSD: 0,
            fromETFUSD: 900, totalUSD: 900, etfWeightPercent: 3, sector: "Technology"
        )
        let item = HoldingsHeatmapTile.Model(
            id: row.ticker, content: .exposure(row, directHolding: nil),
            marketValue: 900, portfolioFraction: 0.009, changePercent: 41,
            performanceTitle: "持有期", performancePeriod: .holdingPeriod
        )
        XCTAssertNil(try XCTUnwrap(item.detailHolding).todayChangePercent)
    }
}
