import XCTest
@testable import CatfolioIOS

final class Holding52WeekRangeTests: XCTestCase {
    func testRangeUsesLatest252SessionsAndConvertsProviderUnits() throws {
        let bars = (0..<253).map { index in
            MarketDailyBar(date: String(format: "%04d", index), close: index == 1 ? 90 : 100,
                high: index == 0 ? 900 : 120, low: index == 0 ? 1 : 80, volume: 0)
        }
        let range = try XCTUnwrap(Holding52WeekRange.make(bars: bars.reversed(), currency: "GBP", scale: 0.01))
        XCTAssertEqual(range.low, 0.8, accuracy: 0.0001)
        XCTAssertEqual(range.high, 1.2, accuracy: 0.0001)
        XCTAssertEqual(range.latestClose, 1)
        XCTAssertEqual(try XCTUnwrap(range.startPrice), 0.9, accuracy: 0.0001)
        XCTAssertEqual(range.currency, "GBP")
    }

    func testCostOutsideRangeExtendsScaleAndPricesRiseUpwards() throws {
        let positions = try XCTUnwrap(Holding52WeekPositions(low: 100, high: 200, current: 150, cost: 300))
        XCTAssertEqual(positions.cost, 0)
        XCTAssertEqual(positions.high, 0.5)
        XCTAssertEqual(positions.current, 0.75)
        XCTAssertEqual(positions.low, 1)
        let below = try XCTUnwrap(Holding52WeekPositions(low: 100, high: 200, current: 250, cost: 50))
        XCTAssertEqual(below.current, 0)
        XCTAssertEqual(below.cost, 1)
        XCTAssertEqual(below.high, 0.25)
        XCTAssertEqual(below.low, 0.75)
    }

    func testBlueSegmentUsesTheActualPeriodStartForGainsAndLosses() throws {
        let up = try XCTUnwrap(Holding52WeekPositions(low: 100, high: 200, current: 170, cost: 130, start: 120))
        XCTAssertEqual(up.high, 0)
        XCTAssertEqual(up.low, 1)
        XCTAssertEqual(up.start, 0.8)
        XCTAssertEqual(up.current, 0.3)
        XCTAssertEqual(up.cost, 0.7)
        let down = try XCTUnwrap(Holding52WeekPositions(low: 100, high: 200, current: 120, cost: 130, start: 170))
        XCTAssertEqual(down.start, 0.3)
        XCTAssertEqual(down.current, 0.8)
        let missingStart = try XCTUnwrap(Holding52WeekPositions(low: 100, high: 200, current: 170, cost: 130))
        XCTAssertNil(missingStart.start, "Do not substitute the low or high for a missing period start")
    }

    func testFlatAndMissingPricesNeverProduceInvalidGeometry() throws {
        let flat = try XCTUnwrap(Holding52WeekPositions(low: 100, high: 100, current: 100, cost: 100))
        XCTAssertEqual(flat.current, 0.5)
        XCTAssertEqual(flat.cost, 0.5)
        let missing = try XCTUnwrap(Holding52WeekPositions(low: 100, high: 200, current: .nan, cost: .infinity))
        XCTAssertNil(missing.current)
        XCTAssertNil(missing.cost)
        XCTAssertNil(Holding52WeekPositions(low: .nan, high: 200, current: 100, cost: 100))
        XCTAssertNil(Holding52WeekPositions(low: 200, high: 100, current: 100, cost: 100))
        XCTAssertNil(Holding52WeekRange.make(bars: [], currency: "USD", scale: 1))
        XCTAssertNil(Holding52WeekRange.make(bars: [.init(date: "2026-01-01", close: .nan,
            high: 200, low: 100, volume: 10)], currency: "USD", scale: 1))
    }

    func testCostAndQuoteUseTheSameCurrencyIncludingPence() throws {
        let range = Holding52WeekRange(low: 6_000, high: 10_000, latestClose: 8_000, currency: "GBX")
        let prices = Holding52WeekPrices(holding: holding(currency: "GBP", quote: 85, cost: 75), range: range,
            usdRate: { ["GBP": 1.25, "GBX": 0.0125][$0] })
        XCTAssertEqual(prices.current, 8_500)
        XCTAssertEqual(prices.cost, 7_500)
        XCTAssertEqual(prices.currency, "GBX")
        let unavailableFX = Holding52WeekPrices(holding: holding(currency: "GBP", quote: 85, cost: 75),
            range: range, usdRate: { _ in nil })
        XCTAssertEqual(unavailableFX.current, 8_000)
        XCTAssertNil(unavailableFX.cost)
    }

    func testExposureHasMarketPriceWithoutInventingACostOrRange() {
        let range = Holding52WeekRange(low: 100, high: 200, latestClose: 180, currency: "USD")
        let exposure = Holding52WeekPrices(holding: holding(currency: "USD", quote: 0, cost: 0, shares: 0), range: range)
        XCTAssertEqual(exposure.current, 180)
        XCTAssertNil(exposure.cost)
        let unavailable = Holding52WeekPrices(holding: holding(currency: "USD", quote: 173, cost: 150), range: nil)
        XCTAssertEqual(unavailable.current, 173)
        XCTAssertEqual(unavailable.cost, 150)
        XCTAssertNil(unavailable.positions)
        let residual = Holding52WeekPrices(holding: nil, range: nil)
        XCTAssertNil(residual.current)
        XCTAssertNil(residual.cost)
    }

    func testRankingIgnoresCostAndTheDisplayScale() {
        let range = Holding52WeekRange(low: 100, high: 200, latestClose: 150, currency: "USD")
        for cost in [10.0, 140, 10_000] {
            let prices = Holding52WeekPrices(holding: holding(currency: "USD", quote: 150, cost: cost), range: range)
            XCTAssertEqual(prices.rangePosition, 0.5)
        }
        XCTAssertEqual(Holding52WeekPrices(holding: holding(currency: "USD", quote: 250, cost: 80), range: range)
            .rangePosition, 1.5)
    }

    func testSortingLoadsOffscreenRowsWithBoundedConcurrencyAndToleratesFailure() async throws {
        let requests = try (0..<12).map { index in
            try XCTUnwrap(Holding52WeekRequest(item: .holding(
                holding(currency: "USD", quote: 100, cost: 80, ticker: "TEST\(index)"), performance: nil)))
        }
        let probe = RangeFetchProbe()
        let ranges = await Holding52WeekRange.load(requests) { try await probe.fetch($0) }
        let counts = await probe.counts()
        XCTAssertEqual(counts.completed, 12)
        XCTAssertEqual(counts.peak, 4)
        XCTAssertEqual(ranges.count, 11)
        XCTAssertNotNil(ranges["TEST11"])
        XCTAssertNil(ranges["TEST2"])
    }

    private func holding(currency: String, quote: Double, cost: Double, shares: Double = 10,
                         ticker: String = "TEST") -> Holding {
        Holding(ticker: ticker, logoSymbol: nil, displayName: "Test", sector: nil, source: nil,
            shares: shares, averageCost: cost, costCurrency: currency, quotePrice: quote,
            quoteCurrency: currency, todayChangePercent: nil, marketValue: 1_000, weight: 1,
            unrealized: 0, unrealizedPercent: 0, fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }
}

private actor RangeFetchProbe {
    private var active = 0
    private var peak = 0
    private var completed = 0

    func fetch(_ request: Holding52WeekRequest) async throws -> Holding52WeekRange {
        active += 1
        peak = max(peak, active)
        defer { active -= 1; completed += 1 }
        try await Task.sleep(for: .milliseconds(10))
        if request.ticker == "TEST2" { throw NSError(domain: "Test", code: 1) }
        return Holding52WeekRange(low: 80, high: 120, latestClose: 100, currency: request.currency)
    }

    func counts() -> (peak: Int, completed: Int) { (peak, completed) }
}
