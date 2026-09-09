import XCTest
@testable import CatfolioIOS

/// `DisplayFormat.money` reuses cached, fully-configured `NumberFormatter`s.
///
/// It used to allocate and configure a fresh formatter on every call, and it is
/// called once per figure in every holding row — dozens per list re-render.
///
/// Rather than assert hand-written literals (which only restate whatever
/// `NumberFormatter` happens to do about rounding and grouping), these compare
/// against a local replica of the previous implementation. The claim under test
/// is precisely that caching changed nothing.
final class CurrencyFormattingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: DisplayCurrency.preferenceKey)
    }

    /// The pre-cache implementation, verbatim: a fresh formatter per call.
    private func legacyMoney(
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
        // Mirrors the millions threshold `money` applies after conversion: past
        // a million the cents are dropped even when the caller asked for them.
        // This replica exists to isolate the formatter cache, so it has to
        // track deliberate rule changes or it starts reporting them as cache
        // bugs — which is exactly what it did when the threshold landed.
        let displayedFractionDigits = abs(adjusted) > 1_000_000 ? 0 : fractionDigits
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = targetCurrency
        if targetCurrency == "USD" {
            formatter.currencySymbol = "$"
        }
        formatter.minimumFractionDigits = displayedFractionDigits ?? 0
        formatter.maximumFractionDigits = displayedFractionDigits ?? (abs(adjusted) >= 1_000 ? 0 : 2)
        let text = formatter.string(from: NSNumber(value: abs(adjusted))) ?? "\(adjusted)"
        guard signed else { return text }
        return "\(adjusted >= 0 ? "+" : "-")\(text)"
    }

    private let values: [Double] = [
        0, 1, 12.345, 99.999, 500, 999.995, 1_000, 1_234.5, -1_234.5,
        1_500_000, -0.004, 1e12, .nan, .infinity, -.infinity,
    ]
    private let currencies = ["USD", "GBP", "EUR", "JPY", "CNY", "HKD", "GBX", "gbx", "usd"]

    func testCachedFormattingMatchesTheFreshFormatterForEveryCombination() {
        var compared = 0
        for value in values {
            for currency in currencies {
                for digits in [nil, 0, 2, 4] as [Int?] {
                    for signed in [false, true] {
                        XCTAssertEqual(
                            DisplayFormat.money(value, currency: currency, signed: signed, fractionDigits: digits),
                            legacyMoney(value, currency: currency, signed: signed, fractionDigits: digits),
                            "value=\(value) currency=\(currency) digits=\(String(describing: digits)) signed=\(signed)"
                        )
                        compared += 1
                    }
                }
            }
        }
        XCTAssertEqual(compared, values.count * currencies.count * 4 * 2)
    }

    /// Past a million the cents go, whatever the caller asked for: a headline
    /// figure reads worse with them and nobody reconciles a portfolio to the
    /// penny off a summary line.
    func testCentsAreDroppedPastAMillion() {
        XCTAssertEqual(DisplayFormat.money(1_500_000, currency: "USD", fractionDigits: 2), "$1,500,000")
        XCTAssertEqual(DisplayFormat.money(-1_500_000, currency: "USD", fractionDigits: 2), "$1,500,000")
        // At the threshold itself the request still stands.
        XCTAssertEqual(DisplayFormat.money(1_000_000, currency: "USD", fractionDigits: 2), "$1,000,000.00")
        XCTAssertEqual(DisplayFormat.money(999_999.5, currency: "USD", fractionDigits: 2), "$999,999.50")
    }

    func testRepeatedCallsAreStable() {
        // A cache keyed too loosely would only diverge on the second call.
        for _ in 0..<3 {
            for value in values {
                for digits in [nil, 0, 2] as [Int?] {
                    XCTAssertEqual(
                        DisplayFormat.money(value, currency: "USD", fractionDigits: digits),
                        legacyMoney(value, currency: "USD", fractionDigits: digits)
                    )
                }
            }
        }
    }

    /// Fraction digits are part of the cache key, so the same amount and currency
    /// must still format differently under different digit settings.
    func testFractionDigitsAreNotSharedBetweenConfigurations() {
        let zero = DisplayFormat.money(12.5, currency: "USD", fractionDigits: 0)
        let four = DisplayFormat.money(12.5, currency: "USD", fractionDigits: 4)
        XCTAssertNotEqual(zero, four)
        XCTAssertEqual(zero, DisplayFormat.money(12.5, currency: "USD", fractionDigits: 0))
    }

    func testCompactMoneyMatchesAFreshlyBuiltSymbol() {
        for value in [0, 950, 1_500_000, -1_500_000, 2_400_000_000] as [Double] {
            let displayCurrency = DisplayCurrency.current
            let converted = displayCurrency.fromUSD(value)
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = displayCurrency.rawValue
            if displayCurrency == .usd { formatter.currencySymbol = "$" }
            let symbol = formatter.currencySymbol ?? "\(displayCurrency.rawValue) "
            let compact = abs(converted).formatted(
                .number.notation(.compactName).precision(.fractionLength(0...1))
            )
            let expected = "\(converted < 0 ? "-" : "")\(symbol)\(compact)"
            XCTAssertEqual(DisplayFormat.compactMoney(value), expected)
        }
    }

    /// The cached formatters are shared across threads — the local services format
    /// off the main actor — so concurrent use must agree with serial use.
    func testConcurrentFormattingAgreesWithSerialFormatting() {
        let cases = currencies
        let expected = cases.map { DisplayFormat.money(4321.5, currency: $0, fractionDigits: 2) }

        let count = cases.count * 40
        let results = NSMutableArray(array: Array(repeating: "", count: count))
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let text = DisplayFormat.money(4321.5, currency: cases[i % cases.count], fractionDigits: 2)
            lock.lock(); results[i] = text; lock.unlock()
        }

        for i in 0..<count {
            XCTAssertEqual(results[i] as? String, expected[i % cases.count])
        }
    }
}
