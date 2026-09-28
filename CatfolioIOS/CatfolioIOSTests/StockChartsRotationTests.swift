import XCTest
import UIKit
@testable import CatfolioIOS

@MainActor
final class StockChartsRotationTests: XCTestCase {
    private func fixture() throws -> StockChartsRRGCapture {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "stockcharts_rrg_reference", withExtension: "json"))
        return try StockChartsRRGCapture.decode(Data(contentsOf: url))
    }
    func testSourceCoordinatesMatchCapturedPublicChartWithoutNormalising() throws {
        let response = try fixture().response
        XCTAssertEqual(response.period, "W")
        XCTAssertEqual(response.companies.count, 7)
        let last = try XCTUnwrap(response.rrgdata.last)
        XCTAssertEqual(last.end, "2026-09-10 12:59:54")
        XCTAssertEqual(last.benchmark, 7604.95)
        let expected = ["$INDU": [100.04, 100.36], "$COMPQ": [99.96, 99.03], "$NYA": [99.08, 100.87], "$XAX": [95.14, 101.84], "$TSX": [99.15, 100.33], "$CDNX": [91.23, 101.82]]
        for symbol in StockChartsRRGResponse.symbols {
            let value = try XCTUnwrap(last.rrgdata[symbol])
            XCTAssertEqual(value.jdkratio, expected[symbol]![0])
            XCTAssertEqual(value.jdkmom, expected[symbol]![1])
        }
    }
    func testThirtyWeekTailIncludesCurrentAndThirtyPreviousObservations() throws {
        let response = try fixture().response
        let latest = response.trail(endingAt: response.rrgdata.count - 1)
        XCTAssertEqual(latest.count, 31)
        XCTAssertEqual(latest.first?.date, "2026-02-13")
        XCTAssertEqual(latest.last?.date, "2026-09-10")
        let historical = response.trail(endingAt: 30)
        XCTAssertEqual(historical.count, 31)
        XCTAssertEqual(historical.last?.end, response.rrgdata[30].end)
        XCTAssertTrue(historical.allSatisfy { $0.end <= response.rrgdata[30].end })
        XCTAssertTrue(response.trail(endingAt: -1).isEmpty)
    }
    func testWrongPeriodMissingSymbolAndCorruptValuesAreRejected() throws {
        let data = try JSONEncoder().encode(fixture().response)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var wrong = base; wrong["period"] = "D"
        XCTAssertThrowsError(try StockChartsRRGResponse.decode(JSONSerialization.data(withJSONObject: wrong)))
        var rows = try XCTUnwrap(base["rrgdata"] as? [[String: Any]])
        var values = try XCTUnwrap(rows[0]["rrgdata"] as? [String: Any])
        values.removeValue(forKey: "$COMPQ"); rows[0]["rrgdata"] = values
        wrong = base; wrong["rrgdata"] = rows
        XCTAssertThrowsError(try StockChartsRRGResponse.decode(JSONSerialization.data(withJSONObject: wrong)))
        wrong = base; wrong["rrgdata"] = Array(rows.reversed())
        XCTAssertThrowsError(try StockChartsRRGResponse.decode(JSONSerialization.data(withJSONObject: wrong)))
        rows = base["rrgdata"] as! [[String: Any]]
        values = rows[0]["rrgdata"] as! [String: Any]
        values["$COMPQ"] = ["price": 1, "jdkratio": 99, "jdkmom": -1]
        rows[0]["rrgdata"] = values
        wrong = base; wrong["rrgdata"] = rows
        XCTAssertThrowsError(try StockChartsRRGResponse.decode(JSONSerialization.data(withJSONObject: wrong)))
    }
    func testFailedOrOlderRefreshRetainsSourceSnapshot() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StockChartsRRGStore(cacheURL: url)
        XCTAssertNil(store.capture, "Construction must not synchronously decode the snapshot")
        await store.restore()
        let original = try XCTUnwrap(store.capture?.response.rrgdata.last?.end)
        XCTAssertThrowsError(try store.accept(Data("{}".utf8)))
        XCTAssertEqual(store.capture?.response.rrgdata.last?.end, original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture().response)) as? [String: Any])
        object["rrgdata"] = Array((object["rrgdata"] as! [[String: Any]]).dropLast())
        XCTAssertThrowsError(try store.accept(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(store.capture?.response.rrgdata.last?.end, original)
    }
    func testUIKitAxesUseHundredAndKeepFullThirtyWeekTrailVisible() throws {
        let response = try fixture().response
        let weeks = response.trail(endingAt: response.rrgdata.count - 1)
        let chart = StockChartsRRGChart(frame: CGRect(x: 0, y: 0, width: 370, height: 300))
        chart.configure(weeks: weeks, selected: nil); chart.layoutIfNeeded()
        let center = chart.point(.init(price: 1, jdkratio: 100, jdkmom: 100))
        XCTAssertEqual(center.x, 185); XCTAssertEqual(center.y, 150)
        for week in weeks {
            for value in week.rrgdata.values { XCTAssertTrue(chart.bounds.contains(chart.point(value))) }
        }
        XCTAssertEqual(chart.weeks.count, 31)
        XCTAssertEqual(chart.subviews.filter { $0 is UIControl }.count, 6)
    }
}
