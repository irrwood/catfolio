import XCTest
@testable import CatfolioIOS

final class SecurityPriceAxisTicksTests: XCTestCase {
    private func labels(_ domain: ClosedRange<Double>) -> [String] {
        let axis = SecurityPricePlotSeriesCache.axisTicks(for: domain)
        return axis.ticks.map { $0.formatted(.number.precision(.fractionLength(axis.decimals))) }
    }

    func testWideRangeGivesUpToFourRoundLabels() {
        let found = labels(158...236)
        XCTAssertLessThanOrEqual(found.count, 4)
        XCTAssertGreaterThanOrEqual(found.count, 2)
        XCTAssertEqual(Set(found).count, found.count)
    }

    /// The case that read "23, 23, 23, 22".
    func testNarrowRangeNeverRepeatsALabel() {
        let found = labels(22.2...23.3)
        XCTAssertEqual(Set(found).count, found.count)
        XCTAssertEqual(found, ["23"])
    }

    func testRangeWithNoWholeNumberFallsBackToDecimals() {
        let found = labels(22.31...22.78)
        XCTAssertFalse(found.isEmpty)
        XCTAssertEqual(Set(found).count, found.count)
        XCTAssertTrue(found.allSatisfy { $0.contains(".") })
    }

    func testCheapStockUsesDecimals() {
        let found = labels(3.1...3.9)
        XCTAssertLessThanOrEqual(found.count, 4)
        XCTAssertTrue(found.allSatisfy { $0.contains(".") })
    }
}
