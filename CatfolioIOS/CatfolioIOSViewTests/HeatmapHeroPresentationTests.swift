import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class HeatmapHeroPresentationTests: XCTestCase {
    func testExpandedHeatmapStartsAtToolbarInsteadOfScreenTop() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var tileFrame = CGRect.zero
        var followingFrame = CGRect.zero
        let state = HeatmapHeroState(isExpanded: true, pull: 0, topInset: 80,
            isOnScreen: true, isScrolling: true, onToggle: {})
        let host = UIHostingController(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 80)
            PerformanceHeatmapHero(state: state, renderKey: 1) { _ in
                Color.green.frame(height: 300)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tileFrame = $0 }
            }
            Color.clear.frame(height: 10)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { followingFrame = $0 }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).ignoresSafeArea())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for _ in 0..<30 where followingFrame == .zero {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(tileFrame.minY, 36, accuracy: 1)
        XCTAssertEqual(tileFrame.height, 300, accuracy: 1)
        XCTAssertEqual(followingFrame.minY, 336, accuracy: 1)
    }
}
