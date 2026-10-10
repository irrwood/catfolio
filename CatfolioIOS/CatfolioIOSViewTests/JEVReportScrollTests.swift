import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class JEVReportScrollTests: XCTestCase {
    func testLongReportScrollsAndUpdatesExpandedCards() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let probe = ExpansionProbe()
        let holding = Holding(ticker: "TEST", logoSymbol: nil, displayName: "Test", sector: nil, source: nil,
            shares: 10, averageCost: 50, costCurrency: "USD", quotePrice: 70, quoteCurrency: "USD",
            todayChangePercent: 1.5, marketValue: 700, weight: 0.25, unrealized: 200,
            unrealizedPercent: 40, fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
        let facts = JEVHoldingFacts.make(holding: holding, bars: [], spy: [])
        let scores = Dictionary(uniqueKeysWithValues: JEVDimension.allCases.map {
            ($0.rawValue, JEVScore(score: 3, confidence: 0.8))
        })
        let calls = (0..<100).map { index in
            JEVCall(ticker: "SCROLL\(index)", name: "Scroll report \(index)", logoSymbol: nil,
                facts: facts, scores: scores, error: nil,
                explanation: String(repeating: "Trend, momentum, stretch and risk. ", count: 30))
        }
        let report = JEVReport(generatedAt: .now, model: "scroll-test", calls: calls)
        let host = UIHostingController(rootView: NavigationStack {
            SettingsPage {
                JEVReportCards(report: report, expanded: Binding(
                    get: { probe.expanded }, set: { probe.expanded = $0 }), explain: { _ in })
            }.navigationTitle("JEV")
        })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(250))
        let scroll = try XCTUnwrap(findScroll(in: host.view))
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height * 10)
        for index in 0..<12 {
            probe.expanded = index.isMultiple(of: 2) ? Set(calls.map(\.id)) : []
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: index.isMultiple(of: 2) ? maximum : 0), animated: false)
            try await Task.sleep(for: .milliseconds(40))
            host.view.layoutIfNeeded()
            _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            XCTAssertTrue(scroll.isScrollEnabled)
            XCTAssertTrue(scroll.contentOffset.y.isFinite)
        }
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }

    @Observable final class ExpansionProbe {
        var expanded: Set<String> = []
    }
}
