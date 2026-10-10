import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class SettingsPageLayoutTests: XCTestCase {
    func testAccountStaysCompactAndAppSettingsFitsBothLanguagesAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let suite = "settings-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        await model.refreshPortfolio(refreshMarketData: false)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        for (language, size, dark) in [
            ("zh-Hans", DynamicTypeSize.large, false),
            ("en", DynamicTypeSize.large, true),
            ("en", DynamicTypeSize.accessibility1, false)
        ] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let account = try await measure(SettingsView(), model: model, window: window,
                language: language, size: size, dark: dark, name: "account")
            let settings = try await measure(AppSettingsView(), model: model, window: window,
                language: language, size: size, dark: dark, name: "settings")
            XCTAssertLessThan(account.contentSize.height, account.bounds.height,
                              "An empty account page should fit without scrolling through app preferences")
            XCTAssertGreaterThan(settings.contentSize.height, settings.bounds.height,
                                 "The dedicated settings page must retain the preference sections")
        }
    }

    private func measure<V: View>(
        _ page: V, model: AppModel, window: UIWindow, language: String,
        size: DynamicTypeSize, dark: Bool, name: String
    ) async throws -> UIScrollView {
        let host = UIHostingController(rootView: NavigationStack { page }
            .environment(model)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, size)
            .preferredColorScheme(dark ? .dark : .light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(350))
        host.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(findScroll(in: host.view))
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)-\(language)-\(size)-\(dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
        return scroll
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
}
