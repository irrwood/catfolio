import SwiftUI
import XCTest
@testable import CatfolioIOS

final class SettingsInteractionTests: XCTestCase {
    @MainActor
    func testOnlyTheNearestSettingsScrollViewGetsImmediateTouches() {
        let outer = UIScrollView()
        let settings = UIScrollView()
        let nested = UIScrollView()
        let boundary = SettingsImmediateTouchFeedback.BoundaryView()
        let refresh = UIRefreshControl()
        settings.refreshControl = refresh
        outer.addSubview(settings)
        settings.addSubview(boundary)
        settings.addSubview(nested)
        let pan = settings.panGestureRecognizer
        let originalCancellation = settings.canCancelContentTouches

        boundary.configureScrollView()

        XCTAssertFalse(settings.delaysContentTouches)
        XCTAssertTrue(outer.delaysContentTouches)
        XCTAssertTrue(nested.delaysContentTouches)
        XCTAssertEqual(settings.canCancelContentTouches, originalCancellation)
        XCTAssertTrue(settings.panGestureRecognizer === pan)
        XCTAssertTrue(pan.isEnabled)
        XCTAssertTrue(settings.isScrollEnabled)
        XCTAssertTrue(settings.refreshControl === refresh)
    }

    @MainActor
    func testRemovalRestoresOriginalTouchPolicy() {
        let scroll = UIScrollView()
        let boundary = SettingsImmediateTouchFeedback.BoundaryView()
        scroll.addSubview(boundary)
        boundary.configureScrollView()
        boundary.configureScrollView()
        XCTAssertFalse(scroll.delaysContentTouches)
        boundary.restoreScrollView()
        XCTAssertTrue(scroll.delaysContentTouches)

        // Do not change a policy that already opted into immediate touches.
        scroll.delaysContentTouches = false
        boundary.configureScrollView()
        boundary.restoreScrollView()
        XCTAssertFalse(scroll.delaysContentTouches)

        scroll.delaysContentTouches = true
        boundary.configureScrollView()
        boundary.deactivate()
        // A queued SwiftUI update after dismantling cannot reapply the policy.
        boundary.configureScrollView()
        XCTAssertTrue(scroll.delaysContentTouches)
    }

    @MainActor
    func testReparentingRestoresOldScrollAndConfiguresNewScroll() {
        let first = UIScrollView()
        let second = UIScrollView()
        let boundary = SettingsImmediateTouchFeedback.BoundaryView()
        first.addSubview(boundary)
        boundary.configureScrollView()
        second.addSubview(boundary)
        boundary.configureScrollView()
        XCTAssertTrue(first.delaysContentTouches)
        XCTAssertFalse(second.delaysContentTouches)
    }

    @MainActor
    func testActualSettingsPageKeepsImmediateTouchesAfterUpdates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let probe = SettingsTouchProbe()
        let controller = UIHostingController(rootView: SettingsTouchFixture(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(350))
        let scroll = try XCTUnwrap(scrollView(in: controller.view))
        XCTAssertFalse(scroll.delaysContentTouches)
        XCTAssertTrue(scroll.canCancelContentTouches)
        XCTAssertTrue(scroll.touchesShouldCancel(in: UIView()))

        probe.revision += 1
        probe.isOn.toggle()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(scroll.delaysContentTouches)
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertTrue(scroll.panGestureRecognizer.isEnabled)
        XCTAssertEqual(probe.buttonActions, 0)

        scroll.setContentOffset(CGPoint(x: 0, y: 250), animated: true)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(scroll.contentOffset.y, 250, accuracy: 1)
        XCTAssertEqual(probe.buttonActions, 0)
        XCTAssertFalse(scroll.delaysContentTouches)
    }

    @MainActor
    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}

@Observable
private final class SettingsTouchProbe {
    var revision = 0
    var isOn = false
    var buttonActions = 0
}

private struct SettingsTouchFixture: View {
    @Bindable var probe: SettingsTouchProbe

    var body: some View {
        NavigationStack {
            SettingsPage(title: "Settings") {
                SettingsSection {
                    SettingsButtonRow(title: "Action \(probe.revision)") { probe.buttonActions += 1 }
                    SettingsNavigationRow(title: "Detail") { Text("Detail") }
                    SettingsToggleRow(title: "Toggle", isOn: $probe.isOn)
                }
                Color.clear.frame(height: 1500)
            }
        }
    }
}
