import XCTest
@testable import CatfolioIOS

/// The reconstructed FX component, and the rate series it reads.
final class FXImpactTests: XCTestCase {

    private func rates() throws -> GBPFXRates { try GBPFXRates.bundled.get() }

    private func buy(_ ticker: String, _ date: String, qty: Double, price: Double, currency: String)
        -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date, action: "BUY", ticker: ticker, quantity: qty,
            price: price, currency: currency, source: "test",
            accountID: nil, accountName: nil
        )
    }

    private func sell(_ ticker: String, _ date: String, qty: Double, price: Double, currency: String)
        -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date, action: "SELL", ticker: ticker, quantity: qty,
            price: price, currency: currency, source: "test",
            accountID: nil, accountName: nil
        )
    }

    // MARK: - The rate series

    func testPackageStatesItsDirectionAndIsLoadable() throws {
        let rates = try rates()
        XCTAssertEqual(rates.baseCurrency, "GBP")
        XCTAssertTrue(rates.direction.hasPrefix("GBP_TO_QUOTE"))
        XCTAssertEqual(rates.nonObservationDayPolicy, "OMIT_NO_FORWARD_FILL")
        XCTAssertGreaterThan(rates.dates.count, 6_000)
    }

    /// Two days everybody can check. Sterling fell hard against the dollar
    /// the morning the referendum result landed, and a series that had been
    /// interpolated or forward-filled would show that step spread out.
    func testKnownRatesOnDaysThatMoved() throws {
        let rates = try rates()
        let before = try XCTUnwrap(rates.quote(currency: "USD", on: "2016-06-23"))
        let after = try XCTUnwrap(rates.quote(currency: "USD", on: "2016-06-24"))
        XCTAssertEqual(before.rate, 1.4869, accuracy: 0.001)
        XCTAssertEqual(after.rate, 1.3704, accuracy: 0.001)
        if case .carriedForward = before.match { XCTFail("2016-06-23 should be a published day") }
    }

    /// Sterling and pence are definitional, not observations.
    func testSterlingAndPenceNeedNoSeries() throws {
        let rates = try rates()
        XCTAssertEqual(rates.quote(currency: "GBP", on: "2024-01-02")?.rate, 1)
        XCTAssertEqual(rates.quote(currency: "GBX", on: "2024-01-02")?.rate, 100)
    }

    /// A weekend has no rate. The caller still has to value a trade dated on
    /// one, so the lookup steps back and says how far — it must never step
    /// forward to a rate that was not knowable at the time.
    func testWeekendsCarryBackwardsAndNeverForwards() throws {
        let rates = try rates()
        // 2024-01-06 was a Saturday; 2024-01-05 a published Friday.
        let quote = try XCTUnwrap(rates.quote(currency: "USD", on: "2024-01-06"))
        XCTAssertEqual(quote.date, "2024-01-05")
        guard case .carriedForward(let days) = quote.match else {
            return XCTFail("a Saturday should not be an exact match")
        }
        XCTAssertEqual(days, 1)
        XCTAssertLessThan(quote.date, "2024-01-06", "stepped forward, not back")
    }

    func testUncoveredCurrencyHasNoRate() throws {
        let rates = try rates()
        XCTAssertNil(rates.quote(currency: "TWD", on: "2024-01-02"))
        XCTAssertNil(rates.quote(currency: "NOTACURRENCY", on: "2024-01-02"))
    }

    // MARK: - The impact

    /// Worked by hand from the two published rates, so the sign and the size
    /// are pinned rather than whatever the code happens to produce.
    ///
    /// $10,000 of cost bought when £1 = $1.4869 and held to a day when
    /// £1 = $1.2000. In sterling that cost went from £6,726 to £8,333, so the
    /// holder is £1,607 better off on the currency alone — and expressed back
    /// in dollars at today's rate, +$1,928.
    func testWorkedExampleMatchesHandCalculation() throws {
        let rates = try rates()
        let asOf = ISO8601DateFormatter().date(from: "2024-01-05T12:00:00Z")!
        let now = try XCTUnwrap(rates.quote(currency: "USD", on: "2024-01-05")).rate
        let then = try XCTUnwrap(rates.quote(currency: "USD", on: "2016-06-23")).rate

        let result = try XCTUnwrap(FXImpactCalculator.impact(
            ticker: "TEST",
            transactions: [buy("TEST", "2016-06-23", qty: 100, price: 100, currency: "USD")],
            rates: rates,
            asOf: asOf
        ))
        XCTAssertEqual(result.cost, 10_000, accuracy: 0.01)
        XCTAssertEqual(result.amount, 10_000 * (1 / now - 1 / then), accuracy: 0.01)
        // Sterling weakened over that span, so a dollar holding gained.
        XCTAssertGreaterThan(result.amount, 0)
        XCTAssertTrue(result.isExact)
    }

    /// A sterling-quoted holding has no currency exposure. That is a fact,
    /// and zero says it; nil would claim the answer is unknown.
    func testSterlingHoldingIsZeroNotUnknown() throws {
        let result = try XCTUnwrap(FXImpactCalculator.impact(
            ticker: "VUAG.L",
            transactions: [buy("VUAG.L", "2024-01-05", qty: 10, price: 80, currency: "GBP")],
            rates: try rates()
        ))
        XCTAssertEqual(result.amount, 0)
        XCTAssertEqual(result.cost, 800, accuracy: 0.01)
    }

    /// Only the money still invested counts. Sold lots took their currency
    /// outcome with them into realised P&L.
    func testSoldLotsDropOutFIFO() throws {
        let rates = try rates()
        let both = try XCTUnwrap(FXImpactCalculator.impact(
            ticker: "TEST",
            transactions: [
                buy("TEST", "2016-06-23", qty: 100, price: 100, currency: "USD"),
                buy("TEST", "2020-03-19", qty: 100, price: 100, currency: "USD"),
            ],
            rates: rates
        ))
        let second = try XCTUnwrap(FXImpactCalculator.impact(
            ticker: "TEST",
            transactions: [
                buy("TEST", "2016-06-23", qty: 100, price: 100, currency: "USD"),
                buy("TEST", "2020-03-19", qty: 100, price: 100, currency: "USD"),
                sell("TEST", "2024-01-05", qty: 100, price: 150, currency: "USD"),
            ],
            rates: rates
        ))
        XCTAssertEqual(both.cost, 20_000, accuracy: 0.01)
        XCTAssertEqual(second.cost, 10_000, accuracy: 0.01, "FIFO should retire the 2016 lot")
        XCTAssertNotEqual(both.amount, second.amount)
    }

    /// One lot in a currency the series does not carry makes the total wrong
    /// by an unknown amount, so nothing is shown rather than a partial sum.
    func testAnUnpriceableLotWithholdsTheWholeFigure() throws {
        XCTAssertNil(FXImpactCalculator.impact(
            ticker: "TEST",
            transactions: [buy("TEST", "2024-01-05", qty: 10, price: 100, currency: "TWD")],
            rates: try rates()
        ))
    }

    /// Two currencies on one ticker need two answers and the row has space
    /// for one, so it stays silent rather than picking.
    func testMixedCurrencyLotsAreRefused() throws {
        XCTAssertNil(FXImpactCalculator.impact(
            ticker: "TEST",
            transactions: [
                buy("TEST", "2024-01-05", qty: 10, price: 100, currency: "USD"),
                buy("TEST", "2024-01-08", qty: 10, price: 90, currency: "EUR"),
            ],
            rates: try rates()
        ))
    }

    func testNoTransactionsMeansNoFigure() throws {
        XCTAssertNil(FXImpactCalculator.impact(ticker: "TEST", transactions: [], rates: try rates()))
    }

    /// A trade dated on a non-observation day is still valued, but the result
    /// is marked so the row can say it was estimated rather than read off.
    func testCarriedForwardRateMarksTheResultInexact() throws {
        let result = try XCTUnwrap(FXImpactCalculator.impact(
            ticker: "TEST",
            transactions: [buy("TEST", "2024-01-06", qty: 10, price: 100, currency: "USD")],
            rates: try rates()
        ))
        XCTAssertFalse(result.isExact)
    }
}
