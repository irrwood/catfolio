import XCTest
@testable import CatfolioIOS

final class ChinaMarketDataTests: XCTestCase {
    private let security = ChinaSecurity("600519.SH")!

    @MainActor
    func testUnheldASharePublishesDailyChangeWithoutCreatingAPosition() async throws {
        let suite = "ChinaMarketDataTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        let document = model.document
        let now = try XCTUnwrap(ChinaSecurity.date("2026-10-20 15:00", format: "yyyy-MM-dd HH:mm"))
        for ticker in ["600519.SS", "000001.SZ", "510300.SS"] {
            let history = SecurityPriceHistory(ticker: ticker, currency: "CNY",
                points: [.init(dateText: "2026-10-19", close: 100), .init(dateText: "2026-10-20", close: 102)],
                intradayPoints: [.init(dateText: "minute", close: 102, timestamp: now)], trades: [])
            try await model.publishSecurityPriceHistory(history, source: model.portfolioSource, now: now)
            XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges[ticker]), 2, accuracy: 1e-9)
        }
        XCTAssertEqual(model.document, document)
        XCTAssertTrue(model.holdings.isEmpty)
    }

    func testListingIdentityKeepsVenueAndCurrency() {
        for value in ["600519.SH", "600519.SS", "SH.600519", "sh600519"] {
            XCTAssertEqual(ChinaSecurity(value)?.ticker, "600519.SS")
            XCTAssertEqual(ChinaSecurity(value)?.eastmoneyID, "1.600519")
        }
        XCTAssertEqual(ChinaSecurity("000001", currency: "CNY")?.longbridgeSymbol, "000001.SZ")
        XCTAssertNil(ChinaSecurity("000001"))
        XCTAssertNil(ChinaSecurity("000001", currency: "HKD"))
        XCTAssertNil(ChinaSecurity("000001.SH"), "Do not confuse Shanghai Composite with Ping An Bank")
        XCTAssertNil(ChinaSecurity("600519.SZ"))
        XCTAssertNil(ChinaSecurity("AAPL"))
        XCTAssertNil(ChinaSecurity("430047.BJ"))
        XCTAssertTrue(ChinaSecurity("510300.SH")!.isFund)
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "SH.600519", currency: "CNY"), "600519.SS")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "000001", currency: "USD"), "000001")
    }

    func testChinaDateUsesShanghaiEvenWhenUserIsAbroad() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-19T16:30:00Z"))
        XCTAssertEqual(ChinaSecurity.day(date), "2026-10-20")
        XCTAssertEqual(LocalMarketDataClient.sessionKey(for: date, symbol: "600519.SS"), "2026-10-20")
        XCTAssertNil(ChinaSecurity.date("2026-02-30"))
    }

    func testPublicQuoteUsesFeedTimeAndNeverRefreshTime() throws {
        let data = Data(#"{"rc":0,"data":{"f43":1331.88,"f57":"600519","f60":1324.97,"f86":1792483921}}"#.utf8)
        let quote = try AKShareMarketDataClient.parseQuote(data, security: security,
            now: Date(timeIntervalSince1970: 1792485000))
        XCTAssertEqual(quote.price, 1331.88)
        XCTAssertEqual(quote.observedAt.timeIntervalSince1970, 1792483921)
        XCTAssertEqual(quote.changePercent, (1331.88 / 1324.97 - 1) * 100, accuracy: 0.000001)
        XCTAssertThrowsError(try AKShareMarketDataClient.parseQuote(data, security: ChinaSecurity("000001.SZ")!))
        XCTAssertThrowsError(try AKShareMarketDataClient.parseQuote(data, security: security,
            now: Date(timeIntervalSince1970: 1700000000)))
        XCTAssertThrowsError(try AKShareMarketDataClient.parseQuote(
            Data(#"{"rc":0,"data":{"f43":"-","f57":"600519","f60":1324.97,"f86":1792483921}}"#.utf8), security: security))
    }

    func testPublicDailyPriceAndLotUnits() throws {
        let data = Data(#"{"rc":0,"data":{"code":"600519","market":1,"klines":["2026-10-09,1255.42,1263.00,1282.00,1255.42,35111","2026-10-08,1252.90,1255.79,1258.00,1242.00,25168"]}}"#.utf8)
        let bars = try AKShareMarketDataClient.parseDaily(data, security: security)
        XCTAssertEqual(bars.map(\.date), ["2026-10-08", "2026-10-09"])
        XCTAssertEqual(bars[0].close, 1255.79)
        XCTAssertEqual(bars[0].volume, 2516800, "Eastmoney reports lots; app models use shares")
        let wrong = Data(#"{"rc":0,"data":{"code":"600519","market":0,"klines":[]}}"#.utf8)
        XCTAssertThrowsError(try AKShareMarketDataClient.parseDaily(wrong, security: security))
    }

    func testPublicIntradayUsesCloseColumnAndShanghaiTime() throws {
        let data = Data(#"{"rc":0,"data":{"code":"600519","market":1,"trends":["2026-10-08 09:31,1200,1255.79,1258,1242,20,1,1250"]}}"#.utf8)
        let bars = try AKShareMarketDataClient.parseIntraday(data, security: security,
            now: ChinaSecurity.date("2026-10-09")!)
        XCTAssertEqual(bars[0].close, 1255.79)
        XCTAssertEqual(bars[0].timestamp, ISO8601DateFormatter().date(from: "2026-10-08T01:31:00Z"))
    }

    func testMinuteQuoteFallbackKeepsActualObservationTime() throws {
        let data = Data(#"{"rc":0,"data":{"code":"600519","market":1,"preClose":100,"trends":["2026-10-08 15:00,101,102,103,100,20,1,101"]}}"#.utf8)
        let quote = try AKShareMarketDataClient.parseMinuteQuote(data, security: security,
            now: ChinaSecurity.date("2026-10-09")!)
        XCTAssertEqual(quote.price, 102)
        XCTAssertEqual(quote.changePercent, 2, accuracy: 0.00001)
        XCTAssertEqual(quote.observedAt, ChinaSecurity.date("2026-10-08 15:00", format: "yyyy-MM-dd HH:mm"))
    }

    func testChineseSearchKeepsExchangeAndRejectsIndexAndHongKong() throws {
        let data = Data(#"{"QuotationCodeTable":{"Data":[{"Code":"600519","Name":"贵州茅台","MktNum":"1"},{"Code":"000001","Name":"平安银行","MktNum":"0"},{"Code":"000001","Name":"上证指数","MktNum":"1"},{"Code":"00700","Name":"腾讯","MktNum":"116"}]}}"#.utf8)
        let results = try AKShareMarketDataClient.parseSearch(data)
        XCTAssertEqual(results.map(\.ticker), ["600519.SS", "000001.SZ"])
        XCTAssertEqual(results.first?.holding.quoteCurrency, "CNY")
        XCTAssertEqual(results.first?.holding.displayName, "贵州茅台")
        XCTAssertTrue(ChinaMarketDataClient.shouldSearch("茅台"))
        XCTAssertTrue(ChinaMarketDataClient.shouldSearch("600519"))
        XCTAssertFalse(ChinaMarketDataClient.shouldSearch("AAPL"))
    }

    func testAutomaticFallbackAndExplicitProviderSelection() async throws {
        XCTAssertEqual(ChinaMarketSource.automatic.providers(hasLongbridge: false), [.akshare])
        XCTAssertEqual(ChinaMarketSource.automatic.providers(hasLongbridge: true), [.longbridge, .akshare])
        var calls: [ChinaMarketSource] = []
        let result = try await ChinaMarketDataClient.firstAvailable([.longbridge, .akshare]) { source in
            calls.append(source)
            if source == .longbridge { throw ChinaMarketError.rejected(401) }
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(calls, [.longbridge, .akshare])
        calls = []
        do {
            let _: Int = try await ChinaMarketDataClient.firstAvailable([.longbridge]) { source in
                calls.append(source); throw ChinaMarketError.rejected(401)
            }
            XCTFail("A fixed provider must expose its failure")
        } catch { XCTAssertEqual(calls, [.longbridge]) }
    }

    func testCancellationDoesNotTryTheFallback() async {
        var calls: [ChinaMarketSource] = []
        do {
            let _: Int = try await ChinaMarketDataClient.firstAvailable([.longbridge, .akshare]) { source in
                calls.append(source); throw CancellationError()
            }
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, [.longbridge])
    }

    func testCacheSeparatesProviderAndAdjustmentAndReplacesSeries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChinaDailyCache(directory: directory)
        let raw = MarketDailyBar(date: "2026-10-08", close: 100, high: 105, low: 95, volume: 1000)
        let adjusted = MarketDailyBar(date: raw.date, close: 90, high: 95, low: 85, volume: 1000)
        await cache.save("akshare|600519.SS|raw", from: raw.date, to: raw.date, bars: [raw])
        await cache.save("akshare|600519.SS|forward", from: raw.date, to: raw.date, bars: [adjusted])
        let missing = await cache.load("longbridge|600519.SS|raw", from: raw.date, to: raw.date)
        XCTAssertNil(missing)
        let rawCached = await cache.load("akshare|600519.SS|raw", from: raw.date, to: raw.date)
        XCTAssertEqual(rawCached?.bars[0].close, 100)
        let adjustedCached = await cache.load("akshare|600519.SS|forward", from: raw.date, to: raw.date)
        XCTAssertEqual(adjustedCached?.bars[0].close, 90)
        let revised = MarketDailyBar(date: raw.date, close: 80, high: 85, low: 75, volume: 1000)
        await cache.save("akshare|600519.SS|forward", from: raw.date, to: raw.date, bars: [revised])
        let replaced = await cache.load("akshare|600519.SS|forward", from: raw.date, to: raw.date)
        XCTAssertEqual(replaced?.bars.count, 1)
        XCTAssertEqual(replaced?.bars[0].close, 80, "A new adjustment basis must replace old prices")
        let unchangedRaw = await cache.load("akshare|600519.SS|raw", from: raw.date, to: raw.date)
        XCTAssertEqual(unchangedRaw?.bars[0].close, 100)
        let tooEarly = await cache.load("akshare|600519.SS|raw", from: "2020-01-01", to: raw.date)
        XCTAssertNil(tooEarly)
    }
}
