import XCTest
@testable import CatfolioIOS

/// The Swift engine against Core's Python `VolatilityRegimeEngine` v1.1.
/// Expected values were produced by running the Python engine on the same
/// synthetic series these tests build, so a drift in either shows up here.
final class IndustrySentimentEngineTests: XCTestCase {
    private func weekdays(_ count: Int) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var day = calendar.date(from: DateComponents(year: 2025, month: 1, day: 2))!
        var result: [String] = []
        while result.count < count {
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1 && weekday != 7 { result.append(IndustrySentimentSnapshot.dateFormatter.string(from: day)) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    /// The same construction as the Python reference: a sine-and-trend
    /// volatility series with a jump on the last day, and SMH moving up or
    /// down on that day.
    private func inputs(count: Int, shift: Double, lastDayUp: Bool)
        -> ([IndustrySentimentEngine.VolatilityDay], [IndustrySentimentEngine.PriceDay], String) {
        let days = weekdays(count)
        let volatility = days.enumerated().map { index, date in
            IndustrySentimentEngine.VolatilityDay(
                date: date,
                close: 30 + 6 * sin(Double(index) / 9) + 0.02 * Double(index) + (index == count - 1 ? shift : 0))
        }
        var prices: [IndustrySentimentEngine.PriceDay] = []
        for (index, date) in days.enumerated() {
            var close = 200 + 10 * sin(Double(index) / 13) + 0.1 * Double(index)
            if index == count - 1 { close = prices[prices.count - 1].close * (lastDayUp ? 1.01 : 0.98) }
            prices.append(.init(date: date, open: close, high: close + 1, low: close - 1, close: close,
                                volume: 1_000_000 + Double(index)))
        }
        return (volatility, prices, days[days.count - 1])
    }

    private func snapshot(count: Int, shift: Double, lastDayUp: Bool) throws -> IndustrySentimentSnapshot {
        let (volatility, prices, last) = inputs(count: count, shift: shift, lastDayUp: lastDayUp)
        let object = try IndustrySentimentEngine.evaluate(volatility: volatility, prices: prices, asOf: last)
        return try IndustrySentimentSnapshot.decode(JSONSerialization.data(withJSONObject: object))
    }

    func testAFullYearMatchesCoreWhenPricesRiseWithVolatility() throws {
        let value = try snapshot(count: 260, shift: 3, lastDayUp: true)
        XCTAssertEqual(value.asOf, "2025-12-31")
        XCTAssertEqual(value.score, 46)
        XCTAssertEqual(value.regime, "Hedging")
        XCTAssertEqual(value.sampleCount, 252)
        XCTAssertEqual(value.close, 35.28533004710789, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value.ma20), 37.67952502964838, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value.z20), -0.9148625471805051, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value.percentile), 62.1031746031746, accuracy: 1e-9)
        XCTAssertEqual(value.availablePercentile, 62.1031746031746, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value.changePct), 7.361422592078876, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value.priceChangePct), 1.0000000000000009, accuracy: 1e-9)
        // The 20-day average starts on the 20th day and not before.
        XCTAssertNil(value.history[18].ma20)
        XCTAssertEqual(try XCTUnwrap(value.history[19].ma20), 34.40332056091627, accuracy: 1e-9)
    }

    func testFallingPricesWithRisingVolatilityReadAsFear() throws {
        let value = try snapshot(count: 260, shift: 3, lastDayUp: false)
        XCTAssertEqual(value.score, 46)
        XCTAssertEqual(value.regime, "Fear")
        XCTAssertEqual(try XCTUnwrap(value.priceChangePct), -2.0000000000000018, accuracy: 1e-9)
    }

    /// Fewer than 252 sessions still scores, but the full-year percentile is
    /// withheld — the page's "provisional" state, which is where VXSMH's own
    /// short history puts it today.
    func testAShortHistoryIsProvisional() throws {
        let value = try snapshot(count: 120, shift: -2, lastDayUp: true)
        XCTAssertEqual(value.score, 34)
        XCTAssertEqual(value.regime, "Risk-on")
        XCTAssertEqual(value.sampleCount, 120)
        XCTAssertNil(value.percentile)
        XCTAssertEqual(value.availablePercentile, 66.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(value.z20), 1.2290306962245858, accuracy: 1e-9)
    }

    func testCachedDatesPreserveSnapshotRoundTrip() throws {
        let original = try snapshot(count: 260, shift: 3, lastDayUp: true)
        let encoded = try JSONEncoder.sentimentEncoder.encode(original)
        let restored = try IndustrySentimentSnapshot.decode(encoded)
        XCTAssertEqual(restored.history.map(\.timestamp), original.history.map(\.timestamp))
        XCTAssertEqual(restored.history.map(\.date), original.history.map(\.date))
        XCTAssertEqual(restored.history.map(\.close), original.history.map(\.close))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try XCTUnwrap(object["history"] as? [[String: Any]])
        XCTAssertNil(rows.first?["timestamp"], "The cached date must not change the snapshot file format")
    }

    func testMalformedHistoryDateIsRejectedDuringDecode() {
        let payload = Data(#"{"date":"invalid","close":25,"ma20":null,"volume":null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(IndustrySentimentSnapshot.Day.self, from: payload))
    }

    func testCboeHistoryParsesToIsoDates() throws {
        let csv = "\u{FEFF}DATE,OPEN,HIGH,LOW,CLOSE\n09/16/2026,36.27,39.05,35.16,38.20\n09/17/2026,35.30,36.51,33.86,35.19\n"
        let rows = try IndustrySentimentClient.parseVolatility(Data(csv.utf8))
        XCTAssertEqual(rows, [.init(date: "2026-09-16", close: 38.20), .init(date: "2026-09-17", close: 35.19)])
    }
}
