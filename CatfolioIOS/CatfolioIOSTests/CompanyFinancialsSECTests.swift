import XCTest
@testable import CatfolioIOS

/// The shapes SEC filers actually use, read back as statements.
final class CompanyFinancialsSECTests: XCTestCase {
    private typealias Namespace = [String: CompanyFinancialsClient.SECFact]

    private func namespace(_ rows: [String: [[String: Any]]]) throws -> Namespace {
        let json = rows.mapValues { ["units": ["USD": $0]] }
        return try JSONDecoder().decode(Namespace.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func year(_ value: Double, _ end: String = "2025-12-31") -> [String: Any] {
        [
            "start": "\(end.prefix(4))-01-01", "end": end, "val": value,
            "filed": "2026-02-24", "form": "10-K", "fp": "FY",
        ]
    }

    func testAppleCumulativeCashFlowsProduceLatestStandaloneQuarters() throws {
        // SEC Company Facts, CIK 320193: fiscal 2026 Q1, Q2 and Q3.
        let periods = [("2025-12-27", "2026-01-30", "Q1"),
                       ("2026-03-28", "2026-05-01", "Q2"),
                       ("2026-06-27", "2026-07-31", "Q3")]
        func facts(_ values: [Double]) -> [[String: Any]] {
            zip(periods, values).map { period, value in
                ["start": "2025-09-28", "end": period.0, "filed": period.1,
                 "fp": period.2, "form": "10-Q", "val": value]
            }
        }
        let rows = CompanyFinancialsClient.makeSECCashFlow(namespace: try namespace([
            "NetCashProvidedByUsedInOperatingActivities": facts([53_925, 82_627, 116_996]),
            "PaymentsToAcquirePropertyPlantAndEquipment": facts([2_373, 4_344, 6_799]),
        ]))
        XCTAssertEqual(rows.map(\.fiscalPeriod), ["Q3", "Q2", "Q1"])
        XCTAssertEqual(rows.map(\.fiscalYear), [2026, 2026, 2026])
        XCTAssertEqual(rows.map(\.operatingCashFlow), [34_369, 28_702, 53_925])
        XCTAssertEqual(rows.map(\.capitalExpenditure), [2_455, 1_971, 2_373])
        XCTAssertEqual(rows.map(\.freeCashFlow), [31_914, 26_731, 51_552])
        XCTAssertEqual(rows.first?.periodEnd, "2026-06-27")
    }

    func testAnnualCashFlowAlsoProvidesFourthQuarterWithoutChangingAnnualTotal() throws {
        let q3: [String: Any] = ["start": "2025-01-01", "end": "2025-09-30", "filed": "2025-11-01",
                                 "fp": "Q3", "form": "10-Q", "val": 70]
        let rows = CompanyFinancialsClient.makeSECCashFlow(namespace: try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [q3, year(100)],
            "PaymentsToAcquirePropertyPlantAndEquipment": [q3.merging(["val": 16]) { _, new in new }, year(20)],
        ]))
        XCTAssertEqual(rows.first(where: { $0.kind == .annual })?.freeCashFlow, 80)
        let q4 = try XCTUnwrap(rows.first(where: { $0.fiscalPeriod == "Q4" }))
        XCTAssertEqual(q4.operatingCashFlow, 30)
        XCTAssertEqual(q4.capitalExpenditure, 4)
        XCTAssertEqual(q4.freeCashFlow, 26)
        // A missing Q2 baseline must not turn the cumulative Q3 into a quarter.
        XCTAssertFalse(rows.contains(where: { $0.fiscalPeriod == "Q3" }))
    }

    func testMissingCapitalExpenditureDoesNotBecomeZeroOrInventFreeCashFlow() throws {
        let rows = CompanyFinancialsClient.makeSECCashFlow(namespace: try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [year(100)]
        ]))
        let annual = try XCTUnwrap(rows.first)
        XCTAssertEqual(annual.operatingCashFlow, 100)
        XCTAssertNil(annual.capitalExpenditure)
        XCTAssertNil(annual.freeCashFlow)
        XCTAssertNoThrow(try JSONEncoder().encode(annual))
    }

    func testQuarterCalculationDoesNotMixFiscalYearsOrFutureRestatements() throws {
        let q1: [String: Any] = ["start": "2026-01-01", "end": "2026-03-31", "filed": "2026-05-01",
                                 "fp": "Q1", "form": "10-Q", "val": 10]
        let q2: [String: Any] = ["start": "2026-01-01", "end": "2026-06-30", "filed": "2026-08-01",
                                 "fp": "Q2", "form": "10-Q", "val": 35]
        let restated = q1.merging(["val": 99, "filed": "2026-10-01"]) { _, new in new }
        let rows = CompanyFinancialsClient.makeSECCashFlow(namespace: try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [q1, q2, restated]
        ]))
        XCTAssertEqual(rows.first(where: { $0.fiscalPeriod == "Q2" })?.operatingCashFlow, 25)
        XCTAssertEqual(rows.first(where: { $0.fiscalPeriod == "Q1" })?.operatingCashFlow, 99)
        let mismatched = q1.merging(["start": "2025-12-31"]) { _, new in new }
        XCTAssertTrue(CompanyFinancialsClient.makeSECCashFlow(namespace: try namespace([
            "NetCashProvidedByUsedInOperatingActivities": [mismatched, q2]
        ])).allSatisfy { $0.fiscalPeriod != "Q2" })
    }

    /// SoFi's shape: revenue net of interest expense, a cost of revenue, and
    /// one total expense line. No operating income and no operating expenses
    /// have been tagged since 2021, which used to drop every period and left
    /// the page with nothing to show.
    func testALenderWithNoOperatingLineStillReportsItsStatements() throws {
        let namespace = try namespace([
            "RevenuesNetOfInterestExpense": [year(3_613_354_000)],
            "RevenueFromContractWithCustomerExcludingAssessedTax": [year(619_353_000)],
            "CostOfRevenue": [year(608_998_000)],
            "NoninterestExpense": [year(3_057_178_000)],
            "NetIncomeLoss": [year(481_320_000)],
        ])

        let income = CompanyFinancialsClient.makeSECIncome(namespace: namespace)

        let period = try XCTUnwrap(income.first)
        XCTAssertEqual(income.count, 1)
        XCTAssertEqual(period.periodEnd, "2025-12-31")
        // The lender's top line, not the fee slice of it.
        XCTAssertEqual(period.revenue, 3_613_354_000)
        XCTAssertEqual(period.grossProfit, 3_004_356_000)
        // Revenue less the total expense line: taking it off the gross would
        // subtract the cost of revenue twice and print this negative.
        XCTAssertEqual(period.operatingIncome, 556_176_000)
        XCTAssertEqual(period.operatingExpenses, 2_448_180_000)
        XCTAssertEqual(period.netIncome, 481_320_000)
    }

    /// An industrial filer keeps the gross-profit arithmetic it has always
    /// had: the total-expense line is only read when neither is tagged.
    func testOperatingExpensesStillComeOffTheGross() throws {
        let namespace = try namespace([
            "Revenues": [year(1_000)],
            "CostOfRevenue": [year(400)],
            "OperatingExpenses": [year(250)],
            "NoninterestExpense": [year(900)],
            "NetIncomeLoss": [year(300)],
        ])

        let period = try XCTUnwrap(CompanyFinancialsClient.makeSECIncome(namespace: namespace).first)

        XCTAssertEqual(period.grossProfit, 600)
        XCTAssertEqual(period.operatingIncome, 350)
        XCTAssertEqual(period.operatingExpenses, 250)
    }

    /// Two concepts reported through the same period are ranked by the order
    /// the catalog lists them in. The sort is not stable, so without the rank
    /// this answered differently from run to run.
    func testConceptsReportedThroughTheSamePeriodAreRankedByPreference() throws {
        let namespace = try namespace([
            "RevenuesNetOfInterestExpense": [year(3_613_354_000)],
            "RevenueFromContractWithCustomerExcludingAssessedTax": [year(619_353_000)],
            "CostOfRevenue": [year(608_998_000)],
            "NoninterestExpense": [year(3_057_178_000)],
        ])

        for _ in 0..<50 {
            let period = try XCTUnwrap(CompanyFinancialsClient.makeSECIncome(namespace: namespace).first)
            XCTAssertEqual(period.revenue, 3_613_354_000)
        }
    }
}
