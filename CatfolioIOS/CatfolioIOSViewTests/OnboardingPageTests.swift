import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class OnboardingPageTests: XCTestCase {
    func testFooterReservesSpaceAndFollowsKeyboardOnNarrowScreen() async throws {
        try await verifyLayout(size: .large)
    }

    func testAccessibilityTextCanScrollFullyAboveTheAction() async throws {
        try await verifyLayout(size: .accessibility3)
    }

    func testChangingStepsResetsScrollWithoutPullingHeaderUnderNavigation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let step = Step()
        var headerFrame = CGRect.zero
        let host = UIHostingController(rootView: StepScreen(step: step) { headerFrame = $0 })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(250))
        let initial = headerFrame
        XCTAssertGreaterThan(initial.minY, 80)
        let scroll = try XCTUnwrap(findScroll(in: host.view))
        scroll.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        step.value += 1
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(headerFrame.minY, initial.minY, accuracy: 1)
    }

    @MainActor @Observable final class Step { var value = 0 }

    private struct StepScreen: View {
        let step: Step
        let recordHeader: (CGRect) -> Void
        var body: some View {
            NavigationStack {
                OnboardingPage(scrollReset: step.value, progress: OnboardingProgress(step: step.value + 1, total: 3)) {
                    OnboardingHeader(title: "Step \(step.value)")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { recordHeader($0) }
                    ForEach(0..<20) { index in Text("Instruction \(index)").frame(height: 50) }
                } actions: {
                    OnboardingPrimaryButton(title: "Next") { step.value += 1 }
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") {} } }
            }
        }
    }


    private func verifyLayout(size: DynamicTypeSize) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        var buttonFrame = CGRect.zero
        var finalRowFrame = CGRect.zero
        let host = UIHostingController(rootView: OnboardingPage(progress: OnboardingProgress(step: 2, total: 4)) {
            OnboardingHeader(title: "Connect your account", subtitle: "Keep your investments together.")
            ForEach(0..<6) { index in
                OnboardingFeature(symbol: "key", title: "Connection step \(index)",
                                  detail: "Open the provider, copy your key and return here to continue setting up your account.")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        if index == 5 { finalRowFrame = $0 }
                    }
            }
        } actions: {
            OnboardingPrimaryButton(title: "Continue", action: {})
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { buttonFrame = $0 }
        }.environment(\.dynamicTypeSize, size))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(findScroll(in: host.view))
        let initial = buttonFrame
        XCTAssertGreaterThanOrEqual(initial.height, 54)
        XCTAssertGreaterThan(initial.minY, window.bounds.height * 0.65)
        XCTAssertGreaterThanOrEqual(initial.minX, 24)
        XCTAssertLessThanOrEqual(initial.maxX, window.bounds.maxX - 24)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        scroll.setContentOffset(CGPoint(x: 0,
            y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(buttonFrame.minY, initial.minY, accuracy: 1)
        XCTAssertLessThanOrEqual(finalRowFrame.maxY, buttonFrame.minY)
        host.additionalSafeAreaInsets.bottom = 260
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(buttonFrame.minY, initial.minY - 260, accuracy: 1)
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
}
