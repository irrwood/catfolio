import Foundation
import XCTest
@testable import CatfolioIOS

final class MoneyWeightedAnnualReturnTests: XCTestCase {
    func testUsesInvestmentTimingAndAdditionalDeposits() throws {
        let ledger = AccountMWRLedger(dates: ["2025-01-01", "2025-07-02", "2026-01-01"],
            cashFlows: [1000, 1000, 0], values: [1000, 2100, 2310], benchmarkValues: [:])
        let rate = try XCTUnwrap(ledger.annualizedReturn())
        // XIRR: 1000 grows for a year, the additional 1000 for 183 days.
        XCTAssertEqual(1000 * pow(1 + rate, 365 / 365.25)
            + 1000 * pow(1 + rate, 183 / 365.25), 2310, accuracy: 0.001)
    }

    func testIntervalUsesOpeningValueAndAccountsForWithdrawals() throws {
        let ledger = AccountMWRLedger(dates: ["2024-12-31", "2025-01-01", "2026-01-01"],
            cashFlows: [500, 0, -100], values: [500, 1000, 1000], benchmarkValues: [:])
        XCTAssertEqual(try XCTUnwrap(ledger.annualizedReturn(startIndex: 1)),
            pow(1.1, 365.25 / 365) - 1, accuracy: 0.000001)
    }

    func testShortOrMissingInvestmentHistoryIsUnavailable() {
        let short = AccountMWRLedger(dates: ["2026-01-01", "2026-01-20"],
            cashFlows: [1000, 0], values: [1000, 1100], benchmarkValues: [:])
        XCTAssertNil(short.annualizedReturn())
        let empty = AccountMWRLedger(dates: [], cashFlows: [], values: [], benchmarkValues: [:])
        XCTAssertNil(empty.annualizedReturn())
    }
}
