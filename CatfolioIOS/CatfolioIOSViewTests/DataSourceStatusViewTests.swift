import SwiftUI
import XCTest
@testable import CatfolioIOS

final class DataSourceStatusViewTests: XCTestCase {
    @MainActor
    func testStatusPageRendersEmptyAndMixedSourcesAtNarrowLargeType() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }

        let empty = DataSourceHealth()
        try await capture(empty, language: "zh-Hans", large: false, dark: false,
                          name: "data-source-status-empty-zh")

        let health = DataSourceHealth()
        let sec = try XCTUnwrap(DataSource.named("sec"))
        let yahoo = try XCTUnwrap(DataSource.named("yahoo"))
        let openAI = try XCTUnwrap(DataSource.named("openai"))
        health.apply(.success, for: sec)
        health.apply(.unusable("Company Facts 的格式无法识别"), for: sec, subject: "SOFI")
        health.apply(.rateLimited, for: yahoo)
        health.apply(.success, for: openAI)
        XCTAssertEqual(health.failingCount, 2)

        try await capture(health, language: "en", large: true, dark: false,
                          name: "data-source-status-mixed-en-large")
        try await capture(health, language: "zh-Hans", large: true, dark: true,
                          name: "data-source-status-mixed-zh-dark-large")
    }

    @MainActor
    private func capture(_ health: DataSourceHealth, language: String, large: Bool,
                         dark: Bool, name: String) async throws {
        UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let width: CGFloat = 320
        let height: CGFloat = 920
        let host = UIHostingController(rootView: NavigationStack {
            DataSourceStatusView(health: health)
        }
        .frame(width: width, height: height)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.dynamicTypeSize, large ? .accessibility2 : .large)
        .environment(\.colorScheme, dark ? .dark : .light))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(150))
        host.view.bounds = window.bounds
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
