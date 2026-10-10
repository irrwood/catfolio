import ImageIO
import Observation
import SwiftUI
import UIKit

/// Cached, fully-configured currency formatters.
///
/// `NumberFormatter` costs far more to allocate and configure than to run, and
/// `DisplayFormat.money` is called once per figure in every holding row, so a
/// single list re-render was building dozens of them. Formatters are keyed by
/// their configuration and never mutated after being published, which is the
/// documented-safe way to share one across threads.
///
/// The date side already avoids this cost (see `DayDateCodec` in Models.swift);
/// this is the currency equivalent.
enum CurrencyFormatterCache {
    private struct Key: Hashable {
        let currencyCode: String
        let minimumFractionDigits: Int
        let maximumFractionDigits: Int
    }

    private static let lock = NSLock()
    private static var formatters: [Key: NumberFormatter] = [:]

    static func formatter(
        currencyCode: String,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int
    ) -> NumberFormatter {
        let key = Key(
            currencyCode: currencyCode,
            minimumFractionDigits: minimumFractionDigits,
            maximumFractionDigits: maximumFractionDigits
        )
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        if currencyCode == "USD" {
            formatter.currencySymbol = "$"
        }
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        formatters[key] = formatter
        return formatter
    }

    /// The currency symbol alone, for callers that render the number themselves.
    static func symbol(for currencyCode: String) -> String {
        formatter(currencyCode: currencyCode, minimumFractionDigits: 0, maximumFractionDigits: 2)
            .currencySymbol ?? "\(currencyCode) "
    }
}

enum DisplayFormat {
    static func shares(_ value: Double) -> String {
        value.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(0...4))
        )
    }

    static func listShares(_ value: Double, compact: Bool = true, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        var displayed = value
        var suffix = ""
        if compact && abs(value) >= 1_000 {
            let suffixes = ["K", "M", "B"]
            var unitIndex = 0
            displayed /= 1_000
            // Promote values that would round to 1000.00 of the smaller unit.
            while abs(displayed) >= 999.995 && unitIndex < suffixes.count - 1 {
                displayed /= 1_000
                unitIndex += 1
            }
            suffix = suffixes[unitIndex]
        }
        return displayed.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(2))
                .locale(locale)
        ) + suffix
    }

    static func money(
        _ value: Double,
        currency: String? = nil,
        signed: Bool = false,
        fractionDigits: Int? = nil
    ) -> String {
        guard value.isFinite else { return "—" }
        let targetCurrency: String
        let adjusted: Double
        if let currency {
            let normalizedCurrency = currency.uppercased()
            targetCurrency = normalizedCurrency == "GBX" ? "GBP" : normalizedCurrency
            adjusted = normalizedCurrency == "GBX" ? value / 100 : value
        } else {
            let displayCurrency = DisplayCurrency.current
            targetCurrency = displayCurrency.rawValue
            adjusted = displayCurrency.fromUSD(value)
        }

        // Apply the display threshold after currency/GBX conversion, including
        // callers that otherwise request fixed cents for headlines and holdings.
        let displayedFractionDigits = abs(adjusted) > 1_000_000 ? 0 : fractionDigits
        let formatter = CurrencyFormatterCache.formatter(
            currencyCode: targetCurrency,
            minimumFractionDigits: displayedFractionDigits ?? 0,
            maximumFractionDigits: displayedFractionDigits ?? (abs(adjusted) >= 1_000 ? 0 : 2)
        )
        let text = formatter.string(from: NSNumber(value: abs(adjusted))) ?? "\(adjusted)"
        guard signed else { return text }
        return "\(adjusted >= 0 ? "+" : "-")\(text)"
    }

    /// How many digits an abbreviated figure keeps.
    enum CompactPrecision {
        /// Whole units. Axis labels, where a decimal point is noise.
        case whole
        /// Up to one decimal. The default for a figure read at a glance.
        case tenth
        /// Three significant digits, which is what a statement line needs:
        /// 1.23万 / 12.3亿 / 3910亿, or 1.23M / 12.3B / 391B. A fixed two
        /// decimals would print 3910.35亿, which is six digits of precision
        /// nobody asked for.
        case statement
    }

    /// The one magnitude ladder. Everything abbreviated in this app comes
    /// through here; nothing else divides by a million.
    ///
    /// The suffix follows the language: 万, 亿 and 万亿 under zh-Hans, K/M/B/T
    /// under English. That is one convention, not two — the app had a
    /// hand-rolled K/M/B/T table on some screens and `.compactName` on others,
    /// and they disagreed in Chinese.
    ///
    /// The locale is passed explicitly. `formatted()` would otherwise follow
    /// `Locale.current`, which tracks the device; the language preference here
    /// lives in `AppLanguage` and does not set `AppleLanguages`, so a person
    /// reading the app in Chinese on an English phone would still be shown K
    /// and M.
    static func compact(
        _ value: Double,
        precision: CompactPrecision = .tenth
    ) -> String {
        guard value.isFinite else { return "—" }
        let locale = Locale(identifier: AppLanguage.currentIdentifier)
        let compact: String
        switch precision {
        case .whole:
            compact = value.formatted(
                .number.notation(.compactName).precision(.fractionLength(0...0)).locale(locale))
        case .tenth:
            compact = value.formatted(
                .number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
        case .statement:
            compact = value.formatted(
                .number.notation(.compactName).precision(.significantDigits(3)).locale(locale))
        }
        // Below the first step there is nothing to abbreviate, and compact
        // notation drops the thousands separator while it is at it — 1500
        // rather than 1,500, which looks wrong beside a 1.23亿 on the same
        // axis. Detected by the absence of a suffix rather than by comparing
        // against a threshold, because where that threshold falls is the
        // locale's business (10,000 in Chinese, 1,000 in English).
        if !compact.contains(where: { $0.isLetter || ($0.unicodeScalars.first?.value ?? 0) > 0x2E80 }) {
            return value.formatted(.number.precision(.fractionLength(0...0)).locale(locale))
        }
        return compact
    }

    /// An abbreviated amount carrying its currency symbol.
    static func compactMoney(
        _ value: Double,
        currency: String? = nil,
        precision: CompactPrecision = .tenth
    ) -> String {
        guard value.isFinite else { return "—" }
        let targetCurrency: String
        let adjusted: Double
        if let currency {
            targetCurrency = currency.uppercased()
            adjusted = value
        } else {
            let displayCurrency = DisplayCurrency.current
            targetCurrency = displayCurrency.rawValue
            adjusted = displayCurrency.fromUSD(value)
        }
        var symbol = CurrencyFormatterCache.symbol(for: targetCurrency)
        // A currency with no glyph prints its code, and a code run straight
        // into a digit reads as one token: "SEK1.00T". money() spaces these,
        // so this does too.
        if let last = symbol.last, last.isLetter { symbol += "\u{00A0}" }
        let body = compact(abs(adjusted), precision: precision)
        // The sign leads the whole amount. The statement formatter this
        // replaced put it after the symbol — "$-1.50K" — which reads as a
        // negative quantity of dollars rather than a negative amount.
        return "\(adjusted < 0 ? "-" : "")\(symbol)\(body)"
    }

    static func percent(_ value: Double, signed: Bool = true) -> String {
        "\(signed && value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    static func ratioPercent(_ value: Double?) -> String {
        guard let value else { return L10n.text("暂无") }
        return percent(value * 100)
    }
}
