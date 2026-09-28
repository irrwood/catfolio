import Foundation
import XCTest
@testable import CatfolioIOS

final class AIComputedContextTests: XCTestCase {
    func testSnapshotPreservesCalculatedValuesAndMissingData() {
        let summary = PortfolioSummary(totalCost: 100, openPositions: 2, asOf: "2026-09-28", marketValue: 125, unrealized: 25)
        let context = AIComputedContext.build(overview: .init(summary: summary), holdings: [], dailyChanges: [:],
            realisedProfit: .nan, realisedProfitGaps: 3, comparison: nil, analytics: nil,
            updatedAt: Date(timeIntervalSince1970: 0), cachedAt: nil)
        XCTAssertTrue(context.contains("\"market_value_usd\":125"))
        XCTAssertTrue(context.contains("\"unrealized_usd\":25"))
        XCTAssertTrue(context.contains("已实现盈亏 USD：unavailable"))
        XCTAssertTrue(context.contains("缺少卖出盈亏的记录数：3"))
        XCTAssertTrue(context.contains("收益对比：unavailable"))
        XCTAssertTrue(context.contains("1970-01-01T00:00:00Z"))
    }

    func testMissingDrawdownDoesNotBecomeZeroAndWarningsSurvive() {
        let analytics = ReturnsAnalyticsResponse(drawdown: .empty, valuation: .empty, warnings: ["partial coverage"])
        let context = AIComputedContext.build(overview: nil, holdings: [], dailyChanges: [:],
            realisedProfit: 0, realisedProfitGaps: 0, comparison: nil, analytics: analytics,
            updatedAt: nil, cachedAt: nil)
        XCTAssertTrue(context.contains("回撤：unavailable"))
        XCTAssertFalse(context.contains("max_drawdown=0"))
        XCTAssertTrue(context.contains("partial coverage"))
        XCTAssertTrue(context.contains("不得把账户金额"))
    }
}
