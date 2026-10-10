import XCTest
@testable import CatfolioIOS

final class HistoryIncomeSummaryTests: XCTestCase {
    func testAddsDividendsToExistingRealisedTotalExactlyOnce() {
        let realised = RealisedProfitSummary(brokerTotals: ["USD": 100], brokerCount: 1,
            estimatedUSD: 10, estimatedCount: 1, brokerUSD: 100)
        let total = HistoryIncomeSummary(realised: realised, dividendsUSD: 50, dividendCount: 2, dividendsComplete: true)
        XCTAssertEqual(total.amountUSD, 160)
        XCTAssertTrue(total.isComplete)
        XCTAssertEqual(total.realised, realised)
    }

    func testDividendsWithoutSalesStillHaveAnOverviewIncludingZeroNetDividends() {
        for dividend in [0.0, 42.5, -12] {
            let total = HistoryIncomeSummary(realised: .init(), dividendsUSD: dividend,
                dividendCount: 2, dividendsComplete: true)
            XCTAssertEqual(total.amountUSD, dividend)
        }
        XCTAssertNil(HistoryIncomeSummary(realised: .init(), dividendsUSD: 0,
            dividendCount: 0, dividendsComplete: true).amountUSD)
    }

    func testLossesAndDividendReversalsKeepTheirSigns() {
        let realised = RealisedProfitSummary(brokerCount: 1, brokerUSD: -100)
        XCTAssertEqual(HistoryIncomeSummary(realised: realised, dividendsUSD: 25,
            dividendCount: 1, dividendsComplete: true).amountUSD, -75)
        XCTAssertEqual(HistoryIncomeSummary(realised: realised, dividendsUSD: -25,
            dividendCount: 1, dividendsComplete: true).amountUSD, -125)
    }

    func testPartialSalesStayMarkedAndUnknownDividendsNeverBecomeZero() {
        let partial = RealisedProfitSummary(brokerCount: 1, unavailableCount: 1, brokerUSD: 100)
        let known = HistoryIncomeSummary(realised: partial, dividendsUSD: 20,
            dividendCount: 1, dividendsComplete: true)
        XCTAssertEqual(known.amountUSD, 120)
        XCTAssertFalse(known.isComplete)
        let missing = HistoryIncomeSummary(realised: partial, dividendsUSD: .nan,
            dividendCount: 1, dividendsComplete: false)
        XCTAssertNil(missing.amountUSD)
        XCTAssertFalse(missing.isComplete)
        let noFX = RealisedProfitSummary(brokerTotals: ["XYZ": 50], brokerCount: 1,
                                        unconvertibleCurrencies: ["XYZ"])
        XCTAssertNil(HistoryIncomeSummary(realised: noFX, dividendsUSD: 0,
            dividendCount: 0, dividendsComplete: true).amountUSD)
    }

    func testBothComponentsUseTheSameAccountAndYearWithoutAddingProceedsOrInterest() throws {
        func trade(_ action: String, date: String, price: Double, account: String = "one") -> LocalTransactionRecord {
            .init(date: date, action: action, ticker: "AAA", quantity: 1, price: price,
                  currency: "USD", source: "CSV", accountID: account, accountName: account)
        }
        let trades = [trade("BUY", date: "2025-12-01", price: 100),
                      trade("SELL", date: "2026-06-01", price: 140),
                      trade("DIVIDEND", date: "2026-06-02", price: 6),
                      trade("DIVIDEND", date: "2025-06-02", price: 4),
                      trade("INTEREST", date: "2026-06-03", price: 99),
                      trade("DIVIDEND", date: "2026-06-02", price: 888, account: "other")]
        let prepared = try HistoryPreparedLedger.build(
            ledger: .init(accounts: [], transactions: trades, securityNames: [:]),
            accountIDs: [trades[0].accountKey], locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(prepared.incomeSummary(basis: .calendar, year: nil).amountUSD, 50)
        XCTAssertEqual(prepared.incomeSummary(basis: .calendar, year: "2026").amountUSD, 46)
        XCTAssertEqual(prepared.incomeSummary(basis: .uk, year: "2026/27").amountUSD, 46)
        XCTAssertEqual(prepared.incomeSummary(basis: .calendar, year: "2025").amountUSD, 4)
    }

    func testNonFiniteTotalsDoNotRenderAsIncome() {
        let total = HistoryIncomeSummary(realised: .init(brokerCount: 1, brokerUSD: .greatestFiniteMagnitude),
            dividendsUSD: .greatestFiniteMagnitude, dividendCount: 1, dividendsComplete: true)
        XCTAssertNil(total.amountUSD)
        XCTAssertFalse(total.isComplete)
    }
}
