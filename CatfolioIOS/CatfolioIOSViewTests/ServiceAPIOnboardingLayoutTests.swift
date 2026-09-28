import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class ServiceAPIOnboardingLayoutTests: XCTestCase {
    func testWelcomeAndReusableGuideRenderWithoutCredentials() async throws {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: AppLanguage.preferenceKey)
        defer { defaults.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let directory = URL(fileURLWithPath: "/tmp/catfolio-service-api-guide", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in ["zh-Hans", "en"] {
            defaults.set(language, forKey: AppLanguage.preferenceKey)
            for dark in [false, true] {
                let screens: [(String, AnyView)] = [
                    ("welcome", AnyView(ServiceAPIOnboardingView())),
                    ("provider", AnyView(NavigationStack {
                        APIKeySetupGuide(title: "OpenRouter", purpose: LocalServiceProvider.openRouter.purpose,
                                         detail: LocalServiceProvider.openRouter.detail,
                                         consoleURL: LocalServiceProvider.openRouter.setupURL) { Text("Form") }
                    }))
                ]
                for (name, screen) in screens {
                    let host = UIHostingController(rootView: screen.preferredColorScheme(dark ? .dark : .light))
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    try await Task.sleep(for: .milliseconds(150))
                    host.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                    }
                    let filename = "\(name)-\(language)-\(dark)"
                    try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(filename + ".png"))
                    let attachment = XCTAttachment(image: image)
                    attachment.name = filename
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    window.isHidden = true
                    window.rootViewController = nil
                    previousWindow?.makeKeyAndVisible()
                }
            }
        }
    }
}
