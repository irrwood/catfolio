import XCTest
@testable import CatfolioIOS

/// The put and call walls: support under the price and resistance over it.
final class OptionsWallTests: XCTestCase {
    private func contract(_ type: String, _ strike: Double, _ oi: Double, id: String? = nil) -> OIContract {
        OIContract(details: .init(ticker: id ?? "\(type)\(strike)", contract_type: type,
                                  expiration_date: "2026-10-16", strike_price: strike,
                                  shares_per_contract: 100),
                   open_interest: oi)
    }

    /// META on 2026-09-16: one old block of 30,521 puts sat at 140 with the
    /// shares at 670, and it outranked every strike anywhere near the price.
    private var metaPuts: [OIContract] {
        [contract("put", 140, 30_521), contract("put", 550, 20_047), contract("put", 600, 18_725),
         contract("put", 500, 16_384), contract("put", 650, 12_441)]
    }

    func testAFarAwayBlockIsNotAPutWall() throws {
        let distribution = OIDistribution(contracts: metaPuts, currentPrice: 670.24)
        XCTAssertEqual(try XCTUnwrap(distribution.putWalls.first).strike, 550)
    }

    /// Without a quote there is no side to face, so the heaviest strike stands.
    func testWithoutAPriceTheHeaviestStrikeStands() throws {
        let distribution = OIDistribution(contracts: metaPuts, currentPrice: nil)
        XCTAssertEqual(try XCTUnwrap(distribution.putWalls.first).strike, 140)
    }

    func testThePutWallSitsAtOrBelowThePrice() throws {
        let contracts = [contract("put", 110, 900), contract("put", 95, 400), contract("put", 90, 300)]
        let distribution = OIDistribution(contracts: contracts, currentPrice: 100)
        XCTAssertEqual(try XCTUnwrap(distribution.putWalls.first).strike, 95)
    }

    func testTheCallWallSitsAtOrAboveThePrice() throws {
        let contracts = [contract("call", 90, 900), contract("call", 105, 400), contract("call", 110, 300)]
        let distribution = OIDistribution(contracts: contracts, currentPrice: 100)
        XCTAssertEqual(try XCTUnwrap(distribution.callWalls.first).strike, 105)
    }

    /// Nothing near the money is still worth naming; the band widens rather
    /// than leaving the reader with no wall at all.
    func testAChainWithNothingNearbyStillReportsAWall() throws {
        let contracts = [contract("put", 40, 700), contract("put", 30, 200)]
        let distribution = OIDistribution(contracts: contracts, currentPrice: 100)
        XCTAssertEqual(try XCTUnwrap(distribution.putWalls.first).strike, 40)
    }

    func testTiedStrikesAreAllWalls() {
        let contracts = [contract("put", 95, 500, id: "a"), contract("put", 90, 500, id: "b"),
                         contract("put", 85, 100, id: "c")]
        let distribution = OIDistribution(contracts: contracts, currentPrice: 100)
        XCTAssertEqual(Set(distribution.putWalls.map(\.strike)), [95, 90])
    }
}

/// Zooming in: the band around the walls and the price, not a cut of the
/// cumulative open interest, whose tails are heavy enough to keep everything.
final class OptionsZoomTests: XCTestCase {
    /// META's chain on 2026-09-16: strikes from 5 to 1480, the shares at 670,
    /// and the walls at 550 and 700.
    private var chain: [OIContract] {
        var contracts: [OIContract] = []
        for strike in stride(from: 5.0, through: 1480.0, by: 5.0) {
            let distance = abs(strike - 670)
            let weight = max(1, 2_000 - distance * 2)
            contracts.append(OIContract(details: .init(ticker: "p\(strike)", contract_type: "put",
                expiration_date: "2026-10-16", strike_price: strike, shares_per_contract: 100),
                open_interest: strike == 550 ? 20_047 : weight))
            contracts.append(OIContract(details: .init(ticker: "c\(strike)", contract_type: "call",
                expiration_date: "2026-10-16", strike_price: strike, shares_per_contract: 100),
                open_interest: strike == 700 ? 21_000 : weight))
        }
        // The old block far below the price, which is not a wall.
        contracts.append(OIContract(details: .init(ticker: "pFar", contract_type: "put",
            expiration_date: "2026-10-16", strike_price: 140, shares_per_contract: 100),
            open_interest: 30_521))
        return contracts
    }

    func testZoomInFramesTheWallsAndThePrice() {
        let distribution = OIDistribution(contracts: chain, currentPrice: 670.24)
        let zoomed = OIPlotGeometry(distribution, range: .main, currentPrice: 670.24)
        let all = OIPlotGeometry(distribution, range: .all, currentPrice: 670.24)
        XCTAssertTrue(zoomed.domain.contains(550), "the put wall stays in view")
        XCTAssertTrue(zoomed.domain.contains(700), "the call wall stays in view")
        XCTAssertTrue(zoomed.domain.contains(670.24), "so does the price")
        let zoomedWidth = zoomed.domain.upperBound - zoomed.domain.lowerBound
        let allWidth = all.domain.upperBound - all.domain.lowerBound
        XCTAssertLessThan(zoomedWidth, allWidth * 0.25, "zooming in has to actually zoom")
        XCTAssertFalse(zoomed.domain.contains(140), "the far block is left out of the zoom")
    }

    func testZoomInKeepsRoomAroundASingleStrike() {
        let contracts = [OIContract(details: .init(ticker: "p100", contract_type: "put",
            expiration_date: "2026-10-16", strike_price: 100, shares_per_contract: 100), open_interest: 10)]
        let distribution = OIDistribution(contracts: contracts, currentPrice: 100)
        let zoomed = OIPlotGeometry(distribution, range: .main, currentPrice: 100)
        XCTAssertTrue(zoomed.domain.contains(100))
        XCTAssertGreaterThan(zoomed.domain.upperBound - zoomed.domain.lowerBound, 0)
    }
}
