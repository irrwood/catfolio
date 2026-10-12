import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SettingsHeaderStabilityTests: XCTestCase {
    func testSettingsSubpagesKeepNativeTitlesAndRestoreTheirScrollPosition() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "settings-header-stability-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        await model.refreshPortfolio(refreshMarketData: false)
        let route = Route()
        let host = UIHostingController(rootView: NavigationStack(path: Binding(
            get: { route.path }, set: { route.path = $0 }
        )) {
            SettingsView()
                .navigationDestination(for: Destination.self) { destination in
                    Group {
                        switch destination {
                        case .settings: AppSettingsView()
                        case .news: NewsSettingsView()
                        case .services: LocalServicesSettingsView()
                        }
                    }
                    .accessibilityIdentifier("header-page-\(route.revision)")
                }
        }.environment(model).defaultAppStorage(defaults))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(500))
        let navigation = try XCTUnwrap(controller(UINavigationController.self, in: host))
        withAnimation { route.path = [.settings] }
        try await Task.sleep(for: .milliseconds(800))

        let expandedScroll = try XCTUnwrap(navigation.topViewController?.contentScrollView(for: .top))
        let expandedOffset = -expandedScroll.adjustedContentInset.top
        let expandedBarHeight = navigation.navigationBar.frame.height
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            for parentCollapsed in [false, true] {
                let parent = try XCTUnwrap(navigation.topViewController)
                let parentScroll = try XCTUnwrap(parent.contentScrollView(for: .top))
                parentScroll.setContentOffset(CGPoint(x: 0, y: parentCollapsed ? 200 : expandedOffset), animated: true)
                try await Task.sleep(for: .milliseconds(650))
                let parentOffset = parentScroll.contentOffset.y
                let parentBarHeight = navigation.navigationBar.frame.height
                if parentCollapsed {
                    XCTAssertLessThan(parentBarHeight, expandedBarHeight)
                } else {
                    XCTAssertEqual(parentBarHeight, expandedBarHeight, accuracy: 1)
                }

                for destination in [Destination.news, .services] {
                    withAnimation { route.path = [.settings, destination] }
                    try await Task.sleep(for: .milliseconds(800))
                    let page = try XCTUnwrap(navigation.topViewController)
                    let scroll = try XCTUnwrap(page.contentScrollView(for: .top))
                    XCTAssertFalse(scroll === parentScroll, "Each subpage must own its navigation scroll view")
                    XCTAssertEqual(page.navigationItem.title, destination.title)
                    XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top, accuracy: 1)
                    let largeTitle = try XCTUnwrap(largeTitle(destination.title, in: window))
                    let titleY = largeTitle.convert(.zero, to: window).y
                    XCTAssertGreaterThan(titleY, window.safeAreaInsets.top)
                    XCTAssertLessThan(titleY, window.safeAreaInsets.top + 85)
                    try await assertStable(navigation, page: page, scroll: scroll, route: route, defaults: defaults)
                    XCTAssertEqual(largeTitle.convert(.zero, to: window).y, titleY, accuracy: 1)

                    scroll.setContentOffset(CGPoint(x: 0, y: 200), animated: true)
                    try await Task.sleep(for: .milliseconds(650))
                    XCTAssertLessThan(navigation.navigationBar.frame.height, expandedBarHeight)
                    try await assertStable(navigation, page: page, scroll: scroll, route: route, defaults: defaults)

                    withAnimation { route.path = [.settings] }
                    try await Task.sleep(for: .milliseconds(800))
                    XCTAssertTrue(navigation.topViewController === parent)
                    XCTAssertTrue(parent.contentScrollView(for: .top) === parentScroll)
                    XCTAssertEqual(parentScroll.contentOffset.y, parentOffset, accuracy: 1,
                                   "Returning from a subpage must preserve the parent's reading position")
                    XCTAssertEqual(navigation.navigationBar.frame.height, parentBarHeight, accuracy: 1)
                    try await assertStable(navigation, page: parent, scroll: parentScroll, route: route, defaults: defaults)
                }
            }
        }
    }

    private func assertStable(
        _ navigation: UINavigationController, page: UIViewController, scroll: UIScrollView,
        route: Route, defaults: UserDefaults
    ) async throws {
        let height = navigation.navigationBar.frame.height
        let offset = scroll.contentOffset.y
        for index in 0..<5 {
            route.revision += 1
            defaults.set(index.isMultiple(of: 2), forKey: ChartInteractionStyle.hapticsPreferenceKey)
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(navigation.navigationBar.frame.height, height, accuracy: 1,
                           "Settings updates must not reopen or collapse the title")
            XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1)
            XCTAssertTrue(page.contentScrollView(for: .top) === scroll)
        }
    }

    enum Destination: Hashable {
        case settings, news, services
        var title: String {
            switch self {
            case .settings: L10n.text("设置")
            case .news: L10n.text("新闻")
            case .services: L10n.text("服务商")
            }
        }
    }
    @Observable final class Route { var path: [Destination] = []; var revision = 0 }

    private func largeTitle(_ text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.text == text, label.font.pointSize >= 30 { return label }
        return view.subviews.lazy.compactMap { self.largeTitle(text, in: $0) }.first
    }

    private func controller<T: UIViewController>(_ type: T.Type, in parent: UIViewController) -> T? {
        if let match = parent as? T { return match }
        return parent.children.lazy.compactMap { self.controller(type, in: $0) }.first
    }
}
