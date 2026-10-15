import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountHeaderTests: XCTestCase {
    func testAccountTabRestoresNativeLargeTitleAndWorkingAddButtonAfterSwitchingTabs() async throws {
        let suite = "AccountHeaderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        await model.refreshPortfolio(refreshMarketData: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: RootTabView().environment(model).defaultAppStorage(defaults))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(500))
        let tabs = try XCTUnwrap(controller(UITabBarController.self, in: host))

        for (index, style) in [(2, UIUserInterfaceStyle.light), (3, .light), (2, .dark), (3, .dark)] {
            window.overrideUserInterfaceStyle = style
            tabs.selectedIndex = index
            tabs.delegate?.tabBarController?(tabs, didSelect: try XCTUnwrap(tabs.selectedViewController))
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertTrue(isVisible(tabs.tabBar, in: window), "Root pages must keep the tab bar visible")
            if index == 2 {
                let navigation = try await selectedNavigation(in: tabs)
                XCTAssertFalse(navigation.isNavigationBarHidden, "Research uses the same native header as Account")
                XCTAssertEqual(navigation.topViewController?.navigationItem.title, L10n.text("研究"))
                continue
            }
            let navigation = try await selectedNavigation(in: tabs)
            XCTAssertFalse(navigation.isNavigationBarHidden, "Account must have its native navigation header")
            XCTAssertEqual(navigation.topViewController?.navigationItem.title, L10n.text("账户"))
            let title = try XCTUnwrap(descendants(window).compactMap { $0 as? UILabel }.first {
                $0.text == L10n.text("账户") && $0.font.pointSize >= 30 && isVisible($0, in: window)
            }, "The large account title must be visible, not attached to a hidden tab")
            let titleFrame = title.convert(title.bounds, to: window)
            XCTAssertLessThan(titleFrame.minX, 25)
            XCTAssertLessThan(titleFrame.minY, window.safeAreaInsets.top + 85)
            _ = try await NativeToolbarTestSupport.button(in: navigation, leading: false,
                                                          identifier: "settings-add-account")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = "account-header-\(style == .light ? "light" : "dark")"
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            addAttachment(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        }
        let navigation = try await selectedNavigation(in: tabs)
        let add = try await NativeToolbarTestSupport.button(in: navigation, leading: false,
                                                            identifier: "settings-add-account")
        try add.tap()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotNil(host.presentedViewController ?? navigation.presentedViewController,
                        "The restored add button must still present account creation")
    }

    private func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        return view.window === window && view.convert(view.bounds, to: window).intersects(window.bounds)
    }

    private func addAttachment(_ attachment: XCTAttachment) { add(attachment) }

    /// A newly selected tab builds its stack on its first visit, sometimes
    /// after a fixed wait has passed; wait for it rather than fail early.
    private func selectedNavigation(in tabs: UITabBarController) async throws -> UINavigationController {
        for _ in 0..<40 {
            if let selected = tabs.selectedViewController,
               let navigation = controller(UINavigationController.self, in: selected) { return navigation }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(controller(UINavigationController.self, in: try XCTUnwrap(tabs.selectedViewController)))
    }

    private func controller<T: UIViewController>(_ type: T.Type, in parent: UIViewController) -> T? {
        if let match = parent as? T { return match }
        return parent.children.lazy.compactMap { self.controller(type, in: $0) }.first
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
