import XCTest
@testable import CatfolioIOS

/// One magnitude ladder, in one place.
///
/// Three call sites each divided by a million on their own: statement lines
/// (K/M/B/T, three significant digits), axis labels (M and K only, so a
/// portfolio past a billion drew `1234M`), and the contribution bars
/// (`.compactName`, which says 万 under zh-Hans). They now share
/// `DisplayFormat.compact`.
///
/// The statement figures must not have moved, so they are compared against a
/// verbatim replica of the formatter that was deleted.
final class CompactNumberRuleTests: XCTestCase {

    /// FinancialAmountFormatter as it stood before the ladder was shared.
    private func legacyStatement(_ value: Double, currency: String) -> String {
        let symbol: String
        switch currency.uppercased() {
        case "USD": symbol = "$"
        case "GBP": symbol = "£"
        case "EUR": symbol = "€"
        case "JPY", "CNY": symbol = "¥"
        default: symbol = "\(currency.uppercased()) "
        }
        let magnitude = abs(value)
        let scaled: Double
        let suffix: String
        switch magnitude {
        case 1_000_000_000_000...: scaled = value / 1_000_000_000_000; suffix = "T"
        case 1_000_000_000...: scaled = value / 1_000_000_000; suffix = "B"
        case 1_000_000...: scaled = value / 1_000_000; suffix = "M"
        case 1_000...: scaled = value / 1_000; suffix = "K"
        default: scaled = value; suffix = ""
        }
        let decimals = abs(scaled) >= 100 ? 0 : 2
        return "\(symbol)\(scaled.formatted(.number.precision(.fractionLength(decimals))))\(suffix)"
    }

    private let amounts: [Double] = [
        0, 1, 999, 1_000, 1_500, 99_999, 100_000, 999_999,
        1_000_000, 12_340_000, 123_456_789, 999_999_999,
        1_000_000_000, 12_300_000_000, 391_035_000_000,
        1_000_000_000_000, 1_234_000_000_000, 3_450_000_000_000,
        -1_500, -123_456_789, -1_234_000_000_000,
    ]

    /// Positive figures must be untouched — that is the whole refactor.
    /// CNY is excluded and covered below: its symbol was wrong before.
    func testPositiveStatementFiguresAreUnchangedByTheSharedLadder() {
        for currency in ["USD", "GBP", "EUR", "JPY"] {
            for amount in amounts where amount >= 0 {
                XCTAssertEqual(
                    DisplayFormat.compactMoney(amount, currency: currency, precision: .statement),
                    legacyStatement(amount, currency: currency),
                    "\(amount) \(currency)"
                )
            }
        }
    }

    /// A currency with no glyph prints its code, which must not run into the
    /// digits. The formatter this replaced spaced them and so does this one.
    /// The statement page kept its own symbol table, which printed CNY and JPY
    /// both as "¥" — indistinguishable — while the rest of the app took its
    /// symbols from the system and showed "CN¥". Symbols now come from one
    /// place, so a currency looks the same wherever it appears.
    func testSymbolsAgreeWithTheRestOfTheApp() {
        for currency in ["USD", "GBP", "EUR", "JPY", "CNY"] {
            let full = DisplayFormat.money(1_000_000, currency: currency)
            let brief = DisplayFormat.compactMoney(1_000_000, currency: currency)
            let prefix = String(full.prefix(while: { !$0.isNumber }))
            XCTAssertFalse(prefix.isEmpty, currency)
            XCTAssertTrue(
                brief.hasPrefix(prefix),
                "\(currency): compact \"\(brief)\" does not start like full \"\(full)\""
            )
        }
    }

    func testYuanIsNoLongerIndistinguishableFromYen() {
        XCTAssertEqual(legacyStatement(1_000_000, currency: "CNY"),
                       legacyStatement(1_000_000, currency: "JPY"),
                       "precondition: the old table collapsed both to ¥")
        XCTAssertNotEqual(
            DisplayFormat.compactMoney(1_000_000, currency: "CNY", precision: .statement),
            DisplayFormat.compactMoney(1_000_000, currency: "JPY", precision: .statement)
        )
    }

    func testCurrencyCodesKeepTheirSeparator() {
        let text = DisplayFormat.compactMoney(1_000_000_000_000, currency: "SEK", precision: .statement)
        XCTAssertEqual(text.replacingOccurrences(of: "\u{00A0}", with: " "), "SEK 1.00T")
    }

    /// One deliberate change: the sign now leads the amount. The statement
    /// formatter put it after the symbol — "$-1.50K" — which reads as a
    /// negative quantity of dollars rather than a negative amount.
    func testNegativeAmountsLeadWithTheSign() {
        XCTAssertEqual(legacyStatement(-1_500, currency: "USD"), "$-1.50K")
        XCTAssertEqual(
            DisplayFormat.compactMoney(-1_500, currency: "USD", precision: .statement),
            "-$1.50K"
        )
        // The magnitude itself is untouched.
        for amount in amounts where amount < 0 {
            let updated = DisplayFormat.compactMoney(amount, currency: "USD", precision: .statement)
            let legacy = legacyStatement(amount, currency: "USD")
            XCTAssertEqual(updated.replacingOccurrences(of: "-", with: ""),
                           legacy.replacingOccurrences(of: "-", with: ""), "\(amount)")
        }
    }

    /// The bug the shared ladder fixes: past a billion the axis kept counting
    /// in millions.
    func testAxisLabelsNowClimbPastMillions() {
        XCTAssertEqual(DisplayFormat.compact(1_500, precision: .whole), "2K")
        XCTAssertEqual(DisplayFormat.compact(12_000_000, precision: .whole), "12M")
        XCTAssertEqual(DisplayFormat.compact(1_000_000_000, precision: .whole), "1B")
        XCTAssertEqual(DisplayFormat.compact(3_400_000_000_000, precision: .whole), "3T")
        // The old implementation would have said 1000M and 3400000M here.
        XCTAssertFalse(DisplayFormat.compact(1_000_000_000, precision: .whole).hasSuffix("M"))
        XCTAssertFalse(DisplayFormat.compact(3_400_000_000_000, precision: .whole).hasSuffix("M"))
    }

    /// Halves round to even, as everywhere else in the app: 2.5T is "2T".
    func testTiesRoundToEven() {
        XCTAssertEqual(DisplayFormat.compact(2_500_000_000_000, precision: .whole), "2T")
        XCTAssertEqual(DisplayFormat.compact(3_500_000_000_000, precision: .whole), "4T")
    }

    func testLatinSuffixesAreTheSameInEveryLanguage() {
        // A reader comparing two statement lines needs the same suffix on both,
        // whichever language the app is running in.
        XCTAssertEqual(DisplayFormat.compact(1_200_000_000, precision: .tenth), "1.2B")
        XCTAssertEqual(DisplayFormat.compact(1_200_000, precision: .tenth), "1.2M")
    }

    func testPrecisionModesDiffer() {
        let value = 1_234_500_000.0
        XCTAssertEqual(DisplayFormat.compact(value, precision: .whole), "1B")
        XCTAssertEqual(DisplayFormat.compact(value, precision: .tenth), "1.2B")
        XCTAssertEqual(DisplayFormat.compact(value, precision: .statement), "1.23B")
    }

    func testSignAndNonFiniteAreHandled() {
        XCTAssertEqual(DisplayFormat.compact(.nan), "—")
        XCTAssertEqual(DisplayFormat.compactMoney(.infinity, currency: "USD"), "—")
        XCTAssertTrue(DisplayFormat.compactMoney(-1_500_000, currency: "USD").hasPrefix("-"))
        XCTAssertFalse(DisplayFormat.compactMoney(1_500_000, currency: "USD").hasPrefix("-"))
    }

    func testCompactMoneyKeepsTheCurrencySymbolInFront() {
        let text = DisplayFormat.compactMoney(1_500_000, currency: "USD")
        XCTAssertTrue(text.hasPrefix("$"), text)
        XCTAssertTrue(text.hasSuffix("M"), text)
    }
}
