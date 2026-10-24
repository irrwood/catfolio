import SwiftUI
import UIKit
import XCTest
import Observation
@testable import CatfolioIOS

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    func testSecurityAIStaysInsideDetailAndReturnsToTheSameStock() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let probe = WorkspaceProbe()
        let host = UIHostingController(rootView: WorkspaceFixture(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await waitUntil { self.detailNavigation(host)?.topViewController?.navigationItem.title == "AAPL" }
        let split = try XCTUnwrap(controllers(host).compactMap { $0 as? UISplitViewController }.first)
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        let navigation = try XCTUnwrap(detailNavigation(host))
        let root = try XCTUnwrap(navigation.topViewController)
        for _ in 0..<2 {
            probe.paper = SecurityPaperRequest(context: SecurityPriceMoveContext(
                ticker: "AAPL", name: "Apple", currency: "USD", rangeLabel: "1D",
                startDate: Date(timeIntervalSince1970: 1788912000),
                endDate: Date(timeIntervalSince1970: 1788998400),
                startPrice: 100, endPrice: 105, isIntraday: false))
            try await waitUntil { navigation.viewControllers.count == 2 }
            try await settled(navigation)
            XCTAssertEqual(navigation.topViewController?.navigationItem.title, L10n.text("AI 解读"))
            XCTAssertTrue(controllers(host).allSatisfy { $0.presentedViewController == nil },
                          "AI must push in the detail column, never present a cover")
            XCTAssertTrue(split.viewController(for: .primary) === sidebar)
            XCTAssertFalse(sidebar.view.isHidden)
            XCTAssertFalse(split.isCollapsed)
            let detail = try XCTUnwrap(split.viewController(for: .secondary))
            XCTAssertTrue(controllers(detail).contains { $0 === navigation },
                          "AI must belong to the split view's detail column")
            assertSystemBack(in: navigation)
            assertNativeToolbar(sidebar: sidebar, detail: navigation)
            try capture(window, name: "workspace-ai-detail")
            navigation.popViewController(animated: false)
            try await waitUntil { probe.paper == nil }
            XCTAssertTrue(navigation.topViewController === root)
        }
    }

    func testReadingPagesPushAndPopInDetailWithoutReplacingSidebar() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let probe = WorkspaceProbe()
        let host = UIHostingController(rootView: WorkspaceFixture(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await waitUntil { self.controllers(host).contains { $0 is UISplitViewController } }
        let split = try XCTUnwrap(controllers(host).compactMap { $0 as? UISplitViewController }.first)
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        try await waitUntil { self.detailNavigation(host)?.topViewController?.navigationItem.title == "AAPL" }
        let navigation = try XCTUnwrap(detailNavigation(host))
        let rootCount = navigation.viewControllers.count
        try await settled(navigation)
        assertNativeToolbar(sidebar: sidebar, detail: navigation)

        probe.child = true
        try await waitUntil { navigation.viewControllers.count == rootCount + 1 }
        XCTAssertNil(host.presentedViewController)
        XCTAssertTrue(split.viewController(for: .primary) === sidebar)
        try await waitUntil { navigation.topViewController?.navigationItem.title == "Research" }
        try await settled(navigation)
        assertSystemBack(in: navigation)

        XCTAssertTrue(probe.isWorkspace)
        XCTAssertNotNil(probe.column)
        probe.source = WorkspaceProbe.Source(id: "filing")
        try await waitUntil { navigation.viewControllers.count == rootCount + 2 }
        XCTAssertNil(navigation.presentedViewController)
        try await waitUntil { navigation.topViewController?.navigationItem.title == "Source" }
        try await settled(navigation)
        assertSystemBack(in: navigation)
        assertNativeToolbar(sidebar: sidebar, detail: navigation)
        try capture(window, name: "workspace-nested-source")
        navigation.popViewController(animated: false)
        try await waitUntil { probe.source == nil }
        XCTAssertTrue(probe.child)
        XCTAssertEqual(navigation.topViewController?.navigationItem.title, "Research")
        XCTAssertEqual(probe.sourceDismissals, 1)
        try await settled(navigation)

        navigation.popViewController(animated: false)
        try await waitUntil { !probe.child }
        XCTAssertEqual(probe.childDismissals, 1)
        try await settled(navigation)
        XCTAssertEqual(navigation.topViewController?.navigationItem.title, "AAPL")
        XCTAssertTrue(split.viewController(for: .primary) === sidebar)

        // A new sidebar root clears the previous security's navigation.
        probe.child = true
        try await waitUntil { navigation.viewControllers.count == rootCount + 1 }
        probe.child = false
        probe.selection = "MSFT"
        try await waitUntil { self.detailNavigation(host)?.topViewController?.navigationItem.title == "MSFT" }
        let replacement = try XCTUnwrap(detailNavigation(host))
        XCTAssertEqual(replacement.viewControllers.count, rootCount)
        XCTAssertTrue(split.viewController(for: .primary) === sidebar)
    }

    func testProgrammaticSecurityPushUsesTheSameNativeStack() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let probe = WorkspaceProbe()
        let host = UIHostingController(rootView: WorkspaceDetailStack {
            Text("Overview").navigationTitle("Overview")
                .background(WorkspaceRouterProbe(probe: probe))
        })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await waitUntil { probe.column != nil }
        let navigation = try XCTUnwrap(controllers(host).compactMap { $0 as? UINavigationController }.first)
        try await settled(navigation)
        probe.column?.open(AnyView(Text("AAPL").navigationTitle("AAPL")))
        try await waitUntil { navigation.viewControllers.count == 2 }
        try await settled(navigation)
        assertSystemBack(in: navigation)
        navigation.popViewController(animated: false)
        try await waitUntil { navigation.viewControllers.count == 1 }
        try await settled(navigation)
        probe.column?.open(AnyView(Text("MSFT").navigationTitle("MSFT")))
        try await waitUntil { navigation.topViewController?.navigationItem.title == "MSFT" }
        XCTAssertEqual(navigation.viewControllers.count, 2)
        try await settled(navigation)
        probe.column?.close()
        try await waitUntil { navigation.viewControllers.count == 1 }
    }

    func testRealWorkspaceSearchesAndSortsTheCompleteSidebarList() async throws {
        let suite = "WorkspaceNavigationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppModel.fakeDataModeKey)
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        defaults.set(HoldingSortField.marketValue.rawValue, forKey: "portfolio.holdings.sortField")
        defaults.set(false, forKey: "portfolio.holdings.sortAscending")
        let document = FakePortfolioGenerator.make()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { document })
        await model.refreshPortfolio(refreshMarketData: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NativeWorkspace(tab: .constant(.portfolio),
            presentationPreferencesID: "test", trading212SetupStore: .shared)
            .environment(model).defaultAppStorage(defaults))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await waitUntil { self.controllers(host).contains { $0 is UISplitViewController } }
        let splits = controllers(host).compactMap { $0 as? UISplitViewController }
        XCTAssertEqual(splits.count, 1)
        XCTAssertFalse(controllers(host).contains { $0 is UITabBarController })
        let sidebar = try XCTUnwrap(splits[0].viewController(for: .primary))
        let list = try XCTUnwrap(descendants(sidebar.view).compactMap { $0 as? UICollectionView }.first)
        try await waitUntil { list.numberOfSections >= 2 && list.numberOfItems(inSection: 1) == model.holdings.count }
        XCTAssertEqual(list.numberOfItems(inSection: 0), RootDestination.sidebarCases.count)
        XCTAssertGreaterThan(model.holdings.count, 0)
        if MacPlatform.isMac {
            list.layoutIfNeeded()
            let header = try XCTUnwrap(list.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 1)))
            let buttonFrames = descendants(header).compactMap { $0 as? UIButton }
                .map { $0.convert($0.bounds, to: list) }.sorted { $0.minX < $1.minX }
            let titleFrame = try XCTUnwrap(buttonFrames.first)
            let filterFrame = try XCTUnwrap(buttonFrames.last)
            let cell = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 0, section: 1)))
            let rowContent = cell.contentView.convert(cell.contentView.layoutMarginsGuide.layoutFrame, to: list)
            XCTAssertEqual(titleFrame.minX, rowContent.minX, accuracy: 1,
                           "The holdings title must share the rows' leading edge")
            XCTAssertEqual(filterFrame.maxX, rowContent.maxX, accuracy: 1,
                           "The sort button must share the amounts' trailing edge")
            XCTAssertEqual(filterFrame.width, 44, accuracy: 1)
            XCTAssertEqual(filterFrame.height, 44, accuracy: 1)
        }
        let holding = try XCTUnwrap(model.holdings.max(by: { $0.marketValue < $1.marketValue }))
        let search = try XCTUnwrap(descendants(sidebar.view).compactMap { $0 as? UISearchBar }.first)
        XCTAssertTrue(search.searchTextField.placeholder?.contains("ETF") == true)
        XCTAssertFalse(search.isHidden)
        XCTAssertNotNil(search.window)
        if MacPlatform.isMac {
            list.layoutIfNeeded()
            let firstTab = try XCTUnwrap(list.cellForItem(at: IndexPath(item: 0, section: 0)))
            let searchFrame = search.searchTextField.convert(search.searchTextField.bounds, to: sidebar.view)
            let tabFrame = firstTab.convert(firstTab.bounds, to: sidebar.view)
            XCTAssertGreaterThanOrEqual(tabFrame.minY - searchFrame.maxY, 15.5,
                                       "Search and the first tab need at least 16 points of separation")
        }
        search.searchTextField.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThanOrEqual(list.numberOfSections, 2)
        XCTAssertEqual(list.numberOfItems(inSection: 0), RootDestination.sidebarCases.count,
                       "Focusing an empty search field must keep the tabs visible")
        search.text = "   "
        search.delegate?.searchBar?(search, textDidChange: "   ")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(list.numberOfItems(inSection: 0), RootDestination.sidebarCases.count,
                       "Whitespace alone must not hide the tabs")
        let detail = try XCTUnwrap(splits[0].viewController(for: .secondary))
        XCTAssertFalse(descendants(detail.view).contains { $0.accessibilityIdentifier == "portfolio-inline-filter" },
                       "The overview must not duplicate the sidebar holdings controls")
        search.text = holding.ticker.lowercased()
        search.delegate?.searchBar?(search, textDidChange: search.text ?? "")
        let catalog = try CompanyReferenceCatalog.bundled.get()
        let heldResults = MarketSecurityResult.search(holding.ticker, in: catalog, limit: 16)
        let heldRows = MarketSecurityResult.includingHoldings(Array(heldResults.prefix(15)),
                                                             holdings: model.holdings, query: holding.ticker)
        try await waitUntil { list.numberOfSections == 1 && list.numberOfItems(inSection: 0) == heldRows.count + (heldResults.count > 15 ? 1 : 0) }
        XCTAssertEqual(list.numberOfSections, 1, "Search results replace the tabs section")
        let index = IndexPath(item: 0, section: 0)
        list.selectItem(at: index, animated: false, scrollPosition: [])
        list.delegate?.collectionView?(list, didSelectItemAt: index)
        try await assertHoldingTitleTracksScroll(holding.ticker, in: host)
        XCTAssertFalse(search.searchTextField.isFirstResponder,
                       "Selecting a result releases search focus")
        XCTAssertEqual(search.text, holding.ticker.lowercased(), "Ending editing keeps the query and results")
        let navigation = try XCTUnwrap(detailNavigation(host))
        XCTAssertEqual(navigation.viewControllers.count, 1)
        XCTAssertNil(host.presentedViewController)
        XCTAssertEqual(navigation.topViewController?.navigationItem.title, "")
        let item = try XCTUnwrap(navigation.topViewController?.navigationItem)
        let toolbarItems = (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
        XCTAssertGreaterThanOrEqual(Set(toolbarItems.map(ObjectIdentifier.init)).count, 2)
        #if targetEnvironment(macCatalyst)
        let toolbarIDs = Set(toolbarItems.compactMap(\.accessibilityIdentifier))
        XCTAssertTrue(toolbarIDs.contains("holding-detail-why-move"))
        XCTAssertTrue(toolbarIDs.contains("holding-detail-watchlist"))
        #endif
        try capture(window, name: "workspace-holding-search")
        // The same field can open a fund that is absent from the portfolio.
        let fund = try XCTUnwrap(["SCHD", "VTI", "QQQ", "SPY"].first { ticker in
            !model.holdings.contains { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
        })
        search.searchTextField.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(350))
        search.text = fund
        search.delegate?.searchBar?(search, textDidChange: fund)
        // Allow the debounced directory lookup and List's row replacement to
        // settle; a single loading row has the same count as one exact match.
        try await Task.sleep(for: .milliseconds(650))
        let fundResults = MarketSecurityResult.search(fund, in: catalog, limit: 16)
        let fundRows = MarketSecurityResult.includingHoldings(Array(fundResults.prefix(15)),
                                                             holdings: model.holdings, query: fund)
        try await waitUntil { list.numberOfSections == 1 && list.numberOfItems(inSection: 0) == fundRows.count + (fundResults.count > 15 ? 1 : 0) }
        let fundIndex = IndexPath(item: try XCTUnwrap(fundRows.firstIndex { $0.ticker == fund }), section: 0)
        list.selectItem(at: fundIndex, animated: false, scrollPosition: [])
        list.delegate?.collectionView?(list, didSelectItemAt: fundIndex)
        try await assertHoldingTitleTracksScroll(fund, in: host)
        XCTAssertFalse(search.searchTextField.isFirstResponder)
        XCTAssertEqual(search.text, fund)
        XCTAssertNil(host.presentedViewController)
        XCTAssertEqual(self.detailNavigation(host)?.viewControllers.count, 1)
        try capture(window, name: "workspace-unheld-etf-search")
        search.searchTextField.becomeFirstResponder()
        search.text = ""
        search.delegate?.searchBar?(search, textDidChange: "")
        try await waitUntil { list.numberOfSections >= 2 && list.numberOfItems(inSection: 1) == model.holdings.count }
        XCTAssertEqual(list.numberOfItems(inSection: 0), RootDestination.sidebarCases.count, "Clearing the query restores navigation")
        defaults.set(HoldingSortField.name.rawValue, forKey: "portfolio.holdings.sortField")
        defaults.set(true, forKey: "portfolio.holdings.sortAscending")
        // AppStorage updates the same shared sort used by the phone list.
        try await Task.sleep(for: .milliseconds(500))
        let sorted = PortfolioHoldingListItem.sorted(PortfolioHoldingListItem.make(holdings: model.holdings,
            period: .holdingPeriod, dailyChanges: [:]), by: .name, ascending: true)
        let first = try XCTUnwrap(sorted.first)
        let restoredIndex = IndexPath(item: 0, section: 1)
        list.selectItem(at: restoredIndex, animated: false, scrollPosition: [])
        list.delegate?.collectionView?(list, didSelectItemAt: restoredIndex)
        try await assertHoldingTitleTracksScroll(first.ticker, in: host)
        XCTAssertFalse(search.searchTextField.isFirstResponder,
                       "Selecting a holding releases an empty search field")
        try capture(window, name: "workspace-holding")
        let overview = IndexPath(item: 0, section: 0)
        search.searchTextField.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(100))
        list.selectItem(at: overview, animated: false, scrollPosition: [])
        list.delegate?.collectionView?(list, didSelectItemAt: overview)
        try await waitUntil { !search.searchTextField.isFirstResponder }
        try await waitUntil { self.detailNavigation(host)?.topViewController?.navigationItem.title == RootDestination.portfolio.title }
        #if targetEnvironment(macCatalyst)
        XCTAssertEqual(scene.titlebar?.titleVisibility, .visible)
        #endif
    }

    func testEverySidebarTabUsesTheSystemToolbar() async throws {
        let suite = "WorkspaceTabs.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppModel.fakeDataModeKey)
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { FakePortfolioGenerator.make() })
        await model.refreshPortfolio(refreshMarketData: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NativeWorkspace(tab: .constant(.portfolio),
            presentationPreferencesID: "toolbar-test", trading212SetupStore: .shared)
            .environment(model).defaultAppStorage(defaults))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await waitUntil { self.controllers(host).contains { $0 is UISplitViewController } }
        let split = try XCTUnwrap(controllers(host).compactMap { $0 as? UISplitViewController }.first)
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        let list = try XCTUnwrap(descendants(sidebar.view).compactMap { $0 as? UICollectionView }.first)
        for (index, destination) in RootDestination.sidebarCases.enumerated() {
            let row = IndexPath(item: index, section: 0)
            list.selectItem(at: row, animated: false, scrollPosition: [])
            list.delegate?.collectionView?(list, didSelectItemAt: row)
            try await waitUntil { self.detailNavigation(host)?.topViewController?.navigationItem.title == destination.title }
            let navigation = try XCTUnwrap(detailNavigation(host))
            try await settled(navigation)
            XCTAssertEqual(navigation.viewControllers.count, 1, "\(destination)")
            XCTAssertFalse(navigation.isNavigationBarHidden, "\(destination)")
            XCTAssertEqual(navigation.topViewController?.navigationItem.largeTitleDisplayMode, .always, "\(destination)")
            XCTAssertTrue(navigation.navigationBar.prefersLargeTitles, "\(destination)")
            assertNativeToolbar(sidebar: sidebar, detail: navigation)
            #if !targetEnvironment(macCatalyst)
            _ = try RootTabTitleTestSupport.frame(title: destination.title, window: window)
            #endif
            try capture(window, name: "workspace-large-title-\(destination)")
        }
        try capture(window, name: "workspace-system-tab-toolbar")
    }

    func testRealSubpagesKeepSystemTitlesAndBackButtons() async throws {
        let suite = "WorkspaceSubpages.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppModel.fakeDataModeKey)
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { FakePortfolioGenerator.make() })
        await model.refreshPortfolio(refreshMarketData: false)
        let probe = WorkspaceProbe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: WorkspaceSplitView {
            List { Text("Holdings") }
        } detail: {
            WorkspaceDetailStack {
                Text("Overview").navigationTitle("Overview")
                    .background(WorkspaceRouterProbe(probe: probe))
            }
        }.environment(model).defaultAppStorage(defaults))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await waitUntil { probe.column != nil }
        let split = try XCTUnwrap(controllers(host).compactMap { $0 as? UISplitViewController }.first)
        let sidebar = try XCTUnwrap(split.viewController(for: .primary))
        let navigation = try XCTUnwrap(detailNavigation(host))
        let pages: [(String, () -> AnyView)] = [
            ("comparison", { AnyView(ReturnsChartPage(chart: .comparison)) }),
            ("contributors", { AnyView(ReturnsChartPage(chart: .contributors)) }),
            ("losses", { AnyView(ReturnsChartPage(chart: .losses)) }),
            ("history", { AnyView(HistoryView()) }),
            ("sector-rotation", { AnyView(SectorRotationView()) }),
            ("market-rotation", { AnyView(StockChartsRotationView()) }),
            ("industry-sentiment", { AnyView(IndustrySentimentView()) }),
            ("dca", { AnyView(DCACalculatorView()) }),
            ("services", { AnyView(LocalServicesSettingsView()) }),
            ("news", { AnyView(NewsSettingsView()) }),
            ("account-guide", { AnyView(IBKRGuideHelpView()) }),
            ("account-guide-step-2", { AnyView(IBKRGuideHelpView(initialStep: 1)) }),
            ("account-guide-step-3", { AnyView(IBKRGuideHelpView(initialStep: 2)) })
        ]
        for (name, page) in pages {
            probe.column?.open(page())
            try await waitUntil { navigation.viewControllers.count == 2 }
            try await settled(navigation)
            XCTAssertFalse(navigation.topViewController?.navigationItem.title?.isEmpty ?? true, name)
            XCTAssertEqual(navigation.topViewController?.navigationItem.largeTitleDisplayMode, .never, name)
            assertSystemBack(in: navigation)
            assertNativeToolbar(sidebar: sidebar, detail: navigation)
            XCTAssertTrue(split.viewController(for: .primary) === sidebar, name)
            XCTAssertNil(host.presentedViewController, name)
            navigation.popViewController(animated: false)
            try await waitUntil { navigation.viewControllers.count == 1 }
            try await settled(navigation)
        }
    }

    func testNativeLinksCarryWorkspaceChromeIntoComparison() async throws {
        let suite = "WorkspaceLink.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppModel.fakeDataModeKey)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { FakePortfolioGenerator.make() })
        let probe = WorkspaceProbe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: WorkspaceComparisonLinkFixture(probe: probe).environment(model)
            .defaultAppStorage(defaults))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await waitUntil { self.detailNavigation(host) != nil }
        let navigation = try XCTUnwrap(detailNavigation(host))
        try await settled(navigation)
        probe.nativeChild = true
        try await waitUntil { navigation.viewControllers.count == 2 }
        try await settled(navigation)
        XCTAssertTrue(probe.isWorkspace, "A native link must keep the split view's workspace environment")
        XCTAssertEqual(navigation.topViewController?.navigationItem.title, ReturnsChartDestination.comparison.title)
        assertSystemBack(in: navigation)
        let split = try XCTUnwrap(controllers(host).compactMap { $0 as? UISplitViewController }.first)
        assertNativeToolbar(sidebar: try XCTUnwrap(split.viewController(for: .primary)), detail: navigation)
        try capture(window, name: "workspace-native-comparison-toolbar")
        navigation.popViewController(animated: false)
        try await waitUntil { !probe.nativeChild }
    }

    private func settled(_ navigation: UINavigationController) async throws {
        // A navigation item is installed before UIKit finishes its push.
        // Wait for the visible destination before interacting with its controls.
        try await Task.sleep(for: .milliseconds(650))
        try await waitUntil {
            navigation.transitionCoordinator == nil && navigation.visibleViewController === navigation.topViewController
        }
    }

    private func assertSystemBack(in navigation: UINavigationController) {
        XCTAssertFalse(navigation.isNavigationBarHidden)
        XCTAssertFalse(navigation.topViewController?.navigationItem.hidesBackButton ?? true)
        XCTAssertNotNil(navigation.navigationBar.backItem)
        XCTAssertFalse(controllers(navigation).contains { $0 !== navigation && $0 is UINavigationController },
                       "A pushed reader must reuse the detail navigation controller")
        let items = navigation.topViewController?.navigationItem.leftBarButtonItems ?? []
        XCTAssertFalse(items.contains { $0.accessibilityIdentifier == "holding-modal-close" })
    }

    private func assertNativeToolbar(sidebar: UIViewController, detail: UINavigationController) {
        #if targetEnvironment(macCatalyst)
        // Mac idiom lets UIKit place both navigation bars in the same AppKit
        // toolbar, instead of stacking an iPad bar below the window title bar.
        XCTAssertEqual(detail.traitCollection.userInterfaceIdiom, .mac)
        let primary = controllers(sidebar).compactMap { $0 as? UINavigationController }.first
        XCTAssertEqual(primary?.navigationBar.currentNSToolbarSection, .sidebar)
        XCTAssertEqual(detail.navigationBar.currentNSToolbarSection, .content)
        #endif
    }

    private func assertHoldingTitleTracksScroll(_ ticker: String, in host: UIViewController) async throws {
        // Selection replaces the detail stack. Let its native scroll view attach
        // before testing both ends of the title transition on the real page.
        try await Task.sleep(for: .milliseconds(650))
        let navigation = try XCTUnwrap(detailNavigation(host))
        let item = try XCTUnwrap(navigation.topViewController?.navigationItem)
        XCTAssertEqual(item.title, "", "The security identity is already visible in its header")
        #if targetEnvironment(macCatalyst)
        XCTAssertEqual(navigation.view.window?.windowScene?.titlebar?.titleVisibility, .hidden)
        #endif
        let scroll = try XCTUnwrap(navigation.topViewController?.contentScrollView(for: .top))
        scroll.setContentOffset(CGPoint(x: 0, y: 180 - scroll.adjustedContentInset.top), animated: false)
        try await waitUntil { item.title == ticker }
        XCTAssertEqual(item.title, ticker, "Scrolled security title for \(ticker)")
        #if targetEnvironment(macCatalyst)
        XCTAssertEqual(navigation.view.window?.windowScene?.titlebar?.titleVisibility, .visible)
        #endif
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        try await waitUntil { item.title == "" }
        #if targetEnvironment(macCatalyst)
        XCTAssertEqual(navigation.view.window?.windowScene?.titlebar?.titleVisibility, .hidden)
        #endif
    }

    private func detailNavigation(_ host: UIViewController) -> UINavigationController? {
        controllers(host).compactMap { $0 as? UINavigationController }.last
    }

    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<160 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Workspace navigation must settle", file: file, line: line)
    }

    private func capture(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
}

@MainActor @Observable
private final class WorkspaceProbe {
    struct Source: Identifiable { let id: String }
    var selection: String? = "AAPL"
    var child = false
    var nativeChild = false
    var source: Source?
    var paper: SecurityPaperRequest?
    var childDismissals = 0
    var sourceDismissals = 0
    var column: MacDetailColumn?
    var isWorkspace = false
}

private struct WorkspaceFixture: View {
    @Bindable var probe: WorkspaceProbe
    private let paperStore = SecurityDailyMoveStore { _ in
        SecurityDailyMoveNote(text: "The company's latest report explains the price movement.", sources: [])
    }
    var body: some View {
        WorkspaceSplitView {
            List(selection: $probe.selection) {
                Section("Pages") { Text("Overview") }
                Section("Holdings") {
                    NavigationLink("AAPL", value: "AAPL")
                    NavigationLink("MSFT", value: "MSFT")
                }
            }.listStyle(.sidebar)
        } detail: {
            WorkspaceDetailStack {
                ScrollView {
                    HoldingDetailChildPageCard(title: "Research", subtitle: "Open research",
                                              isPresented: $probe.child,
                                              onDismiss: { probe.childDismissals += 1 }) {
                        Text("Research content")
                            .background(WorkspaceRouterProbe(probe: probe))
                            .workspacePage(item: $probe.source, onDismiss: { probe.sourceDismissals += 1 }) { _ in
                                HoldingDetailChildPage(title: "Source") { Text("Source content") }
                            }
                    }
                }.navigationTitle(probe.selection ?? "Overview")
                    .securityPaper(item: $probe.paper) { request in
                        SecurityDailyMovePaper(context: request.context, store: paperStore)
                    }
            }.id(probe.selection)
        }
    }
}

private struct WorkspaceRouterProbe: View {
    @Environment(\.macDetailColumn) private var column
    @Environment(\.isWorkspaceDetail) private var isWorkspace
    let probe: WorkspaceProbe
    var body: some View { Color.clear.onAppear { probe.column = column; probe.isWorkspace = isWorkspace } }
}

private struct WorkspaceComparisonLinkFixture: View {
    @Bindable var probe: WorkspaceProbe
    var body: some View {
        WorkspaceSplitView {
            List { Text("Holdings") }
        } detail: {
            WorkspaceDetailStack {
                NavigationLink(isActive: $probe.nativeChild) {
                    ReturnsChartPage(chart: .comparison)
                        .background(WorkspaceRouterProbe(probe: probe))
                } label: { Text("Comparison") }
                .navigationTitle("Overview")
            }
        }
    }
}
