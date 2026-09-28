import XCTest
import SwiftUI
@testable import CatfolioIOS

final class IncomeChartRoundedPathTests: XCTestCase {
    func testEntryPreviewUsesLatestTwoMonthsAcrossYearBoundary() throws {
        let costs = ["A": 100.0]
        let history = HoldingValueHistory(rows: [
            .init(dateText: "2025-10-14", cost: 100, values: ["A": 190], costs: costs),
            .init(dateText: "2025-11-15", cost: 100, values: ["A": 110], costs: costs),
            .init(dateText: "2025-12-15", cost: 100, values: ["A": 120], costs: costs),
            .init(dateText: "2026-01-15", cost: 100, values: ["A": 130], costs: costs)
        ], costs: costs, names: ["A": "A"])
        let preview = try XCTUnwrap(ReturnsSourcePreview.gains(history: history, holdings: []))
        XCTAssertEqual(preview.sourceLayers(), [[10, 20, 30]])
        XCTAssertEqual(preview.headline, 30)
    }

    func testRoundingUsesQuadraticCornerAndPreservesEndpoints() {
        let points = [CGPoint(x: 0, y: 40), CGPoint(x: 20, y: 0), CGPoint(x: 40, y: 40)]
        let path = StandardLineChartRoundedPath.make(points, radius: 6)
        var curves = 0
        var start: CGPoint?
        path.forEach { element in
            switch element {
            case .move(let point): start = point
            case .quadCurve(let end, let control):
                curves += 1
                XCTAssertEqual(control, points[1])
                XCTAssertEqual(end, CGPoint(x: 26, y: 12))
            default: break
            }
        }
        XCTAssertEqual(start, points.first)
        XCTAssertEqual(path.currentPoint, points.last)
        XCTAssertEqual(curves, 1)
        XCTAssertGreaterThanOrEqual(path.boundingRect.minY, 0)
        XCTAssertLessThanOrEqual(path.boundingRect.maxY, 40)
    }

    func testDefaultAndShortPathsStayStraight() {
        for points in [[], [CGPoint.zero], [CGPoint.zero, CGPoint(x: 10, y: 20)]] {
            let path = StandardLineChartRoundedPath.make(points, radius: 6)
            path.forEach { element in
                if case .quadCurve = element { XCTFail("Short paths must stay straight") }
            }
        }
        let path = StandardLineChartRoundedPath.make([.zero, CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 0)], radius: 0)
        path.forEach { element in
            if case .quadCurve = element { XCTFail("Rounding must be opt-in") }
        }
    }
}
