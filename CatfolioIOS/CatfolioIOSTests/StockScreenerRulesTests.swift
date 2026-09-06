import XCTest
@testable import CatfolioIOS

/// Screen rules are parsed from model-generated JSON, so anything the app
/// cannot actually evaluate must be rejected outright rather than silently
/// ignored — a filter that quietly does nothing is worse than an error.
final class StockScreenerRulesTests: XCTestCase {

    private let validJSON = #"{"sector":"Technology","industry":"","conditions":[{"metric":"revenue","comparison":"atLeast","value":10}],"unsupported":""}"#

    // MARK: - Thresholds

    func testAtLeastIsInclusive() {
        let condition = ScreenCondition(metric: .revenue, comparison: .atLeast, value: 10)

        XCTAssertTrue(condition.accepts(10))
        XCTAssertFalse(condition.accepts(9.99))
    }

    func testMissingAndNonFiniteValuesAreRejected() {
        let condition = ScreenCondition(metric: .revenue, comparison: .atLeast, value: 10)

        XCTAssertFalse(condition.accepts(nil))
        XCTAssertFalse(condition.accepts(.nan))
        XCTAssertFalse(condition.accepts(.infinity))
    }

    func testNegativeThresholdsWorkForDecline() {
        let decline = ScreenCondition(metric: .growth, comparison: .atMost, value: -5)

        XCTAssertTrue(decline.accepts(-6))
        XCTAssertFalse(decline.accepts(6))
    }

    /// A non-positive P/E is not "cheap", it is meaningless.
    func testNonPositivePERatioNeverPassesAnAtMostFilter() {
        let pe = ScreenCondition(metric: .pe, comparison: .atMost, value: 20)

        XCTAssertFalse(pe.accepts(-10))
        XCTAssertFalse(pe.accepts(0))
        XCTAssertTrue(pe.accepts(15))
    }

    // MARK: - Parsing

    func testValidRulesParse() throws {
        XCTAssertEqual(try ScreenRules.parse(validJSON).conditions.first?.value, 10)
    }

    func testFencedJSONParsesIdentically() throws {
        XCTAssertEqual(
            try ScreenRules.parse("```json\n" + validJSON + "\n```"),
            try ScreenRules.parse(validJSON))
    }

    // MARK: - Refusals

    /// A criterion the screener cannot evaluate must fail loudly, or the user
    /// believes a filter is applied that never runs.
    func testUnsupportedCriteriaAreRejected() {
        assertRejected(validJSON.replacingOccurrences(
            of: #""unsupported":"""#, with: #""unsupported":"印度股票""#))
    }

    func testInventedMetricIsRejected() {
        assertRejected(validJSON.replacingOccurrences(of: #""revenue""#, with: #""inventedMetric""#))
    }

    func testInventedSectorIsRejected() {
        assertRejected(validJSON.replacingOccurrences(of: #""Technology""#, with: #""inventedSector""#))
    }

    func testNegativeValueForAPositiveOnlyMetricIsRejected() {
        assertRejected(validJSON.replacingOccurrences(of: #""value":10"#, with: #""value":-10"#))
    }

    func testDuplicateMetricsAreRejected() {
        let condition = ScreenCondition(metric: .revenue, comparison: .atLeast, value: 10)

        XCTAssertThrowsError(try ScreenRules(conditions: [condition, condition]).validate())
    }

    func testEmptyRulesAreRejected() {
        XCTAssertThrowsError(try ScreenRules().validate())
    }

    private func assertRejected(
        _ json: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try ScreenRules.parse(json), file: file, line: line)
    }
}
