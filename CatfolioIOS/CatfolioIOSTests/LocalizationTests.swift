import Foundation
import XCTest
@testable import CatfolioIOS

final class LocalizationTests: XCTestCase {
    func testLanguageResolutionAndFallback() {
        XCTAssertEqual(AppLanguage.resolvedIdentifier("en", preferredLanguages: ["zh-CN"]), "en")
        XCTAssertEqual(AppLanguage.resolvedIdentifier("zh-Hans", preferredLanguages: ["en-GB"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolvedIdentifier("system", preferredLanguages: ["zh-TW"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolvedIdentifier(nil, preferredLanguages: ["en-GB"]), "en")
        XCTAssertEqual(AppLanguage.resolvedIdentifier("invalid", preferredLanguages: []), "en")
        XCTAssertEqual(AppLanguage.resolvedIdentifier("system", preferredLanguages: ["fr-FR", "zh-CN"]), "zh-Hans")
    }

    func testBothLanguagesAreBundledAndHaveMatchingPlaceholders() throws {
        func catalog(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
        }
        let english = try catalog("en")
        let chinese = try catalog("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertGreaterThan(english.count, 950)
        for (key, value) in english {
            XCTAssertEqual(key.components(separatedBy: "%@").count, value.components(separatedBy: "%@").count, key)
            XCTAssertEqual(key.components(separatedBy: "%@").count, chinese[key]?.components(separatedBy: "%@").count, key)
        }
    }

    func testSwitchingDoesNotCacheThePreviousLanguage() {
        XCTAssertEqual(L10n.render("设置", language: "en"), "Settings")
        XCTAssertEqual(L10n.render("设置", language: "zh-Hans"), "设置")
        XCTAssertEqual(L10n.render("设置", language: "en"), "Settings")
        XCTAssertEqual(L10n.render("Performance", language: "zh-Hans"), "收益表现")
    }

    func testSavedLanguageChangesAffectTheNextRender() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppLanguage.preferenceKey)
        defer {
            if let original { defaults.set(original, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(L10n.text("语言"), "Language")
        XCTAssertEqual(L10n.text("MY"), "MY")
        defaults.set("zh-Hans", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(L10n.text("语言"), "语言")
        XCTAssertEqual(L10n.text("MY"), "我的")
    }

    func testInterpolationPreservesUserDataAndPercentSigns() {
        let account = "我的账户 %@ 100% AAPL"
        XCTAssertEqual(L10n.render("不计入\(account)", language: "en"), "Exclude \(account)")
        XCTAssertEqual(L10n.render("不计入\(account)", language: "zh-Hans"), "不计入\(account)")
        XCTAssertEqual(L10n.render("已同步 \(12) 个持仓\(" · GBP")", language: "en"), "Synced 12 holdings · GBP")
    }

    func testAccountNicknamesFollowLanguageWithStablePrefixesAndSuffixes() {
        XCTAssertEqual(L10n.accountName("IBKR · 全球账户", language: "en"), "IBKR · Global account")
        XCTAssertEqual(L10n.accountName("Moomoo · 美股账户", language: "en"), "Moomoo · US stocks account")
        XCTAssertEqual(L10n.accountName("Trading 212 · 橘子 12", language: "en"), "Trading 212 · Orange 12")
        XCTAssertEqual(L10n.accountName("CSV · Blueberry", language: "zh-Hans"), "CSV · 蓝莓")
        XCTAssertEqual(L10n.accountName("演示账户 1", language: "en"), "Demo account 1")
        XCTAssertEqual(L10n.accountName("IBKR · 全球账户", language: "zh-Hans"), "IBKR · 全球账户")
    }

    func testCustomAccountNamesAreNotPartiallyReplaced() {
        for name in ["IBKR · 我的橘子养老计划", "Trading 212 · ISA", "CSV · Team · 橘子", "Moomoo · ", "", "IBKR · 100% %@"] {
            XCTAssertEqual(L10n.accountName(name, language: "en"), name)
        }
    }

    func testUnknownKeysAndFormattedInterpolationRemainReadable() {
        XCTAssertEqual(L10n.render("unknown \(42)", language: "en"), "unknown 42")
        XCTAssertEqual(L10n.render("test \(1.234, specifier: "%.2f")", language: "en"), "test 1.23")
    }

    func testPreferencePersistsWithoutChangingFinancialPreferences() throws {
        let suite = "catfolio.localization.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("GBP", forKey: DisplayCurrency.preferenceKey)
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AppLanguage.resolvedIdentifier(reloaded.string(forKey: AppLanguage.preferenceKey)), "en")
        XCTAssertEqual(reloaded.string(forKey: DisplayCurrency.preferenceKey), "GBP")
        XCTAssertEqual(CompanyNameDisplay.original.rawValue, "原始名称")
        XCTAssertEqual(ChartTimeRange.oneMonth.rawValue, "1M")
    }
}
