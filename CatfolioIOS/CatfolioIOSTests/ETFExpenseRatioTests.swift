import XCTest
@testable import CatfolioIOS

/// The fund fee shown on a holding, and the resolution that finds it.
final class ETFExpenseRatioTests: XCTestCase {

    private func catalog() throws -> ETFReferenceCatalog {
        try ETFReferenceCatalog.bundled.get()
    }

    func testBundledPackageDecodes() throws {
        let catalog = try catalog()
        XCTAssertGreaterThan(catalog.products.count, 1_000)
        XCTAssertGreaterThan(catalog.listings.count, 1_000)
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
        ]
        for (symbol, rate) in expected {
            let fee = catalog.expenseRatio(brokerSymbol: symbol)
            XCTAssertEqual(fee?.rate ?? .nan, rate, accuracy: 1e-9, symbol)
        }
    }

    /// A share in a company has no expense ratio. Returning zero would render
    /// as "0.00%", which reads as a fund that charges nothing.
    func testOrdinarySharesHaveNoFee() throws {
        let catalog = try catalog()
        for symbol in ["AAPL", "NVDA", "HSBA.L", "6758.T"] {
            XCTAssertNil(catalog.expenseRatio(brokerSymbol: symbol), symbol)
        }
    }

    /// The suffix narrows the search to a market; it is never dropped so the
    /// lookup can be retried bare. A London ticker must not be answered with
    /// whatever US fund shares its letters.
    func testSuffixIsNotStrippedToReachAUSListing() throws {
        let catalog = try catalog()
        XCTAssertNotNil(catalog.expenseRatio(brokerSymbol: "IWM"))
        XCTAssertNil(
            catalog.expenseRatio(brokerSymbol: "IWM.L"),
            "IWM.L has no London listing in the package and must not fall back to the US fund"
        )
        XCTAssertNil(catalog.expenseRatio(brokerSymbol: "VOO.L"))
    }

    /// An unmapped suffix means an unknown market, which is not the same as a
    /// US ticker. `.XX` must not resolve at all.
    func testUnknownSuffixResolvesToNothing() throws {
        let catalog = try catalog()
        XCTAssertNil(catalog.expenseRatio(brokerSymbol: "VOO.XX"))
        XCTAssertNil(catalog.expenseRatio(brokerSymbol: "NOTAFUND"))
        XCTAssertNil(catalog.expenseRatio(brokerSymbol: ""))
    }

    /// The same letters mean different funds on different exchanges, and the
    /// two charge different fees. Reading the market off the suffix is the
    /// only thing keeping these apart — resolve `IUSB` bare and you get a
    /// 0.06% bond fund, resolve `IUSB.DE` and you get a 0.65% timber fund.
    func testTheSameTickerIsADifferentFundOnAnotherExchange() throws {
        let catalog = try catalog()
        let pairs: [(us: String, foreign: String)] = [
            ("IUSB", "IUSB.DE"),   // Core Total USD Bond vs Global Timber & Forestry
            ("WOOD", "WOOD.L"),    // the US listing vs its UCITS sibling
            ("CNYA", "CNYA.L"),
            ("LQDH", "LQDH.L"),
            ("SHYG", "SHYG.L"),
        ]
        for pair in pairs {
            let us = try XCTUnwrap(catalog.expenseRatio(brokerSymbol: pair.us), pair.us)
            let foreign = try XCTUnwrap(catalog.expenseRatio(brokerSymbol: pair.foreign), pair.foreign)
            XCTAssertNotEqual(
                us.rate, foreign.rate,
                "\(pair.us) and \(pair.foreign) charge different fees; one answer for both is wrong"
            )
        }
    }

    /// What makes a single answer safe: within one market, a ticker never has
    /// two fees. If a rebuild broke that, every lookup above becomes a guess.
    func testNoTickerHasTwoFeesOnOneMarket() throws {
        let catalog = try catalog()
        var seen: [String: Set<Double>] = [:]
        for listing in catalog.listings.values {
            guard let ticker = listing.ticker.verifiedValue,
                  let exchange = listing.exchange.verifiedValue,
                  let rate = catalog.product(for: listing)?.expenseRatio.verifiedValue else { continue }
            seen["\(exchange):\(ticker.uppercased())", default: []].insert(rate)
        }
        let conflicted = seen.filter { $0.value.count > 1 }
        XCTAssertTrue(conflicted.isEmpty, "same market, two fees: \(conflicted.keys.sorted())")
    }

    /// Every fee shown is a real annual rate, not a fraction/percent mix-up.
    /// A package that switched units would otherwise show 3% as 300%.
    func testEveryFeeIsAPlausibleAnnualRate() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.expenseRatioUnit, "FRACTION")
        for product in catalog.products.values {
            guard let rate = product.expenseRatio.verifiedValue else { continue }
            XCTAssertGreaterThanOrEqual(rate, 0)
            XCTAssertLessThan(rate, 0.5, product.id)
        }
    }
}
