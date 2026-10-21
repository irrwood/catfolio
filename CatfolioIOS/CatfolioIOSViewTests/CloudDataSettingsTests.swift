import Observation
import SwiftUI
import XCTest
@testable import CatfolioIOS

final class CloudDataSettingsTests: XCTestCase {
    @MainActor
    func testSwitchBindingsChangeOnlyTheirOwnSyncFeature() async throws {
        let credentials = SettingsDataSyncProbe()
        let portfolio = SettingsDataSyncProbe()
        let keyControls = controls(credentials, "credentials")
        let portfolioControls = controls(portfolio, "portfolio")

        XCTAssertFalse(keyControls.enabled.wrappedValue)
        XCTAssertFalse(portfolioControls.enabled.wrappedValue)

        keyControls.enabled.wrappedValue = true
        try await settleActions()
        XCTAssertEqual(credentials.enabledChanges, [true])
        XCTAssertTrue(keyControls.enabled.wrappedValue)
        XCTAssertFalse(portfolioControls.enabled.wrappedValue)
        XCTAssertTrue(portfolio.enabledChanges.isEmpty)

        portfolioControls.enabled.wrappedValue = true
        try await settleActions()
        keyControls.enabled.wrappedValue = false
        try await settleActions()
        XCTAssertEqual(credentials.enabledChanges, [true, false])
        XCTAssertEqual(portfolio.enabledChanges, [true])
        XCTAssertTrue(portfolioControls.enabled.wrappedValue,
                      "Portfolio encryption remains enabled when API-key sync is disabled")
    }

    @MainActor
    func testRetryTargetsOnlyTheEnabledIdleFeature() async throws {
        let credentials = SettingsDataSyncProbe()
        let portfolio = SettingsDataSyncProbe()
        let keyControls = controls(credentials, "credentials")
        let portfolioControls = controls(portfolio, "portfolio")

        keyControls.requestRefresh()
        try await settleActions()
        XCTAssertEqual(credentials.refreshCount, 0)

        credentials.isEnabled = true
        credentials.isBusy = true
        keyControls.requestRefresh()
        keyControls.enabled.wrappedValue = false
        try await settleActions()
        XCTAssertEqual(credentials.refreshCount, 0)
        XCTAssertFalse(credentials.isEnabled, "An in-flight request must not prevent turning sync off")
        XCTAssertEqual(credentials.enabledChanges, [false])

        keyControls.enabled.wrappedValue = true
        try await settleActions()
        XCTAssertFalse(credentials.isEnabled, "Wait for cancellation before enabling a new request")
        XCTAssertEqual(credentials.enabledChanges, [false])

        credentials.isBusy = false
        credentials.isEnabled = true
        keyControls.requestRefresh()
        portfolioControls.requestRefresh()
        try await settleActions()
        XCTAssertEqual(credentials.refreshCount, 1)
        XCTAssertEqual(portfolio.refreshCount, 0)
        XCTAssertTrue(credentials.isEnabled)
    }

    func testCloudSettingsEnglishCopyExplainsSeparateEncryptionKeyAndDeviceOptIn() {
        XCTAssertEqual(L10n.render("同步 API 密钥", language: "en"), "Sync API keys")
        XCTAssertEqual(L10n.render("同步账户与持仓", language: "en"), "Sync accounts and holdings")
        XCTAssertEqual(L10n.render("等待钥匙串中的解密密钥", language: "en"), "Waiting for the decryption key in iCloud Keychain")
        let privacy = L10n.render("账户、持仓与交易记录在本机加密后上传到你的 iCloud 私有数据库。解密密钥通过 iCloud 钥匙串同步，不受 API 密钥开关影响。", language: "en")
        XCTAssertTrue(privacy.contains("encrypted on this device"))
        XCTAssertTrue(privacy.contains("independently of API-key sync"))
    }

    @MainActor
    func testStoredStatusFollowsLanguageSwitchWithoutRefreshingCloud() {
        let model = SettingsDataSyncProbe()
        model.statusText = "暂时无法同步密钥，请检查 iCloud 和钥匙串设置后重试。"
        let presentation = controls(model, "credentials")
        ContentLanguage.$requested.withValue("en") {
            XCTAssertEqual(presentation.localizedStatusText,
                           "Unable to sync keys right now. Check iCloud and Keychain settings, then try again.")
        }
        ContentLanguage.$requested.withValue("zh-Hans") {
            XCTAssertEqual(presentation.localizedStatusText, model.statusText)
        }
        XCTAssertEqual(model.refreshCount, 0)
    }

    /// Both models are in memory. Rendering these states must not contact the
    /// user's CloudKit container or the synchronizable Keychain.
    @MainActor
    func testCloudDataSettingsScreenshots() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let window = UIWindow(windowScene: scene)
        defer {
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }

        for (name, language, keysEnabled, portfolioEnabled, large) in [
            ("icloud-data-off-zh", "zh-Hans", false, false, false),
            ("icloud-keys-only-en", "en", true, false, false),
            ("icloud-portfolio-only-zh", "zh-Hans", false, true, false),
            ("icloud-data-errors-large-en", "en", true, true, true)
        ] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let credentials = SettingsDataSyncProbe()
            let portfolio = SettingsDataSyncProbe()
            credentials.isEnabled = keysEnabled
            portfolio.isEnabled = portfolioEnabled
            credentials.statusText = L10n.text(keysEnabled ? "正在同步钥匙串…" : "未开启")
            portfolio.statusText = L10n.text(portfolioEnabled ? "等待钥匙串中的解密密钥" : "未开启")
            if large {
                credentials.statusText = L10n.text("暂时无法同步密钥，请检查 iCloud 和钥匙串设置后重试。")
                portfolio.statusText = L10n.text("Apple 账户已更改，请切回原账户")
                portfolio.lastSyncedAt = Date(timeIntervalSince1970: 1_792_152_000)
            }
            let controller = UIHostingController(rootView: NavigationStack {
                SettingsPage(title: "iCloud") {
                    CloudDataSettingsSection(credentialSync: credentials, portfolioSync: portfolio)
                }
            }
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
            .preferredColorScheme(large ? .dark : .light))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            attachScreenshot(window, name: name + "-top")
            if let scroll = scrollView(in: controller.view) {
                let bottom = max(-scroll.adjustedContentInset.top,
                                 scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                attachScreenshot(window, name: name + "-bottom")
            }
        }
    }

    @MainActor
    private func controls(_ model: SettingsDataSyncProbe, _ identifier: String) -> CloudDataSyncSettingsControls {
        CloudDataSyncSettingsControls(sync: model, title: identifier, icon: "icloud", identifier: identifier)
    }

    private func settleActions() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    @MainActor
    private func attachScreenshot(_ window: UIWindow, name: String) {
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}

@MainActor
@Observable
private final class SettingsDataSyncProbe: CloudDataSyncSettingsModel {
    var isEnabled = false
    var isBusy = false
    var statusText = "Off"
    var lastSyncedAt: Date?
    var enabledChanges: [Bool] = []
    var refreshCount = 0

    func setEnabled(_ enabled: Bool) async {
        enabledChanges.append(enabled)
        isEnabled = enabled
    }

    func refresh() async { refreshCount += 1 }
}
