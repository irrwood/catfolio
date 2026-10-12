import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

/// The Research cards keep one height through loading, data and no data, so
/// the page does not shift when the figures land.
@MainActor
final class ResearchCardHeightTests: XCTestCase {
    private let points = (0..<20).map { ResearchMarketSnapshot.Point(id: "d\($0)", value: 100 + Double($0 % 5)) }

    func testMetricCardHeightDoesNotChangeWhenDataLands() {
        let history = Dictionary(uniqueKeysWithValues: (1...20).map {
            (String(format: "2026-09-%02d", $0), 100 + Double($0 % 5))
        })
        let snapshot = ResearchMarketSnapshot(id: "^GSPC", title: "S&P 500", history: history)
        let heights = [
            height(ResearchMetricCard(symbol: "^GSPC", title: "S&P 500", snapshot: nil, isLoading: true)),
            height(ResearchMetricCard(symbol: "^GSPC", title: "S&P 500", snapshot: snapshot)),
            height(ResearchMetricCard(symbol: "^GSPC", title: "S&P 500", snapshot: nil)),
        ]
        XCTAssertEqual(heights[0], heights[1], accuracy: 0.5, "loading vs loaded")
        XCTAssertEqual(heights[2], heights[1], accuracy: 0.5, "no data vs loaded")
    }

    func testMacroCardHeightDoesNotChangeWhenDataLands() {
        let indicator = MacroIndicator(id: "FEDFUNDS", title: "Fed funds", source: .fred,
                                       points: points, isMonthly: true)
        let heights = [
            height(MacroIndicatorCard(indicator: nil, title: "Fed funds", color: .blue, isLoading: true)),
            height(MacroIndicatorCard(indicator: indicator, title: "Fed funds", color: .blue)),
            height(MacroIndicatorCard(indicator: nil, title: "Fed funds", color: .blue)),
        ]
        XCTAssertEqual(heights[0], heights[1], accuracy: 0.5, "loading vs loaded")
        XCTAssertEqual(heights[2], heights[1], accuracy: 0.5, "no data vs loaded")
    }

    private func height(_ view: some View) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: 180))
        return host.sizeThatFits(in: CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude)).height
    }
}
