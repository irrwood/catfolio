import XCTest
@testable import CatfolioIOS

@MainActor
final class SecuritySearchModelTests: XCTestCase {
    private nonisolated static func result(_ ticker: String) -> MarketSecurityResult {
        .init(ticker: ticker, name: ticker, market: "US", exchange: "NASDAQ",
              currency: "USD", sector: nil, isFund: false)
    }

    func testHoldingsMergePaginationAndNewQueryReset() async {
        let model = SecuritySearchModel(searchDelay: .zero, directorySearch: { query, limit in
            Array((0..<70).map { Self.result("\(query)\($0)") }.prefix(limit))
        })
        let held = Self.result("MATCH-HELD").holding
        var request = model.request(query: " MATCH ", holdings: [held])
        await model.search(request)
        XCTAssertEqual(model.results(for: request).count, 16)
        XCTAssertEqual(model.results(for: request).last?.ticker, held.ticker)
        XCTAssertTrue(model.hasMore)
        model.loadMore(for: "MATCH")
        request = model.request(query: "MATCH", holdings: [held])
        XCTAssertEqual(request.limit, 40)
        await model.search(request)
        XCTAssertEqual(model.results(for: request).count, 41)

        let next = model.request(query: "NEXT", holdings: [])
        XCTAssertEqual(next.limit, 15)
        XCTAssertTrue(model.results(for: next).isEmpty, "Never display the previous query's directory matches")
        await model.search(next)
        XCTAssertEqual(model.request(query: "MATCH", holdings: []).limit, 15)
        let empty = model.request(query: "  ", holdings: [held])
        await model.search(empty)
        XCTAssertTrue(model.results(for: empty).isEmpty)
        XCTAssertFalse(model.hasMore)
    }

    func testCancelledDebounceDoesNotCallDirectory() async {
        let calls = Calls()
        let model = SecuritySearchModel(searchDelay: .seconds(10), directorySearch: { _, _ in
            await calls.record(); return []
        })
        let task = Task { await model.search(model.request(query: "A", holdings: [])) }
        task.cancel()
        await task.value
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testLateDirectoryCannotReplaceANewerQuery() async {
        let gate = Gate<[MarketSecurityResult]>()
        let model = SecuritySearchModel(searchDelay: .zero, directorySearch: { query, _ in
            query == "OLD" ? await gate.wait() : [Self.result(query)]
        })
        let old = Task { await model.search(model.request(query: "OLD", holdings: [])) }
        await gate.waitUntilStarted()
        let next = model.request(query: "NEW", holdings: [])
        await model.search(next)
        await gate.finish([Self.result("OLD")])
        await old.value
        XCTAssertEqual(model.searchedQuery, "NEW")
        XCTAssertEqual(model.results(for: next).map(\.ticker), ["NEW"])
    }

    func testLateMainlandResponseCannotRestoreClearedQuery() async {
        let gate = Gate<[MarketSecurityResult]>()
        let model = SecuritySearchModel(searchDelay: .zero, directorySearch: { _, _ in [Self.result("OFFLINE")] },
            mainlandSearch: { _ in await gate.wait() })
        let old = Task { await model.search(model.request(query: "腾讯", holdings: [])) }
        await gate.waitUntilStarted()
        XCTAssertEqual(model.searchedQuery, "腾讯", "Offline results appear before network enrichment")
        let empty = model.request(query: "", holdings: [])
        await model.search(empty)
        await gate.finish([Self.result("0700.HK")])
        await old.value
        XCTAssertEqual(model.searchedQuery, "")
        XCTAssertTrue(model.results(for: empty).isEmpty)
    }

    func testQuoteRequestsUseListingIdentityAndHoldingsFallback() async {
        let result = Self.result("AAPL")
        let holding = Holding(ticker: "AAPL", logoSymbol: nil, displayName: "Apple", sector: nil, source: nil,
            shares: 1, averageCost: 80, costCurrency: "USD", quotePrice: 100, quoteCurrency: "USD",
            todayChangePercent: nil, marketValue: 100, weight: 1, unrealized: 20,
            unrealizedPercent: 25, fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
        let model = SecuritySearchModel(searchDelay: .zero, quoteDelay: .zero,
            directorySearch: { _, _ in [result] }, quoteLoader: { entries in
                Dictionary(uniqueKeysWithValues: entries.map {
                    ($0.id, WatchlistQuote(price: 123, previousClose: 120, observedAt: .now))
                })
            })
        let request = model.request(query: "AAPL", holdings: [holding])
        XCTAssertEqual(model.quote(for: result, holdings: [holding])?.price, 100)
        await model.search(request)
        let quotes = model.quoteRequest(for: request)
        XCTAssertEqual(quotes, model.quoteRequest(for: request), "Fresh membership IDs must not restart loading")
        XCTAssertEqual(quotes.entries.map(\.id), ["AAPL|USD"])
        await model.loadQuotes(quotes)
        XCTAssertEqual(model.quote(for: result, holdings: [holding])?.price, 123)
        XCTAssertEqual(model.quote(for: result, holdings: [])?.price, 123)
    }

    func testSupersededAndCancelledQuotesDoNotApply() async {
        let gate = Gate<[String: WatchlistQuote]>()
        let result = Self.result("AAPL")
        let model = SecuritySearchModel(quoteDelay: .zero, quoteLoader: { _ in await gate.wait() })
        let request = SecuritySearchModel.QuoteRequest(entries: [WatchlistEntry(holding: result.holding)])
        let old = Task { await model.loadQuotes(request) }
        await gate.waitUntilStarted()
        await model.loadQuotes(.init(entries: []))
        old.cancel()
        await gate.finish(["AAPL|USD": WatchlistQuote(price: 123, previousClose: nil, observedAt: nil)])
        await old.value
        XCTAssertNil(model.quote(for: result, holdings: []))
    }

    private actor Calls {
        var count = 0
        func record() { count += 1 }
    }

    private actor Gate<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func wait() async -> Value {
            await withCheckedContinuation {
                continuation = $0
                started?.resume(); started = nil
            }
        }
        func waitUntilStarted() async {
            if continuation != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func finish(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
    }
}
