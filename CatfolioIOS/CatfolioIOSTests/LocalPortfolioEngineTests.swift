import XCTest
@testable import CatfolioIOS

/// Every figure on the Holdings tab is funnelled through `usd(_:currency:)` and
/// `totals(for:)`, so the currency handling is pinned here — in particular the
/// pence/pound relationship that an earlier build got wrong for Trading 212
/// positions (see `migrateKnownInstrumentCurrencies`).
final class LocalPortfolioEngineTests: XCTestCase {

    private func position(
        ticker: String = "TEST",
        shares: Double,
        averageCost: Double,
        currency: String,
        quotePrice: Double,
        quoteCurrency: String? = nil
    ) -> LocalPositionRecord {
        LocalPositionRecord(
            ticker: ticker,
            name: ticker,
            shares: shares,
            averageCost: averageCost,
            currency: currency,
            quotePrice: quotePrice,
            quoteCurrency: quoteCurrency ?? currency,
            source: "test",
            openedDate: nil
        )
    }

    // MARK: - Currency conversion

    func testUSDIsIdentity() throws {
        XCTAssertEqual(try LocalPortfolioEngine.usd(1_234.56, currency: "USD"), 1_234.56)
    }

    /// GBX is pence. Any drift between these two entries silently rescales every
    /// London holding by 100x, which is exactly the class of bug the Trading 212
    /// currency migration exists to repair.
    func testPenceIsExactlyOneHundredthOfAPound() throws {
        let pound = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBP"))
        let pence = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBX"))

        XCTAssertEqual(pence, pound / 100, accuracy: 1e-9)
    }

    func testOneHundredPoundsEqualsTenThousandPence() throws {
        XCTAssertEqual(
            try LocalPortfolioEngine.usd(100, currency: "GBP"),
            try LocalPortfolioEngine.usd(10_000, currency: "GBX"),
            accuracy: 1e-9
        )
    }

    func testCurrencyLookupIsCaseInsensitive() throws {
        XCTAssertEqual(
            try LocalPortfolioEngine.usd(100, currency: "gbp"),
            try LocalPortfolioEngine.usd(100, currency: "GBP")
        )
    }

    /// An unknown currency must fail loudly. Falling back to 1.0 would quietly
    /// report a JPY holding as if it were dollars.
    func testUnsupportedCurrencyThrowsRatherThanAssumingParity() {
        XCTAssertNil(LocalPortfolioEngine.usdRate(for: "ZZZ"))
        XCTAssertThrowsError(try LocalPortfolioEngine.usd(100, currency: "ZZZ"))
    }

    func testEverySupportedRateIsPositiveAndFinite() {
        for code in ["USD", "GBP", "GBX", "EUR", "HKD", "CAD", "AUD", "SGD", "JPY", "CNY", "CNH"] {
            let rate = LocalPortfolioEngine.usdRate(for: code)
            XCTAssertNotNil(rate, "\(code) must be convertible")
            if let rate {
                XCTAssertTrue(rate.isFinite, "\(code) rate must be finite")
                XCTAssertGreaterThan(rate, 0, "\(code) rate must be positive")
            }
        }
    }

    // MARK: - Totals

    func testTotalsSumSharesTimesPrice() throws {
        let totals = try LocalPortfolioEngine.totals(for: [
            position(shares: 10, averageCost: 100, currency: "USD", quotePrice: 150)
        ])

        XCTAssertEqual(totals.cost, 1_000, accuracy: 1e-9)
        XCTAssertEqual(totals.marketValue, 1_500, accuracy: 1e-9)
    }

    func testTotalsConvertEachPositionFromItsOwnCurrency() throws {
        let gbpRate = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBP"))
        let totals = try LocalPortfolioEngine.totals(for: [
            position(ticker: "AAA", shares: 10, averageCost: 100, currency: "USD", quotePrice: 100),
            position(ticker: "BBB", shares: 10, averageCost: 100, currency: "GBP", quotePrice: 100),
        ])

        XCTAssertEqual(totals.cost, 1_000 + 1_000 * gbpRate, accuracy: 1e-6)
    }

    /// A pence-quoted holding and the equivalent pound-quoted holding must value
    /// identically once converted.
    func testPenceQuotedHoldingMatchesEquivalentPoundQuotedHolding() throws {
        let pence = try LocalPortfolioEngine.totals(for: [
            position(shares: 100, averageCost: 1_200, currency: "GBX", quotePrice: 1_500)
        ])
        let pounds = try LocalPortfolioEngine.totals(for: [
            position(shares: 100, averageCost: 12, currency: "GBP", quotePrice: 15)
        ])

        XCTAssertEqual(pence.cost, pounds.cost, accuracy: 1e-6)
        XCTAssertEqual(pence.marketValue, pounds.marketValue, accuracy: 1e-6)
    }

    /// Cost and market value are converted through separate currency fields, so
    /// a position bought in one currency and quoted in another must use both.
    func testCostAndQuoteCurrenciesAreAppliedIndependently() throws {
        let gbpRate = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBP"))
        let totals = try LocalPortfolioEngine.totals(for: [
            position(
                shares: 10, averageCost: 100, currency: "GBP",
                quotePrice: 200, quoteCurrency: "USD"
            )
        ])

        XCTAssertEqual(totals.cost, 1_000 * gbpRate, accuracy: 1e-6)
        XCTAssertEqual(totals.marketValue, 2_000, accuracy: 1e-6)
    }

    func testEmptyPortfolioTotalsToZero() throws {
        let totals = try LocalPortfolioEngine.totals(for: [])

        XCTAssertEqual(totals.cost, 0)
        XCTAssertEqual(totals.marketValue, 0)
    }

    func testTotalsPropagateUnsupportedCurrencyAsAnError() {
        XCTAssertThrowsError(
            try LocalPortfolioEngine.totals(for: [
                position(shares: 1, averageCost: 1, currency: "ZZZ", quotePrice: 1)
            ])
        )
    }
}
