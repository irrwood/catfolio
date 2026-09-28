import XCTest
@testable import CatfolioIOS

final class DCAStrategyPresetTests: XCTestCase {
    func testPresetsAreValidAndFixedClearsConditions() {
        XCTAssertNil(DCAStrategyPreset.fixed.plan)
        for preset in DCAStrategyPreset.allCases {
            XCTAssertNil(preset.plan?.validationError)
            XCTAssertTrue(preset.matches(preset.plan))
        }
    }
    func testTieredRulesUseLargestMatchingAllocationWithoutStacking() {
        let plan = DCAStrategyPreset.tieredDip.plan!
        for (last, expected) in [(100.0, 1.0), (89, 1.5), (79, 2.0), (50, 2.0)] {
            let points = Array(repeating: PolicyPricePoint(day: "2024-01-01", close: 100), count: 251)
                + [.init(day: "2024-01-02", close: last)]
            XCTAssertEqual(plan.decision(priorPrices: points[...])?.multiplier ?? 1, expected)
        }
    }
    func testModestDipAndInsufficientHistory() {
        let plan = DCAStrategyPreset.modestDip.plan!
        let short = [PolicyPricePoint(day: "2024-01-01", close: 80)]
        XCTAssertEqual(plan.decision(priorPrices: short[...])?.multiplier, 0)
        let full = Array(repeating: PolicyPricePoint(day: "2024-01-01", close: 100), count: 251) + short
        XCTAssertEqual(plan.decision(priorPrices: full[...])?.multiplier, 1.5)
    }
}
