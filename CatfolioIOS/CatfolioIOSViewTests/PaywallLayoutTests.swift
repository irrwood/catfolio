import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class PaywallLayoutTests: XCTestCase {
    func testPaywallLayouts() async throws {
        let defaults = UserDefaults.standard
        let language = defaults.object(forKey: AppLanguage.preferenceKey)
        defer { defaults.set(language, forKey: AppLanguage.preferenceKey) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let directory = URL(fileURLWithPath: "/tmp/catfolio-paywall", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for locale in ["zh-Hans", "en"] {
            defaults.set(locale, forKey: AppLanguage.preferenceKey)
            for dark in [false, true] {
                let host = UIHostingController(rootView: PaywallView().preferredColorScheme(dark ? .dark : .light))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
                window.rootViewController = host
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(150))
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let name = "paywall-\(locale)-\(dark)"
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
        }
    }

    func testCompactAndAccessibilityLayoutsRemainScrollable() async throws {
        let defaults = UserDefaults.standard
        let language = defaults.object(forKey: AppLanguage.preferenceKey)
        defer { defaults.set(language, forKey: AppLanguage.preferenceKey) }
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let directory = URL(fileURLWithPath: "/tmp/catfolio-paywall", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configurations: [(String, CGSize, DynamicTypeSize)] = [
            ("compact", CGSize(width: 320, height: 568), .large),
            ("accessibility", CGSize(width: 402, height: 874), .accessibility3)
        ]
        for (name, size, typeSize) in configurations {
            let host = UIHostingController(rootView: PaywallView().dynamicTypeSize(typeSize))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await waitUntil { self.scrollView(in: host.view)?.contentSize.height ?? 0 > 0 }
            host.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(scrollView(in: host.view))
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1,
                                     "Plan cards must fit without horizontal scrolling")
            let bottom = max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1,
                           "Both plans and the billing summary must remain reachable")
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("paywall-\(name)-bottom.png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = "paywall-\(name)-bottom"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCloseDismissesPaywallAndRestoreShowsPreviewNotice() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for restores in [false, true] {
            let host = UIHostingController(rootView: PresentedPaywallFixture())
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await waitUntil {
                host.presentedViewController.flatMap { self.navigation(in: $0) } != nil
            }
            let page = try XCTUnwrap(host.presentedViewController)
            let navigation = try XCTUnwrap(navigation(in: page))
            let button = try await NativeToolbarTestSupport.button(in: navigation,
                leading: !restores, identifier: restores ? "paywall-restore" : "paywall-close")
            try button.tap()
            if restores {
                try await waitUntil { self.alert(in: page) != nil }
                let alert = try XCTUnwrap(alert(in: page))
                XCTAssertEqual(alert.title, L10n.text("付费墙预览"))
                XCTAssertEqual(alert.message, L10n.text("当前是测试页面，尚未连接 App Store，没有恢复或更改任何购买记录。"))
            } else {
                try await waitUntil { host.presentedViewController == nil }
            }
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigation(in: $0) }.first
    }

    private func alert(in controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController, let alert = alert(in: presented) { return alert }
        return controller.children.lazy.compactMap { self.alert(in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition(), "The paywall presentation must finish")
    }

}


private struct PresentedPaywallFixture: View {
    @State private var isPresented = true

    var body: some View {
        Color.clear.fullScreenCover(isPresented: $isPresented) { PaywallView() }
    }
}
