import XCTest
@testable import CatfolioIOS

final class DividendIncomeTests: XCTestCase {
    private func payment(_ date: String, _ amount: Double) -> DividendForecast.Payment {
        .init(exDate: date, perShare: amount, currency: "USD")
    }

    func testIncomeUsesThePastYearAndRepeatsTheLatestPayment() throws {
        let today = try XCTUnwrap(DayDateCodec.date(from: "2026-10-03"))
        let income = try XCTUnwrap(DividendIncome(payments: [
            payment("2025-08-11", 0.26), payment("2025-11-10", 0.26), payment("2026-02-09", 0.26),
            payment("2026-05-11", 0.27), payment("2026-08-10", 0.27),
        ], today: today))
        XCTAssertEqual(income.nextPerShare, 0.27, accuracy: 1e-9)
        XCTAssertEqual(income.trailingPerShare, 1.06, accuracy: 1e-9)
        XCTAssertEqual(income.forwardPerShare, 1.08, accuracy: 1e-9)
    }

    func testNoRecentPaymentMeansNoIncome() throws {
        let today = try XCTUnwrap(DayDateCodec.date(from: "2026-10-03"))
        XCTAssertNil(DividendIncome(payments: [payment("2024-05-01", 0.5)], today: today))
    }

    func testStepsIncludeTheHoldingAndFindTheNearest() {
        let steps = DividendIncome.shareSteps(including: 12.5)
        XCTAssertTrue(steps.contains(12.5))
        XCTAssertEqual(steps.first, 0)
        XCTAssertEqual(steps.last, 100_000)
        XCTAssertEqual(steps[DividendIncome.nearestStep(to: 1_234, in: steps)], 1_200)
    }
}
