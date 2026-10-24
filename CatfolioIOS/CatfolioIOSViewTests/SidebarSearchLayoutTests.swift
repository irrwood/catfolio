import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SidebarSearchLayoutTests: XCTestCase {
    func testSearchIdentityAndQuotesFitNarrowWideAndAccessibilitySidebars() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let results = [
            MarketSecurityResult(ticker: "UBER", name: "Uber Technologies, Inc.", market: "US",
                exchange: "NYSE", currency: "USD", sector: nil, isFund: false),
            MarketSecurityResult(ticker: "DX-Y.NYB", name: "US Dollar Index", market: "US",
                exchange: "ICE Futures", currency: "USD", sector: nil, isFund: false),
            MarketSecurityResult(ticker: "VUSA.L", name: "Vanguard S&P 500 UCITS ETF", market: "UK",
                exchange: "LSE", currency: "GBP", sector: nil, isFund: true)
        ]
        for width: CGFloat in [280, 360, 440] {
            for large in [false, true] {
                let frames = Frames()
                let host = UIHostingController(rootView: VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        SidebarSecuritySearchRow(result: result, entry: WatchlistEntry(holding: result.holding),
                            quote: index == 2 ? nil : WatchlistQuote(price: index == 0 ? 66.70 : 1098.88,
                                changePercent: index == 0 ? -3.43 : 0.14, observedAt: nil), isHeld: index == 0)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: width)
                .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                .overlayPreferenceValue(ResearchCardLayoutFrames.self) { anchors in
                    GeometryReader { geometry in
                        let values = anchors.mapValues { geometry[$0] }
                        Color.clear.onAppear { frames.values = values }
                            .onChange(of: values) { _, value in frames.values = value }
                    }
                })
                window.rootViewController = host
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(200))
                for result in results {
                    let row = try XCTUnwrap(frames.values["sidebar-search.row.\(result.id)"])
                    let identity = try XCTUnwrap(frames.values["sidebar-search.identity.\(result.id)"])
                    let metrics = try XCTUnwrap(frames.values["sidebar-search.metrics.\(result.id)"])
                    XCTAssertEqual(row.width, width - 24, accuracy: 1)
                    XCTAssertGreaterThanOrEqual(identity.minX, row.minX - 1)
                    XCTAssertLessThanOrEqual(metrics.maxX, row.maxX + 1)
                    if large {
                        XCTAssertGreaterThanOrEqual(metrics.minY, identity.maxY + 7)
                    } else {
                        XCTAssertGreaterThanOrEqual(metrics.minX, identity.maxX + 11)
                        XCTAssertEqual(metrics.maxX, row.maxX, accuracy: 1)
                    }
                }
            }
        }
    }

    private final class Frames { var values: [String: CGRect] = [:] }
}
