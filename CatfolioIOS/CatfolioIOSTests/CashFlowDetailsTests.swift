import Foundation
import XCTest
@testable import CatfolioIOS

/// Cash-flow rows must preserve disclosed cash movements, reporting scope,
/// and missing values when annual-to-date filings are reduced to quarters.
final class CashFlowDetailsTests: XCTestCase {
    private typealias Namespace = [String: CompanyFinancialsClient.SECFact]

    private func namespace(_ rows: [String: [[String: Any]]]) throws -> Namespace {
        let values = rows.mapValues { ["units": ["USD": $0]] }
        return try JSONDecoder().decode(Namespace.self, from: JSONSerialization.data(withJSONObject: values))
    }

    private func duration(_ value: Double, start: String = "2026-01-01", end: String = "2026-03-31",
                          quarter: String = "Q1", filed: String = "2026-04-30") -> [String: Any] {
        ["start": start, "end": end, "val": value, "fp": quarter, "fy": 2026,
         "form": "10-Q", "filed": filed]
    }

    private func instant(_ value: Double, end: String, filed: String = "2026-04-30") -> [String: Any] {
        ["end": end, "val": value, "fp": "Q1", "fy": 2026, "form": "10-Q", "filed": filed]
    }

    private func quarter(_ values: [String: Double]) throws -> CashFlowStatementPeriod {
        let rows = try CompanyFinancialsClient.makeSECCashFlow(namespace: namespace(values.mapValues {
            [duration($0)]
        }))
        return try XCTUnwrap(rows.first(where: { $0.kind == .quarterly }))
    }

    func testMetaDisclosedCashReconcilesAndLeasePrincipalHasSeparateFCFDefinition() throws {
        // Extracted USD facts, CIK 1326801, 2026 Q1 10-Q filed April 30, 2026.
        // https://data.sec.gov/api/xbrl/companyfacts/CIK0001326801.json
        // Official cash-flow statement and FCF reconciliation:
        // https://investor.atmeta.com/investor-news/press-release-details/2026/Meta-Reports-First-Quarter-2026-Results/default.aspx
        let amounts: [String: Double] = [
            "NetCashProvidedByUsedInOperatingActivities": 32_226_000_000,
            "PaymentsToAcquirePropertyPlantAndEquipment": 18_997_000_000,
            "NetCashProvidedByUsedInInvestingActivities": -33_678_000_000,
            "NetCashProvidedByUsedInFinancingActivities": -6_553_000_000,
            "FinanceLeasePrincipalPayments": 843_000_000,
            "NetIncomeLoss": 26_773_000_000,
            "DepreciationDepletionAndAmortization": 5_999_000_000,
            "DeferredIncomeTaxExpenseBenefit": 123_000_000,
            "ShareBasedCompensation": 6_032_000_000,
            "OtherNoncashIncomeExpense": 17_000_000,
            "PaymentsOfDividends": 1_346_000_000,
            "PaymentsForRepurchaseOfCommonStock": 0,
            "EffectOfExchangeRateOnCashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": 7_000_000,
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect": -7_998_000_000,
        ]
        var facts = amounts.mapValues { [duration($0)] }
        facts["CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents"] = [
            instant(39_100_000_000, end: "2025-12-31"),
            instant(31_102_000_000, end: "2026-03-31"),
        ]
        facts["CashAndCashEquivalentsAtCarryingValue"] = [
            instant(35_873_000_000, end: "2025-12-31"),
            instant(23_426_000_000, end: "2026-03-31"),
        ]
        let period = try XCTUnwrap(CompanyFinancialsClient.makeSECCashFlow(namespace: namespace(facts)).first)
        let details = try XCTUnwrap(period.details)

        XCTAssertEqual(period.freeCashFlow, 13_229_000_000)
        XCTAssertEqual(period.leaseAdjustedFreeCashFlow, 12_386_000_000)
        XCTAssertNil(details.sourceFreeCashFlow)
        XCTAssertEqual(details.value(.financeLeasePrincipalPayments), -843_000_000)
        XCTAssertEqual(details.value(.dividendsPaid), -1_346_000_000)
        XCTAssertEqual(details.value(.commonStockRepurchased), 0)
        XCTAssertEqual(details.value(.netIncome), 26_773_000_000)
        XCTAssertEqual(details.value(.depreciationAndAmortization), 5_999_000_000)
        XCTAssertEqual(details.value(.deferredIncomeTaxes), 123_000_000)
        XCTAssertEqual(details.value(.stockBasedCompensation), 6_032_000_000)
        XCTAssertEqual(details.value(.otherNonCashItems), -17_000_000)
        XCTAssertTrue(details.isPartial(.otherNonCashItems))
        XCTAssertEqual(details.cashIncludesRestrictedCash, true)
        XCTAssertEqual(details.value(.cashAtBeginningOfPeriod), 39_100_000_000)
        XCTAssertEqual(details.value(.cashAtEndOfPeriod), 31_102_000_000)
        XCTAssertEqual(details.value(.changeInCash), -7_998_000_000)
        XCTAssertEqual(period.cashReconciliationDifference, 0)
        XCTAssertEqual(period.cashFlowTotalDifference, 0)
    }

    func testCumulativeDetailFlowsBecomeSingleQuarterButCashBalancesStayInstantaneous() throws {
        func ytd(_ q1: Double, _ q2: Double) -> [[String: Any]] {
            [duration(q1), duration(q2, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")]
        }
        let facts = try namespace([
            "NetCashProvidedByUsedInOperatingActivities": ytd(100, 240),
            "PaymentsToAcquirePropertyPlantAndEquipment": ytd(20, 55),
            "NetCashProvidedByUsedInInvestingActivities": ytd(-60, -140),
            "NetCashProvidedByUsedInFinancingActivities": ytd(-30, -80),
            "NetIncomeLoss": ytd(70, 160),
            "ShareBasedCompensation": ytd(10, 25),
            "PaymentsOfDividends": ytd(4, 10),
            "FinanceLeasePrincipalPayments": ytd(3, 8),
            "EffectOfExchangeRateOnCashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": ytd(1, 2),
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect": ytd(11, 22),
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": [
                instant(50, end: "2025-12-31"), instant(61, end: "2026-03-31"),
                instant(72, end: "2026-06-30", filed: "2026-07-30"),
            ],
        ])
        let period = try XCTUnwrap(CompanyFinancialsClient.makeSECCashFlow(namespace: facts)
            .first(where: { $0.fiscalPeriod == "Q2" }))
        let details = try XCTUnwrap(period.details)

        XCTAssertEqual(period.operatingCashFlow, 140)
        XCTAssertEqual(period.capitalExpenditure, 35)
        XCTAssertEqual(period.freeCashFlow, 105)
        XCTAssertEqual(period.leaseAdjustedFreeCashFlow, 100)
        XCTAssertEqual(details.value(.netIncome), 90)
        XCTAssertEqual(details.value(.stockBasedCompensation), 15)
        XCTAssertEqual(details.value(.dividendsPaid), -6)
        XCTAssertEqual(details.value(.financeLeasePrincipalPayments), -5)
        XCTAssertEqual(details.value(.effectOfExchangeRates), 1)
        XCTAssertEqual(details.value(.changeInCash), 11)
        XCTAssertEqual(details.value(.cashAtBeginningOfPeriod), 61)
        XCTAssertEqual(details.value(.cashAtEndOfPeriod), 72)
        XCTAssertEqual(period.cashReconciliationDifference, 0)
        XCTAssertEqual(period.cashFlowTotalDifference, 0)
    }

    func testLatestMetaThirdQuarterUsesActualYearToDateFactsAndQuarterOpeningCash() throws {
        // Compact extract of the same Company Facts source, retrieved October
        // 22, 2026. The Q3 10-Q includes nine-month flows and a standalone
        // three-month net-income disclosure; cash endpoints are instant facts.
        func ytd(_ q2Millions: Double, _ q3Millions: Double) -> [[String: Any]] {
            [duration(q2Millions * 1_000_000, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30"),
             duration(q3Millions * 1_000_000, end: "2026-09-30", quarter: "Q3", filed: "2026-10-22")]
        }
        var rows: [String: [[String: Any]]] = [
            "NetCashProvidedByUsedInOperatingActivities": ytd(64_088, 96_873),
            "PaymentsToAcquirePropertyPlantAndEquipment": ytd(49_113, 83_055),
            "NetCashProvidedByUsedInInvestingActivities": ytd(-83_331, -114_309),
            "NetCashProvidedByUsedInFinancingActivities": ytd(9_414, 2_682),
            "FinanceLeasePrincipalPayments": ytd(1_805, 2_769),
            "NetIncomeLoss": ytd(42_621, 52_481),
            "ShareBasedCompensation": ytd(13_690, 21_053),
            "EffectOfExchangeRateOnCashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": ytd(0, 8),
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect": ytd(-9_829, -14_746),
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": [
                instant(29_271_000_000, end: "2026-06-30", filed: "2026-07-30"),
                instant(24_354_000_000, end: "2026-09-30", filed: "2026-10-22"),
            ],
            "CashAndCashEquivalentsAtCarryingValue": [
                instant(15_462_000_000, end: "2026-06-30", filed: "2026-07-30"),
                instant(11_222_000_000, end: "2026-09-30", filed: "2026-10-22"),
            ],
        ]
        rows["NetIncomeLoss"]?.append(duration(9_860_000_000, start: "2026-07-01", end: "2026-09-30",
            quarter: "Q3", filed: "2026-10-22"))
        let periods = try CompanyFinancialsClient.makeSECCashFlow(namespace: namespace(rows))
        let latest = try XCTUnwrap(periods.first)
        let details = try XCTUnwrap(latest.details)

        XCTAssertEqual(latest.periodEnd, "2026-09-30")
        XCTAssertEqual(latest.fiscalPeriod, "Q3")
        XCTAssertEqual(latest.filedDate, "2026-10-22")
        XCTAssertEqual(latest.operatingCashFlow, 32_785_000_000)
        XCTAssertEqual(latest.capitalExpenditure, 33_942_000_000)
        XCTAssertEqual(latest.freeCashFlow, -1_157_000_000)
        XCTAssertEqual(latest.leaseAdjustedFreeCashFlow, -2_121_000_000)
        XCTAssertEqual(latest.investingCashFlow, -30_978_000_000)
        XCTAssertEqual(latest.financingCashFlow, -6_732_000_000)
        XCTAssertEqual(details.value(.netIncome), 9_860_000_000)
        XCTAssertEqual(details.value(.stockBasedCompensation), 7_363_000_000)
        XCTAssertEqual(details.value(.financeLeasePrincipalPayments), -964_000_000)
        XCTAssertEqual(details.value(.effectOfExchangeRates), 8_000_000)
        XCTAssertEqual(details.value(.changeInCash), -4_917_000_000)
        XCTAssertEqual(details.value(.cashAtBeginningOfPeriod), 29_271_000_000)
        XCTAssertEqual(details.value(.cashAtEndOfPeriod), 24_354_000_000)
        XCTAssertEqual(details.cashIncludesRestrictedCash, true)
        XCTAssertEqual(latest.cashReconciliationDifference, 0)
        XCTAssertEqual(latest.cashFlowTotalDifference, 0)
    }

    func testMissingCumulativeDetailBaselineDoesNotTurnYearToDateIntoAQuarter() throws {
        let facts = try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [duration(100),
                duration(240, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
            "ShareBasedCompensation": [duration(25, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
            "FinanceLeasePrincipalPayments": [duration(8, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
        ])
        let period = try XCTUnwrap(CompanyFinancialsClient.makeSECCashFlow(namespace: facts)
            .first(where: { $0.fiscalPeriod == "Q2" }))

        XCTAssertEqual(period.operatingCashFlow, 140)
        XCTAssertNil(period.details?.value(.stockBasedCompensation))
        XCTAssertNil(period.details?.value(.financeLeasePrincipalPayments))
        XCTAssertNil(period.leaseAdjustedFreeCashFlow)
        XCTAssertNil(period.cashReconciliationDifference)
        XCTAssertNil(period.cashFlowTotalDifference)
    }

    func testPartialDirectQuarterDepreciationCannotReplaceCompleteDerivedDepreciationAndAmortization() throws {
        let facts = try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [duration(100),
                duration(240, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
            "DepreciationDepletionAndAmortization": [duration(20),
                duration(50, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
            // The note discloses quarterly PPE depreciation only, excluding
            // amortization already included in the complete cash-flow total.
            "DepreciationDepletionAndAmortizationPropertyPlantAndEquipment": [
                duration(18, start: "2026-04-01", end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
        ])
        let quarter = try XCTUnwrap(CompanyFinancialsClient.makeSECCashFlow(namespace: facts)
            .first(where: { $0.fiscalPeriod == "Q2" }))
        let details = try XCTUnwrap(quarter.details)

        XCTAssertEqual(details.value(.depreciationAndAmortization), 30)
        XCTAssertFalse(details.isPartial(.depreciationAndAmortization))
    }

    func testIncompleteStatementDoesNotTreatUndisclosedDetailsAsZero() throws {
        let period = try quarter(["NetCashProvidedByUsedInOperatingActivities": 100])

        XCTAssertNil(period.capitalExpenditure)
        XCTAssertNil(period.freeCashFlow)
        XCTAssertNil(period.leaseAdjustedFreeCashFlow)
        XCTAssertNil(period.details?.value(.dividendsPaid))
        XCTAssertNil(period.details?.value(.commonStockRepurchased))
        XCTAssertNil(period.details?.value(.changeInCash))
        XCTAssertNil(period.cashReconciliationDifference)
        XCTAssertNil(period.cashFlowTotalDifference)
    }

    func testDisclosedZeroLeasePrincipalStillSupportsLeaseAdjustedFCF() throws {
        let period = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "PaymentsToAcquirePropertyPlantAndEquipment": 20,
            "FinanceLeasePrincipalPayments": 0,
        ])

        XCTAssertEqual(period.details?.value(.financeLeasePrincipalPayments), 0)
        XCTAssertEqual(period.freeCashFlow, 80)
        XCTAssertEqual(period.leaseAdjustedFreeCashFlow, 80)
    }

    func testWorkingCapitalTotalIsACashEffectRatherThanAnAssetIncrease() throws {
        let period = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "IncreaseDecreaseInOperatingCapital": 18,
        ])

        XCTAssertEqual(period.details?.value(.changeInWorkingCapital), -18)
        XCTAssertFalse(try XCTUnwrap(period.details).isPartial(.changeInWorkingCapital))
    }

    func testKnownWorkingCapitalComponentsHaveCorrectSignsAndRemainMarkedPartial() throws {
        // Broad prepaid/other-asset and other-operating-asset concepts can
        // overlap across issuers. Keep only the conservative known subtotal.
        let period = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 32_226_000_000,
            "IncreaseDecreaseInAccountsReceivable": -2_128_000_000,
            "IncreaseDecreaseInPrepaidDeferredExpenseAndOtherAssets": 2_424_000_000,
            "IncreaseDecreaseInOtherOperatingAssets": 1_082_000_000,
            "IncreaseDecreaseInAccountsPayableTrade": -937_000_000,
            "IncreaseDecreaseInAccruedLiabilities": -271_000_000,
            "IncreaseDecreaseInOtherNoncurrentLiabilities": -5_173_000_000,
        ])
        let details = try XCTUnwrap(period.details)

        XCTAssertEqual(details.value(.changeInWorkingCapital), -6_677_000_000)
        XCTAssertTrue(details.isPartial(.changeInWorkingCapital))
        XCTAssertNil(details.value(.otherNonCashItems))
    }

    func testWorkingCapitalAggregateDoesNotAddItsIndividualComponentsAgain() throws {
        let period = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "IncreaseDecreaseInOperatingCapital": 18,
            "IncreaseDecreaseInAccountsReceivable": 12,
            "IncreaseDecreaseInAccountsPayableTrade": -6,
        ])

        XCTAssertEqual(period.details?.value(.changeInWorkingCapital), -18)
        XCTAssertFalse(try XCTUnwrap(period.details).isPartial(.changeInWorkingCapital))
    }

    func testInvestmentPurchaseAggregateWinsOverItsKnownComponentsAndIsComplete() throws {
        let partial = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "PaymentsToAcquireAvailableForSaleSecuritiesDebt": 40,
        ])
        XCTAssertEqual(partial.details?.value(.investmentPurchases), -40)
        XCTAssertTrue(try XCTUnwrap(partial.details).isPartial(.investmentPurchases))

        let total = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "PaymentsToAcquireInvestments": 60,
            "PaymentsToAcquireAvailableForSaleSecuritiesDebt": 40,
            "PaymentsToAcquireHeldToMaturitySecurities": 20,
        ])
        XCTAssertEqual(total.details?.value(.investmentPurchases), -60)
        XCTAssertFalse(try XCTUnwrap(total.details).isPartial(.investmentPurchases))
    }

    func testPaymentsAndProceedsKeepTheirFinancialDirection() throws {
        let period = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "PaymentsToAcquireBusinessesNetOfCashAcquired": 12,
            "PaymentsToAcquireAvailableForSaleSecuritiesDebt": 40,
            "ProceedsFromSaleAndMaturityOfAvailableForSaleSecurities": 20,
            "PaymentsForProceedsFromOtherInvestingActivities": -5,
            "PaymentsOfDividends": 4,
            "PaymentsForRepurchaseOfCommonStock": 10,
            "FinanceLeasePrincipalPayments": 3,
        ])
        let details = try XCTUnwrap(period.details)

        XCTAssertEqual(details.value(.acquisitions), -12)
        XCTAssertEqual(details.value(.investmentPurchases), -40)
        XCTAssertEqual(details.value(.investmentSalesAndMaturities), 20)
        XCTAssertEqual(details.value(.otherInvestingActivities), 5)
        XCTAssertEqual(details.value(.dividendsPaid), -4)
        XCTAssertEqual(details.value(.commonStockRepurchased), -10)
        XCTAssertEqual(details.value(.financeLeasePrincipalPayments), -3)
    }

    func testNegativeSECPaymentsPreserveTheirCashInflowDirection() throws {
        let period = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "PaymentsToAcquireBusinessesNetOfCashAcquiredAndDivestitures": -12,
            "PaymentsToAcquireInvestments": -40,
            "RepaymentsOfDebt": -5,
        ])

        XCTAssertEqual(period.details?.value(.acquisitions), 12)
        XCTAssertEqual(period.details?.value(.investmentPurchases), 40)
        XCTAssertEqual(period.details?.value(.debtRepaid), 5)
    }

    func testAggregateDebtAndShareIssuanceDoNotDoubleCountTheirComponents() throws {
        let period = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "ProceedsFromIssuanceOfDebt": 120,
            "ProceedsFromIssuanceOfLongTermDebt": 90,
            "ProceedsFromShortTermDebt": 30,
            "RepaymentsOfDebt": 50,
            "RepaymentsOfLongTermDebt": 40,
            "RepaymentsOfShortTermDebt": 10,
            "ProceedsFromIssuanceOfCommonStock": 25,
            "ProceedsFromStockOptionsExercised": 7,
        ])

        XCTAssertEqual(period.details?.value(.debtIssued), 120)
        XCTAssertEqual(period.details?.value(.debtRepaid), -50)
        XCTAssertEqual(period.details?.value(.commonStockIssued), 25)
    }

    func testDisjointShortAndLongDebtAreSummedWhenNoAggregateIsReported() throws {
        let period = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "ProceedsFromIssuanceOfLongTermDebt": 90,
            "ProceedsFromShortTermDebt": 30,
            // An alternative tag for the same short-term amount is no addend.
            "ProceedsFromIssuanceOfShortTermDebt": 30,
            "RepaymentsOfLongTermDebt": 40,
            "RepaymentsOfShortTermDebt": 10,
        ])

        XCTAssertEqual(period.details?.value(.debtIssued), 120)
        XCTAssertEqual(period.details?.value(.debtRepaid), -50)
    }

    func testReconciliationDifferencesExposeDisagreementRatherThanForcingTotals() throws {
        let facts = try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [duration(100)],
            "NetCashProvidedByUsedInInvestingActivities": [duration(-60)],
            "NetCashProvidedByUsedInFinancingActivities": [duration(-30)],
            "EffectOfExchangeRateOnCashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": [duration(1)],
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect": [duration(12)],
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": [
                instant(50, end: "2025-12-31"), instant(65, end: "2026-03-31"),
            ],
        ])
        let period = try XCTUnwrap(CompanyFinancialsClient.makeSECCashFlow(namespace: facts).first)

        XCTAssertEqual(period.details?.value(.changeInCash), 12)
        XCTAssertEqual(period.details?.value(.cashAtEndOfPeriod), 65)
        XCTAssertEqual(period.cashReconciliationDifference, 3)
        XCTAssertEqual(period.cashFlowTotalDifference, 1)
    }

    func testRestrictedCashFlowDoesNotBorrowOrdinaryCashOpeningBalance() throws {
        let facts = try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [duration(100)],
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect": [duration(10)],
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": [instant(70, end: "2026-03-31")],
            "CashAndCashEquivalentsAtCarryingValue": [
                instant(40, end: "2025-12-31"), instant(50, end: "2026-03-31"),
            ],
        ])
        let period = try XCTUnwrap(CompanyFinancialsClient.makeSECCashFlow(namespace: facts).first)

        XCTAssertEqual(period.details?.cashIncludesRestrictedCash, true)
        XCTAssertEqual(period.details?.value(.cashAtEndOfPeriod), 70)
        // The beginning may be derived as 70 - 10, but must never become 40.
        if let beginning = period.details?.value(.cashAtBeginningOfPeriod) {
            XCTAssertEqual(beginning, 60)
        }
    }

    func testLaterBalanceRestatementDoesNotRewriteAnEarlierCashFlowStatement() throws {
        let facts = try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [duration(100)],
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect": [duration(10)],
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": [
                instant(60, end: "2025-12-31"), instant(70, end: "2026-03-31"),
                instant(900, end: "2025-12-31", filed: "2026-08-01"),
                instant(999, end: "2026-03-31", filed: "2026-08-01"),
            ],
        ])
        let period = try XCTUnwrap(CompanyFinancialsClient.makeSECCashFlow(namespace: facts).first)

        XCTAssertEqual(period.details?.value(.cashAtBeginningOfPeriod), 60)
        XCTAssertEqual(period.details?.value(.cashAtEndOfPeriod), 70)
        XCTAssertEqual(period.cashReconciliationDifference, 0)
    }

    func testCashScopeChangeCannotBecomeASingleQuarterCashMovement() throws {
        let facts = try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [duration(100),
                duration(240, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
            "CashAndCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect": [duration(11)],
            "EffectOfExchangeRateOnCashAndCashEquivalents": [duration(1)],
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalentsPeriodIncreaseDecreaseIncludingExchangeRateEffect": [
                duration(22, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
            "EffectOfExchangeRateOnCashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": [
                duration(2, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
            "CashAndCashEquivalentsAtCarryingValue": [instant(61, end: "2026-03-31")],
            "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": [
                instant(82, end: "2026-06-30", filed: "2026-07-30")],
        ])
        let quarter = try XCTUnwrap(CompanyFinancialsClient.makeSECCashFlow(namespace: facts)
            .first(where: { $0.fiscalPeriod == "Q2" }))

        XCTAssertEqual(quarter.operatingCashFlow, 140)
        XCTAssertEqual(quarter.details?.cashIncludesRestrictedCash, true)
        XCTAssertEqual(quarter.details?.value(.cashAtEndOfPeriod), 82)
        XCTAssertNil(quarter.details?.value(.cashAtBeginningOfPeriod))
        XCTAssertNil(quarter.details?.value(.changeInCash))
        XCTAssertNil(quarter.details?.value(.effectOfExchangeRates))
        XCTAssertNil(quarter.cashReconciliationDifference)
    }

    func testChangingTheKnownCompositionDoesNotProduceAMisleadingQuarterSubtotal() throws {
        let facts = try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [duration(100),
                duration(240, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
            "PaymentsToAcquireAvailableForSaleSecuritiesDebt": [duration(40),
                duration(70, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
            // The second filing discloses a new component, but not its Q1
            // value. Subtracting 40 from 70 + 20 cannot establish Q2 spend.
            "PaymentsToAcquireHeldToMaturitySecurities": [
                duration(20, end: "2026-06-30", quarter: "Q2", filed: "2026-07-30")],
        ])
        let quarter = try XCTUnwrap(CompanyFinancialsClient.makeSECCashFlow(namespace: facts)
            .first(where: { $0.fiscalPeriod == "Q2" }))

        XCTAssertEqual(quarter.operatingCashFlow, 140)
        XCTAssertNil(quarter.details?.value(.investmentPurchases))
    }

    func testProviderFCFDoesNotReplaceTheComparableOperatingMinusPPEAmount() throws {
        let json: [[String: Any]] = [[
            "date": "2026-03-31", "period": "Q1", "fiscalYear": "2026",
            "reportedCurrency": "USD", "operatingCashFlow": 32_226,
            "capitalExpenditure": -18_997, "freeCashFlow": 12_386,
        ]]
        let rows = try JSONDecoder().decode([CompanyFinancialsClient.FMPCashRow].self,
            from: JSONSerialization.data(withJSONObject: json))
        let period = try XCTUnwrap(CompanyFinancialsClient.makeFMPCashFlow(rows, kind: .quarterly).first)

        XCTAssertEqual(period.freeCashFlow, 13_229)
        XCTAssertEqual(period.details?.sourceFreeCashFlow, 12_386)
        // A provider's number alone cannot establish that leases explain it.
        XCTAssertNil(period.leaseAdjustedFreeCashFlow)
    }

    func testProviderNetAcquisitionsRemainSignedAndNetBorrowingDoesNotBecomeGrossIssuance() throws {
        let json: [[String: Any]] = [
            ["date": "2026-03-31", "period": "Q1", "operatingCashFlow": 100,
             "acquisitionsNet": -12, "netDebtIssuance": 40, "debtRepayment": -10],
            ["date": "2026-06-30", "period": "Q2", "operatingCashFlow": 120,
             "acquisitionsNet": 9, "netDebtIssuance": -15],
        ]
        let rows = try JSONDecoder().decode([CompanyFinancialsClient.FMPCashRow].self,
            from: JSONSerialization.data(withJSONObject: json))
        let periods = CompanyFinancialsClient.makeFMPCashFlow(rows, kind: .quarterly)
        let q1 = try XCTUnwrap(periods.first(where: { $0.fiscalPeriod == "Q1" }))
        let q2 = try XCTUnwrap(periods.first(where: { $0.fiscalPeriod == "Q2" }))

        XCTAssertEqual(q1.details?.value(.acquisitions), -12)
        XCTAssertEqual(q2.details?.value(.acquisitions), 9)
        XCTAssertNil(q1.details?.value(.debtIssued))
        XCTAssertEqual(q1.details?.value(.debtRepaid), -10)
        XCTAssertNil(q2.details?.value(.debtIssued))
        XCTAssertNil(q2.details?.value(.debtRepaid))
    }

    func testOldCashFlowCacheStillDecodesWithoutFabricatingDetails() throws {
        let json: [String: Any] = [
            "periodEnd": "2025-12-31", "fiscalYear": 2025, "fiscalPeriod": "FY",
            "kind": "annual", "currency": "USD", "operatingCashFlow": 100,
            "capitalExpenditure": 20, "freeCashFlow": 80,
            "investingCashFlow": -40, "financingCashFlow": -30,
        ]
        let period = try JSONDecoder().decode(CashFlowStatementPeriod.self,
            from: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(period.freeCashFlow, 80)
        XCTAssertNil(period.details)
        XCTAssertNil(period.leaseAdjustedFreeCashFlow)
        XCTAssertNil(period.cashReconciliationDifference)
        XCTAssertNil(period.cashFlowTotalDifference)
    }

    func testDetailsSurviveStatementCacheRoundTrip() throws {
        let original = try quarter([
            "NetCashProvidedByUsedInOperatingActivities": 100,
            "PaymentsToAcquirePropertyPlantAndEquipment": 20,
            "FinanceLeasePrincipalPayments": 3,
            "PaymentsOfDividends": 0,
        ])
        let restored = try JSONDecoder().decode(CashFlowStatementPeriod.self,
            from: JSONEncoder().encode(original))

        XCTAssertEqual(restored.details?.value(.financeLeasePrincipalPayments), -3)
        XCTAssertEqual(restored.details?.value(.dividendsPaid), 0)
        XCTAssertEqual(restored.freeCashFlow, 80)
        XCTAssertEqual(restored.leaseAdjustedFreeCashFlow, 77)
    }
}
