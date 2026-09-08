import XCTest
@testable import CatfolioIOS

/// The merged "其他" block shows a return over what is priced.
///
/// It used to require every constituent: `percent` was gated on
/// `knownCount == totalCount`. That block collects the smallest holdings —
/// exactly the ones most often missing a quote — so one unpriced name out of
/// thirty-odd blanked the whole block while its detail sheet, which fills gaps
/// from a later fetch, showed a figure. Same data, two answers.
final class HeatmapRemainderReturnTests: XCTestCase {

    /// A leaf, not a remainder: `leafItems` recurses through remainder content,
    /// so a remainder-shaped leaf flattens to nothing.
    private func leaf(_ id: String, value: Double, change: Double?) -> HoldingsHeatmapTile.Model {
        let row = ETFLookThroughRow(
            ticker: id, logoSymbol: nil, name: id, directUSD: 0,
            fromETFUSD: value, totalUSD: value, etfWeightPercent: 1, sector: "Technology"
        )
        return HoldingsHeatmapTile.Model(
            id: id, content: .exposure(row, directHolding: nil), marketValue: value,
            portfolioFraction: 0.01, changePercent: change,
            performanceTitle: "今日", performancePeriod: .today
        )
    }

    func testReturnIsShownWhenOnlySomeConstituentsArePriced() throws {
        let model = HoldingsHeatmapTile.Model.remainder(id: "r", items: [
            leaf("A", value: 1_100, change: 10),
            leaf("B", value: 500, change: nil),      // no quote
        ])
        let summary = model.performanceSummary()

        XCTAssertFalse(summary.isComplete, "one of two is unpriced")
        XCTAssertEqual(summary.knownCount, 1)
        XCTAssertEqual(summary.totalCount, 2)
        let percent = try XCTUnwrap(summary.percent, "a partly-priced block must still report a return")
        XCTAssertEqual(percent, 10, accuracy: 0.001, "the return covers the priced part only")
    }

    func testTheReturnMatchesTheOneCompleteCoverageWouldGive() throws {
        let priced = HoldingsHeatmapTile.Model.remainder(id: "r", items: [
            leaf("A", value: 1_100, change: 10),
            leaf("B", value: 2_200, change: 10),
        ])
        let partly = HoldingsHeatmapTile.Model.remainder(id: "r", items: [
            leaf("A", value: 1_100, change: 10),
            leaf("B", value: 2_200, change: 10),
            leaf("C", value: 999, change: nil),
        ])
        XCTAssertEqual(try XCTUnwrap(priced.performanceSummary().percent),
                       try XCTUnwrap(partly.performanceSummary().percent),
                       accuracy: 0.001,
                       "an unpriced name must not drag the figure toward zero")
    }

    func testNothingPricedStillReportsNoReturn() {
        let model = HoldingsHeatmapTile.Model.remainder(id: "r", items: [
            leaf("A", value: 1_000, change: nil),
            leaf("B", value: 2_000, change: nil),
        ])
        let summary = model.performanceSummary()

        XCTAssertEqual(summary.knownCount, 0)
        XCTAssertNil(summary.percent, "with no prices there is nothing to report")
    }

    /// `isComplete` still distinguishes the two, which is what the detail
    /// sheet's "已覆盖 n/m 项" line reads.
    func testCoverageIsStillReported() {
        let model = HoldingsHeatmapTile.Model.remainder(id: "r", items: [
            leaf("A", value: 1_000, change: 5),
            leaf("B", value: 1_000, change: nil),
        ])
        XCTAssertFalse(model.performanceSummary().isComplete)

        let full = HoldingsHeatmapTile.Model.remainder(id: "r", items: [
            leaf("A", value: 1_000, change: 5),
            leaf("B", value: 1_000, change: 5),
        ])
        XCTAssertTrue(full.performanceSummary().isComplete)
    }
}
