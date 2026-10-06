import XCTest
import SwiftUI
@testable import CatfolioIOS

@MainActor
final class PortfolioPresentationCacheTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "HomeCacheTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func fixture() -> LocalPortfolioDocument {
        LocalPortfolioDocument(source: "CSV", updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            positions: [
                LocalPositionRecord(ticker: "CACHE_TEST", name: "Cache fixture", shares: 10,
                    averageCost: 100, currency: "USD", quotePrice: 120, quoteCurrency: "USD", source: "CSV",
                    openedDate: nil, accountID: "A", accountName: "A"),
                LocalPositionRecord(ticker: "CACHE_TEST", name: "Cache fixture", shares: 5,
                    averageCost: 100, currency: "USD", quotePrice: 120, quoteCurrency: "USD", source: "CSV",
                    openedDate: nil, accountID: "B", accountName: "B")
            ], snapshots: [])
    }

    private func snapshot(_ document: LocalPortfolioDocument) throws -> PortfolioPresentationSnapshot {
        let local = try LocalPortfolioEngine.presentation(for: document)
        let chart = PortfolioChartResponse(positionCount: 1,
            positionHistory: .init(available: true, rows: [
                .init(dateText: "2026-09-10", marketValue: 1800, cost: 1500),
                .init(dateText: "2026-09-11", marketValue: 1830, cost: 1500)]),
            currentPoint: .init(dateText: "2026-09-11", marketValue: 1830, cost: 1500),
            warning: "Preserve account basis", accountNAV: ["2026-09-10": 1, "2026-09-11": 1.02],
            dataIssues: ["Fixture assumption"])
        return .init(overview: local.0, chart: chart, holdings: local.2,
            dailyChanges: ["CACHE_TEST": 2.5], benchmark: 0.8,
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            savedAt: Date(timeIntervalSince1970: 1_780_000_100))
    }

    private func context(_ document: LocalPortfolioDocument, source: PortfolioSource = .personal,
                         accounts: Set<String>? = nil, language: String = ContentLanguage.current) -> PortfolioPresentationCache.Context {
        .init(source: source, accountKeys: accounts ?? Set(document.accounts.map(\.id)), language: language)
    }

    func testColdLaunchRestoresComputedNAVAndDailyMovesWithoutRebuild() async throws {
        let input = fixture()
        let expected = try snapshot(input)
        let writer = PortfolioPresentationCache(directory: directory)
        try await writer.save(expected, document: input, context: context(input))
        // A different actor and AppModel simulate process memory being lost.
        let reader = PortfolioPresentationCache(directory: directory)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input }, presentationCache: reader)
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 1830,
                       "Local presentation has unavailable NAV; the computed value must come from disk")
        XCTAssertEqual(model.portfolioChart?.accountNAV, expected.chart.accountNAV)
        XCTAssertEqual(model.portfolioChart?.dataIssues, expected.chart.dataIssues)
        XCTAssertEqual(model.holdingDailyChanges["CACHE_TEST"], 2.5)
        XCTAssertEqual(model.benchmarkDailyChange, 0.8)
        XCTAssertEqual(model.localUpdatedAt, expected.updatedAt)
        XCTAssertEqual(model.portfolioCachedAt, expected.savedAt)
        XCTAssertFalse(model.isPortfolioLoading)
        XCTAssertFalse(model.isPortfolioChartLoading)
        // A second refresh must not replace the restored NAV with a placeholder.
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 1830)
    }

    func testCompletedPresentationPersistsForAnotherModel() async throws {
        let input = fixture()
        let cache = PortfolioPresentationCache(directory: directory)
        let first = AppModel(defaults: defaults, personalDocumentLoader: { input }, presentationCache: cache)
        await first.refreshPortfolio(refreshMarketData: false)
        first.portfolioChart = try snapshot(input).chart
        await first.saveHomePresentation()
        let second = AppModel(defaults: defaults, personalDocumentLoader: { input },
                              presentationCache: PortfolioPresentationCache(directory: directory))
        await second.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(second.portfolioChart?.currentPoint.marketValue, 1830)
        XCTAssertEqual(second.holdings.first?.shares, 15)
    }

    func testRestoredHomeRendersChartWithoutWaitingForMarketHistory() async throws {
        let input = fixture()
        let cache = PortfolioPresentationCache(directory: directory)
        try await cache.save(snapshot(input), document: input, context: context(input))
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input }, presentationCache: cache)
        await model.refreshPortfolio(refreshMarketData: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let ready = expectation(description: "Restored curve is rendered")
        var didBecomeReady = false
        let host = UIHostingController(rootView: PortfolioView().environment(model)
            .environment(\.locale, Locale(identifier: ContentLanguage.current))
            .onPreferenceChange(PortfolioHeroReadyPreference.self) { value in
                if value && !didBecomeReady { didBecomeReady = true; ready.fulfill() }
            })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        await fulfillment(of: [ready], timeout: 5)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Home restored from persistent cache"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNotNil(model.portfolioCachedAt)
    }

    func testChangedLedgerAndAccountScopeRejectOldResults() async throws {
        let input = fixture()
        let cache = PortfolioPresentationCache(directory: directory)
        try await cache.save(snapshot(input), document: input, context: context(input))
        var changed = input
        changed.positions.removeLast()
        let miss = await cache.load(document: changed, context: context(input))
        XCTAssertNil(miss)
        let otherAccount = await cache.load(document: input, context: context(input, accounts: ["CSV|A"]))
        XCTAssertNil(otherAccount)
        let changedInput = changed
        let model = AppModel(defaults: defaults, personalDocumentLoader: { changedInput }, presentationCache: cache)
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.holdings.first?.shares, 10)
        XCTAssertNil(model.portfolioCachedAt)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 1200)
        XCTAssertEqual(model.portfolioChart?.currentPoint.cost, 1000)
        XCTAssertNil(model.portfolioChart?.accountNAV)
    }

    func testHomeWithoutHistoryUsesKnownHoldingsFigures() async throws {
        let input = fixture()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input },
            presentationCache: PortfolioPresentationCache(directory: directory))
        await model.refreshPortfolio(refreshMarketData: false)
        let chart = try XCTUnwrap(model.portfolioChart)
        XCTAssertEqual(chart.currentPoint.marketValue, 1800)
        XCTAssertEqual(chart.currentPoint.cost, 1500)
        XCTAssertTrue(chart.isCurrentHoldingsOnly)
        XCTAssertNil(chart.accountNAV, "Holding cost return must not be labeled account TWR")
        XCTAssertEqual(chart.positionHistory.rows.count, 0, "Do not invent a historical curve")
    }

    func testHoldingsFiguresFollowNewQuotesBeforeHistoryIsAvailable() async throws {
        let input = fixture()
        let loader = HomeNumbersDocumentLoader(input)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { await loader.load() },
            presentationCache: PortfolioPresentationCache(directory: directory))
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 1800)
        var updated = input
        updated.positions = updated.positions.map { $0.withQuotePrice(130, observedAt: Date()) }
        await loader.set(updated)
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 1950)
        XCTAssertEqual(model.portfolioChart?.currentPoint.cost, 1500)
        XCTAssertNil(model.portfolioChart?.accountNAV)
    }

    func testCachedCurvePreparesWhileHistoryRefreshIsPending() async throws {
        let input = fixture()
        let cached = try snapshot(input)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input })
        let ready = expectation(description: "Cached chart prepared during background history loading")
        var fulfilled = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: CostMarketCard(overview: cached.overview,
            response: cached.chart, isAwaitingEnrichedHistory: true).environment(model)
            .onPreferenceChange(PortfolioHeroReadyPreference.self) { value in
                if value && !fulfilled { fulfilled = true; ready.fulfill() }
            })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        await fulfillment(of: [ready], timeout: 5)
    }

    func testModesLanguagesAndSelectionsAreIsolated() async throws {
        let input = fixture()
        let cache = PortfolioPresentationCache(directory: directory)
        try await cache.save(snapshot(input), document: input, context: context(input, language: "zh"))
        for source in [PortfolioSource.demo, .publicInvestors("pelosi"), .publicInvestors("hh")] {
            let miss = await cache.load(document: input, context: context(input, source: source, language: "zh"))
            XCTAssertNil(miss)
        }
        let languageMiss = await cache.load(document: input, context: context(input, language: "en"))
        XCTAssertNil(languageMiss)
    }

    func testUnavailableResultCannotOverwriteLastUsableCache() async throws {
        let input = fixture()
        let cache = PortfolioPresentationCache(directory: directory)
        let local = try LocalPortfolioEngine.presentation(for: input)
        let pending = PortfolioPresentationSnapshot(overview: local.0, chart: local.1, holdings: local.2,
            dailyChanges: [:], benchmark: nil, updatedAt: nil, savedAt: Date())
        try await cache.save(pending, document: input, context: context(input))
        let empty = await cache.load(document: input, context: context(input))
        XCTAssertNil(empty)
        try await cache.save(snapshot(input), document: input, context: context(input))
        try await cache.save(pending, document: input, context: context(input))
        let retained = await cache.load(document: input, context: context(input))
        XCTAssertEqual(retained?.chart.currentPoint.marketValue, 1830)
    }

    func testQuoteRefreshAndDiskDateRoundingDoNotInvalidatePresentation() async throws {
        var input = fixture()
        input.updatedAt = Date(timeIntervalSince1970: 1_780_000_000.123)
        input.marketDataUpdatedAt = input.updatedAt
        input.positions = input.positions.map { $0.withQuotePrice(121, observedAt: input.updatedAt) }
        let cache = PortfolioPresentationCache(directory: directory)
        try await cache.save(snapshot(input), document: input, context: context(input))
        // Exactly the date encoding/decoding used by LocalPortfolioStore.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var disk = try decoder.decode(LocalPortfolioDocument.self, from: encoder.encode(input))
        XCTAssertNotEqual(input.updatedAt, disk.updatedAt)
        let roundTrip = await cache.load(document: disk, context: context(disk))
        XCTAssertNotNil(roundTrip)
        disk.updatedAt = Date()
        disk.marketDataUpdatedAt = disk.updatedAt
        disk.positions = disk.positions.map { $0.withQuotePrice(130, observedAt: disk.updatedAt) }
        disk.snapshots = [.init(date: "2026-09-15", marketValueUSD: 1950, costUSD: 1500)]
        let latest = disk
        let model = AppModel(defaults: defaults, personalDocumentLoader: { latest }, presentationCache: cache)
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 1830)
        XCTAssertNotNil(model.portfolioCachedAt)
        // Correctly restoring cached numbers must not suppress future refreshes.
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.holdings.first?.marketValue, 1950)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 1830)
    }

    func testCorruptOrUnknownVersionCacheIsIgnored() async throws {
        let input = fixture()
        let cache = PortfolioPresentationCache(directory: directory)
        try await cache.save(snapshot(input), document: input, context: context(input))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("personal"), includingPropertiesForKeys: nil).first)
        var envelope = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: file), format: nil) as? [String: Any])
        envelope["version"] = 999
        try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0).write(to: file)
        let versionMiss = await cache.load(document: input, context: context(input))
        XCTAssertNil(versionMiss)
        try Data("truncated cache".utf8).write(to: file)
        let corruptMiss = await cache.load(document: input, context: context(input))
        XCTAssertNil(corruptMiss)
    }

    func testRemovingPersonalCacheKeepsOtherModes() async throws {
        let input = fixture()
        let cache = PortfolioPresentationCache(directory: directory)
        try await cache.save(snapshot(input), document: input, context: context(input))
        try await cache.save(snapshot(input), document: input, context: context(input, source: .demo))
        await cache.removePersonal()
        let personal = await cache.load(document: input, context: context(input))
        let demo = await cache.load(document: input, context: context(input, source: .demo))
        XCTAssertNil(personal)
        XCTAssertNotNil(demo)
    }
}

private actor HomeNumbersDocumentLoader {
    private var document: LocalPortfolioDocument
    init(_ document: LocalPortfolioDocument) { self.document = document }
    func load() -> LocalPortfolioDocument { document }
    func set(_ document: LocalPortfolioDocument) { self.document = document }
}
