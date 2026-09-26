import XCTest
@testable import CatfolioIOS

final class ReturnsSourceLayersTests: XCTestCase {
    private func band(_ colour: Int?, _ values: [Double]) -> ReturnsSourcePreview.Band {
        ReturnsSourcePreview.Band(colour: colour, values: values)
    }

    func testKeepsTheThreeLargestHoldingsStackedLargestFirst() {
        let preview = ReturnsSourcePreview(headline: 0, losingCount: 0, bands: [
            band(0, [1, 1]),
            band(1, [5, 5]),
            band(nil, [50, 50]),
            band(2, [3, 3]),
            band(3, [2, 5]),
        ])

        XCTAssertEqual(preview.sourceLayers(), [[5, 5], [7, 10], [10, 13]])
    }

    func testSkipsHoldingsThatNeverContributed() {
        let preview = ReturnsSourcePreview(headline: 0, losingCount: 0, bands: [
            band(0, [0, 0]),
            band(1, [2, 1]),
        ])

        XCTAssertEqual(preview.sourceLayers(), [[2, 1]])
    }

    func testResamplesToTheRequestedCount() {
        let values = (0..<48).map(Double.init)
        let sampled = ReturnsSourcePreview.sampled(values, count: 14)
        XCTAssertEqual(sampled.count, 14)
        XCTAssertEqual(sampled.first, 0)
        XCTAssertEqual(sampled.last, 47)
    }
}
