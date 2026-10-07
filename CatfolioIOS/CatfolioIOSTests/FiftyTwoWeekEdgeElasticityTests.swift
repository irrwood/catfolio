import CoreGraphics
import XCTest
@testable import CatfolioIOS

/// Dragging past either end of the 52-week range stretches it a little and
/// no further, the same on both sides, and only near the end being pulled.
final class FiftyTwoWeekEdgeElasticityTests: XCTestCase {
    private typealias Band = FiftyTwoWeekEdgeElasticity

    func testInsideTheRangeThereIsNoPull() {
        for x in stride(from: CGFloat(0), through: 300, by: 5) {
            XCTAssertEqual(Band.pull(location: x, lower: 0, upper: 300), 0)
        }
    }

    func testPullIsSymmetricResistedAndBounded() {
        var previous: CGFloat = 0
        for distance in stride(from: CGFloat(1), through: 1000, by: 1) {
            let left = Band.pull(location: -distance, lower: 0, upper: 300)
            let right = Band.pull(location: 300 + distance, lower: 0, upper: 300)
            XCTAssertEqual(left + right, 0, accuracy: 0.000_001)
            XCTAssertGreaterThan(right, previous)
            XCTAssertLessThan(right, Band.limit)
            XCTAssertLessThan(right, distance, "Always less than the finger moved")
            previous = right
        }
    }

    func testInvalidGeometryDoesNotPull() {
        XCTAssertEqual(Band.pull(location: .nan, lower: 0, upper: 300), 0)
        XCTAssertEqual(Band.pull(location: -20, lower: 0, upper: 0), 0)
    }

    func testOnlyTheTicksNearThePulledEndMove() {
        XCTAssertEqual(Band.influence(index: 0, count: 45, pull: -10), 1)
        XCTAssertEqual(Band.influence(index: 44, count: 45, pull: 10), 1)
        XCTAssertEqual(Band.influence(index: 22, count: 45, pull: 10), 0)
        XCTAssertEqual(Band.influence(index: 0, count: 45, pull: 0), 0)
        for index in 0..<45 {
            XCTAssertEqual(Band.influence(index: index, count: 45, pull: -10),
                           Band.influence(index: 44 - index, count: 45, pull: 10))
        }
    }
}
