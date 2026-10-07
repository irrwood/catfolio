import XCTest
@testable import CatfolioIOS

/// Reading an options chain into open interest by strike: each contract
/// counts once, unusable rows are dropped, and the chart's lookup stays on
/// the strikes that exist.
final class OIDistributionTests: XCTestCase {
    private func contract(_ id: String, _ strike: Double, _ side: String, _ oi: Double) -> OIContract {
        OIContract(details: .init(ticker: id, contract_type: side, expiration_date: "2026-10-16",
                                  strike_price: strike, shares_per_contract: 100),
                   open_interest: oi)
    }

    func testEachContractCountsOnceAndStrikesAreGrouped() {
        let repeated = contract("a", 90, "call", 20)
        let result = OIDistribution(contracts: [repeated, repeated, contract("b", 100, "call", 20),
                                                contract("c", 90, "put", 60)])
        XCTAssertEqual(result.rows.map(\.strike), [90, 100])
        XCTAssertEqual(result.rows[0].call, 20, "A contract listed twice is not doubled")
        XCTAssertEqual(result.rows[0].put, 60)
        XCTAssertEqual(result.concentration, 90...100)
    }

    func testEmptyZeroAndInvalidChainsHaveNoWallsOrConcentration() {
        let empty = OIDistribution(contracts: [])
        XCTAssertTrue(empty.callWalls.isEmpty && empty.putWalls.isEmpty)
        XCTAssertNil(empty.concentration)
        let zero = OIDistribution(contracts: [contract("z", 100, "call", 0)])
        XCTAssertTrue(zero.callWalls.isEmpty)
        XCTAssertNil(zero.concentration)
        let invalid = OIDistribution(contracts: [contract("n", 100, "call", .nan), contract("p", -1, "put", 2)])
        XCTAssertTrue(invalid.rows.isEmpty)
        let single = OIDistribution(contracts: [contract("s", 100, "put", 20)])
        XCTAssertEqual(single.concentration, 100...100)
        XCTAssertTrue(single.callWalls.isEmpty)
    }

    func testThePlotLooksUpTheNearestRealStrike() {
        let result = OIDistribution(contracts: [contract("a", 90, "call", 20), contract("b", 100, "call", 20),
                                                contract("c", 90, "put", 60)])
        let plot = OIPlotGeometry(result, markers: [91, 120, .nan])
        XCTAssertEqual(plot.maximum, 60)
        XCTAssertEqual(plot.nearest(to: -100)?.strike, 90)
        XCTAssertEqual(plot.nearest(to: 1000)?.strike, 100)
        XCTAssertEqual(plot.nearest(to: 96)?.call, 20)
        XCTAssertNil(plot.nearest(to: .nan))
    }
}
