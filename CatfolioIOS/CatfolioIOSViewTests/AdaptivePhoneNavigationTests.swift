import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AdaptivePhoneNavigationTests: XCTestCase {
    func testActualPhoneRootRetainsItsSelectedPageAcrossWindowSizes() async throws {
        let suite = "adaptive-phone-root-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppModel.fakeDataModeKey)
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let document = FakePortfolioGenerator.make()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { document })
        await model.refreshPortfolio(refreshMarketData: false)
        let host = UIHostingController(rootView: RootTabView().environment(model).defaultAppStorage(defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        resize(window, host: host, wide: false)
        window.makeKeyAndVisible()
        defer {
            RootTabBar.setTucked(false, animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await wait { self.tabs(in: host) != nil }
        let tabs = try XCTUnwrap(tabs(in: host))
        RootNavigationRequests.shared.open(.settings)
        try await wait { tabs.selectedIndex == 4 }
        let page = try XCTUnwrap(tabs.selectedViewController)
        var workspace: UISplitViewController?
        for wide in [true, false, true, false] {
            resize(window, host: host, wide: wide)
            try await Task.sleep(for: .milliseconds(700))
            if wide {
                let split = try XCTUnwrap(controllers(host).compactMap { $0 as? UISplitViewController }.first)
                if let workspace { XCTAssertTrue(split === workspace) }
                else { workspace = split }
                XCTAssertNil(self.tabs(in: host), "Expanded Duo must use the iPad workspace, not phone tabs with a sidebar")
                try await wait { self.controllers(split).contains {
                    ($0 as? UINavigationController)?.topViewController?.navigationItem.title == L10n.text("账户")
                } }
                XCTAssertTrue(controllers(split).contains {
                    ($0 as? UINavigationController)?.topViewController?.navigationItem.title == L10n.text("账户")
                })
            } else {
                XCTAssertTrue(self.tabs(in: host) === tabs)
                XCTAssertTrue(tabs.selectedViewController === page)
                XCTAssertEqual(tabs.selectedIndex, 4)
                XCTAssertFalse(controllers(host).contains { $0 is UISplitViewController })
            }
        }
    }

    func testWorkspaceRetainsSearchAndPushedPageAcrossFolds() async throws {
        let probe = Probe()
        let host = UIHostingController(rootView: WorkspaceFixture(probe: probe))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        resize(window, host: host, wide: true)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        try await wait { probe.edit != nil }
        let navigation = try XCTUnwrap(controllers(host).compactMap { $0 as? UINavigationController }
            .first { $0.topViewController?.navigationItem.title == "Research" })
        let root = try XCTUnwrap(navigation.topViewController)
        let identity = try XCTUnwrap(probe.snapshot?.identity)
        probe.edit?()
        try await wait { probe.snapshot?.query == "MSFT" && probe.snapshot?.period == "1Y" }
        probe.push?()
        try await wait { navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil }
        let detail = try XCTUnwrap(navigation.topViewController)

        for wide in [false, true, false, true] {
            resize(window, host: host, wide: wide)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(controllers(host).contains { $0 === navigation }, wide)
            if wide {
                XCTAssertTrue(navigation.topViewController === detail)
                XCTAssertEqual(navigation.viewControllers.count, 2)
            }
            XCTAssertEqual(probe.snapshot, Snapshot(identity: identity, query: "MSFT", period: "1Y"))
        }
        navigation.popViewController(animated: false)
        try await wait { navigation.viewControllers.count == 1 }
        XCTAssertTrue(navigation.topViewController === root)
        XCTAssertEqual(probe.snapshot, Snapshot(identity: identity, query: "MSFT", period: "1Y"))
    }

    func testOnlyBottomHorizontalBarsUseTheDownwardScrollAnimation() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
        XCTAssertTrue(AdaptivePhoneTabNavigation.isBottomBar(
            CGRect(x: 20, y: 625, width: 860, height: 55), in: bounds))
        for frame in [
            CGRect(x: 0, y: 0, width: 900, height: 55),
            CGRect(x: 0, y: 70, width: 55, height: 600),
            CGRect(x: 845, y: 70, width: 55, height: 600),
            CGRect(x: 0, y: 0, width: 320, height: 700),
            .zero
        ] {
            XCTAssertFalse(AdaptivePhoneTabNavigation.isBottomBar(frame, in: bounds))
        }
    }

    private func resize(_ window: UIWindow, host: UIViewController, wide: Bool) {
        window.frame = CGRect(x: 0, y: 0, width: wide ? 1000 : 393, height: wide ? 800 : 852)
        host.traitOverrides.horizontalSizeClass = wide ? .regular : .compact
        host.traitOverrides.verticalSizeClass = .regular
        window.setNeedsLayout()
        window.layoutIfNeeded()
    }

    private struct WorkspaceFixture: View {
        let probe: Probe
        var body: some View {
            AdaptivePhoneWorkspace {
                Text("Phone")
            } workspace: {
                WorkspaceSplitView {
                    Text("Sidebar")
                } detail: {
                    WorkspaceDetailStack { SearchPage(probe: probe) }
                }
            }
        }
    }

    private struct SearchPage: View {
        let probe: Probe
        @State private var identity = UUID()
        @State private var query = "AAPL"
        @State private var period = "1M"
        @State private var pushed = false
        private var snapshot: Snapshot { Snapshot(identity: identity, query: query, period: period) }
        var body: some View {
            SettingsPage(title: "Research", navigationRole: .root) {
                TextField("Search", text: $query)
                Picker("Period", selection: $period) {
                    Text("1M").tag("1M")
                    Text("1Y").tag("1Y")
                }
                Button("Detail") { pushed = true }
            }
            .navigationDestination(isPresented: $pushed) {
                SettingsPage(title: "Detail", titleDisplayMode: .inline) { Text("Detail content") }
            }
            .onAppear {
                probe.snapshot = snapshot
                probe.edit = { query = "MSFT"; period = "1Y" }
                probe.push = { pushed = true }
            }
            .onChange(of: snapshot) { _, value in probe.snapshot = value }
        }
    }

    fileprivate struct Snapshot: Equatable {
        let identity: UUID
        let query: String
        let period: String
    }
    @Observable fileprivate final class Probe {
        var selection = 1
        var snapshot: Snapshot?
        var edit: (() -> Void)?
        var push: (() -> Void)?
    }
    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
    }
    private func tabs(in controller: UIViewController) -> UITabBarController? {
        controllers(controller).compactMap { $0 as? UITabBarController }.first
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Navigation did not settle")
    }
}
