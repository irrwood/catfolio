import XCTest
import SwiftUI
@testable import CatfolioIOS

@MainActor
final class HomePlotSeriesCacheTests: XCTestCase {
    private func range(marketValue: Double) throws -> CostMarketRangeData {
        let first = CostMarketPlotPoint(
            dateText: "2026-09-21", date: try XCTUnwrap(DayDateCodec.date(from: "2026-09-21")),
            marketValue: 100, cost: 90
        )
        let latest = CostMarketPlotPoint(
            dateText: "2026-09-22", date: try XCTUnwrap(DayDateCodec.date(from: "2026-09-22")),
            marketValue: marketValue, cost: 95
        )
        return CostMarketRangeData(rows: [first, latest], plottedRows: [first, latest],
                                   domain: 0...max(150, marketValue))
    }

    func testSelectionReusesSeriesButNewHistoryAndAppearanceInvalidateIt() throws {
        let cache = CostMarketPlotSeriesCache()
        let original = try range(marketValue: 120)
        let initial = cache.prepared(for: original, scheme: .light, showsLatestPoint: true)
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(initial.market.points.map(\.value), [100, 120])
        XCTAssertEqual(initial.cost.points.map(\.value), [90, 95])

        // The selected date changes outside the immutable series. Both chart
        // and nearest-point lookup must continue using the same current range.
        let selected = try XCTUnwrap(original.nearest(to: original.rows[0].date))
        XCTAssertEqual(selected.marketValue, 100)
        let afterSelection = cache.prepared(for: original, scheme: .light, showsLatestPoint: true)
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(afterSelection.interactionDates, initial.interactionDates)

        // A new prepared range represents a new response, including account
        // or currency changes, even if the range picker stays on the same tab.
        let refreshed = try range(marketValue: 140)
        XCTAssertNotEqual(original.id, refreshed.id)
        let updated = cache.prepared(for: refreshed, scheme: .light, showsLatestPoint: true)
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertEqual(updated.market.points.last?.value, 140)

        _ = cache.prepared(for: refreshed, scheme: .dark, showsLatestPoint: true)
        XCTAssertEqual(cache.rebuildCount, 3)
        let noEndpoint = cache.prepared(for: refreshed, scheme: .dark, showsLatestPoint: false)
        XCTAssertEqual(cache.rebuildCount, 4)
        XCTAssertEqual(noEndpoint.market.latestPointRadius, 0)
    }

    func testPreparedAccountLookupMatchesFirstRowSemanticsAndMissingDateBounds() {
        let rows = [
            ChartPoint(dateText: "2026-09-21", marketValue: 100, cost: 80),
            ChartPoint(dateText: "2026-09-20", marketValue: 90, cost: 80),
            // Deliberately unsorted and duplicated: the existing calculation
            // chooses the first matching row, not the largest/latest value.
            ChartPoint(dateText: "2026-09-21", marketValue: 999, cost: 80),
            ChartPoint(dateText: "2026-09-22", marketValue: 120, cost: 85),
        ]
        let response = PortfolioChartResponse(
            positionCount: 1,
            positionHistory: .init(available: true, rows: rows),
            currentPoint: rows[3], warning: nil,
            accountNAV: ["2026-09-20": 1, "2026-09-21": 1.1, "2026-09-22": 1.2]
        )
        let prepared = CostMarketPreparedData(source: CostMarketPreparedSource(response: response))
        for (start, end) in [
            ("2026-09-20", "2026-09-21"),
            ("2026-09-21", "2026-09-22"),
            ("2026-09-22", "2026-09-20"),
            ("2026-09-19", "2026-09-21"),
        ] {
            let expected = response.accountPerformance(from: start, to: end)
            let actual = prepared.accountPerformance(from: start, to: end)
            if expected.amount.isNaN {
                XCTAssertTrue(actual.amount.isNaN)
                XCTAssertTrue(actual.percentage.isNaN)
            } else {
                XCTAssertEqual(actual.amount, expected.amount)
                XCTAssertEqual(actual.percentage, expected.percentage, accuracy: 1e-10)
            }
        }
    }
}
