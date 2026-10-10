import SwiftUI
import XCTest
@testable import CatfolioIOS

final class ReturnsEntrySummaryTests: XCTestCase {
    func testAllTimeAndCurrentYearUseDifferentInvestmentIntervals() throws {
        let now = try XCTUnwrap(DayDateCodec.date(from: "2026-10-10"))
        let allTime = try XCTUnwrap(ReturnsEntrySummary.allTimePercent(fixture))
        let thisYear = try XCTUnwrap(ReturnsEntrySummary.yearToDatePercent(fixture, now: now))
        XCTAssertEqual(allTime, (pow(1.32, 365.25 / 282) - 1) * 100, accuracy: 0.0001)
        XCTAssertNotEqual(allTime, thisYear)
        XCTAssertNil(ReturnsEntrySummary.allTimePercent(nil))
    }

    func testEntryAnnualizesCurrentYearInvestmentReturn() throws {
        let now = try XCTUnwrap(DayDateCodec.date(from: "2026-10-10"))
        let result = try XCTUnwrap(ReturnsEntrySummary.yearToDatePercent(fixture, now: now))
        XCTAssertEqual(result, (pow(1.2, 365.25 / 280) - 1) * 100, accuracy: 0.0001)
    }

    func testPreviousYearAndUnavailableHistoryDoNotInventCurrentReturn() throws {
        let nextYear = try XCTUnwrap(DayDateCodec.date(from: "2027-01-05"))
        XCTAssertNil(ReturnsEntrySummary.yearToDatePercent(fixture, now: nextYear))
        XCTAssertNil(ReturnsEntrySummary.yearToDatePercent(nil, now: nextYear))
    }

    private var fixture: ComparisonResponse {
        ComparisonResponse(available: true, dates: [], portfolio: [], benchmarks: [:],
            cashFlowPortfolioReturns: nil, cashFlowBenchmarkReturns: nil,
            mwrPortfolio: nil, mwrBenchmarks: nil,
            twrDates: ["2025-12-31", "2026-01-02", "2026-10-09"],
            twrPortfolio: [1, 1.1, 1.32], twrBenchmarks: [:], warnings: nil,
            summary: .init(portfolioReturn: 0.32, benchmarkReturn: nil, benchmarkReturns: [:]),
            mwrLedger: .init(dates: ["2025-12-31", "2026-01-02", "2026-10-09"],
                cashFlows: [100, 0, 0], values: [100, 110, 132], benchmarkValues: [:]))
    }
}
