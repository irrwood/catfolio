import XCTest
@testable import CatfolioIOS

private actor DCAHistoryReply {
    private var response: [PolicyPricePoint]?
    private var continuation: CheckedContinuation<[PolicyPricePoint], Never>?
    func get() async -> [PolicyPricePoint] {
        if let response { return response }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ rows: [PolicyPricePoint]) {
        response = rows
        continuation?.resume(returning: rows); continuation = nil
    }
}

final class DCABundledHistoryTests: XCTestCase {
    func testBundledResourceHasVerifiedMetadataAndOrderedRealPrices() throws {
        let snapshot = try DCABundledHistory.spy.get()
        XCTAssertEqual(snapshot.symbol, "SPY")
        XCTAssertEqual(snapshot.firstDay, "1993-01-29")
        XCTAssertEqual(snapshot.currency, "USD")
        XCTAssertEqual(snapshot.priceBasis, "split-adjusted-close")
        XCTAssertGreaterThan(snapshot.count, 8000)
        XCTAssertEqual(snapshot.count, snapshot.prices.count)
        XCTAssertEqual(snapshot.prices.last?.day, snapshot.asOf)
        XCTAssertTrue(DCABundledHistory.valid(snapshot.prices))
        XCTAssertLessThan(snapshot.asOf, DayDateCodec.string(from: Date()))
        XCTAssertTrue(snapshot.sourceURL.hasPrefix("https://query1.finance.yahoo.com/v8/finance/chart/SPY?"))
    }
    func testRejectsWrongSymbolBasisAndCorruptRows() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "spy_daily_history", withExtension: "json"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for (key, value) in [("symbol", "QQQ"), ("priceBasis", "dividend-adjusted"), ("asOf", "1900-01-01")] {
            var json = original; json[key] = value
            XCTAssertThrowsError(try DCABundledHistory.decode(JSONSerialization.data(withJSONObject: json)))
        }
        XCTAssertFalse(DCABundledHistory.valid([.init(day: "2024-01-01", close: 100), .init(day: "2024-01-01", close: 101)]))
        XCTAssertFalse(DCABundledHistory.valid([.init(day: "2024-01-01", close: 100), .init(day: "2024-01-02", close: 0)]))
    }
    @MainActor
    private func makeStore(_ loader: @escaping @Sendable (String, String, String) async -> [PolicyPricePoint]) throws -> DCAStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DCA-bundle-test-" + UUID().uuidString))
        let store = DCAStore(defaults: defaults, historyLoader: loader)
        store.settings.start = DayDateCodec.date(from: "2023-09-20")!
        store.settings.end = DayDateCodec.date(from: "2026-09-19")!
        return store
    }
    @MainActor
    func testOfflineBacktestUsesBundledHistoryAndMatchesIndependentLedger() async throws {
        let store = try makeStore { _, _, _ in [] }
        await store.load(demo: false)
        let result = try XCTUnwrap(store.result)
        XCTAssertTrue(store.usesBundledHistory)
        XCTAssertTrue(store.resultUsesBundledHistory)
        XCTAssertFalse(store.isDemo)
        XCTAssertNil(store.error)
        XCTAssertEqual(result.final.day, "2026-09-18")
        XCTAssertEqual(result.final.contributed, 78500)
        XCTAssertEqual(result.final.baselineContributed, 78500)
        XCTAssertEqual(result.final.value, 101972.79, accuracy: 0.01)
        XCTAssertEqual(result.final.baseline, 101972.79, accuracy: 0.01)
        // Independently solved from the actual dated purchases and terminal holdings.
        XCTAssertEqual(try XCTUnwrap(result.annualizedReturn), 0.182162, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result.baselineAnnualizedReturn), 0.182162, accuracy: 0.000001)
        XCTAssertEqual(result.profit, result.baselineProfit)
        XCTAssertEqual(try XCTUnwrap(result.annualizedReturn), try XCTUnwrap(result.baselineAnnualizedReturn))
        XCTAssertEqual(result.maxDrawdown, result.baselineMaxDrawdown, accuracy: 0.00000001)
    }
    @MainActor
    func testBundleIsUsableBeforeSlowNetworkCompletes() async throws {
        let reply = DCAHistoryReply()
        let store = try makeStore { _, _, _ in await reply.get() }
        let loading = Task { await store.load(demo: false) }
        for _ in 0..<200 {
            if store.isRefreshing && store.result != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(store.result)
        XCTAssertTrue(store.canRun)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertFalse(store.isLoading)
        await reply.finish([])
        await loading.value
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotNil(store.result)
    }
    @MainActor
    func testCompleteRefreshUpdatesPricesAndRecomputesResult() async throws {
        var revised = try DCABundledHistory.spy.get().prices
        let last = try XCTUnwrap(revised.popLast())
        revised.append(.init(day: last.day, close: last.close * 1.01))
        let refreshed = revised
        let store = try makeStore { _, _, _ in refreshed }
        await store.load(demo: false)
        XCTAssertFalse(store.usesBundledHistory)
        XCTAssertFalse(store.resultUsesBundledHistory)
        XCTAssertEqual(try XCTUnwrap(store.result).final.value, 101972.79 * 1.01, accuracy: 0.02)
        XCTAssertFalse(store.isStale)
    }
    @MainActor
    func testPartialOrOldRefreshCannotTruncateBundle() async throws {
        let snapshot = try DCABundledHistory.spy.get()
        let partial = Array(snapshot.prices.suffix(100))
        let store = try makeStore { _, _, _ in partial }
        await store.load(demo: false)
        XCTAssertTrue(store.usesBundledHistory)
        XCTAssertEqual(store.prices.count, snapshot.count)
        XCTAssertEqual(store.result?.final.day, snapshot.asOf)
    }
    @MainActor
    func testOtherSymbolNeverFallsBackToSPY() async throws {
        let store = try makeStore { _, _, _ in [] }
        store.settings.symbol = "QQQ"
        await store.load(demo: false)
        XCTAssertNil(store.result)
        XCTAssertTrue(store.prices.isEmpty)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.usesBundledHistory)
    }
    @MainActor
    func testLateSPYRefreshCannotReplaceNewSymbol() async throws {
        let reply = DCAHistoryReply()
        let alternate = [PolicyPricePoint(day: "2026-09-17", close: 200), .init(day: "2026-09-18", close: 210)]
        let store = try makeStore { symbol, _, _ in symbol == "SPY" ? await reply.get() : alternate }
        let first = Task { await store.load(demo: false) }
        for _ in 0..<200 {
            if store.isRefreshing && store.result != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.settings.symbol = "AMD"
        await store.load(demo: false)
        await reply.finish(try DCABundledHistory.spy.get().prices)
        await first.value
        XCTAssertEqual(store.loadedSymbol, "AMD")
        XCTAssertEqual(store.prices.last?.close, 210)
        XCTAssertEqual(store.result?.settings.symbol, "AMD")
        XCTAssertFalse(store.usesBundledHistory)
    }
}
