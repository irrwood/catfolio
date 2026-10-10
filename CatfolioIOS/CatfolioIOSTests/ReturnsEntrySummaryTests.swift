import XCTest
@testable import CatfolioIOS

final class ReturnsEntrySummaryTests: XCTestCase {
    func testWithdrawalDoesNotTurnFourHundredDollarsIntoEightHundredPercent() {
        let ledger = AccountMWRLedger(dates: ["2026-10-01", "2026-10-02"],
            cashFlows: [1_000, -950], values: [1_000, 450], benchmarkValues: [:])
        let chart = PortfolioChartResponse.accountHistory(ledger: ledger, nav: [1, 1.4], positionCount: 1)
        XCTAssertEqual(chart.allTimeProfitUSD, 400)
    }

    func testWholeHistoryIncludesFirstDayIncomeAndDoesNotAddPrincipal() {
        let ledger = AccountMWRLedger(dates: ["2026-10-01", "2026-10-02", "2026-10-03"],
            cashFlows: [1_000, 5_000, 0], values: [1_050, 6_050, 6_170], benchmarkValues: [:])
        let chart = PortfolioChartResponse.accountHistory(ledger: ledger, nav: [1.05, 1.05, 1.07], positionCount: 1)
        XCTAssertEqual(chart.allTimeProfitUSD, 170, "Keep the initial $50 income and later $120 gain; deposits are not gains")
    }

    func testZeroAndLossStayValidIncludingATotalLoss() {
        for value in [1_000.0, 900, 0] {
            let ledger = AccountMWRLedger(dates: ["2026-10-01"], cashFlows: [1_000],
                values: [value], benchmarkValues: [:])
            let chart = PortfolioChartResponse.accountHistory(ledger: ledger, nav: [value / 1_000], positionCount: 1)
            XCTAssertEqual(chart.allTimeProfitUSD, value - 1_000)
        }
    }

    func testUnavailableHistoryDoesNotPretendCurrentHoldingsAreTheLifetimeResult() {
        let summary = PortfolioSummary(totalCost: 100, openPositions: 1, asOf: nil, marketValue: 900, unrealized: 800)
        XCTAssertNil(PortfolioChartResponse.currentHoldings(overview: .init(summary: summary), positionCount: 1).allTimeProfitUSD)
        XCTAssertNil(PortfolioChartResponse.unavailableAccountHistory(positionCount: 1, reason: "Missing ledger").allTimeProfitUSD)
    }

    func testFullHistoryPreviewUsesTheCurrentEndpointWithoutCappingLargeGains() {
        let old = ChartPoint(dateText: "2026-10-01", marketValue: 100, cost: 100)
        let current = ChartPoint(dateText: "2026-10-02", marketValue: 1_234_567, cost: 100)
        let chart = PortfolioChartResponse(positionCount: 1, positionHistory: .init(available: true, rows: [old]),
            currentPoint: current, warning: nil)
        XCTAssertEqual(chart.allTimeProfitUSD, 1_234_467)
    }

    func testInvalidNumbersNeverReachTheCard() {
        for (value, cost) in [(Double.nan, 100.0), (.infinity, 100), (100, .nan),
                              (.greatestFiniteMagnitude, -.greatestFiniteMagnitude)] {
            let point = ChartPoint(dateText: "2026-10-01", marketValue: value, cost: cost)
            let chart = PortfolioChartResponse(positionCount: 1,
                positionHistory: .init(available: true, rows: [point]), currentPoint: point, warning: nil,
                accountNAV: [point.dateText: 1])
            XCTAssertNil(chart.allTimeProfitUSD)
        }
    }
}
