import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountFlowActionsTests: XCTestCase {
    func testActionsStayAtBottomWhileLastContentCanScrollAboveThem() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        var buttonFrame = CGRect.zero
        var lastRowFrame = CGRect.zero
        let host = UIHostingController(rootView: SettingsPage(bottomInset: 16) {
            ForEach(0..<30) { index in
                Text("Import preview \(index)")
                    .frame(height: 50)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        if index == 29 { lastRowFrame = $0 }
                    }
            }
        }.accountFlowActions {
            GlassPrimaryButton(title: "Next", action: {})
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { buttonFrame = $0 }
        })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.loadViewIfNeeded()
        for _ in 0..<100 where buttonFrame == .zero || findScroll(in: host.view) == nil {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let initial = buttonFrame
        XCTAssertGreaterThan(initial.minY, window.bounds.height * 0.7)
        XCTAssertLessThanOrEqual(initial.maxY, window.bounds.maxY - window.safeAreaInsets.bottom)
        let scroll = try XCTUnwrap(findScroll(in: host.view))
        scroll.setContentOffset(CGPoint(x: 0,
            y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(buttonFrame.minY, initial.minY, accuracy: 1)
        XCTAssertLessThanOrEqual(lastRowFrame.maxY, buttonFrame.minY)
        // A smaller bottom safe area, as when the keyboard occupies the
        // bottom of the page, carries the actions with it.
        host.additionalSafeAreaInsets.bottom = 300
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(buttonFrame.minY, initial.minY - 300, accuracy: 1)
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
}
