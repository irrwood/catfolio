import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SettingsTabBarVisibilityTests: XCTestCase {
    func testShortReverseDragCanFinishRestoringBarDuringInertia() {
        var state = RootTabBarScrollState()
        XCTAssertNil(state.phaseChanged(to: .interacting, offset: 100))
        XCTAssertEqual(state.scrolled(from: 100, to: 130), true)
        XCTAssertNil(state.phaseChanged(to: .idle, offset: 130))
        XCTAssertNil(state.phaseChanged(to: .tracking, offset: 130))
        XCTAssertNil(state.phaseChanged(to: .interacting, offset: 130))
        XCTAssertNil(state.scrolled(from: 130, to: 124))
        XCTAssertNil(state.phaseChanged(to: .decelerating, offset: 124))
        XCTAssertEqual(state.scrolled(from: 124, to: 116), false)
        // A bottom-edge bounce or forward inertia cannot hide it again.
        XCTAssertNil(state.scrolled(from: 116, to: 145))
    }

    func testTopRestoresBarEvenIfScrollEndsBeforeFinalGeometryCallback() {
        for phase in [ScrollPhase.idle, .decelerating, .animating] {
            var state = RootTabBarScrollState()
            XCTAssertNil(state.phaseChanged(to: .interacting, offset: 100))
            XCTAssertEqual(state.scrolled(from: 100, to: 130), true)
            XCTAssertEqual(state.phaseChanged(to: phase, offset: 0), false)
            XCTAssertEqual(state.scrolled(from: 8, to: 0), false)
        }
    }

    func testPushedPagesHaveNoTabBarAndTheRootBringsItBack() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let route = Route()
        let host = UIHostingController(rootView: testTabs(route: route))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await waitUntil { self.findTabs(host) != nil }
        let tabs = try XCTUnwrap(findTabs(host))
        try await waitUntil { self.isVisible(tabs.tabBar, in: window) }
        for path in [[1], [1, 2], [1]] {
            route.path = path
            try await waitUntil { !self.isVisible(tabs.tabBar, in: window) }
        }
        route.path = []
        try await waitUntil { self.isVisible(tabs.tabBar, in: window) }
    }

    func testInitialDestinationHidesBarBeforeReturningToRoot() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let route = Route()
        route.path = [1]
        let host = UIHostingController(rootView: testTabs(route: route))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await waitUntil { self.findNavigation(host)?.viewControllers.count == 2 }
        let tabs = try XCTUnwrap(findTabs(host))
        try await waitUntil { !self.isVisible(tabs.tabBar, in: window) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(isVisible(tabs.tabBar, in: window))
        route.path = []
        try await waitUntil { self.isVisible(tabs.tabBar, in: window) }
    }

    func testRapidPushesAndPopsLeaveTheBarWhereItBelongs() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let route = Route()
        let host = UIHostingController(rootView: testTabs(route: route))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await waitUntil { self.findTabs(host) != nil }
        let tabs = try XCTUnwrap(findTabs(host))
        try await waitUntil { self.isVisible(tabs.tabBar, in: window) }

        // Each change lands while the last transition is still running.
        for path in [[1], [], [1], [], [1], [1, 2], [1], []] {
            route.path = path
            try await Task.sleep(for: .milliseconds(60))
        }
        try await waitUntil { self.isVisible(tabs.tabBar, in: window) }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(isVisible(tabs.tabBar, in: window))
        // No frozen page or pictured bar is left over anything.
        XCTAssertEqual(pictures(in: window), 0)

        route.path = [1]
        try await waitUntil { !self.isVisible(tabs.tabBar, in: window) }
        try await Task.sleep(for: .seconds(1))
        let pushed = try XCTUnwrap(findNavigation(host)).topViewController
        let pushedView = try XCTUnwrap(pushed?.view)
        XCTAssertFalse(pushedView.subviews.contains { String(describing: type(of: $0)).contains("Replicant") })
    }

    private func findNavigation(_ controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.findNavigation($0) }.first
    }

    private func pictures(in view: UIView) -> Int {
        let own = String(describing: type(of: view)).contains("Replicant") ? 1 : 0
        return own + view.subviews.reduce(0) { $0 + pictures(in: $1) }
    }

    func testScrollingTucksTheBarStraightDownAndBack() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: TabView {
            Tab("Portfolio", systemImage: "chart.bar") { RootPageNavigation { Text("Root").ownsTabBar() } }
            Tab("Settings", systemImage: "gearshape") { Text("Settings") }
        })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            RootTabBar.setTucked(false, animated: false)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.findTabs(host) != nil }
        let tabs = try XCTUnwrap(findTabs(host))
        try await waitUntil { self.isVisible(tabs.tabBar, in: window) }
        let resting = tabs.tabBar.frame

        RootTabBar.setTucked(true, animated: false)
        // Down and off the screen, still full width: not folded sideways.
        XCTAssertEqual(tabs.tabBar.transform.tx, 0)
        XCTAssertGreaterThan(tabs.tabBar.frame.minY, window.bounds.maxY)
        XCTAssertEqual(tabs.tabBar.frame.width, resting.width, accuracy: 0.5)

        RootTabBar.setTucked(false, animated: false)
        XCTAssertEqual(tabs.tabBar.frame, resting)

        for _ in 0..<4 {
            RootTabBar.setTucked(true)
            try await Task.sleep(for: .milliseconds(40))
            RootTabBar.setTucked(false)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(tabs.tabBar.transform, .identity)
        XCTAssertEqual(tabs.tabBar.frame.minY, resting.minY, accuracy: 0.5)
        XCTAssertTrue(isVisible(tabs.tabBar, in: window))
    }

    private func testTabs(route: Route) -> some View {
        TabView {
            Tab("Settings", systemImage: "gearshape") {
                RootPageNavigation { TestPage(route: route, depth: 0).ownsTabBar() }
            }
            Tab("Portfolio", systemImage: "chart.bar") {
                RootPageNavigation { Text("Portfolio").ownsTabBar() }
            }
        }
    }

    private struct TestPage: View {
        let route: Route
        let depth: Int

        var body: some View {
            SettingsPage(title: depth == 0 ? "Account" : "Settings") { Text("Depth \(depth)") }
                .navigationDestination(isPresented: Binding(
                    get: { route.path.count > depth },
                    set: { if !$0 { route.path = Array(route.path.prefix(depth)) } }
                )) { TestPage(route: route, depth: depth + 1) }
        }
    }

    @Observable final class Route { var path: [Int] = [] }

    private func findTabs(_ controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.findTabs($0) }.first
    }

    private func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0.01 { return false }
            ancestor = current.superview
        }
        return view.window === window && view.convert(view.bounds, to: window).intersects(window.bounds)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(20))
            if condition() { return }
        }
        XCTFail("Timed out waiting for settings tab bar visibility")
        throw NSError(domain: "SettingsTabBarVisibilityTests", code: 1)
    }
}
