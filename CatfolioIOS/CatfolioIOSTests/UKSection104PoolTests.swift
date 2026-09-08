import XCTest
@testable import CatfolioIOS

/// The sterling pool cost, and what a disposal produces against it.
final class UKSection104PoolTests: XCTestCase {

    private func rates() throws -> GBPFXRates { try GBPFXRates.bundled.get() }

    private func tx(_ action: String, _ date: String, _ qty: Double, _ price: Double,
                    _ currency: String = "GBP", ticker: String = "TEST") -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date, action: action, ticker: ticker, quantity: qty,
            price: price, currency: currency, source: "test",
            accountID: nil, accountName: nil
        )
    }

    /// Sterling in, sterling out: no conversion, so the pool is just what was
    /// paid and the arithmetic is checkable by eye.
    func testPoolIsTheAverageOfWhatWasPaid() throws {
        let position = try XCTUnwrap(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [
                tx("BUY", "2024-01-10", 100, 5),
                tx("BUY", "2024-06-10", 100, 7),
            ],
            rates: try rates()
        ))
        XCTAssertEqual(position.quantity, 200, accuracy: 0.001)
        XCTAssertEqual(position.cost, 1_200, accuracy: 0.01)
        XCTAssertEqual(position.costPerShare, 6, accuracy: 0.001)
    }

    /// A part disposal takes its share of the pooled cost, not the cost of
    /// any particular purchase — this is what makes it a pool.
    func testPartDisposalTakesItsShareOfThePool() throws {
        let position = try XCTUnwrap(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [
                tx("BUY", "2024-01-10", 100, 5),
                tx("BUY", "2024-06-10", 100, 7),
                tx("SELL", "2025-01-10", 50, 10),
            ],
            rates: try rates()
        ))
        // 50 of 200 shares carry 50/200 of the £1,200 cost.
        XCTAssertEqual(position.realisations.count, 1)
        XCTAssertEqual(position.realisations[0].cost, 300, accuracy: 0.01)
        XCTAssertEqual(position.realisations[0].proceeds, 500, accuracy: 0.01)
        XCTAssertEqual(position.realisations[0].gain, 200, accuracy: 0.01)
        XCTAssertEqual(position.quantity, 150, accuracy: 0.001)
        XCTAssertEqual(position.cost, 900, accuracy: 0.01)
    }

    /// A repurchase inside the window is matched to the disposal and never
    /// joins the pool, so the disposal is costed at what the *repurchase*
    /// cost — not at the pool average. This is the whole reason the 30-day
    /// rule changes the answer rather than just the paperwork.
    func testRepurchaseInsideTheWindowCostsTheDisposal() throws {
        let matched = try XCTUnwrap(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [
                tx("BUY", "2024-01-10", 100, 10),
                tx("SELL", "2025-01-10", 100, 6),
                tx("BUY", "2025-01-20", 100, 6.5),
            ],
            rates: try rates()
        ))
        // Sold at £600, matched to the £650 repurchase: a £50 loss, not the
        // £400 the original purchase price would suggest.
        XCTAssertEqual(matched.realisations[0].gain, -50, accuracy: 0.01)
        XCTAssertEqual(matched.realisations[0].matchedToAcquisitions, 100, accuracy: 0.001)
        // The original 100 shares are still pooled at their original cost.
        XCTAssertEqual(matched.quantity, 100, accuracy: 0.001)
        XCTAssertEqual(matched.cost, 1_000, accuracy: 0.01)
    }

    /// Without the repurchase the same sale is a £400 loss against the pool.
    /// The pair of tests is the feature: the repurchase changed the loss from
    /// £400 to £50.
    func testTheSameSaleWithoutARepurchase() throws {
        let plain = try XCTUnwrap(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [
                tx("BUY", "2024-01-10", 100, 10),
                tx("SELL", "2025-01-10", 100, 6),
            ],
            rates: try rates()
        ))
        XCTAssertEqual(plain.realisations[0].gain, -400, accuracy: 0.01)
        XCTAssertEqual(plain.realisations[0].matchedToAcquisitions, 0, accuracy: 0.001)
        XCTAssertEqual(plain.quantity, 0, accuracy: 0.001)
        XCTAssertEqual(plain.cost, 0, accuracy: 0.01)
    }

    /// A dollar holding's sterling cost is set by the rate on the day it was
    /// bought. Bought when sterling was strong, the sterling cost is lower —
    /// which is exactly why a position can be down in dollars and up in
    /// pounds, and why the app's own P&L cannot answer this question.
    func testForeignCostUsesTheRateOnTheDayItWasBought() throws {
        let series = try rates()
        let position = try XCTUnwrap(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [tx("BUY", "2016-06-23", 100, 100, "USD")],
            rates: series
        ))
        let rate = try XCTUnwrap(series.quote(currency: "USD", on: "2016-06-23")).rate
        XCTAssertEqual(position.cost, 10_000 / rate, accuracy: 0.01)
        // £1 bought about $1.49 that day, so $10,000 cost roughly £6,700.
        XCTAssertEqual(position.cost, 6_726, accuracy: 25)
    }

    /// Same dollar cost, same dollar proceeds, no dollar gain at all — and a
    /// sterling gain, because the currency moved underneath it.
    func testACurrencyOnlyGain() throws {
        let position = try XCTUnwrap(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [
                tx("BUY", "2016-06-23", 100, 100, "USD"),
                tx("SELL", "2024-01-05", 100, 100, "USD"),
            ],
            rates: try rates()
        ))
        XCTAssertGreaterThan(position.realisations[0].gain, 1_000,
                             "flat in dollars, but sterling weakened over the period")
    }

    /// Selling to take a loss lowers the pool cost of what is left, so the
    /// loss is deferred rather than removed. Any screen presenting a harvest
    /// has to be able to say this.
    func testSellingLowersThePoolCostOfWhatRemains() throws {
        let position = try XCTUnwrap(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [tx("BUY", "2024-01-10", 200, 10)],
            rates: try rates()
        ))
        XCTAssertEqual(position.cost, 2_000, accuracy: 0.01)
        XCTAssertEqual(position.poolCostAfterSelling(50), 1_500, accuracy: 0.01)
        XCTAssertEqual(position.poolCostAfterSelling(200), 0, accuracy: 0.01)
        XCTAssertEqual(position.poolCostAfterSelling(0), 2_000, accuracy: 0.01)
    }

    /// What a sale today would produce, which is the number a harvesting
    /// screen is actually about.
    func testDisposalNowMeasuresAgainstThePoolNotThePurchasePrice() throws {
        let position = try XCTUnwrap(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [
                tx("BUY", "2024-01-10", 100, 10),
                tx("BUY", "2024-06-10", 100, 20),
            ],
            rates: try rates()
        ))
        let sale = try XCTUnwrap(position.disposalNow(price: 12, rate: 1))
        XCTAssertEqual(sale.proceeds, 2_400, accuracy: 0.01)
        // Pool cost £3,000 against £2,400 of proceeds: a £600 allowable loss,
        // even though the first tranche is showing a profit.
        XCTAssertEqual(sale.gain, -600, accuracy: 0.01)
    }

    /// A currency with no series makes the sterling cost unknowable, and a
    /// partial pool would look like a real one.
    func testUncoveredCurrencyYieldsNothing() throws {
        XCTAssertNil(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [tx("BUY", "2024-01-10", 100, 10, "TWD")],
            rates: try rates()
        ))
    }

    /// Selling more than was ever bought means the history is incomplete, so
    /// there is no cost basis to report.
    func testSellingMoreThanWasBoughtIsRefused() throws {
        XCTAssertNil(UKSection104Pool.position(
            ticker: "TEST",
            transactions: [
                tx("BUY", "2024-01-10", 50, 10),
                tx("SELL", "2025-01-10", 100, 12),
            ],
            rates: try rates()
        ))
    }

    /// A trade dated on a non-observation day is still costed, and the result
    /// says it was not read off a published rate for that date.
    func testCarriedForwardRatesMarkThePositionInexact() throws {
        let position = try XCTUnwrap(UKSection104Pool.position(
            ticker: "TEST",
            // 2024-01-06 was a Saturday.
            transactions: [tx("BUY", "2024-01-06", 100, 100, "USD")],
            rates: try rates()
        ))
        XCTAssertFalse(position.isExact)
    }

    func testNoTransactionsMeansNoPosition() throws {
        XCTAssertNil(UKSection104Pool.position(
            ticker: "TEST", transactions: [], rates: try rates()
        ))
    }
}

/// The ledger has to agree with the holding it describes.
extension UKSection104PoolTests {

    /// The failure this guard exists for. A sync that returns purchases but
    /// no disposals leaves every sold share's cost in the pool, and nothing
    /// about the individual rows looks wrong — so the only thing that catches
    /// it is comparing the total against what is actually held.
    func testAPoolThatDisagreesWithTheHoldingIsRefused() throws {
        let transactions = [
            tx("BUY", "2024-01-10", 100, 10),
            tx("BUY", "2024-06-10", 100, 10),
        ]
        // Ledger says 200, broker says 40 are held: 160 were sold and the
        // disposals never arrived.
        XCTAssertNil(UKSection104Pool.position(
            ticker: "TEST", transactions: transactions,
            rates: try rates(), expectedQuantity: 40
        ))
        XCTAssertNotNil(UKSection104Pool.position(
            ticker: "TEST", transactions: transactions,
            rates: try rates(), expectedQuantity: 200
        ))
    }

    /// Fractional share counts are ordinary, so the check is relative rather
    /// than exact — but tight enough that a missing disposal cannot pass.
    func testReconciliationToleratesRoundingButNotAMissingDisposal() throws {
        let transactions = [tx("BUY", "2024-01-10", 33.0386, 10)]
        XCTAssertNotNil(UKSection104Pool.position(
            ticker: "TEST", transactions: transactions,
            rates: try rates(), expectedQuantity: 33.0386001
        ))
        XCTAssertNil(UKSection104Pool.position(
            ticker: "TEST", transactions: transactions,
            rates: try rates(), expectedQuantity: 33.0
        ))
    }
}
