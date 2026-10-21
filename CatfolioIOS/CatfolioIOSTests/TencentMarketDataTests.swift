import XCTest
@testable import CatfolioIOS

final class TencentMarketDataTests: XCTestCase {
    private let security = ChinaSecurity("600519.SH")!

    func testQuoteUsesProviderTimeAndChecksListing() throws {
        let data = try Self.response()
        let quote = try TencentMarketDataClient.parseQuote(data, security: security)
        XCTAssertEqual(quote.price, 102)
        XCTAssertEqual(quote.previousClose, 100)
        XCTAssertEqual(quote.observedAt, ChinaSecurity.date("20261008150000", format: "yyyyMMddHHmmss"))
        XCTAssertThrowsError(try TencentMarketDataClient.parseQuote(data, security: ChinaSecurity("000001.SZ")!))
        XCTAssertThrowsError(try TencentMarketDataClient.parseQuote(data, security: security,
            now: ChinaSecurity.date("2026-10-01")!))
    }

    func testMinutesUseShanghaiDateAndExcludeLunchAndPostClosePrints() throws {
        let data = try Self.response(extra: ["data": ["date": "20261008",
            "data": ["0930 101 20", "1130 102 30", "1200 104 40", "1300 103 50", "1500 102 60", "1530 105 70"]]])
        let bars = try TencentMarketDataClient.parseIntraday(data, security: security)
        XCTAssertEqual(bars.map(\.close), [101, 102, 103, 102])
        XCTAssertEqual(bars.last?.timestamp, ISO8601DateFormatter().date(from: "2026-10-08T07:00:00Z"))
    }

    func testDailyUsesCorrectVolumeUnitsForShenzhenSTARAndETF() throws {
        for (symbol, shares) in [("000001.SZ", 123400.0), ("688981.SH", 1234.0), ("510300.SH", 123400.0)] {
            let listing = ChinaSecurity(symbol)!
            let data = try Self.response(security: listing, extra: [
                "day": [["2026-10-08", "100", "102", "105", "99", "1234"]],
            ])
            let page = try TencentMarketDataClient.parseDailyPage(data, security: listing, adjusted: false)
            XCTAssertEqual(page.bars.first?.volume, shares)
            XCTAssertEqual(page.bars.first?.close, 102)
        }
    }

    func testNonpositiveAdjustedPricesAreNotClampedOrReplacedWithRaw() throws {
        let data = try Self.response(extra: [
            "qfqday": [["2001-08-27", "-314", "-313", "-310", "-315", "100"],
                       ["2026-10-08", "100", "102", "105", "99", "1234"]],
            "day": [["2001-08-27", "30", "31", "32", "29", "100"]],
        ])
        let page = try TencentMarketDataClient.parseDailyPage(data, security: security, adjusted: true)
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.firstDate, "2001-08-27", "Paging uses the original dates, even when prices are excluded")
        XCTAssertEqual(page.bars.map(\.date), ["2026-10-08"])
    }

    func testHistoryPagesPast640Days() async throws {
        let probe = TencentRequestProbe()
        let end = ChinaSecurity.date("2026-10-08")!
        let client = TencentMarketDataClient { host, path, query in
            XCTAssertEqual(host, "proxy.finance.qq.com")
            XCTAssertEqual(path, "/ifzqgtimg/appstock/app/newfqkline/get")
            let calls = await probe.record(query["param"] ?? "")
            let indices = calls == 1 ? Array(0..<640) : [640]
            let rows = indices.map { index in
                [ChinaSecurity.day(end.addingTimeInterval(-Double(index) * 86400)), "100", "102", "105", "99", "1234"]
            }
            return try Self.response(extra: ["qfqday": rows])
        }
        let from = ChinaSecurity.day(end.addingTimeInterval(-640 * 86400))
        let bars = try await client.daily(security, from: from, to: "2026-10-08", adjusted: true)
        XCTAssertEqual(bars.count, 641)
        XCTAssertEqual(bars.first?.date, from)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].contains("2026-10-09"))
        XCTAssertTrue(requests[1].contains(from))
    }

    func testWorkingTencentQuoteDoesNotContactBrokenEastmoney() async throws {
        let probe = TencentRequestProbe()
        let client = AKShareMarketDataClient(transport: { request, _ in
            _ = await probe.record(request.url!.host!)
            XCTAssertEqual(request.url?.host, "web.ifzq.gtimg.cn")
            return (try Self.response(), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                        httpVersion: nil, headerFields: nil)!)
        })
        let quote = try await client.quote(security)
        XCTAssertEqual(quote.price, 102)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testConnectionLossFallsBackButCancellationAndRateLimitDoNot() async throws {
        for failure in [URLError.Code.networkConnectionLost, .cancelled] {
            let probe = TencentRequestProbe()
            let client = AKShareMarketDataClient(transport: { request, _ in
                _ = await probe.record(request.url!.host!)
                if request.url?.host == "web.ifzq.gtimg.cn" { throw URLError(failure) }
                let data = Data(#"{"rc":0,"data":{"f43":102,"f57":"600519","f60":100,"f86":1700000000}}"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            do {
                let quote = try await client.quote(security)
                XCTAssertEqual(failure, .networkConnectionLost)
                XCTAssertEqual(quote.price, 102)
            } catch {
                XCTAssertEqual(failure, .cancelled)
                XCTAssertEqual((error as? URLError)?.code, .cancelled)
            }
            let requests = await probe.requests
            XCTAssertEqual(requests.count, failure == .cancelled ? 1 : 2)
        }
        let probe = TencentRequestProbe()
        let limited = AKShareMarketDataClient(transport: { request, _ in
            _ = await probe.record(request.url!.host!)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await limited.quote(security); XCTFail("429 must be surfaced") }
        catch { if case ChinaMarketError.http(429) = error { } else { XCTFail("\(error)") } }
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testHTMLAccessControlResponseDoesNotTriggerAnotherUpstream() async throws {
        let probe = TencentRequestProbe()
        let client = AKShareMarketDataClient(transport: { request, _ in
            _ = await probe.record(request.url!.host!)
            let data = Data(#"<!DOCTYPE html><html><script>location.href="https://waf.tencent.com/501page.html"</script></html>"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await client.quote(security); XCTFail("Access-control pages must be surfaced") }
        catch { if case ChinaMarketError.http(403) = error { } else { XCTFail("\(error)") } }
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    private static func response(security: ChinaSecurity = ChinaSecurity("600519.SH")!,
                                 extra: [String: Any] = [:]) throws -> Data {
        var fields = [String](repeating: "", count: 31)
        fields[2] = security.code; fields[3] = "102"; fields[4] = "100"; fields[30] = "20261008150000"
        var listing = extra
        listing["qt"] = [security.tencentSymbol: fields]
        return try JSONSerialization.data(withJSONObject: ["code": 0, "data": [security.tencentSymbol: listing]])
    }
}

private actor TencentRequestProbe {
    var requests: [String] = []
    func record(_ value: String) -> Int { requests.append(value); return requests.count }
}
