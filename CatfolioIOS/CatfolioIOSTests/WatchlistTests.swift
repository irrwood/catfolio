import XCTest
@testable import CatfolioIOS

@MainActor
final class WatchlistTests: XCTestCase {
    func testStarTogglesCanonicalListingAndPersistsWithoutCreatingPositions() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let first = WatchlistStore(defaults: fixture.defaults)
        let holding = security("BRK.B", price: 500, change: 2)
        first.toggle(holding)
        XCTAssertTrue(first.contains(security("BRK-B")))
        let restored = WatchlistStore(defaults: fixture.defaults)
        XCTAssertEqual(restored.entries.count, 1)
        let entry = try XCTUnwrap(restored.entries.first)
        XCTAssertEqual(entry.ticker, "BRK-B")
        XCTAssertEqual(entry.holding.shares, 0)
        XCTAssertEqual(entry.holding.marketValue, 0)
        XCTAssertEqual(entry.holding.quotePrice, 500)
        XCTAssertEqual(try XCTUnwrap(entry.quote?.changeAmount), 500 - 500 / 1.02, accuracy: 0.0001)
        XCTAssertNil(entry.quote?.observedAt, "An undated portfolio quote must not be labelled live")
        restored.toggle(security("BRK-B"))
        XCTAssertTrue(WatchlistStore(defaults: fixture.defaults).entries.isEmpty)
    }

    func testDistinctMarketsAndChineseAliases() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let store = WatchlistStore(defaults: fixture.defaults)
        store.toggle(security("BABA"))
        store.toggle(security("9988.HK", currency: "HKD"))
        store.toggle(security("600519", currency: "CNY"))
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertTrue(store.contains(security("600519.SS", currency: "CNY")))
        store.toggle(security("600519.SS", currency: "CNY"))
        XCTAssertEqual(store.entries.map(\.ticker), ["9988.HK", "BABA"])
        XCTAssertEqual(store.entries.first?.holding.quoteCurrency, "HKD")
    }

    func testPartialRefreshKeepsCacheAndRejectsInvalidPrices() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let observed = Date()
        let store = WatchlistStore(defaults: fixture.defaults, loader: { entries, _ in
            Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, WatchlistQuote(price: $0.ticker == "AAPL" ? 105 : .nan,
                                      previousClose: 100, observedAt: observed))
            })
        })
        store.toggle(security("MSFT", price: 200, change: -2))
        store.toggle(security("AAPL", price: 100, change: 0))
        await store.refresh(forceRefresh: true)
        XCTAssertEqual(store.entries.first?.quote?.price, 105)
        XCTAssertEqual(store.entries.first?.quote?.changeAmount, 5)
        XCTAssertEqual(store.entries.first?.quote?.changePercent, 5)
        XCTAssertEqual(store.entries.last?.quote?.price, 200)
        XCTAssertEqual(store.failedIDs, ["MSFT|USD"])
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(WatchlistStore(defaults: fixture.defaults).entries, store.entries)
    }

    func testRemovingAndReAddingDuringRefreshCannotResurrectOldQuote() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let pending = PendingQuotes()
        let store = WatchlistStore(defaults: fixture.defaults, loader: { _, _ in await pending.load() })
        let holding = security("AAPL", price: 100)
        store.toggle(holding)
        let refresh = Task { await store.refresh(forceRefresh: true) }
        for _ in 0..<100 {
            if await pending.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await pending.isWaiting
        XCTAssertTrue(waiting)
        store.toggle(holding)
        store.toggle(security("AAPL", price: 120))
        await pending.finish(["AAPL|USD": .init(price: 101, previousClose: 100, observedAt: .now)])
        await refresh.value
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.quote?.price, 120)
    }

    func testOlderRefreshDoesNotReplaceNewerDetailQuote() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let now = Date()
        let store = WatchlistStore(defaults: fixture.defaults, loader: { _, _ in
            ["AAPL|USD": .init(price: 90, previousClose: 100, observedAt: now.addingTimeInterval(-86400))]
        })
        store.toggle(security("AAPL"), observation: .init(ticker: "AAPL", currency: "USD", price: 110,
                                                         observedAt: now, changePercent: 10))
        await store.refresh(forceRefresh: true)
        XCTAssertEqual(store.entries.first?.quote?.price, 110)
        XCTAssertEqual(store.failedIDs, ["AAPL|USD"])
    }

    func testQuoteUsesPreviousTradingCloseNotTodaysOpenOrPartialClose() throws {
        let now = date("2026-10-19T16:00:00Z") // Monday after a weekend.
        let quote = try XCTUnwrap(WatchlistMarketData.resolvedQuote(symbol: "AAPL",
            closes: ["2026-10-15": 95, "2026-10-16": 100, "2026-10-19": 103],
            live: .init(price: 105, observedAt: now), now: now))
        XCTAssertEqual(quote.price, 105)
        XCTAssertEqual(quote.changeAmount, 5)
        XCTAssertEqual(quote.changePercent, 5)
        XCTAssertEqual(quote.observedAt, now)
    }

    func testClosingQuoteCurrencyScaleMissingBaselineAndFlatDay() throws {
        let now = date("2026-10-20T10:00:00Z")
        let quote = try XCTUnwrap(WatchlistMarketData.resolvedQuote(symbol: "BARC.L",
            closes: ["2026-10-16": 250, "2026-10-19": 245],
            live: .init(price: 240, observedAt: date("2026-10-15T10:00:00Z")), scale: 0.01, now: now))
        XCTAssertEqual(quote.price, 2.45, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(quote.changeAmount), -0.05, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(quote.changePercent), -2, accuracy: 0.0001)
        let single = WatchlistMarketData.resolvedQuote(symbol: "NEW", closes: [:],
            live: .init(price: 20, observedAt: now), now: now)
        XCTAssertEqual(single?.price, 20)
        XCTAssertNil(single?.changeAmount)
        XCTAssertNil(single?.changePercent)
        let flat = WatchlistQuote(price: 100, previousClose: 100, observedAt: now)
        XCTAssertEqual(flat.changeAmount, 0)
        XCTAssertEqual(flat.changePercent, 0)
        XCTAssertNil(WatchlistMarketData.resolvedQuote(symbol: "AAPL", closes: ["2026-10-19": .nan], live: nil, now: now))
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func security(_ ticker: String, currency: String = "USD", price: Double = 0, change: Double? = nil) -> Holding {
        Holding(ticker: ticker, logoSymbol: ticker, displayName: ticker, sector: nil, source: nil,
                shares: 123, averageCost: 20, costCurrency: currency, quotePrice: price, quoteCurrency: currency,
                todayChangePercent: change, marketValue: 9999, weight: 1, unrealized: 500, unrealizedPercent: 20,
                fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }

    private final class Fixture {
        let suite = "watchlist-\(UUID())"
        let defaults: UserDefaults
        init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) }
        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
}

private actor PendingQuotes {
    private var continuation: CheckedContinuation<[String: WatchlistQuote], Never>?
    var isWaiting: Bool { continuation != nil }
    func load() async -> [String: WatchlistQuote] {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ result: [String: WatchlistQuote]) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
