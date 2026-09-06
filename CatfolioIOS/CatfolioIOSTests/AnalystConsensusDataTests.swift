import XCTest
@testable import CatfolioIOS

/// Consensus ratings and price targets come from a third party and are drawn
/// as a distribution bar, so malformed input must be rejected rather than
/// rendered as a confident-looking chart.
final class AnalystConsensusDataTests: XCTestCase {

    func testAnAllZeroDistributionIsStillValid() {
        XCTAssertEqual(
            AnalystConsensusData.ratingCounts(
                ["strongSell": 0, "sell": 0, "hold": 0, "buy": 0, "strongBuy": 0]),
            [0, 0, 0, 0, 0])
    }

    func testAPartialDistributionIsRejected() {
        XCTAssertNil(AnalystConsensusData.ratingCounts(["buy": 11, "hold": 3]))
    }

    func testANegativeCountIsRejected() {
        XCTAssertNil(AnalystConsensusData.ratingCounts(
            ["strongSell": -1, "sell": 0, "hold": 0, "buy": 0, "strongBuy": 0]))
    }

    func testTargetsMustBeOrderedLowToHigh() {
        XCTAssertTrue(AnalystConsensusData.validTargets(low: 96, mean: 131.86, high: 165))
        XCTAssertFalse(AnalystConsensusData.validTargets(low: 165, mean: 131.86, high: 96))
    }

    func testNonFiniteOrMissingTargetsAreRejected() {
        XCTAssertFalse(AnalystConsensusData.validTargets(low: 96, mean: .nan, high: 165))
        XCTAssertFalse(AnalystConsensusData.validTargets(low: nil, mean: 131.86, high: 165))
    }

    /// A zero-width range must not divide by zero.
    func testAnEqualLowAndHighSitsInTheMiddle() {
        XCTAssertEqual(AnalystConsensusData.position(100, low: 100, high: 100), 0.5)
    }

    func testAPriceOutsideTheRangeClampsToTheEdge() {
        XCTAssertEqual(AnalystConsensusData.position(200, low: 96, high: 200), 1)
        XCTAssertEqual(AnalystConsensusData.position(80, low: 80, high: 165), 0)
    }
}
