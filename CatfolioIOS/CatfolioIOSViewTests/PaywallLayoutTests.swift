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
}
