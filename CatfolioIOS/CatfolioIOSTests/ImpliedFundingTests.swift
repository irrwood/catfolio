import XCTest
@testable import CatfolioIOS

/// Accounts imported without their cash legs: trades funded from their
/// fills, short days topped up, and shares the trades cannot explain
/// transferred in at market value — none of which may create a gain.
final class ImpliedFundingTests: XCTestCase {
    typealias T = DailyTimeWeightedReturn

    private func trade(_ id: String, _ date: String, _ symbol: String, _ quantity: Decimal, at price: Decimal) -> T.Event {
        T.Event(id: id, date: date, account: "A", symbol: symbol, quantity: quantity,
                cash: [T.Cash(currency: "USD", amount: -quantity * price)])
    }

    private func day(_ date: String, _ price: Decimal) -> T.Day {
        T.Day(date: date, quotes: ["AAA": T.Quote(price: price, currency: "USD")], usdRates: [:])
    }

    func testAShortDayIsFundedByThatDaysDeposit() {
        let events = [
            trade("b1", "2026-01-02", "AAA", 10, at: 100),   // -1000
            trade("s1", "2026-01-05", "AAA", -6, at: 100),   // +600
            trade("b2", "2026-01-06", "AAA", 8, at: 100),    // -800: 200 short
        ]
        let deposits = T.fundingShortfalls(events: events, accounts: ["A"])
        XCTAssertEqual(deposits.map(\.date), ["2026-01-02", "2026-01-06"])
        XCTAssertEqual(deposits.map { $0.cash[0].amount }, [1000, 200])
        XCTAssertTrue(deposits.allSatisfy(\.external))
    }

    func testAnAccountWithItsCashIsLeftAlone() {
        let events = [trade("b1", "2026-01-02", "AAA", 10, at: 100)]
        XCTAssertTrue(T.fundingShortfalls(events: events, accounts: []).isEmpty)
    }

    func testSharesTheTradesCannotExplainAreTransferredInAtTheFirstClose() {
        // History starts with a sale of 4; the account holds 10 today.
        let events = [trade("s1", "2026-01-05", "AAA", -4, at: 60)]
        let openings = T.openingTransfers(events: events, splits: [], expected: ["A": ["AAA": 10]],
                                          quotes: ["AAA": ["2026-01-02": T.Quote(price: 50, currency: "USD")]],
                                          start: "2026-01-01", accounts: ["A"])
        XCTAssertEqual(openings.count, 2)
        let buy = openings.first { $0.symbol == "AAA" }
        XCTAssertEqual(buy?.quantity, 14, "10 held today plus the 4 sold")
        XCTAssertEqual(buy?.date, "2026-01-02")
        let funding = openings.first { $0.external }
        XCTAssertEqual(funding?.cash.first?.amount, 700, "valued at the first close, so no gain appears")
    }

    func testAnOpeningIsCountedBeforeLaterSplits() {
        let openings = T.openingTransfers(events: [], splits: [T.Split(date: "2026-01-10", symbol: "AAA", factor: 2)],
                                          expected: ["A": ["AAA": 20]], quotes: ["AAA": ["2026-01-02": T.Quote(price: 50, currency: "USD")]],
                                          start: "2026-01-01", accounts: ["A"])
        XCTAssertEqual(openings.first { $0.symbol == "AAA" }?.quantity, 10, "20 after a 2-for-1 split")
    }

    func testAShortfallBeforeAnyPriceIsLeftForTheLedgerToReport() {
        let events = [trade("s1", "2026-01-02", "AAA", -4, at: 60)]
        XCTAssertTrue(T.openingTransfers(events: events, splits: [], expected: [:],
                                         quotes: ["AAA": ["2026-01-05": T.Quote(price: 50, currency: "USD")]],
                                         start: "2026-01-01", accounts: ["A"]).isEmpty)
    }

    func testAPositionWithoutTradesOpensOnItsOwnDate() {
        let quotes: [String: T.Quote] = ["2026-01-02": T.Quote(price: 50, currency: "USD"), "2026-03-02": T.Quote(price: 80, currency: "USD")]
        let openings = T.openingTransfers(events: [], splits: [], expected: ["A": ["AAA": 3]], quotes: ["AAA": quotes],
                                          start: "2026-01-01", openedDates: ["A": ["AAA": "2026-03-01"]], accounts: ["A"])
        let buy = openings.first { $0.symbol == "AAA" }
        XCTAssertEqual(buy?.date, "2026-03-02", "the first close after the broker's opening date")
        XCTAssertEqual(openings.first { $0.external }?.cash.first?.amount, 240)
    }

    func testAFillWithoutAPriceTakesTheNearestClose() {
        let closes: [String: T.Quote] = ["2026-02-18": T.Quote(price: 400, currency: "USD"), "2026-02-24": T.Quote(price: 410, currency: "USD")]
        XCTAssertEqual(T.close(near: "2026-02-20", in: closes)?.date, "2026-02-18", "the latest close before it comes first")
        XCTAssertEqual(T.close(near: "2026-02-10", in: closes)?.date, "2026-02-18", "or the earliest after it")
        XCTAssertNil(T.close(near: "2026-01-01", in: closes), "nothing within ten days")
    }

    func testSharesNoLongerHeldLeaveAtTheirLastCloseWithoutALoss() {
        // Bought 10, no sale recorded, none held today: exchanged in a takeover.
        let events = [trade("b1", "2026-01-02", "AAA", 10, at: 100)]
        let quotes: [String: [String: T.Quote]] = ["AAA": ["2026-01-02": T.Quote(price: 100, currency: "USD"),
                                                           "2026-02-20": T.Quote(price: 130, currency: "USD")]]
        let closings = T.closingTransfers(events: events, splits: [], expected: [:], quotes: quotes, accounts: ["A"])
        XCTAssertEqual(closings.symbols, ["AAA"])
        let sale = closings.events.first { $0.symbol == "AAA" }
        XCTAssertEqual(sale?.date, "2026-02-20")
        XCTAssertEqual(sale?.quantity, -10)
        let withdrawal = closings.events.first { $0.external }
        XCTAssertEqual(withdrawal?.cash.first?.amount, -1300, "its value leaves as a withdrawal, so the account keeps the gain it had")
    }

    func testTheImpliedLedgerMeasuresOnlyThePriceMove() throws {
        var events = [trade("b1", "2026-01-02", "AAA", 10, at: 100)]
        events += T.fundingShortfalls(events: events, accounts: ["A"])
        let result = try T.calculate(events: events, days: [day("2026-01-02", 100), day("2026-01-03", 110)])
        XCTAssertEqual(result.points.map(\.nav), [1, Decimal(string: "1.1")!])
        XCTAssertEqual(result.points.first?.inflow, 1000)
        XCTAssertEqual(result.points.last?.value, 1100)
    }

    func testADayNoPriceExplainsIsTakenAsATransfer() throws {
        // Funded for 1 share, but the account holds 15 the next day: a gap
        // in the data, not a 1400% day.
        var events = [trade("b1", "2026-01-02", "AAA", 1, at: 100)]
        events += T.fundingShortfalls(events: events, accounts: ["A"])
        events.append(T.Event(id: "gap", date: "2026-01-03", account: "A", symbol: "AAA", quantity: 14, cash: []))
        let days = [day("2026-01-02", 100), day("2026-01-03", 100), day("2026-01-05", 110)]
        let result = try T.calculate(events: events, days: days, inferUnfundedShareTransfers: true)
        XCTAssertEqual(result.points.map(\.nav), [1, 1, Decimal(string: "1.1")!])
        XCTAssertEqual(result.inferredShareTransfers.map(\.date), ["2026-01-03"])
        XCTAssertEqual(result.points[1].inflow, 1400, "the unexplained value came in as a transfer")
        XCTAssertEqual(try T.calculate(events: events, days: days).points[1].nav, 15, "without the limit, a ledger is taken as it stands")
    }

    // MARK: Without a ledger

    func testAValueJumpNoFundingExplainsIsNotAReturn() {
        let days = LocalMarketDataClient.impliedLedgerDays(values: [
            ("2026-01-02", 100, 100), ("2026-01-03", 1400, 100), ("2026-01-04", 1540, 100),
        ])
        XCTAssertEqual(days.last?.nav ?? 0, 1.1, accuracy: 1e-12)
    }

    func testValueAndFundingLinesChainLikeTheLedger() {
        // 1000 in, grows 10%, 500 more in, flat, 300 out.
        let days = LocalMarketDataClient.impliedLedgerDays(values: [
            ("2026-01-02", 1000, 1000), ("2026-01-03", 1100, 1000),
            ("2026-01-04", 1600, 1500), ("2026-01-05", 1300, 1200),
        ])
        XCTAssertEqual(days.map(\.inflow), [1000, 0, 500, 0])
        XCTAssertEqual(days.map(\.outflow), [0, 0, 0, 300])
        XCTAssertEqual(days.last?.nav ?? 0, 1.1, accuracy: 1e-12, "the deposit and the withdrawal are not returns")
    }

    func testNothingIsReturnedBeforeTheFirstDeposit() {
        let days = LocalMarketDataClient.impliedLedgerDays(values: [("2026-01-01", 0, 0), ("2026-01-02", 100, 100)])
        XCTAssertEqual(days.map(\.date), ["2026-01-02"])
    }
}
