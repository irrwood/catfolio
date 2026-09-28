import XCTest
@testable import CatfolioIOS

final class PortfolioHoldingListTests: XCTestCase {
    private func holding(_ ticker: String, name: String = "Test", value: Double = 100) -> Holding {
        Holding(ticker: ticker, logoSymbol: nil, displayName: name, sector: nil, source: nil,
            shares: 1, averageCost: 80, costCurrency: "USD", quotePrice: value, quoteCurrency: "USD",
            todayChangePercent: 10, marketValue: value, weight: 0.1, unrealized: 20, unrealizedPercent: 25,
            fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }

    private func exposure(_ ticker: String, name: String = "Test", value: Double = 150) -> ETFLookThroughRow {
        .init(ticker: ticker, logoSymbol: nil, name: name, directUSD: 100, fromETFUSD: 50,
            totalUSD: value, etfWeightPercent: 5, sector: nil, allocatedCostUSD: 120,
            fundMarketValues: ["VUAG.L": 50])
    }

    func testDisplayModeChangesAmountsButKeepsTheRealDetailPosition() throws {
        let direct = holding("NVDA")
        let items = PortfolioHoldingListItem.make(holdings: [direct], period: .holdingPeriod, dailyChanges: [:])
        let merged = PortfolioHoldingListItem.make(holdings: [direct], exposures: [exposure("NVDA")],
            period: .holdingPeriod, dailyChanges: [:])
        let normal = try XCTUnwrap(items.first)
        let expanded = try XCTUnwrap(merged.first)
        XCTAssertEqual(normal.marketValue, 100)
        XCTAssertEqual(normal.performance?.amount, 20)
        XCTAssertEqual(expanded.marketValue, 150)
        XCTAssertEqual(expanded.performance?.amount, 30)
        XCTAssertEqual(normal.detailHolding, direct)
        XCTAssertEqual(expanded.detailHolding, direct)
    }

    func testTodayRetainsDirectQuoteFallbackAndFundAllocatedReturn() throws {
        let direct = holding("NVDA")
        let fund = holding("VUAG.L", value: 1000)
        let items = PortfolioHoldingListItem.make(holdings: [direct, fund], exposures: [exposure("NVDA")],
            period: .today, dailyChanges: ["VUAG.L": 25])
        let value = try XCTUnwrap(items.first?.performance)
        let expected = (100 - 100 / 1.1) + (50 - 50 / 1.25)
        XCTAssertEqual(value.amount, expected, accuracy: 1e-8)
        XCTAssertEqual(value.percent, expected / (150 - expected) * 100, accuracy: 1e-8)
    }

    func testBothModesShareSortingIncludingMissingValuesAndNameTies() {
        let inputs: [(String, String, Double, HoldingPerformanceValues?)] = [
            ("AAA", "Same", 100, .init(amount: 20, percent: 25)),
            ("BBB", "Same", 200, .init(amount: -5, percent: -2.5)),
            ("CCC", "Zulu", .nan, nil),
            ("DDD", "Alpha", 150, .init(amount: 30, percent: 12))
        ]
        let expected: [(HoldingSortField, [String], [String])] = [
            (.marketValue, ["AAA", "DDD", "BBB", "CCC"], ["BBB", "DDD", "AAA", "CCC"]),
            (.unrealized, ["BBB", "AAA", "DDD", "CCC"], ["DDD", "AAA", "BBB", "CCC"]),
            (.unrealizedPercent, ["BBB", "DDD", "AAA", "CCC"], ["AAA", "DDD", "BBB", "CCC"]),
            (.name, ["DDD", "AAA", "BBB", "CCC"], ["CCC", "BBB", "AAA", "DDD"])
        ]
        for usesExposure in [false, true] {
            let items: [PortfolioHoldingListItem] = inputs.map { ticker, name, value, performance in
                if usesExposure {
                    return .exposure(exposure(ticker, name: name, value: value), direct: nil,
                                     portfolioTotal: 450, performance: performance)
                }
                return .holding(holding(ticker, name: name, value: value), performance: performance)
            }
            for (field, ascending, descending) in expected {
                XCTAssertEqual(PortfolioHoldingListItem.sorted(items, by: field, ascending: true).map(\.id), ascending)
                XCTAssertEqual(PortfolioHoldingListItem.sorted(items, by: field, ascending: false).map(\.id), descending)
            }
        }
    }

    func testUnavailableExposureFallsBackToDirectRowsAndResidualKeepsItsOwnDestination() throws {
        let direct = holding("NVDA")
        XCTAssertEqual(PortfolioHoldingListItem.make(holdings: [direct], period: .today, dailyChanges: [:])
            .first?.detailHolding, direct)
        XCTAssertTrue(PortfolioHoldingListItem.make(holdings: [direct], exposures: [],
            period: .today, dailyChanges: [:]).isEmpty)
        let items = PortfolioHoldingListItem.make(holdings: [],
            exposures: [exposure("NVDA"), exposure("ETF 其他")], period: .holdingPeriod, dailyChanges: [:])
        XCTAssertEqual(items.first?.detailHolding?.shares, 0)
        XCTAssertEqual(items.first?.detailHolding?.averageCost, 0)
        let other = try XCTUnwrap(items.last)
        XCTAssertNil(other.detailHolding)
        guard case let .exposure(row, _, _, _) = other else { return XCTFail("Keep the summary row") }
        XCTAssertEqual(row.ticker, "ETF 其他")
        XCTAssertEqual(row.fundMarketValues, ["VUAG.L": 50])
    }

    func test52WeekSortUsesRelativeQuotePositionInBothModesAndKeepsMissingLast() {
        let positions = [holding("AAA", value: 110), holding("BBB", value: 19),
                         holding("CCC", value: 250), holding("FLAT", value: 10), holding("MISSING")]
        let ranges: [String: Holding52WeekRange] = [
            "AAA": .init(low: 100, high: 200, latestClose: 180, currency: "USD"),
            "BBB": .init(low: 10, high: 20, latestClose: 11, currency: "USD"),
            "CCC": .init(low: 100, high: 200, latestClose: 190, currency: "USD"),
            "EXPO": .init(low: 100, high: 200, latestClose: 150, currency: "USD"),
            "FLAT": .init(low: 10, high: 10, latestClose: 10, currency: "USD")
        ]
        for lookThrough in [false, true] {
            var items: [PortfolioHoldingListItem] = positions.map {
                lookThrough ? .exposure(exposure($0.ticker), direct: $0, portfolioTotal: 1000, performance: nil)
                    : .holding($0, performance: nil)
            }
            items.append(.exposure(exposure("EXPO"), direct: nil, portfolioTotal: 1000, performance: nil))
            XCTAssertEqual(PortfolioHoldingListItem.sorted(items, by: .week52Position, ascending: true,
                week52Ranges: ranges).map(\.id), ["AAA", "EXPO", "BBB", "CCC", "FLAT", "MISSING"])
            XCTAssertEqual(PortfolioHoldingListItem.sorted(items, by: .week52Position, ascending: false,
                week52Ranges: ranges).map(\.id), ["CCC", "BBB", "EXPO", "AAA", "MISSING", "FLAT"])
        }
    }
}
