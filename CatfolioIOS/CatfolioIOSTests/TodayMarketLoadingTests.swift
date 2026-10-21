import XCTest
@testable import CatfolioIOS

@MainActor
final class TodayMarketLoadingTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var previousCurrency: Any?

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "TodayMarketLoading.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        previousCurrency = UserDefaults.standard.object(forKey: DisplayCurrency.preferenceKey)
        UserDefaults.standard.set("USD", forKey: DisplayCurrency.preferenceKey)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.set(previousCurrency, forKey: DisplayCurrency.preferenceKey)
        super.tearDown()
    }

    func testOpeningCompletePortfolioFillsMissingDailyQuotes() async throws {
        let provider = TodayMarketProvider([.success(["AAA": 110, "BBB": 90])])
        let model = try await readyModel(provider)
        XCTAssertTrue(model.holdingDailyChanges.isEmpty)
        await model.loadPortfolioHomeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["AAA"]), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["BBB"]), -10, accuracy: 1e-9)
        XCTAssertFalse(model.isHoldingDailyChangesLoading)
        XCTAssertNil(model.holdingDailyChangesTask)
        XCTAssertNotNil(model.holdingDailyChangesUpdatedAt)
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].force)
    }

    func testPartialFailureRetriesOnlyMissingSymbolsAndKeepsVisibleResults() async throws {
        let provider = TodayMarketProvider([.success(["AAA": 110]), nil])
        let model = try await readyModel(provider)
        let work = try XCTUnwrap(model.startHoldingDailyChangesRefresh())
        try await waitForCall(2, provider)
        XCTAssertTrue(model.isHoldingDailyChangesLoading)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["AAA"]), 10, accuracy: 1e-9)
        let calls = await provider.calls
        XCTAssertEqual(calls[1].tickers, ["BBB"])
        XCTAssertTrue(calls[1].force)
        await provider.complete(1, with: .success(["BBB": 105]))
        await work.value
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["BBB"]), 5, accuracy: 1e-9)
        let waits = await provider.waits
        XCTAssertEqual(waits, [.seconds(2)])
    }

    func testExhaustedFailuresAreNotCachedAsSuccessAndNextOpenTriesAgain() async throws {
        let provider = TodayMarketProvider([.empty, .empty, .empty, .success(["AAA": 110, "BBB": 90])])
        let model = try await readyModel(provider)
        await model.loadPortfolioHomeIfNeeded()
        let failedCalls = await provider.calls
        XCTAssertEqual(failedCalls.count, 3)
        XCTAssertEqual(failedCalls.map(\.force), [false, true, true])
        let waits = await provider.waits
        XCTAssertEqual(waits, [.seconds(2), .seconds(5)])
        XCTAssertEqual(model.holdingDailyChangesSignature, "")
        XCTAssertNil(model.holdingDailyChangesUpdatedAt)
        XCTAssertFalse(model.isHoldingDailyChangesLoading)
        await model.loadPortfolioHomeIfNeeded()
        XCTAssertEqual(model.holdingDailyChanges.count, 2)
        let recoveredCalls = await provider.calls
        XCTAssertEqual(recoveredCalls.count, 4)
    }

    func testDiskCacheDisplaysBeforeSlowRefreshAndSurvivesEveryFailure() async throws {
        let provider = TodayMarketProvider([nil, .empty, .empty])
        let first = try await readyModel(provider)
        first.holdingDailyChanges = ["AAA": 7, "BBB": -3]
        first.benchmarkDailyChange = 0.2
        await first.saveHomePresentation()
        let restored = makeModel(provider)
        await restored.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(restored.holdingDailyChanges, first.holdingDailyChanges)
        let work = try XCTUnwrap(restored.startHoldingDailyChangesRefresh())
        XCTAssertTrue(restored.isHoldingDailyChangesLoading)
        XCTAssertEqual(restored.holdingDailyChanges, ["AAA": 7, "BBB": -3])
        try await waitForCall(1, provider)
        await provider.complete(0, with: .empty)
        await work.value
        XCTAssertEqual(restored.holdingDailyChanges, ["AAA": 7, "BBB": -3])
        XCTAssertEqual(restored.benchmarkDailyChange, 0.2)
        let reopened = makeModel(provider)
        await reopened.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(reopened.holdingDailyChanges, restored.holdingDailyChanges)
    }

    func testCachedValuesAreReplacedAfterBackgroundRefreshSucceeds() async throws {
        let provider = TodayMarketProvider([nil])
        let model = try await readyModel(provider)
        model.holdingDailyChanges = ["AAA": 7, "BBB": -3]
        let work = try XCTUnwrap(model.startHoldingDailyChangesRefresh())
        try await waitForCall(1, provider)
        XCTAssertEqual(model.holdingDailyChanges["AAA"], 7)
        await provider.complete(0, with: .success(["AAA": 120, "BBB": 100]))
        await work.value
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["AAA"]), 20, accuracy: 1e-9)
        XCTAssertEqual(model.holdingDailyChanges["BBB"], 0, "A flat day is valid data")
        let reopened = makeModel(provider)
        await reopened.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(reopened.holdingDailyChanges, model.holdingDailyChanges)
    }

    func testRemountAndCancelledViewReuseModelOwnedRequest() async throws {
        let provider = TodayMarketProvider([nil])
        let model = try await readyModel(provider)
        let first = Task { await model.loadPortfolioHomeIfNeeded() }
        try await waitForCall(1, provider)
        first.cancel()
        let second = Task { await model.loadPortfolioHomeIfNeeded() }
        await Task.yield()
        await provider.complete(0, with: .success(["AAA": 110, "BBB": 90]))
        await first.value
        await second.value
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(model.holdingDailyChanges.count, 2)
    }

    func testAccountSwitchStartsNewRequestAndRejectsLateOldResult() async throws {
        let provider = TodayMarketProvider([nil, nil])
        let model = try await readyModel(provider)
        let old = try XCTUnwrap(model.startHoldingDailyChangesRefresh())
        try await waitForCall(1, provider)
        await model.updateAccountSelection(["CSV|B"], selectsAll: false)
        try await waitForCall(2, provider)
        let current = try XCTUnwrap(model.holdingDailyChangesTask)
        await provider.complete(1, with: .success(["BBB": 105]))
        await current.value
        await provider.complete(0, with: .success(["AAA": 150, "BBB": 180]))
        await old.value
        XCTAssertEqual(model.holdings.map(\.ticker), ["BBB"])
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["BBB"]), 5, accuracy: 1e-9)
        XCTAssertNil(model.holdingDailyChanges["AAA"])
        XCTAssertFalse(model.isHoldingDailyChangesLoading)
    }

    func testRecentSuccessIsReusedButStaleSuccessRefreshesOnOpen() async throws {
        let provider = TodayMarketProvider([.success(["AAA": 110, "BBB": 90]), .success(["AAA": 120, "BBB": 105])])
        let model = try await readyModel(provider)
        await model.loadPortfolioHomeIfNeeded()
        await model.loadPortfolioHomeIfNeeded()
        let recentCalls = await provider.calls
        XCTAssertEqual(recentCalls.count, 1)
        model.holdingDailyChangesUpdatedAt = Date().addingTimeInterval(-61)
        await model.loadPortfolioHomeIfNeeded()
        let staleCalls = await provider.calls
        XCTAssertEqual(staleCalls.count, 2)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["AAA"]), 20, accuracy: 1e-9)
    }

    func testInvalidAndSingleCloseResponsesRetryInsteadOfReportingSuccess() async throws {
        let invalid = HoldingDailyMarketData(closes: ["AAA": ["2026-10-20": 100],
            "BBB": ["2026-10-19": 100, "2026-10-20": .nan]], benchmark: .nan)
        let provider = TodayMarketProvider([invalid, .success(["AAA": 110, "BBB": 90])])
        let model = try await readyModel(provider)
        await model.loadPortfolioHomeIfNeeded()
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(calls[1].tickers), ["AAA", "BBB"])
        XCTAssertTrue(model.holdingDailyChanges.values.allSatisfy(\.isFinite))
    }

    private func makeModel(_ provider: TodayMarketProvider) -> AppModel {
        let input = fixture()
        return AppModel(defaults: defaults, personalDocumentLoader: { input },
            presentationCache: .init(directory: directory),
            portfolioChartLoader: { document, _, _ in Self.chart(document) },
            dailyMarketLoader: { await provider.load($0, positions: $1, force: $2) },
            dailyMarketRetryWait: { try await provider.wait($0) })
    }

    private func readyModel(_ provider: TodayMarketProvider) async throws -> AppModel {
        let model = makeModel(provider)
        await model.refreshPortfolio(refreshMarketData: false)
        model.portfolioChart = Self.chart(model.document)
        return model
    }

    private func waitForCall(_ count: Int, _ provider: TodayMarketProvider) async throws {
        for _ in 0..<200 {
            if await provider.calls.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected daily request \(count)")
        throw LocalServiceError.noHistoricalPrices
    }

    private func fixture() -> LocalPortfolioDocument {
        .init(source: "CSV", updatedAt: Date(timeIntervalSince1970: 1_790_000_000), positions: [
            .init(ticker: "AAA", name: "A", shares: 10, averageCost: 100, currency: "USD",
                  quotePrice: 110, quoteCurrency: "USD", source: "CSV", openedDate: "2026-01-02", accountID: "A"),
            .init(ticker: "BBB", name: "B", shares: 20, averageCost: 100, currency: "USD",
                  quotePrice: 90, quoteCurrency: "USD", source: "CSV", openedDate: "2026-01-02", accountID: "B")
        ], snapshots: [])
    }

    private nonisolated static func chart(_ document: LocalPortfolioDocument) -> PortfolioChartResponse {
        let value = document.positions.reduce(0) { $0 + $1.shares * $1.quotePrice }
        let rows = ["2026-10-19", "2026-10-20"].map { ChartPoint(dateText: $0, marketValue: value, cost: value) }
        return .init(positionCount: document.positions.count, positionHistory: .init(available: true, rows: rows),
                     currentPoint: rows.last!, warning: nil)
    }
}

private extension HoldingDailyMarketData {
    static var empty: Self { .init(closes: [:], benchmark: nil) }
    static func success(_ latest: [String: Double]) -> Self {
        .init(closes: latest.mapValues { ["2026-10-19": 100, "2026-10-20": $0] }, benchmark: 0.4)
    }
}

private actor TodayMarketProvider {
    struct Call { let tickers: [String]; let force: Bool }
    private(set) var calls: [Call] = []
    private(set) var waits: [Duration] = []
    private var replies: [HoldingDailyMarketData?]
    private var pending: [Int: CheckedContinuation<HoldingDailyMarketData, Never>] = [:]

    init(_ replies: [HoldingDailyMarketData?]) { self.replies = replies }
    func load(_ holdings: [Holding], positions: [LocalPositionRecord], force: Bool) async -> HoldingDailyMarketData {
        let index = calls.count
        calls.append(.init(tickers: holdings.map(\.ticker), force: force))
        guard index < replies.count else { return .empty }
        if let reply = replies[index] { return reply }
        return await withCheckedContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, with result: HoldingDailyMarketData) {
        pending.removeValue(forKey: index)?.resume(returning: result)
    }
    func wait(_ delay: Duration) async throws {
        try Task.checkCancellation()
        waits.append(delay)
        await Task.yield()
        try Task.checkCancellation()
    }
}
