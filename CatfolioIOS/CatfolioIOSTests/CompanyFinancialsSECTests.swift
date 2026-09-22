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
