import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class RootTabHeaderTests: XCTestCase {
    func testHomeOmitsHeaderAndOtherRootTitlesRestoreAfterTabChanges() async throws {
        let suite = "RootTabHeaderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "catfolio.fakeDataMode")
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let document = FakePortfolioGenerator.make()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { document })
        await model.refreshPortfolio(refreshMarketData: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: RootTabView().environment(model).defaultAppStorage(defaults))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(500))
        let tabs = try XCTUnwrap(controller(UITabBarController.self, in: host))
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            var referenceTitle: CGRect?
            var referenceBarBottom: CGFloat?
            for (index, title) in [(3, L10n.text("账户")), (0, L10n.text("持仓")), (2, L10n.text("研究")),
                                   (4, L10n.text("AI 助手")), (3, L10n.text("账户")), (0, L10n.text("持仓"))] {
                tabs.selectedIndex = index
                tabs.delegate?.tabBarController?(tabs, didSelect: try XCTUnwrap(tabs.selectedViewController))
                try await Task.sleep(for: .milliseconds(800))
                let navigation = try XCTUnwrap(controller(UINavigationController.self, in: try XCTUnwrap(tabs.selectedViewController)))
                if index == 0 {
                    XCTAssertTrue(navigation.isNavigationBarHidden, "Home starts with the portfolio hero")
                    XCTAssertTrue(navigation.topViewController?.navigationItem.title?.isEmpty ?? true)
                    let scroll = try XCTUnwrap(descendants(navigation.view).compactMap { $0 as? UIScrollView }
                        .max(by: { $0.contentSize.height < $1.contentSize.height }))
                    let contentTop = scroll.convert(scroll.bounds, to: window).minY + scroll.adjustedContentInset.top
                    XCTAssertEqual(contentTop, window.safeAreaInsets.top, accuracy: 1,
                                   "Removing the home header must remove its reserved space too")
                    XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1)
                    try capture(window, name: "home-no-header-\(style == .light ? "light" : "dark")")
                    continue
                }
                if index == 4 {
                    try capture(window, name: "ai-toolbar-before-\(style == .light ? "light" : "dark")")
                    // Existing conversations open at their latest message.
                    // A new conversation starts at the top, like the other roots.
                    try await tapToolbarItem(in: navigation, leading: true)
                    try await Task.sleep(for: .milliseconds(450))
                    XCTAssertEqual(navigation.topViewController?.navigationItem.title, L10n.text("对话"))
                    try await tapToolbarItem(in: navigation, leading: false)
                    try await Task.sleep(for: .milliseconds(450))
                }
                XCTAssertFalse(navigation.isNavigationBarHidden, title)
                XCTAssertEqual(navigation.topViewController?.navigationItem.title, title)
                try capture(window, name: "root-header-\(index)-\(style == .light ? "light" : "dark")")
                let frame = try RootTabTitleTestSupport.frame(title: title, window: window)
                let barBottom = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window).maxY
                if let referenceTitle, let referenceBarBottom {
                    XCTAssertEqual(frame.minX, referenceTitle.minX, accuracy: 1, title)
                    XCTAssertEqual(frame.minY, referenceTitle.minY, accuracy: 1, title)
                    XCTAssertEqual(frame.height, referenceTitle.height, accuracy: 1, title)
                    if index != 2 {
                        XCTAssertEqual(barBottom, referenceBarBottom, accuracy: 1, title)
                    } else {
                        let search = try XCTUnwrap(descendants(navigation.view).compactMap { $0 as? UISearchBar }.first)
                        let searchFrame = search.searchTextField.convert(search.searchTextField.bounds, to: window)
                        XCTAssertGreaterThan(searchFrame.minY, frame.maxY,
                                             "Research starts with search below its large title")
                        if #available(iOS 26.0, *) {
                            XCTAssertEqual(barBottom, referenceBarBottom, accuracy: 1,
                                           "The search row belongs to scroll content below the navigation title")
                        } else {
                            XCTAssertGreaterThan(barBottom, referenceBarBottom, "Research includes the system search drawer")
                        }
                    }
                } else {
                    referenceTitle = frame
                    referenceBarBottom = barBottom
                }
                let scroll = try XCTUnwrap(navigation.topViewController?.contentScrollView(for: .top), title)
                XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1,
                               "\(title) must start at its native content inset without an extra header spacer")
                if index == 3 {
                    let initialOffset = scroll.contentOffset
                    scroll.setContentOffset(CGPoint(x: 0, y: 250), animated: true)
                    try await Task.sleep(for: .milliseconds(650))
                    XCTAssertLessThan(navigation.navigationBar.frame.maxY, barBottom)
                    XCTAssertTrue(descendants(navigation.navigationBar).compactMap { $0 as? UILabel }.contains {
                        $0.text == title && $0.font.pointSize < 30 && isVisible($0, in: window)
                    }, "The collapsed account title must remain readable")
                    scroll.setContentOffset(initialOffset, animated: true)
                    try await Task.sleep(for: .milliseconds(650))
                    let restored = try RootTabTitleTestSupport.frame(title: title, window: window)
                    XCTAssertEqual(restored.minY, frame.minY, accuracy: 1)
                }
            }
        }
        // Performance deliberately keeps the heatmap ahead of its in-content
        // title, rather than acquiring a second large title above the heatmap.
        tabs.selectedIndex = 1
        tabs.delegate?.tabBarController?(tabs, didSelect: try XCTUnwrap(tabs.selectedViewController))
        try await Task.sleep(for: .milliseconds(600))
        // The performance tab mounts lazily. A full rendering suite can take
        // longer than the animation delay before its navigation stack exists.
        for _ in 0..<60 {
            if let selected = tabs.selectedViewController,
               let navigation = controller(UINavigationController.self, in: selected),
               navigation.topViewController?.navigationItem.title != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let performance = try XCTUnwrap(controller(UINavigationController.self, in: try XCTUnwrap(tabs.selectedViewController)))
        XCTAssertEqual(performance.topViewController?.navigationItem.title, "")
        XCTAssertEqual(performance.topViewController?.navigationItem.largeTitleDisplayMode, .never)
        try capture(window, name: "root-header-performance")
    }

    private func capture(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }

    private func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        return view.window === window && view.convert(view.bounds, to: window).intersects(window.bounds)
    }

    private func controller<T: UIViewController>(_ type: T.Type, in parent: UIViewController) -> T? {
        if let match = parent as? T { return match }
        return parent.children.lazy.compactMap { self.controller(type, in: $0) }.first
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func tapToolbarItem(in navigation: UINavigationController, leading: Bool) async throws {
        let identifier = leading ? "ai.conversations.toggle" : "ai.conversations.new"
        let button = try await NativeToolbarTestSupport.button(in: navigation, leading: leading,
                                                               identifier: identifier)
        try button.tap()
    }

}

/// Inspect the visible native large title in the window.
@MainActor
enum RootTabTitleTestSupport {
    static func frame(title: String, window: UIWindow) throws -> CGRect {
        let label = try XCTUnwrap(descendants(window).compactMap { $0 as? UILabel }.first {
            $0.text == title && $0.font.pointSize >= 30 && isVisible($0, in: window)
        }, "\(title) must render as a plain large title")
        let frame = label.convert(label.bounds, to: window)
        XCTAssertGreaterThan(frame.height, 30)
        return frame
    }

    private static func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        return view.window === window && view.convert(view.bounds, to: window).intersects(window.bounds)
    }

    private static func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
