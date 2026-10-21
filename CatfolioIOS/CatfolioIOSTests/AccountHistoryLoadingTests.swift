import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountHistoryLoadingTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "AccountHistoryLoading.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testSwitchRestoresExactAccountCurveWithoutPriceCacheOrNetwork() async throws {
        let input = fixture()
        let cache = PortfolioPresentationCache(directory: directory)
        let requests = AccountHistoryRequests()
        let model = model(input, cache: cache, requests: requests)
        await model.refreshPortfolio(refreshMarketData: false)
        let selections: [Set<String>] = [["CSV|A"], ["CSV|B"], ["CSV|A", "CSV|B"]]
        for keys in selections {
            let scoped = input.scoped(to: keys)
            let local = try LocalPortfolioEngine.presentation(for: scoped)
            try await cache.save(.init(overview: local.0, chart: chart(scoped), holdings: local.2,
                dailyChanges: [:], benchmark: nil, updatedAt: nil, savedAt: Date()), document: input,
                context: .init(source: .personal, accountKeys: keys, language: ContentLanguage.current))
        }
        for keys in selections + [["CSV|A"]] {
            if keys.count == 2 { await model.selectAllAccounts() }
            else { await model.updateAccountSelection(keys, selectsAll: false) }
            XCTAssertEqual(model.selectedAccountKeys, keys)
            XCTAssertEqual(model.portfolioChart?.positionHistory.rows.count, 3)
            XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, chart(input.scoped(to: keys)).currentPoint.marketValue)
            XCTAssertFalse(model.isPortfolioChartLoading)
            XCTAssertNil(model.accountHistoryTask)
        }
        let calls = await requests.calls
        XCTAssertTrue(calls.isEmpty, "The saved selection curve does not need the lower-level price cache")
    }

    func testMissingSelectionHistoryLoadsAutomaticallyAfterSelectionCallerLeaves() async throws {
        let input = fixture()
        let requests = AccountHistoryRequests()
        let model = model(input, cache: .init(directory: directory), requests: requests)
        await model.refreshPortfolio(refreshMarketData: false)
        let selection = Task { await model.updateAccountSelection(["CSV|A"], selectsAll: false) }
        await selection.value
        selection.cancel()
        try await waitForRequest("CSV|A", in: requests)
        XCTAssertEqual(model.selectedAccountKeys, ["CSV|A"])
        XCTAssertTrue(model.isPortfolioChartLoading)
        XCTAssertTrue(model.portfolioChart?.isCurrentHoldingsOnly == true)
        let revision = model.portfolioChartRevision
        let work = try XCTUnwrap(model.accountHistoryTask)
        let expected = chart(input.scoped(to: ["CSV|A"]))
        await requests.complete("CSV|A", with: expected)
        await work.value
        XCTAssertEqual(model.portfolioChart?.positionHistory.rows.count, 3)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, expected.currentPoint.marketValue)
        XCTAssertGreaterThan(model.portfolioChartRevision, revision)
        XCTAssertFalse(model.isPortfolioChartLoading)
        XCTAssertNil(model.accountHistoryTask)
        let calls = await requests.calls
        XCTAssertEqual(calls.map(\.cachedOnly), [true, false])
        XCTAssertTrue(calls.allSatisfy { !$0.forceRefresh }, "Reuse prices; account selection is not a forced market refresh")
        let saved = await model.savedHomeChart()
        XCTAssertEqual(saved?.positionHistory.rows.count, 3)
    }

    func testSlowPreviousAccountCannotReplaceLatestSelection() async throws {
        let input = fixture()
        let requests = AccountHistoryRequests()
        let model = model(input, cache: .init(directory: directory), requests: requests)
        await model.refreshPortfolio(refreshMarketData: false)
        await model.updateAccountSelection(["CSV|A"], selectsAll: false)
        try await waitForRequest("CSV|A", in: requests)
        let oldWork = try XCTUnwrap(model.accountHistoryTask)
        await model.updateAccountSelection(["CSV|B"], selectsAll: false)
        try await waitForRequest("CSV|B", in: requests)
        let newWork = try XCTUnwrap(model.accountHistoryTask)
        let expected = chart(input.scoped(to: ["CSV|B"]))
        await requests.complete("CSV|B", with: expected)
        await newWork.value
        let revision = model.portfolioChartRevision
        // Simulate a provider that returns after it was cancelled.
        await requests.complete("CSV|A", with: chart(input.scoped(to: ["CSV|A"])))
        await oldWork.value
        XCTAssertEqual(model.selectedAccountKeys, ["CSV|B"])
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, expected.currentPoint.marketValue)
        XCTAssertEqual(model.portfolioChartRevision, revision)
        XCTAssertFalse(model.isPortfolioChartLoading)
    }

    func testFailedHistoryKeepsSelectedAccountFiguresAndEndsLoading() async throws {
        let input = fixture()
        let requests = AccountHistoryRequests()
        let model = model(input, cache: .init(directory: directory), requests: requests)
        await model.refreshPortfolio(refreshMarketData: false)
        await model.updateAccountSelection(["CSV|A"], selectsAll: false)
        try await waitForRequest("CSV|A", in: requests)
        let work = try XCTUnwrap(model.accountHistoryTask)
        await requests.fail("CSV|A")
        await work.value
        XCTAssertEqual(model.selectedAccountKeys, ["CSV|A"])
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 1200)
        XCTAssertTrue(model.portfolioChart?.isCurrentHoldingsOnly == true)
        XCTAssertFalse(model.isPortfolioChartLoading)
    }

    func testFirstHomeLoadsMissingHistoryAndSurvivesCallerCancellation() async throws {
        let input = fixture()
        let requests = AccountHistoryRequests()
        let model = model(input, cache: .init(directory: directory), requests: requests)
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertTrue(model.portfolioChart?.isCurrentHoldingsOnly == true)
        let home = Task { await model.loadPortfolioHomeIfNeeded() }
        let key = "CSV|A,CSV|B"
        try await waitForRequest(key, in: requests)
        XCTAssertTrue(model.isPortfolioChartLoading)
        home.cancel()
        let remountedHome = Task { await model.loadPortfolioHomeIfNeeded() }
        await requests.complete(key, with: chart(input))
        await home.value
        await remountedHome.value
        XCTAssertEqual(model.portfolioChart?.positionHistory.rows.count, 3)
        XCTAssertFalse(model.isPortfolioChartLoading)
        XCTAssertNil(model.accountHistoryTask)
        let calls = await requests.calls
        XCTAssertEqual(calls.map(\.cachedOnly), [true, false], "Remounting must reuse the in-flight history request")
        XCTAssertTrue(calls.allSatisfy { !$0.forceRefresh })
        let saved = await model.savedHomeChart()
        XCTAssertEqual(saved?.positionHistory.rows.count, 3)
        await model.loadPortfolioHomeIfNeeded()
        let subsequentCalls = await requests.calls
        XCTAssertEqual(subsequentCalls.count, calls.count, "A completed curve must not reload on each appearance")
    }

    func testCloudReloadFillsMissingHistoryWithoutReenteringHome() async throws {
        let input = fixture()
        let requests = AccountHistoryRequests()
        let model = model(input, cache: .init(directory: directory), requests: requests)
        await model.refreshPortfolio(refreshMarketData: false)
        let sync = Task { await model.reloadPortfolioAfterSync() }
        try await waitForRequest("CSV|A,CSV|B", in: requests)
        await requests.complete("CSV|A,CSV|B", with: chart(input))
        await sync.value
        XCTAssertEqual(model.portfolioChart?.positionHistory.rows.count, 3)
        XCTAssertFalse(model.isPortfolioChartLoading)
    }

    private func model(_ input: LocalPortfolioDocument, cache: PortfolioPresentationCache,
                       requests: AccountHistoryRequests) -> AppModel {
        AppModel(defaults: defaults, personalDocumentLoader: { input }, presentationCache: cache,
                 portfolioChartLoader: { try await requests.load($0, cachedOnly: $1, forceRefresh: $2) },
                 dailyMarketLoader: { holdings, _, _ in
                     .init(closes: Dictionary(uniqueKeysWithValues: holdings.map {
                         ($0.ticker, ["2026-10-19": 100.0, "2026-10-20": 101.0])
                     }), benchmark: 0)
                 })
    }

    private func waitForRequest(_ key: String, in requests: AccountHistoryRequests) async throws {
        for _ in 0..<100 {
            if await requests.isPending(key) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Account history was not requested automatically")
        throw LocalServiceError.noHistoricalPrices
    }

    private func fixture() -> LocalPortfolioDocument {
        .init(source: "CSV", updatedAt: Date(), positions: [
            .init(ticker: "ACCOUNT_A", name: "A", shares: 10, averageCost: 100, currency: "USD",
                  quotePrice: 120, quoteCurrency: "USD", source: "CSV", openedDate: "2026-01-02", accountID: "A"),
            .init(ticker: "ACCOUNT_B", name: "B", shares: 20, averageCost: 100, currency: "USD",
                  quotePrice: 90, quoteCurrency: "USD", source: "CSV", openedDate: "2026-01-02", accountID: "B")
        ], snapshots: [])
    }

    private func chart(_ document: LocalPortfolioDocument) -> PortfolioChartResponse {
        let value = document.positions.reduce(0) { $0 + $1.shares * $1.quotePrice }
        let rows = ["2026-01-02", "2026-06-01", DayDateCodec.string(from: Date())].enumerated().map { index, date in
            ChartPoint(dateText: date, marketValue: value * (0.8 + Double(index) * 0.1), cost: value * 0.8)
        }
        return .init(positionCount: document.positions.count, positionHistory: .init(available: true, rows: rows),
                     currentPoint: rows.last!, warning: nil)
    }
}

private actor AccountHistoryRequests {
    struct Call: Sendable { let cachedOnly: Bool; let forceRefresh: Bool }
    private(set) var calls: [Call] = []
    private var pending: [String: CheckedContinuation<PortfolioChartResponse, Error>] = [:]

    func load(_ document: LocalPortfolioDocument, cachedOnly: Bool, forceRefresh: Bool) async throws -> PortfolioChartResponse {
        calls.append(.init(cachedOnly: cachedOnly, forceRefresh: forceRefresh))
        if cachedOnly { throw LocalServiceError.noHistoricalPrices }
        let key = document.positions.map(\.accountKey).sorted().joined(separator: ",")
        return try await withCheckedThrowingContinuation { pending[key] = $0 }
    }

    func isPending(_ key: String) -> Bool { pending[key] != nil }
    func complete(_ key: String, with chart: PortfolioChartResponse) { pending.removeValue(forKey: key)?.resume(returning: chart) }
    func fail(_ key: String) { pending.removeValue(forKey: key)?.resume(throwing: LocalServiceError.noHistoricalPrices) }
}
