import XCTest
@testable import CatfolioIOS

final class CashFlowPeriodMergeTests: XCTestCase {
    private func row(_ end: String, kind: FinancialPeriodKind = .quarterly,
                     currency: String = "USD", operating: Double = 100) -> CashFlowStatementPeriod {
        CashFlowStatementPeriod(periodEnd: end, filedDate: nil, fiscalYear: 2026,
            fiscalPeriod: kind == .annual ? "FY" : "Q3", kind: kind, currency: currency,
            operatingCashFlow: operating, capitalExpenditure: 30, freeCashFlow: operating - 30,
            investingCashFlow: -40, financingCashFlow: -10)
    }

    func testNonemptySECStatementCanReceiveANewerActualQuarter() throws {
        let rows = CompanyFinancialsClient.addingNewerCashFlowPeriods(
            to: [row("2026-06-30")], from: [row("2026-09-30", operating: 150)])
        XCTAssertEqual(rows.map(\.periodEnd), ["2026-09-30", "2026-06-30"])
        XCTAssertEqual(rows.first?.operatingCashFlow, 150)
    }

    func testProviderDoesNotReplaceOrBackfillExistingSECDefinitions() {
        let rows = CompanyFinancialsClient.addingNewerCashFlowPeriods(
            to: [row("2026-06-30")],
            from: [row("2026-06-30", operating: 999), row("2026-03-31", operating: 888)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.operatingCashFlow, 100)
    }

    func testAnnualAndQuarterlyHaveIndependentLatestPeriodsAndNoDuplicates() {
        let rows = CompanyFinancialsClient.addingNewerCashFlowPeriods(
            to: [row("2025-12-31", kind: .annual)],
            from: [row("2026-09-30"), row("2026-09-30"), row("2026-06-30")])
        XCTAssertEqual(rows.map(\.periodEnd), ["2026-09-30", "2026-06-30", "2025-12-31"])
        XCTAssertEqual(rows.filter { $0.kind == .annual }.count, 1)
    }

    func testDifferentCurrenciesAndUnusableAmountsCannotBecomeLatest() {
        let rows = CompanyFinancialsClient.addingNewerCashFlowPeriods(
            to: [row("2026-06-30")],
            from: [row("2026-09-30", currency: "EUR"), row("2026-09-30", operating: .nan)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.periodEnd, "2026-06-30")
    }

    func testMatchingProviderFillsMissingAndPartialDetailsWithoutChangingSECTotals() throws {
        var primary = row("2026-06-30")
        primary.details = .init(amounts: [.netIncome: 70, .otherNonCashItems: -1],
                                partialItems: [.otherNonCashItems])
        var provider = row("2026-06-30")
        provider.details = .init(amounts: [.netIncome: 999, .depreciationAndAmortization: 10,
                                           .otherNonCashItems: 5], sourceFreeCashFlow: 65)
        let merged = CompanyFinancialsClient.supplementingCashFlowDetails(to: [primary], from: [provider])
        let result = try XCTUnwrap(merged.periods.first)
        XCTAssertTrue(merged.didSupplement)
        XCTAssertEqual(result.operatingCashFlow, 100)
        XCTAssertEqual(result.freeCashFlow, 70)
        XCTAssertEqual(result.details?.value(.netIncome), 70)
        XCTAssertEqual(result.details?.value(.depreciationAndAmortization), 10)
        XCTAssertEqual(result.details?.value(.otherNonCashItems), 5)
        XCTAssertFalse(result.details?.isPartial(.otherNonCashItems) ?? true)
        XCTAssertEqual(result.details?.sourceFreeCashFlow, 65)
    }

    func testDifferentParentTotalsCannotFillDetailGaps() {
        var provider = row("2026-06-30", operating: 102)
        provider.details = .init(amounts: [.netIncome: 999])
        let result = CompanyFinancialsClient.supplementingCashFlowDetails(
            to: [row("2026-06-30")], from: [provider])
        XCTAssertFalse(result.didSupplement)
        XCTAssertNil(result.periods.first?.details)
    }

    func testDetailSupplementCannotMixUnknownAndRestrictedCashScopes() throws {
        var primary = row("2026-06-30")
        primary.details = .init(amounts: [.cashAtBeginningOfPeriod: 50], cashIncludesRestrictedCash: true)
        var provider = row("2026-06-30")
        provider.details = .init(amounts: [.cashAtEndOfPeriod: 999, .changeInCash: 999,
                                           .depreciationAndAmortization: 10])
        let result = CompanyFinancialsClient.supplementingCashFlowDetails(to: [primary], from: [provider])
        let details = try XCTUnwrap(result.periods.first?.details)
        XCTAssertEqual(details.value(.cashAtBeginningOfPeriod), 50)
        XCTAssertNil(details.value(.cashAtEndOfPeriod))
        XCTAssertNil(details.value(.changeInCash))
        XCTAssertEqual(details.value(.depreciationAndAmortization), 10)
        XCTAssertEqual(details.cashIncludesRestrictedCash, true)
    }
}
