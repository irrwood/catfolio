import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountVisibilityTests: XCTestCase {
    private func fixture() -> LocalPortfolioDocument {
        let positions = [
            LocalPositionRecord(ticker: "SCOPE_TEST", name: "Shared stock", shares: 10,
                averageCost: 100, currency: "USD", quotePrice: 150, quoteCurrency: "USD", source: "CSV",
                openedDate: nil, accountID: "A", accountName: "A"),
            LocalPositionRecord(ticker: "SCOPE_TEST", name: "Shared stock", shares: 3,
                averageCost: 200, currency: "USD", quotePrice: 150, quoteCurrency: "USD", source: "CSV",
                openedDate: nil, accountID: "B", accountName: "B")
        ]
        return LocalPortfolioDocument(source: "CSV", updatedAt: Date(), positions: positions, snapshots: [])
    }

    func testSwitchRecalculatesSharedHoldingWithoutLoadingDocumentAgain() async throws {
        let suite = "AccountVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let loader = AccountVisibilityLoader(fixture())
        let model = AppModel(defaults: defaults, personalDocumentLoader: { await loader.load() })
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.holdings.first?.shares, 13)
        await model.toggleAccount("CSV|B")
        XCTAssertEqual(model.selectedAccountKeys, ["CSV|A"])
        XCTAssertEqual(model.accounts.count, 2, "Keep hidden accounts available for re-selection")
        XCTAssertEqual(model.holdings.first?.shares, 10)
        XCTAssertEqual(model.holdings.first?.unrealized, 500)
        XCTAssertEqual(model.overview?.summary.marketValue, 1500)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 1500)
        XCTAssertFalse(model.isPortfolioLoading)
        XCTAssertFalse(model.isPortfolioChartLoading)
        XCTAssertFalse(model.isHoldingDailyChangesLoading)
        await model.selectAllAccounts()
        await model.toggleAccount("CSV|A")
        XCTAssertEqual(model.selectedAccountKeys, ["CSV|B"])
        XCTAssertEqual(model.holdings.first?.shares, 3)
        XCTAssertEqual(model.holdings.first?.unrealized, -150)
        XCTAssertEqual(model.overview?.summary.marketValue, 450)
        await model.selectAllAccounts()
        XCTAssertEqual(model.holdings.first?.shares, 13)
        XCTAssertEqual(model.overview?.summary.marketValue, 1950)
        let count = await loader.count
        XCTAssertEqual(count, 1, "Visibility uses the full in-memory ledger, never reloads holdings")
    }

    func testRapidToggleBackCannotPublishIntermediateScope() async throws {
        let suite = "AccountVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = fixture()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input })
        await model.refreshPortfolio(refreshMarketData: false)
        let hide = Task { await model.toggleAccount("CSV|B") }
        await Task.yield()
        let restore = Task { await model.toggleAccount("CSV|B") }
        await hide.value
        await restore.value
        XCTAssertEqual(model.selectedAccountKeys, ["CSV|A", "CSV|B"])
        XCTAssertEqual(model.holdings.first?.shares, 13)
        XCTAssertEqual(model.overview?.summary.marketValue, 1950)
    }

    func testOldRefreshCannotOverwriteNewAccountScope() async throws {
        let suite = "AccountVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let loader = AccountVisibilityLoader(fixture())
        let model = AppModel(defaults: defaults, personalDocumentLoader: { await loader.load() })
        await model.refreshPortfolio(refreshMarketData: false)
        await loader.holdNextLoad()
        let refresh = Task { await model.refreshPortfolio(refreshMarketData: false) }
        await fulfillment(of: [loader.waiting], timeout: 2)
        await model.toggleAccount("CSV|B")
        await loader.release()
        await refresh.value
        XCTAssertEqual(model.selectedAccountKeys, ["CSV|A"])
        XCTAssertEqual(model.holdings.first?.shares, 10)
        XCTAssertEqual(model.overview?.summary.marketValue, 1500)
    }

    func testDetailQuoteAndDailyMoveSurviveScopeChanges() async throws {
        let suite = "AccountVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = fixture()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input })
        await model.refreshPortfolio(refreshMarketData: false)
        let now = Date()
        let history = SecurityPriceHistory(ticker: "SCOPE_TEST", currency: "USD",
            points: [.init(dateText: DayDateCodec.string(from: now.addingTimeInterval(-86400)), close: 150),
                     .init(dateText: DayDateCodec.string(from: now), close: 180)],
            intradayPoints: [.init(dateText: "minute", close: 180, timestamp: now)], trades: [])
        try model.publishSecurityPriceHistory(history, source: .personal, now: now)
        await model.toggleAccount("CSV|B")
        XCTAssertEqual(model.overview?.summary.marketValue, 1800)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["SCOPE_TEST"]), 20, accuracy: 0.0001)
        await model.selectAllAccounts()
        XCTAssertEqual(model.holdings.first?.shares, 13)
        XCTAssertEqual(model.overview?.summary.marketValue, 2340)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["SCOPE_TEST"]), 20, accuracy: 0.0001)
    }
}

private actor AccountVisibilityLoader {
    let input: LocalPortfolioDocument
    private(set) var count = 0
    private var shouldHold = false
    private var continuation: CheckedContinuation<Void, Never>?
    nonisolated let waiting = XCTestExpectation(description: "Old document load is waiting")
    init(_ input: LocalPortfolioDocument) { self.input = input }
    func holdNextLoad() { shouldHold = true }
    func load() async -> LocalPortfolioDocument {
        count += 1
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                waiting.fulfill()
            }
        }
        return input
    }
    func release() { continuation?.resume(); continuation = nil }
}

/// Choosing between your own portfolio, a public filer's, and invented data.
final class PublicInvestorSelectionTests: XCTestCase {

    @MainActor
    func testModeFlagsAndSelectionSwitchTogetherWithoutWaitingForRefresh() throws {
        let suite = "PortfolioModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        model.isPortfolioLoading = true
        model.setPortfolioMode(enabled: true, selection: "demo")
        XCTAssertTrue(model.isFakeDataMode)
        XCTAssertFalse(model.isPublicInvestorMode)
        XCTAssertEqual(model.publicInvestorSelection, "demo")
        XCTAssertTrue(defaults.bool(forKey: "catfolio.fakeDataMode"))

        model.setPortfolioMode(enabled: true, selection: "pelosi,hh")
        XCTAssertFalse(model.isFakeDataMode)
        XCTAssertTrue(model.isPublicInvestorMode)
        XCTAssertEqual(model.publicInvestorSelection, "hh,pelosi")
        let revision = model.portfolioChartRevision
        model.setPortfolioMode(enabled: true, selection: "pelosi,hh")
        XCTAssertEqual(model.portfolioChartRevision, revision, "same selection must not reload")

        model.setPortfolioMode(enabled: false, selection: "hh,pelosi")
        XCTAssertFalse(model.isFakeDataMode)
        XCTAssertFalse(model.isPublicInvestorMode)
        XCTAssertEqual(model.publicInvestorSelection, "hh,pelosi", "off remembers the selection")
        XCTAssertFalse(defaults.bool(forKey: PublicInvestorPreferences.enabledKey))
    }

    @MainActor
    func testDemoLoadsLocallyAndWarmSwitchRestoresItsPresentation() async throws {
        let suite = "PortfolioModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "catfolio.fakeDataMode")
        defaults.set("demo", forKey: PublicInvestorPreferences.selectionKey)
        let personalKeys = Data("personal-account-cache".utf8)
        defaults.set(personalKeys, forKey: "catfolio.selectedAccounts")
        let model = AppModel(defaults: defaults, personalDocumentLoader: {
            XCTFail("demo must not read or rebuild the personal portfolio")
            return .empty
        })
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertNil(model.portfolioError)
        XCTAssertFalse(model.holdings.isEmpty)
        XCTAssertEqual(model.accounts.count, 3)
        let count = model.holdings.count
        let value = model.overview?.summary.marketValue

        model.setPortfolioMode(enabled: false, selection: "demo")
        XCTAssertTrue(model.holdings.isEmpty, "never show demo holdings as the personal account")
        model.setPortfolioMode(enabled: true, selection: "demo")
        XCTAssertEqual(model.holdings.count, count, "warm snapshot is restored synchronously")
        XCTAssertEqual(model.overview?.summary.marketValue, value)
        XCTAssertEqual(defaults.data(forKey: "catfolio.selectedAccounts"), personalKeys)
    }

    @MainActor
    func testSupersededLoadCannotPublishOrStartAnotherMode() async throws {
        let suite = "PortfolioModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = PortfolioDocumentGate()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { await gate.load() })
        let old = Task { await model.refreshPortfolio(refreshMarketData: false) }
        await fulfillment(of: [gate.started], timeout: 2)
        model.setPortfolioMode(enabled: true, selection: "demo")
        model.setPortfolioMode(enabled: false, selection: "demo")
        await gate.release()
        await old.value
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.isFakeDataMode)
        XCTAssertFalse(model.isPublicInvestorMode)
        XCTAssertTrue(model.holdings.isEmpty, "the old nonempty load must not overwrite the new empty source")
    }

    func testSwitchBindingOnlyChangesSelectionWhenRequestedStateChanges() {
        XCTAssertEqual(PublicInvestorPreferences.setting("pelosi", isSelected: true, in: "pelosi,hh"), "pelosi,hh")
        XCTAssertEqual(PublicInvestorPreferences.setting("pelosi", isSelected: false, in: "hh"), "hh")
        XCTAssertEqual(PublicInvestorPreferences.setting("demo", isSelected: true, in: "demo"), "demo")
        XCTAssertEqual(PublicInvestorPreferences.setting("demo", isSelected: false, in: "pelosi"), "pelosi")
        XCTAssertEqual(PublicInvestorPreferences.setting("pelosi", isSelected: false, in: "pelosi"), "")
        XCTAssertEqual(PublicInvestorPreferences.setting("demo", isSelected: false, in: "demo"), "")
    }

    func testSwitchesKeepMultipleFilersButExcludeDemo() {
        let multiple = PublicInvestorPreferences.setting("hh", isSelected: true, in: "pelosi")
        XCTAssertEqual(PublicInvestorPreferences.selectedIDs(multiple), ["pelosi", "hh"])
        XCTAssertEqual(PublicInvestorPreferences.setting("demo", isSelected: true, in: multiple), "demo")
        XCTAssertEqual(PublicInvestorPreferences.setting("pelosi", isSelected: true, in: "demo"), "pelosi")
        XCTAssertEqual(PublicInvestorPreferences.setting("hh", isSelected: false, in: multiple), "pelosi")
    }

    @MainActor
    func testNativeMasterSwitchRemainsInteractiveWhilePortfolioIsLoading() async throws {
        let suite = "PortfolioModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("demo", forKey: PublicInvestorPreferences.selectionKey)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        model.isPortfolioLoading = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView: NavigationStack {
            SettingsPage { PublicInvestorSettingsSection() }
        }.environment(model).defaultAppStorage(defaults))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(350))
        let control = try XCTUnwrap(nativeSwitches(in: controller.view).first)
        XCTAssertTrue(control.isEnabled)
        control.setOn(true, animated: false)
        control.sendActions(for: .valueChanged)
        XCTAssertTrue(model.isFakeDataMode, "native toggle must activate demo synchronously")
        XCTAssertFalse(model.isPublicInvestorMode)
        control.setOn(false, animated: false)
        control.sendActions(for: .valueChanged)
        XCTAssertFalse(model.isFakeDataMode, "turning off must not wait for a portfolio refresh")
        XCTAssertFalse(model.isPublicInvestorMode)
    }

    @MainActor
    func testSelectionPageUsesNativeSwitchesInBothAppearances() async throws {
        let suite = "PublicInvestorSwitchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = try PublicInvestorCatalog.loaded.get()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)

        for (scheme, selection) in [(ColorScheme.light, "pelosi,hh"), (.dark, "demo")] {
            defaults.set(selection, forKey: PublicInvestorPreferences.selectionKey)
            let controller = UIHostingController(rootView: NavigationStack {
                PublicInvestorSelectionView()
            }
            .environment(AppModel())
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, scheme))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(350))

            let switches = nativeSwitches(in: controller.view).sorted {
                $0.convert(.zero, to: controller.view).y < $1.convert(.zero, to: controller.view).y
            }
            XCTAssertEqual(switches.count, catalog.investors.count + 1)
            let ids = [PublicInvestorPreferences.demoID] + catalog.investors.map(\.id)
            for (control, id) in zip(switches, ids) {
                XCTAssertEqual(control.isOn, PublicInvestorPreferences.selectedIDs(selection).contains(id), id)
                XCTAssertTrue(control.isEnabled, id)
            }
        }
    }

    @MainActor
    private func nativeSwitches(in view: UIView) -> [UISwitch] {
        if let control = view as? UISwitch { return [control] }
        return view.subviews.flatMap { nativeSwitches(in: $0) }
    }

    /// Invented data and disclosed data must never be blended. A total mixing
    /// a fabricated company with someone's real 13F describes nothing.
    func testChoosingDemoClearsTheFilers() {
        let next = PublicInvestorPreferences.selecting(
            PublicInvestorPreferences.demoID, in: "pelosi,berkshire"
        )
        XCTAssertEqual(next, PublicInvestorPreferences.demoID)
        XCTAssertTrue(PublicInvestorPreferences.isDemo(next))
    }

    func testChoosingAFilerClearsTheDemo() {
        let next = PublicInvestorPreferences.selecting(
            "berkshire", in: PublicInvestorPreferences.demoID
        )
        XCTAssertEqual(PublicInvestorPreferences.selectedIDs(next), ["berkshire"])
        XCTAssertFalse(PublicInvestorPreferences.isDemo(next))
    }

    /// Choosing the demo while it is already chosen turns it off. Without
    /// this the row switched on and never off: the result equalled the
    /// current value, so the caller's change check swallowed it.
    func testChoosingDemoAgainTurnsItOff() {
        let next = PublicInvestorPreferences.selecting(
            PublicInvestorPreferences.demoID, in: PublicInvestorPreferences.demoID
        )
        XCTAssertEqual(next, "")
        XCTAssertFalse(PublicInvestorPreferences.isDemo(next))
        XCTAssertTrue(PublicInvestorPreferences.selectedIDs(next).isEmpty)
    }

    /// Turning off the last filer also leaves nothing selected, which is how
    /// the reader gets back to their own portfolio.
    func testTurningOffTheLastFilerClearsTheSelection() {
        XCTAssertTrue(
            PublicInvestorPreferences.selectedIDs(
                PublicInvestorPreferences.selecting("pelosi", in: "pelosi")
            ).isEmpty
        )
    }

    /// Filers still combine with each other; only the demo is exclusive.
    func testFilersStillCombine() {
        var selection = PublicInvestorPreferences.selecting("pelosi", in: "")
        selection = PublicInvestorPreferences.selecting("berkshire", in: selection)
        XCTAssertEqual(PublicInvestorPreferences.selectedIDs(selection), ["pelosi", "berkshire"])
    }

    func testSelectingAChosenFilerRemovesIt() {
        let selection = PublicInvestorPreferences.selecting("pelosi", in: "pelosi,berkshire")
        XCTAssertEqual(PublicInvestorPreferences.selectedIDs(selection), ["berkshire"])
    }

    /// The demo is not a filer. It is app-provided, and putting it in the
    /// catalogue would mean a fabricated company in a file generated from SEC
    /// and House disclosures.
    func testTheDemoIsNotInTheDisclosureCatalogue() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        XCTAssertFalse(
            catalog.investors.contains { $0.id == PublicInvestorPreferences.demoID },
            "the invented portfolio must not appear in the disclosure catalogue"
        )
    }

    /// A demo selection is only ever exactly the demo, so a stale multi-select
    /// carried over from an older build cannot read as one.
    func testAMixedSelectionIsNotTreatedAsDemo() {
        XCTAssertFalse(PublicInvestorPreferences.isDemo("demo,pelosi"))
        XCTAssertFalse(PublicInvestorPreferences.isDemo(""))
    }

    /// The demo's own state stays off every device but this one — the same
    /// guarantee as before the two modes were merged into one control.
    func testNeitherModeSyncsToICloud() {
        XCTAssertFalse(CloudPreferences.synchronised.contains("catfolio.fakeDataMode"))
        XCTAssertFalse(CloudPreferences.synchronised.contains(PublicInvestorPreferences.enabledKey))
        XCTAssertFalse(CloudPreferences.synchronised.contains(PublicInvestorPreferences.selectionKey))
    }
}

private actor PortfolioDocumentGate {
    nonisolated let started = XCTestExpectation(description: "old personal load started")
    private var continuation: CheckedContinuation<LocalPortfolioDocument, Never>?
    private var requests = 0

    func load() async -> LocalPortfolioDocument {
        requests += 1
        guard requests == 1 else { return .empty }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume(returning: FakePortfolioGenerator.make())
        continuation = nil
    }
}

final class PublicInvestorCacheTests: XCTestCase {
    private func fixture() throws -> PublicInvestorCatalog {
        try PublicInvestorCatalog.decode(Data(#"""
        {"schemaVersion":1,"releaseId":"cache-test","asOf":"2023-01-04","investors":[
          {"investorId":"hh","displayName":"H&H","managerName":"H&H","sourceType":"SEC_13F","portfolioSource":"PUBLIC_DISCLOSURE","snapshot":null,"activities":[],"history":[
            {"snapshotId":"q1","effectiveDate":"2022-12-31","filedDate":"2023-01-03","currency":"USD","sourceURL":"https://example.test/1","confidence":"VERIFIED","completeReport":true,"positions":[{"positionId":"1","ticker":"TEST","shares":10,"confidence":"VERIFIED"}]}
          ]}
        ]}
        """#.utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InvestorCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testColdAndConcurrentRequestsAreCoalescedAndFreshDataDoesNotRefetch() async throws {
        let catalog = try fixture()
        let probe = InvestorHistoryGate()
        let store = PublicInvestorSimulationStore(directory: try temporaryDirectory(), histories: { _, _ in await probe.load() })
        let first = Task { try await store.load(catalog: catalog, selection: "hh") }
        await fulfillment(of: [probe.started], timeout: 2)
        let second = Task { try await store.load(catalog: catalog, selection: "hh") }
        try await Task.sleep(for: .milliseconds(40))
        let count = await probe.count
        XCTAssertEqual(count, 1)
        await probe.release()
        let firstDocument = try await first.value
        let secondDocument = try await second.value
        XCTAssertEqual(firstDocument.positions.first?.shares, 10)
        XCTAssertEqual(secondDocument.positions.first?.shares, 10)
        let update = try await store.refreshIfNeeded(catalog: catalog, selection: "hh")
        XCTAssertNil(update)
        let finalCount = await probe.count
        XCTAssertEqual(finalCount, 1)
    }

    func testRelaunchReadsDiskBeforeNetworkAndFailedRefreshPreservesEveryCache() async throws {
        let directory = try temporaryDirectory()
        let catalog = try fixture()
        let original = PublicInvestorSimulationStore(directory: directory, histories: { _, _ in
            ["TEST": ["2023-01-03": 10, "2023-01-04": 11]]
        })
        let document = try await original.load(catalog: catalog, selection: "hh")
        let file = directory.appendingPathComponent("v2-cache-test-hh.json")
        let oldData = try Data(contentsOf: file)
        // Sentinels stand for other accounts and shared public-data caches.
        let other = directory.appendingPathComponent("other-account.json")
        let shared = directory.appendingPathComponent("shared-market-history.json")
        try Data("other cached data".utf8).write(to: other)
        try Data("shared cached data".utf8).write(to: shared)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path)
        let probe = InvestorHistoryGate(result: [:])
        let relaunched = PublicInvestorSimulationStore(directory: directory, histories: { _, _ in await probe.load() })
        let cached = try await relaunched.load(catalog: catalog, selection: "hh")
        XCTAssertEqual(cached.positions.first?.shares, document.positions.first?.shares)
        let initialCount = await probe.count
        XCTAssertEqual(initialCount, 0, "disk presentation must not wait for a vendor")

        let refresh = Task { try await relaunched.refreshIfNeeded(catalog: catalog, selection: "hh") }
        await fulfillment(of: [probe.started], timeout: 2)
        let duringRefresh = try await relaunched.load(catalog: catalog, selection: "hh")
        XCTAssertEqual(duringRefresh.positions.first?.shares, 10)
        await probe.release()
        let fallback = try await refresh.value
        XCTAssertEqual(fallback?.positions.first?.shares, 10)
        XCTAssertEqual(try Data(contentsOf: file), oldData)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "other cached data")
        XCTAssertEqual(try String(contentsOf: shared, encoding: .utf8), "shared cached data")
        let retry = try await relaunched.refreshIfNeeded(catalog: catalog, selection: "hh")
        XCTAssertNil(retry, "repeated toggles must not keep retrying a failed request")
        let count = await probe.count
        XCTAssertEqual(count, 1)
    }
}

private actor InvestorHistoryGate {
    nonisolated let started = XCTestExpectation(description: "history request started")
    private(set) var count = 0
    private var continuation: CheckedContinuation<[String: [String: Double]], Never>?
    private let result: [String: [String: Double]]

    init(result: [String: [String: Double]] = ["TEST": ["2023-01-03": 10, "2023-01-04": 11]]) {
        self.result = result
    }

    func load() async -> [String: [String: Double]] {
        count += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
