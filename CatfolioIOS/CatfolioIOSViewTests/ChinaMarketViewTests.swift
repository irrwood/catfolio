import SwiftUI
import XCTest
@testable import CatfolioIOS

final class ChinaMarketViewTests: XCTestCase {
    @MainActor
    func testDetailMemoryCacheSeparatesProvidersAndCredentialChanges() throws {
        let defaults = UserDefaults.standard
        let source = defaults.object(forKey: ChinaMarketSource.preferenceKey)
        let revision = defaults.object(forKey: ChinaMarketConfiguration.revisionKey)
        defer {
            defaults.set(source, forKey: ChinaMarketSource.preferenceKey)
            defaults.set(revision, forKey: ChinaMarketConfiguration.revisionKey)
        }
        let suite = "ChinaMarketViewTests.\(UUID().uuidString)"
        let modelDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { modelDefaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: modelDefaults, personalDocumentLoader: { .empty })
        let holding = MarketSecurityResult(ticker: "600519.SS", name: "贵州茅台", market: "CN",
            exchange: "SSE", currency: "CNY", sector: nil, isFund: false).holding
        defaults.set(ChinaMarketSource.akshare.rawValue, forKey: ChinaMarketSource.preferenceKey)
        let publicPage = model.cachedHoldingDetail(for: holding)
        defaults.set(ChinaMarketSource.longbridge.rawValue, forKey: ChinaMarketSource.preferenceKey)
        let longbridgePage = model.cachedHoldingDetail(for: holding)
        XCTAssertFalse(publicPage === longbridgePage)
        defaults.set(ChinaMarketSource.akshare.rawValue, forKey: ChinaMarketSource.preferenceKey)
        XCTAssertTrue(publicPage === model.cachedHoldingDetail(for: holding))
        defaults.set(ChinaMarketSource.longbridge.rawValue, forKey: ChinaMarketSource.preferenceKey)
        ChinaMarketConfiguration.credentialsChanged()
        XCTAssertFalse(longbridgePage === model.cachedHoldingDetail(for: holding))
    }

    @MainActor
    func testIncompleteCredentialsCannotSaveAndTestFailureCannotClaimSuccess() async {
        let setup = ChinaMarketSetup()
        var saved = false
        setup.save { _ in saved = true }
        XCTAssertFalse(saved)
        XCTAssertTrue(setup.failed)
        setup.appKey = " key "
        setup.appSecret = " secret "
        setup.accessToken = " token "
        setup.save {
            XCTAssertEqual($0.appKey, "key")
            XCTAssertEqual($0.appSecret, "secret")
            saved = true
        }
        XCTAssertTrue(saved)
        XCTAssertFalse(setup.failed)
        await setup.test { _ in throw ChinaMarketError.rejected(401) }
        XCTAssertTrue(setup.failed)
        XCTAssertFalse(setup.testing)
        XCTAssertTrue(setup.message?.contains("401") == true)
        await setup.test { _ in
            .init(price: 100, previousClose: 99, observedAt: Date(timeIntervalSince1970: 1700000000))
        }
        XCTAssertFalse(setup.failed)
        XCTAssertFalse(setup.testing)
    }

    func testShanghaiSessionIncludesLunchBreakAndWeekends() throws {
        func date(_ value: String) throws -> Date {
            try XCTUnwrap(ChinaSecurity.date(value, format: "yyyy-MM-dd HH:mm"))
        }
        XCTAssertTrue(MarketHours.isOpen(ticker: "600519.SS", at: try date("2026-10-19 09:30")))
        XCTAssertFalse(MarketHours.isOpen(ticker: "600519.SS", at: try date("2026-10-19 11:30")))
        XCTAssertTrue(MarketHours.isOpen(ticker: "000001.SZ", at: try date("2026-10-19 13:00")))
        XCTAssertFalse(MarketHours.isOpen(ticker: "000001.SZ", at: try date("2026-10-19 15:00")))
        XCTAssertFalse(MarketHours.isOpen(ticker: "600519.SS", at: try date("2026-10-18 10:00")))
    }

    @MainActor
    func testSettingsAndAttributionRenderInBothLanguages() async throws {
        let scene = try await ChinaMarketViewTestHost.foregroundScene()
        let language = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey) }
        for (locale, appearance, size) in [("zh-Hans", ColorScheme.light, DynamicTypeSize.large),
                                            ("en", .dark, .accessibility1)] {
            UserDefaults.standard.set(locale, forKey: AppLanguage.preferenceKey)
            let controller = UIHostingController(rootView: NavigationStack {
                ChinaMarketSettingsView()
            }.environment(\.locale, Locale(identifier: locale))
                .environment(\.colorScheme, appearance)
                .environment(\.dynamicTypeSize, size))
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(200))
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.view.bounds.width, 390, accuracy: 1)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "china-market-\(locale)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
    }
}

enum ChinaMarketViewTestHost {
    @MainActor
    static func foregroundScene() async throws -> UIWindowScene {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        if scene.activationState != .foregroundActive {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
            for _ in 0..<100 {
                if scene.activationState == .foregroundActive { break }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        return try XCTUnwrap(scene.activationState == .foregroundActive ? scene : nil,
            "The test app must be foregrounded on the unlocked device to capture a real chart")
    }
}
