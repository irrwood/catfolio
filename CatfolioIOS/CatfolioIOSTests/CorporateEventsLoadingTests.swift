import XCTest
@testable import CatfolioIOS

@MainActor
final class CorporateEventsLoadingTests: XCTestCase {
    func testFreshDiskCacheRestoresWithoutNetworkAndFiltersBeforeSorting() async throws {
        let url = cacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = ["A": schedule("A", dates: ["2026-09-01", "2026-10-12", "2026-11-01"]),
                        "B": schedule("B", dates: ["2026-10-03"])]
        try JSONEncoder().encode(snapshot).write(to: url)
        let probe = LoaderProbe()
        let store = makeStore(url, probe: probe)
        async let card: Void = store.load(tickers: ["a", "B"])
        async let page: Void = store.load(tickers: ["A", "B"])
        _ = await (card, page)
        XCTAssertEqual(store.events(for: ["A", "B"], during: "2026-10-01"..."2026-10-31").map(\.date),
                       ["2026-10-03", "2026-10-12"])
        let calls = await probe.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    func testPreviewAndCalendarJoinRefreshAfterFirstBatchAndLoadAdditionalScope() async throws {
        let url = cacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = LoaderProbe(blocked: "E")
        let store = makeStore(url, probe: probe)
        let tickers = ["A", "B", "C", "D", "E"]
        let card = Task { await store.load(tickers: tickers) }
        await probe.waitUntilBlocked()
        XCTAssertEqual(store.schedules.count, 4)
        XCTAssertTrue(store.isLoading)
        let page = Task { await store.load(tickers: tickers) }
        let changedScope = Task { await store.load(tickers: tickers + ["F"]) }
        await Task.yield()
        await probe.release()
        await card.value
        await page.value
        await changedScope.value
        let calls = await probe.calls
        XCTAssertEqual(calls, Dictionary(uniqueKeysWithValues: (tickers + ["F"]).map { ($0, 1) }))
        XCTAssertEqual(store.schedules.count, 6)
        XCTAssertFalse(store.isLoading)
        let saved = try JSONDecoder().decode([String: CorporateEventSchedule].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.count, 6)
    }

    func testLeavingPreviewDoesNotCancelTheCalendarsSharedRefresh() async throws {
        let url = cacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = LoaderProbe(blocked: "A")
        let store = makeStore(url, probe: probe)
        let preview = Task { await store.load(tickers: ["A"]) }
        await probe.waitUntilBlocked()
        let page = Task { await store.load(tickers: ["A"]) }
        preview.cancel()
        await probe.release()
        await preview.value
        await page.value
        XCTAssertEqual(store.schedules["A"]?.events.count, 1)
        let calls = await probe.calls
        XCTAssertEqual(calls["A"], 1)
        XCTAssertFalse(store.isLoading)
    }

    func testFailedRefreshPreservesStaleEvents() async throws {
        let url = cacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cached = schedule("A", dates: ["2026-10-12"], fetchedAt: .distantPast)
        try JSONEncoder().encode(["A": cached]).write(to: url)
        let store = CorporateEventsStore(cacheURL: url, fetchCrumb: { nil }, fetchSchedule: { _, _ in nil })
        await store.load(tickers: ["A"])
        XCTAssertEqual(store.schedules["A"]?.events, cached.events)
        XCTAssertEqual(store.schedules["A"]?.fetchedAt, .distantPast)
        XCTAssertFalse(store.isLoading)
    }

    func testInvalidCacheCanBeReplacedBySuccessfulRefresh() async throws {
        let url = cacheURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("incomplete".utf8).write(to: url)
        let store = makeStore(url, probe: LoaderProbe())
        await store.load(tickers: ["A", "a"])
        XCTAssertEqual(store.schedules.count, 1)
        let saved = try JSONDecoder().decode([String: CorporateEventSchedule].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved["A"]?.events.count, 1)
    }

    private func cacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("corporate-events-test-\(UUID()).json")
    }

    private func makeStore(_ url: URL, probe: LoaderProbe) -> CorporateEventsStore {
        CorporateEventsStore(cacheURL: url, fetchCrumb: { nil }, fetchSchedule: { ticker, _ in
            await probe.fetch(ticker)
        })
    }

    private func schedule(_ ticker: String, dates: [String], fetchedAt: Date = Date()) -> CorporateEventSchedule {
        CorporateEventSchedule(events: dates.map {
            .init(ticker: ticker, kind: .earnings, date: $0, isEstimate: false, amount: nil, currency: nil)
        }, fetchedAt: fetchedAt)
    }

    private actor LoaderProbe {
        let blocked: String?
        private(set) var calls: [String: Int] = [:]
        private var pending: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?
        init(blocked: String? = nil) { self.blocked = blocked }
        func fetch(_ ticker: String) async -> CorporateEventSchedule {
            calls[ticker, default: 0] += 1
            if ticker == blocked {
                await withCheckedContinuation { continuation in
                    pending = continuation
                    observer?.resume()
                    observer = nil
                }
            }
            return CorporateEventSchedule(events: [
                .init(ticker: ticker, kind: .earnings, date: "2026-10-12", isEstimate: false, amount: nil, currency: nil)
            ], fetchedAt: Date())
        }
        func waitUntilBlocked() async {
            if pending != nil { return }
            await withCheckedContinuation { observer = $0 }
        }
        func release() { pending?.resume(); pending = nil }
    }
}
