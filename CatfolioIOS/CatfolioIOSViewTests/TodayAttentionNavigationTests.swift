import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class TodayAttentionNavigationTests: XCTestCase {
    func testBothReportsSwitchWithinOneChildAndRememberSelectionOnReturn() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "attention-navigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        let route = AttentionRoute()
        let host = UIHostingController(rootView: NavigationStack(path: Binding(
            get: { route.path }, set: { route.path = $0 }
        )) {
            SettingsPage { TodayAttentionEntry() }
                .navigationTitle("Performance")
                .navigationDestination(for: Int.self) { _ in TodayAttentionView() }
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

        try await waitUntil { self.navigation(in: host) != nil }
        let navigation = try XCTUnwrap(navigation(in: host))
        XCTAssertEqual(navigation.viewControllers.count, 1)
        XCTAssertNil(defaults.string(forKey: "performance.attention.tab"))

        route.path = [1]
        try await waitUntil { navigation.topViewController?.navigationItem.title == L10n.text("今天值得关注") }
        XCTAssertEqual(navigation.viewControllers.count, 2)
        try assertScrollablePage(navigation)
        attach(window, name: "attention-analysis")

        defaults.set("jev", forKey: "performance.attention.tab")
        try await waitUntil { navigation.topViewController?.navigationItem.title == L10n.text("JEV 今日关注") }
        XCTAssertEqual(navigation.viewControllers.count, 2, "Switching reports must stay on the same child page")
        try assertScrollablePage(navigation)
        attach(window, name: "attention-jev")

        route.path = []
        try await waitUntil { navigation.viewControllers.count == 1 }
        XCTAssertEqual(navigation.topViewController?.navigationItem.title, "Performance")
        route.path = [1]
        try await waitUntil { navigation.topViewController?.navigationItem.title == L10n.text("JEV 今日关注") }

        defaults.set("analysis", forKey: "performance.attention.tab")
        try await waitUntil { navigation.topViewController?.navigationItem.title == L10n.text("今天值得关注") }
        XCTAssertEqual(navigation.viewControllers.count, 2)
        defaults.set("obsolete-tab", forKey: "performance.attention.tab")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(navigation.topViewController?.navigationItem.title, L10n.text("今天值得关注"))
    }

    func testEntryCardsAndChildFitBothSchemesAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let suite = "attention-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            defaults.removePersistentDomain(forName: suite)
        }

        for (language, scheme, size) in [
            ("zh-Hans", ColorScheme.light, DynamicTypeSize.large),
            ("en", ColorScheme.dark, DynamicTypeSize.large),
            ("en", ColorScheme.light, DynamicTypeSize.accessibility1)
        ] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let host = UIHostingController(rootView: NavigationStack {
                SettingsPage(title: "Performance") {
                    ReturnsSourceCards(store: ReturnsSourcePreviewStore())
                    HStack(spacing: 16) {
                        ReturnsComparisonEntryArtwork(title: L10n.text("收益对比"), isCycle: false, returnPercent: 12.3)
                        ReturnsComparisonEntryArtwork(title: L10n.text("周期对比"), isCycle: true, returnPercent: 12.3)
                    }
                    TodayAttentionEntry()
                }
            }.environment(model)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, size)
                .preferredColorScheme(scheme)
                .defaultAppStorage(defaults))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(350))
            let navigation = try XCTUnwrap(navigation(in: host))
            try assertScrollablePage(navigation)
            attach(window, name: "entries-\(language)-\(scheme)-\(size)")

            for tab in TodayAttentionTab.allCases {
                defaults.set(tab.rawValue, forKey: "performance.attention.tab")
                let child = UIHostingController(rootView: NavigationStack { TodayAttentionView() }
                    .environment(model)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.dynamicTypeSize, size)
                    .preferredColorScheme(scheme)
                    .defaultAppStorage(defaults))
                window.rootViewController = child
                try await Task.sleep(for: .milliseconds(350))
                let childNavigation = try XCTUnwrap(self.navigation(in: child))
                try assertScrollablePage(childNavigation)
                XCTAssertLessThan(childNavigation.navigationBar.bounds.height, 80,
                                  "The tabbed child uses a compact title, without a large-title gap")
                attach(window, name: "child-\(tab.rawValue)-\(language)-\(scheme)-\(size)")
            }
        }
    }

    private func assertScrollablePage(_ navigation: UINavigationController) throws {
        let page = try XCTUnwrap(navigation.topViewController)
        page.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(scroll(in: page.view))
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertGreaterThan(scroll.bounds.height, 100)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
    }

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigation(in: $0) }.first
    }

    private func scroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scroll(in: $0) }.first
    }

    private func attach(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the attention page to navigate or switch")
        throw NSError(domain: "TodayAttentionNavigationTests", code: 1)
    }
}

@MainActor @Observable
private final class AttentionRoute {
    var path: [Int] = []
}
