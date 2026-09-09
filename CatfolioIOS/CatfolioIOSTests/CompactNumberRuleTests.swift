import XCTest
@testable import CatfolioIOS

/// One magnitude ladder, following the language.
///
/// Three screens each divided by a million on their own and disagreed about
/// what to call the result: a statement table with its own K/M/B/T strings, an
/// axis that stopped at M so a portfolio past a billion drew "1234M", and a
/// contribution bar using `.compactName`, which says 万 under zh-Hans. They now
/// share `DisplayFormat.compact`, and the convention is the locale's own —
/// 万/亿/万亿 in Chinese, K/M/B/T in English.
final class CompactNumberRuleTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: AppLanguage.preferenceKey)
        super.tearDown()
    }

    private func withLanguage(_ language: AppLanguage, _ body: () -> Void) {
        UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        body()
    }

    // MARK: The convention

    func testChineseGetsWanAndYi() {
        withLanguage(.simplifiedChinese) {
            XCTAssertEqual(DisplayFormat.compact(12_345, precision: .tenth), "1.2万")
            XCTAssertEqual(DisplayFormat.compact(123_456_789, precision: .tenth), "1.2亿")
            XCTAssertEqual(DisplayFormat.compact(1_234_000_000_000, precision: .tenth), "1.2万亿")
        }
    }

    func testEnglishGetsTheLatinSuffixes() {
        withLanguage(.english) {
            XCTAssertEqual(DisplayFormat.compact(12_345, precision: .tenth), "12.3K")
            XCTAssertEqual(DisplayFormat.compact(1_234_000_000, precision: .tenth), "1.2B")
            XCTAssertEqual(DisplayFormat.compact(1_234_000_000_000, precision: .tenth), "1.2T")
        }
    }

    /// The point of passing the locale explicitly: the app's own language
    /// setting does not go through `AppleLanguages`, so `Locale.current` would
    /// answer for the device and show K to somebody reading in Chinese.
    func testTheAppLanguageDecidesNotTheDevice() {
        var chinese = "", english = ""
        withLanguage(.simplifiedChinese) { chinese = DisplayFormat.compact(123_456_789) }
        withLanguage(.english) { english = DisplayFormat.compact(123_456_789) }
        XCTAssertNotEqual(chinese, english)
        XCTAssertTrue(chinese.contains("亿"), chinese)
        XCTAssertTrue(english.hasSuffix("M"), english)
    }

    // MARK: Precision

    func testStatementPrecisionHoldsThreeSignificantDigits() {
        withLanguage(.simplifiedChinese) {
            XCTAssertEqual(DisplayFormat.compact(12_345, precision: .statement), "1.23万")
            XCTAssertEqual(DisplayFormat.compact(1_234_000_000, precision: .statement), "12.3亿")
            // A fixed two decimals would have printed 3910.35亿 here.
            XCTAssertEqual(DisplayFormat.compact(391_035_000_000, precision: .statement), "3910亿")
        }
        withLanguage(.english) {
            XCTAssertEqual(DisplayFormat.compact(391_035_000_000, precision: .statement), "391B")
            XCTAssertEqual(DisplayFormat.compact(1_234_000_000_000, precision: .statement), "1.23T")
        }
    }

    func testPrecisionModesDiffer() {
        withLanguage(.english) {
            let value = 1_234_500_000.0
            XCTAssertEqual(DisplayFormat.compact(value, precision: .whole), "1B")
            XCTAssertEqual(DisplayFormat.compact(value, precision: .tenth), "1.2B")
            XCTAssertEqual(DisplayFormat.compact(value, precision: .statement), "1.23B")
        }
    }

    // MARK: The bug the shared ladder fixed

    func testAxisLabelsClimbPastMillions() {
        withLanguage(.english) {
            XCTAssertEqual(DisplayFormat.compact(1_000_000_000, precision: .whole), "1B")
            XCTAssertEqual(DisplayFormat.compact(3_400_000_000_000, precision: .whole), "3T")
            // The old implementation stopped at M and would have said 1000M.
            XCTAssertFalse(DisplayFormat.compact(1_000_000_000, precision: .whole).hasSuffix("M"))
        }
    }

    // MARK: Below the first step

    /// Compact notation leaves a small number alone and drops its thousands
    /// separator while doing so, which reads as a typo beside an abbreviated
    /// figure on the same axis.
    func testUnabbreviatedFiguresKeepTheirSeparator() {
        withLanguage(.simplifiedChinese) {
            // 1,500 is below 万, so Chinese does not abbreviate it at all.
            XCTAssertEqual(DisplayFormat.compact(1_500, precision: .tenth), "1,500")
        }
        withLanguage(.english) {
            XCTAssertEqual(DisplayFormat.compact(999, precision: .tenth), "999")
            XCTAssertEqual(DisplayFormat.compact(1_500, precision: .tenth), "1.5K")
        }
    }

    // MARK: Money

    func testCompactMoneyKeepsTheSymbolInFrontAndTheSignOutside() {
        withLanguage(.english) {
            let text = DisplayFormat.compactMoney(1_500_000, currency: "USD")
            XCTAssertTrue(text.hasPrefix("$"), text)
            XCTAssertTrue(text.hasSuffix("M"), text)
            XCTAssertEqual(DisplayFormat.compactMoney(-1_500_000, currency: "USD"), "-" + text)
        }
    }

    /// A currency with no glyph prints its code, which must not run into the
    /// digits.
    func testCurrencyCodesKeepTheirSeparator() {
        withLanguage(.english) {
            let text = DisplayFormat.compactMoney(1_000_000_000_000, currency: "SEK", precision: .statement)
            XCTAssertEqual(text.replacingOccurrences(of: "\u{00A0}", with: " "), "SEK 1.00T")
        }
    }

    /// The statement page kept its own symbol table, which printed CNY and JPY
    /// both as "¥" while the rest of the app said "CN¥". Symbols now come from
    /// one place.
    func testYuanIsNoLongerIndistinguishableFromYen() {
        withLanguage(.english) {
            XCTAssertNotEqual(
                DisplayFormat.compactMoney(1_000_000, currency: "CNY", precision: .statement),
                DisplayFormat.compactMoney(1_000_000, currency: "JPY", precision: .statement)
            )
        }
    }

    func testSignAndNonFiniteAreHandled() {
        XCTAssertEqual(DisplayFormat.compact(.nan), "—")
        XCTAssertEqual(DisplayFormat.compactMoney(.infinity, currency: "USD"), "—")
    }
}
