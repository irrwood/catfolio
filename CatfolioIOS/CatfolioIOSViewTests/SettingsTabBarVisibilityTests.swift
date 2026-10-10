import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SettingsTabBarVisibilityTests: XCTestCase {
    func testPushedPagesHaveNoTabBarAndTheRootBringsItBack() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let route = Route()
        let host = UIHostingController(rootView: TabView {
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack(path: Binding(get: { route.path }, set: { route.path = $0 })) {
                    SettingsNavigationRow(title: "Services") { Text("Services") }
                        .ownsTabBar()
                        // Pushed pages do nothing of their own: the bar is the root's.
                        .navigationDestination(for: Int.self) { depth in
                            Text("Settings depth \(depth)")
                        }
                }
            }
            Tab("Portfolio", systemImage: "chart.bar") { Text("Portfolio") }
        })
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

    func testRapidPushesAndPopsLeaveNoPictureBehind() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let route = Route()
        let host = UIHostingController(rootView: TabView {
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack(path: Binding(get: { route.path }, set: { route.path = $0 })) {
                    Text("Root")
                        .ownsTabBar()
                        .navigationDestination(for: Int.self) { depth in Text("Depth \(depth)") }
                }
            }
            Tab("Portfolio", systemImage: "chart.bar") { Text("Portfolio") }
        })
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
        let pushed = try XCTUnwrap(findNavigation(tabs)).topViewController
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
            Tab("Portfolio", systemImage: "chart.bar") { NavigationStack { Text("Root").ownsTabBar() } }
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
