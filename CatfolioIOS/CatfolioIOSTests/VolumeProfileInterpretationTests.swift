import XCTest
@testable import CatfolioIOS

/// The volume profile's reading: where the price and the cost sit against
/// the value area, prices in other units, and the shapes the chart draws.
final class VolumeProfileInterpretationTests: XCTestCase {
    private typealias Rules = VolumeProfileInterpretation

    private func result(_ quote: Double, _ low: Double = 90, _ high: Double = 110,
                        _ poc: Double? = 100, cost: Double? = nil) -> Rules.Result {
        Rules.result(sessions: 160, quote: quote, valueAreaLow: low, valueAreaHigh: high,
                     pointOfControl: poc, cost: cost)
    }

    func testPriceAndCostPositions() {
        XCTAssertEqual(result(89).pricePosition, .below)
        XCTAssertEqual(result(111).pricePosition, .above)
        XCTAssertEqual(result(90).pricePosition, .inside, "Lower bound is inclusive")
        XCTAssertEqual(result(110).pricePosition, .inside, "Upper bound is inclusive")
        XCTAssertTrue(result(101).isNearPointOfControl)
        XCTAssertFalse(result(103).isNearPointOfControl)

        XCTAssertEqual(result(100, cost: 101).costPosition, .aligned, "The one-percent parity rule is inclusive")
        let profit = result(100, cost: 84.6)
        XCTAssertEqual(profit.costPosition, .belowCurrent)
        XCTAssertEqual(profit.costDifferencePercent ?? 0, 15.4, accuracy: 0.0001)
        XCTAssertTrue(profit.text.contains("15.4%"))
        let loss = result(100, cost: 108.2)
        XCTAssertEqual(loss.costPosition, .aboveCurrent)
        XCTAssertEqual(loss.costDifferencePercent ?? 0, 8.2, accuracy: 0.0001)

        XCTAssertEqual(result(.nan).pricePosition, .unavailable)
        XCTAssertEqual(result(100, 100, 100).pricePosition, .unavailable)
        XCTAssertEqual(result(100, cost: nil).costPosition, .unavailable)
        XCTAssertNil(result(100, cost: nil).costDifferencePercent)
    }

    func testPricesInOtherUnitsConvertOnlyWhenTheUnitIsKnown() {
        let rates: [String: Double] = ["GBP": 1.346, "GBX": 0.01346, "USD": 1]
        XCTAssertEqual(Rules.convertedPrice(123, from: "gbx", to: "GBP", usdRate: { rates[$0] }) ?? 0, 1.23, accuracy: 0.0001)
        XCTAssertNil(Rules.convertedPrice(100, from: nil, to: "USD", usdRate: { rates[$0] }))
        XCTAssertNil(Rules.convertedPrice(100, from: "UNKNOWN", to: "USD", usdRate: { rates[$0] }))
        XCTAssertNil(Rules.convertedPrice(0, from: "USD", to: "USD", usdRate: { rates[$0] }))
    }

    func testTailsComeOnlyFromRealVolumeOutsideTheValueArea() {
        func tails(_ bins: [(priceLow: Double, priceHigh: Double, volume: Double)]) -> Rules.TailPresence {
            Rules.tailPresence(bins: bins, valueAreaLow: 90, valueAreaHigh: 110)
        }
        XCTAssertEqual(tails([(110, 115, 3)]), .init(hasUpper: true, hasLower: false))
        XCTAssertEqual(tails([(85, 90, 3)]), .init(hasUpper: false, hasLower: true))
        XCTAssertEqual(tails([(85, 90, 3), (90, 110, 8), (110, 115, 2)]), .init(hasUpper: true, hasLower: true))
        XCTAssertEqual(tails([(90, 100, 3), (100, 110, 8)]), .init(hasUpper: false, hasLower: false))
        XCTAssertEqual(tails([(85, 90, 0), (90, 110, 8), (110, 115, 0)]), .init(hasUpper: false, hasLower: false))
        XCTAssertEqual(tails([(90, 110, 8)]), .init(hasUpper: false, hasLower: false))
        XCTAssertTrue(tails([(109.999, 110.001, 0.01)]).hasUpper, "A real narrow tail stays")
    }

    func testDrawnSlicesBridgeGapsWithoutInventingVolume() {
        XCTAssertEqual(Rules.curveVerticalHandle(distance: 0.3), 0.1, accuracy: 0.000_001)
        XCTAssertEqual(Rules.curveVerticalHandle(distance: -1), 0)

        XCTAssertEqual(Rules.continuousSlices(bins: [(90, 110, 8)], lowerBound: 90, upperBound: 110),
                       [.init(priceLow: 90, priceHigh: 110, volume: 8)])
        let connected = Rules.continuousSlices(bins: [(90, 95, 5), (95, 100, 0), (100, 105, 4), (107, 110, 3)],
                                               lowerBound: 90, upperBound: 110)
        XCTAssertEqual(connected.map(\.volume), [5, 0, 4, 0, 3], "A missing interval gets one zero-volume bridge")
        XCTAssertEqual(connected[3], .init(priceLow: 105, priceHigh: 107, volume: 0))
        XCTAssertEqual(Rules.continuousSlices(bins: [(90, 110, 8)], lowerBound: 80, upperBound: 120), [
            .init(priceLow: 80, priceHigh: 90, volume: 0),
            .init(priceLow: 90, priceHigh: 110, volume: 8),
            .init(priceLow: 110, priceHigh: 120, volume: 0),
        ])
        let crossedMain = Rules.continuousSlices(bins: [(88, 92, 5)], lowerBound: 90, upperBound: 110)
        let crossedTail = Rules.continuousSlices(bins: [(88, 92, 5)], lowerBound: 88, upperBound: 90)
        XCTAssertEqual(crossedMain.first.map { [$0.priceLow, $0.priceHigh] }, [90, 92])
        XCTAssertEqual(crossedTail.first.map { [$0.priceLow, $0.priceHigh] }, [88, 90])

        XCTAssertEqual(Rules.constrainedCornerRadius(height: 2, topWidth: 100, bottomWidth: 100), 1)
        XCTAssertEqual(Rules.constrainedCornerRadius(height: 20, topWidth: 0.5, bottomWidth: 100), 0.25)
    }
}
