import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class ServiceAPIOnboardingLayoutTests: XCTestCase {
    func testWelcomeSelectionAndKeyRenderWithoutCredentials() async throws {
        let defaults = UserDefaults.standard
        let setupSuite = "api-onboarding-layout-\(UUID())"
        let setupDefaults = try XCTUnwrap(UserDefaults(suiteName: setupSuite))
        defer { setupDefaults.removePersistentDomain(forName: setupSuite) }
        let setup = ServiceAPISetupState(defaults: setupDefaults)
        let selectionDefaults = try XCTUnwrap(UserDefaults(suiteName: setupSuite + "-selection"))
        defer { selectionDefaults.removePersistentDomain(forName: setupSuite + "-selection") }
        let selectionSetup = ServiceAPISetupState(defaults: selectionDefaults)
        selectionSetup.started = true
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
                    ("welcome", AnyView(ServiceAPIOnboardingView(setup: setup))),
                    ("provider", AnyView(ServiceAPIOnboardingView(setup: selectionSetup))),
                    ("key", AnyView(NavigationStack {
                        LocalServiceDetailView(provider: .openRouter, setup: setup) { _ in }
                            .environment(\.isServiceAPISetupGuide, true)
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
                    if name == "provider" {
                        let scroll = try XCTUnwrap(findScroll(in: host.view))
                        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                        let bottom = max(-scroll.adjustedContentInset.top,
                            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                        try await Task.sleep(for: .milliseconds(150))
                        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
                        let bottomImage = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                        }
                        try XCTUnwrap(bottomImage.pngData()).write(to: directory.appendingPathComponent(filename + "-bottom.png"))
                    }
                    window.isHidden = true
                    window.rootViewController = nil
                    previousWindow?.makeKeyAndVisible()
                }
            }
        }
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }
}
