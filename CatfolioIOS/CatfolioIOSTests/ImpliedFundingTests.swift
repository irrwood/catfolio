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

    func testTheImpliedLedgerMeasuresOnlyThePriceMove() throws {
        var events = [trade("b1", "2026-01-02", "AAA", 10, at: 100)]
        events += T.fundingShortfalls(events: events, accounts: ["A"])
        let result = try T.calculate(events: events, days: [day("2026-01-02", 100), day("2026-01-03", 110)])
        XCTAssertEqual(result.points.map(\.nav), [1, Decimal(string: "1.1")!])
        XCTAssertEqual(result.points.first?.inflow, 1000)
        XCTAssertEqual(result.points.last?.value, 1100)
    }
}
