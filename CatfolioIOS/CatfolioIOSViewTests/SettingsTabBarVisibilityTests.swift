import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SettingsTabBarVisibilityTests: XCTestCase {
    func testSettingsDescendantsHideTabBarAndRootRestoresIt() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let route = Route()
        let host = UIHostingController(rootView: TabView {
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack(path: Binding(get: { route.path }, set: { route.path = $0 })) {
                    SettingsNavigationRow(title: "Services") { Text("Services") }
                        .navigationDestination(for: Int.self) { depth in
                            Text("Settings depth \(depth)").hidesTabBarWhenPushed()
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
