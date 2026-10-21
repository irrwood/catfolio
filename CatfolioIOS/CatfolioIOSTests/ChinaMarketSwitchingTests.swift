import XCTest
@testable import CatfolioIOS

final class ChinaMarketSwitchingTests: XCTestCase {
    private let security = ChinaSecurity("600519.SH")!

    private func client() throws -> ChinaMarketDataClient {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return ChinaMarketDataClient(selection: .longbridge,
            credentials: .init(appKey: "fixture-key", appSecret: "fixture-secret", accessToken: "fixture-token"),
            publicClient: AKShareMarketDataClient(transport: { request, _ in
                (try Self.publicResponse(), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                            httpVersion: nil, headerFields: nil)!)
            }),
            longbridgeClient: LongbridgeMarketDataClient(request: Self.longbridgeResponse),
            dailyCache: ChinaDailyCache(directory: folder.appendingPathComponent("daily")),
            intradayCache: LocalIntradayPriceCache(cacheURL: folder.appendingPathComponent("minutes.json"),
                                                   writeData: { _, _ in }))
    }

    func testSwitchingPreservesEachProvidersPricesAndAttribution() async throws {
        var client = try client()
        for (source, price, cached) in [(ChinaMarketSource.longbridge, 202.0, false),
                                       (.akshare, 102.0, false), (.longbridge, 202.0, true)] {
            client.selection = source
            let history = try await client.history(security, from: "2026-10-19", to: "2026-10-20")
            XCTAssertEqual(history.daily.last?.close, price)
            XCTAssertEqual(history.intraday.last?.close, price)
            XCTAssertEqual(history.attribution.source, source)
            XCTAssertEqual(history.attribution.cached, cached)
        }
    }

    func testChangingCredentialsCannotReadThePreviousAccountsCache() async throws {
        var client = try client()
        _ = try await client.history(security, from: "2026-10-19", to: "2026-10-20")
        client.credentials = .init(appKey: "other", appSecret: "other", accessToken: "other")
        do {
            _ = try await client.history(security, from: "2026-10-19", to: "2026-10-20", cachedOnly: true)
            XCTFail("A different account must not inherit cached entitlement-backed history")
        } catch { XCTAssertTrue(error is ChinaMarketError) }
    }

    func testAutomaticFallbackKeepsDailyAndMinutesFromTheSameProvider() async throws {
        var client = try client()
        client.selection = .automatic
        client.longbridgeClient = LongbridgeMarketDataClient { command, body in
            if command == 27 { throw ChinaMarketError.rejected(403) }
            return try await Self.longbridgeResponse(command, body)
        }
        let history = try await client.history(security, from: "2026-10-19", to: "2026-10-20",
                                               forceRefresh: true)
        XCTAssertEqual(history.daily.last?.close, 102)
        XCTAssertEqual(history.intraday.last?.close, 102)
        XCTAssertEqual(history.attribution.source, .akshare)
    }

    func testExplicitLongbridgeFailureNeverShowsPublicHistoryAsLongbridge() async throws {
        var client = try client()
        client.selection = .akshare
        _ = try await client.history(security, from: "2026-10-19", to: "2026-10-20")
        client.selection = .longbridge
        client.longbridgeClient = LongbridgeMarketDataClient { _, _ in throw ChinaMarketError.rejected(401) }
        do {
            _ = try await client.history(security, from: "2026-10-19", to: "2026-10-20")
            XCTFail("An explicitly selected source must surface its error")
        } catch {
            guard case ChinaMarketError.rejected(401) = error else { return XCTFail("\(error)") }
        }
    }

    @MainActor
    func testDelayedSelectedSourceCanReplaceQuoteButOldSourceCannotPublishAfterSwitch() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: ChinaMarketSource.preferenceKey)
        defer { defaults.set(original, forKey: ChinaMarketSource.preferenceKey) }
        let suite = "ChinaMarketSwitching.\(UUID().uuidString)"
        let modelDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { modelDefaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: modelDefaults, personalDocumentLoader: { .empty })
        let now = try XCTUnwrap(ChinaSecurity.date("2026-10-20 15:00", format: "yyyy-MM-dd HH:mm"))
        func history(price: Double, time: Date) -> SecurityPriceHistory {
            .init(ticker: security.ticker, currency: "CNY",
                points: [.init(dateText: "2026-10-19", close: 100), .init(dateText: "2026-10-20", close: price)],
                intradayPoints: [.init(dateText: "minute", close: price, timestamp: time)], trades: [],
                chinaMarketConfiguration: .current)
        }
        defaults.set(ChinaMarketSource.akshare.rawValue, forKey: ChinaMarketSource.preferenceKey)
        let publicHistory = history(price: 102, time: now)
        try await model.publishSecurityPriceHistory(publicHistory, source: model.portfolioSource, now: now)
        defaults.set(ChinaMarketSource.longbridge.rawValue, forKey: ChinaMarketSource.preferenceKey)
        let delayedHistory = history(price: 103, time: now.addingTimeInterval(-900))
        try await model.publishSecurityPriceHistory(delayedHistory, source: model.portfolioSource, now: now)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges[security.ticker]), 3, accuracy: 1e-9)
        try await model.publishSecurityPriceHistory(publicHistory, source: model.portfolioSource, now: now)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges[security.ticker]), 3, accuracy: 1e-9)
    }

    private static func publicResponse() throws -> Data {
        var fields = [String](repeating: "", count: 31)
        fields[2] = "600519"; fields[3] = "102"; fields[4] = "100"; fields[30] = "20261020150000"
        return try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["sh600519": [
            "qt": ["sh600519": fields],
            "qfqday": [["2026-10-19", "100", "100", "101", "99", "10"],
                       ["2026-10-20", "100", "102", "103", "99", "12"]],
            "data": ["date": "20261020", "data": ["1459 101 10", "1500 102 12"]],
        ]]])
    }

    private static func longbridgeResponse(_ command: UInt8, _ body: Data) async throws -> Data {
        let timestamp = UInt64(ChinaSecurity.date("2026-10-20 15:00", format: "yyyy-MM-dd HH:mm")!.timeIntervalSince1970)
        let symbol = LongbridgeProto.string(1, "600519.SH")
        if command == 18 {
            return symbol + LongbridgeProto.bytes(2,
                LongbridgeProto.string(1, "202") + LongbridgeProto.integer(2, timestamp))
        }
        XCTAssertEqual(command, 27)
        var result = symbol
        for (offset, close) in [(UInt64(86400), "200"), (0, "202")] {
            result += LongbridgeProto.bytes(2, LongbridgeProto.string(1, close)
                + LongbridgeProto.string(3, "199") + LongbridgeProto.string(4, "203")
                + LongbridgeProto.integer(5, 100) + LongbridgeProto.integer(7, timestamp - offset))
        }
        return result
    }
}
