import XCTest
@testable import CatfolioIOS

/// The fund fee shown on a holding, and the resolution that finds it.
final class FundFeeTests: XCTestCase {

    private func catalog() throws -> FundFeeCatalog {
        try FundFeeCatalog.bundled.get()
    }

    func testBundledPackageDecodes() throws {
        let catalog = try catalog()
        XCTAssertGreaterThan(catalog.records.count, 5_000)
        XCTAssertGreaterThan(catalog.aliases.count, 10_000)
        XCTAssertEqual(catalog.missingMeaning, "UNKNOWN_NOT_ZERO")
    }

    /// Fees people can check against the issuer's own page. A silently wrong
    /// one here would be believed, so the widely held funds are pinned.
    func testKnownFundsResolveToPublishedFees() throws {
        let catalog = try catalog()
        let expected: [String: Double] = [
            "VOO": 0.0003,
            "IVV": 0.0003,
            "SPY": 0.000945,
            "VUAG.L": 0.0007,
            "EQQQ.L": 0.003,
            "IWDA.AS": 0.002,
        ]
        for (symbol, rate) in expected {
            XCTAssertEqual(catalog.fee(brokerSymbol: symbol)?.rate ?? .nan, rate, accuracy: 1e-9, symbol)
        }
    }

    /// The reason this package replaced the ETF reference. Each of these had
    /// a listing there but no linked product, so the row simply never
    /// appeared on some of the most commonly held funds in the app.
    func testFundsTheOldPackageCouldNotPrice() throws {
        let catalog = try catalog()
        let expected: [String: Double] = [
            "QQQ": 0.0018,
            "VTI": 0.0003,
            "VT": 0.0006,
            "ARKK": 0.0075,
            "SCHD": 0.0006,
        ]
        for (symbol, rate) in expected {
            XCTAssertEqual(catalog.fee(brokerSymbol: symbol)?.rate ?? .nan, rate, accuracy: 1e-9, symbol)
        }
    }

    /// A share in a company has no expense ratio. Returning zero would render
    /// as "0.00%", which reads as a fund that charges nothing — the thing
    /// `missingMeaning` exists to forbid.
    func testOrdinarySharesHaveNoFee() throws {
        let catalog = try catalog()
        for symbol in ["AAPL", "NVDA", "HSBA.L", "6758.T"] {
            XCTAssertNil(catalog.fee(brokerSymbol: symbol), symbol)
        }
    }

    /// The same letters are a different fund on another exchange, and they
    /// charge differently. Reading the market off the suffix is the only
    /// thing keeping them apart: bare EQQQ is a US fund at 1.12%, EQQQ.L is
    /// the London line at 0.30%.
    func testTheSameTickerIsADifferentFundOnAnotherExchange() throws {
        let catalog = try catalog()
        for pair in [("EQQQ", "EQQQ.L"), ("IUSB", "IUSB.DE"), ("WOOD", "WOOD.L")] {
            let us = try XCTUnwrap(catalog.fee(brokerSymbol: pair.0), pair.0)
            let foreign = try XCTUnwrap(catalog.fee(brokerSymbol: pair.1), pair.1)
            XCTAssertNotEqual(
                us.rate, foreign.rate,
                "\(pair.0) and \(pair.1) charge different fees; one answer for both is wrong"
            )
        }
    }

    /// The suffix narrows to a market; it is never dropped so the lookup can
    /// be retried bare, and an unmapped suffix is an unknown market rather
    /// than a US ticker.
    func testSuffixIsNotStrippedOrGuessed() throws {
        let catalog = try catalog()
        XCTAssertNotNil(catalog.fee(brokerSymbol: "IWM"))
        XCTAssertNil(catalog.fee(brokerSymbol: "IWM.L"))
        XCTAssertNil(catalog.fee(brokerSymbol: "VOO.XX"))
        XCTAssertNil(catalog.fee(brokerSymbol: "NOTAFUND"))
        XCTAssertNil(catalog.fee(brokerSymbol: ""))
    }

    /// What makes a single answer safe: within one market, a ticker names one
    /// fund. If a rebuild broke that, every lookup above becomes a guess.
    func testNoTickerNamesTwoFundsOnOneMarket() throws {
        let catalog = try catalog()
        var seen: [String: Set<String>] = [:]
        for (alias, target) in catalog.aliases {
            let parts = alias.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "LISTING" else { continue }
            seen["\(parts[1]):\(parts[2].uppercased())", default: []].insert(target)
        }
        let conflicted = seen.filter { $0.value.count > 1 }
        XCTAssertTrue(conflicted.isEmpty, "same market, two funds: \(conflicted.keys.sorted())")
    }

    /// Every fee is a real annual rate, not a fraction/percent mix-up. A
    /// package that switched units would otherwise show 0.3% as 30%.
    func testEveryFeeIsAPlausibleAnnualRate() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.feeUnit, "DECIMAL_FRACTION")
        for (key, record) in catalog.records {
            guard let rate = record.expenseRatio else { continue }
            XCTAssertGreaterThanOrEqual(rate, 0, key)
            XCTAssertLessThan(rate, 0.5, key)
        }
    }

    /// `rows` is read from a view body, so this runs whenever the Data
    /// section re-renders. It has to stay far inside a frame.
    func testFeeLookupIsCheapEnoughForAViewBody() throws {
        let catalog = try catalog()
        let symbols = ["VUAG.L", "VOO", "SPY", "AAPL", "EQQQ.L", "NOTAFUND"]

        let start = Date()
        for _ in 0..<600 {
            for symbol in symbols { _ = catalog.fee(brokerSymbol: symbol) }
        }
        let perLookup = Date().timeIntervalSince(start) / Double(600 * symbols.count)

        XCTAssertLessThan(
            perLookup, 0.0002,
            "a fee lookup costs \(String(format: "%.4f", perLookup * 1000)) ms — too much per frame"
        )
    }

    /// The package this replaced is gone, along with its 6.4 MB of listings
    /// and products that only the fee row ever read.
    func testTheOldReferencePackageIsNotBundled() {
        let bundle = Bundle(identifier: "com.catfolio.CatfolioIOS") ?? .main
        XCTAssertNil(bundle.url(forResource: "etf_reference", withExtension: "json"))
    }
}
