import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountGuideLayoutTests: XCTestCase {
    func testGuideScreensRenderInBothLanguagesAndAppearances() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppLanguage.preferenceKey)
        defer { defaults.set(original, forKey: AppLanguage.preferenceKey) }
        let directory = URL(fileURLWithPath: "/tmp/catfolio-account-guide", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in ["zh-Hans", "en"] {
            defaults.set(language, forKey: AppLanguage.preferenceKey)
            for dark in [false, true] {
                for step in [Trading212GuideStep.prepare] {
                    try await capture(OnboardingPage(progress: OnboardingProgress(step: step.progressStep, total: 3)) {
                        Trading212GuideProgress(step: step)
                        Trading212GuideLesson(step: step, next: {})
                    } actions: {
                        Trading212GuideLesson(step: step, next: {}).actions
                    }, name: "trading212-\(step)-\(language)-\(dark)", dark: dark, directory: directory)
                }
                try await capture(OnboardingPage(progress: OnboardingProgress(step: 1, total: 2)) {
                    IBKRSetupIntro(showGuide: {})
                } actions: {
                    OnboardingPrimaryButton(title: L10n.text("填写 Token 和 Query ID"), action: {})
                }, name: "ibkr-prepare-\(language)-\(dark)", dark: dark, directory: directory)
                for step in 0..<3 {
                    try await capture(OnboardingPage(progress: OnboardingProgress(step: step + 1, total: 3)) {
                        IBKRAccountGuide(step: step, next: {}, skip: {})
                    } actions: {
                        IBKRAccountGuide(step: step, next: {}, skip: {}).actions
                    }, name: "ibkr-\(step)-\(language)-\(dark)", dark: dark, directory: directory)
                }
            }
        }
    }

    func testIBKRConnectionFormLayout() async throws {
        let directory = URL(fileURLWithPath: "/tmp/catfolio-account-guide", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            try await capture(OnboardingPage(progress: OnboardingProgress(step: 2, total: 2)) {
                IBKRConnectionIntro()
                SettingsSectionHeader(L10n.text("Flex 凭证"))
                SettingsCard {
                    SettingsFieldRow("Flex Token", text: .constant(""), isSecure: true, isMonospaced: true)
                    SettingsFieldRow("Query ID", text: .constant(""), isMonospaced: true)
                }
            } actions: {
                OnboardingPrimaryButton(title: L10n.text("保存并创建账户"), isDisabled: true, action: {})
            }, name: "ibkr-connection-\(dark)", dark: dark, directory: directory)
        }
    }

    func testTrading212CredentialsLayout() async throws {
        let suite = "trading212-form-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var draft: String?
        let store = Trading212SetupStore(defaults: defaults, read: { _ in draft }, write: { _, value in draft = value })
        try store.save(.init(step: .credentials, environment: .live, apiKey: "", apiSecret: "",
                             accountSlot: 1, nickname: "Test", nicknameEdited: true), for: .create)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        let directory = URL(fileURLWithPath: "/tmp/catfolio-account-guide", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            try await capture(Trading212View(setupStore: store).environment(model),
                              name: "trading212-key-\(dark)", dark: dark, directory: directory)
        }
    }

    private func capture<V: View>(_ view: V, name: String, dark: Bool, directory: URL) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: view.preferredColorScheme(dark ? .dark : .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
