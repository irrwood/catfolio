import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SecurityDetailLiveZoomTests: XCTestCase {
    func testHiddenNavigationBarKeepsNativeBackswipeAvailable() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Content backswipe requires iOS 26") }
        try await withSource(inNavigationStack: true) { presenter, key, transition in
            let stack = try XCTUnwrap(presenter as? UINavigationController)
            let root = try XCTUnwrap(stack.topViewController)
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace,
                                          page: Self.page, didEnd: {}))
            try await self.waitUntil { stack.topViewController !== root && stack.transitionCoordinator == nil }
            let page = try XCTUnwrap(stack.topViewController)
            XCTAssertTrue(stack.isNavigationBarHidden)
            XCTAssertFalse(page.navigationItem.hidesBackButton)
            XCTAssertTrue(try XCTUnwrap(stack.interactiveContentPopGestureRecognizer).isEnabled)
            transition.close()
            try await self.waitUntil { stack.topViewController === root && stack.transitionCoordinator == nil }
        }
    }

    func testProductionSecurityPageOpenLatency() async throws {
        try await checkProductionPageOpenLatency(restoresAccountContext: false)
    }

    func testProductionCachedSecurityPageOpenLatency() async throws {
        try await checkProductionPageOpenLatency(restoresAccountContext: true)
    }

    private func checkProductionPageOpenLatency(restoresAccountContext: Bool) async throws {
        let defaults = UserDefaults(suiteName: "security-open-latency-\(UUID())")!
        defaults.set(true, forKey: "catfolio.fakeDataMode")
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { FakePortfolioGenerator.make() })
        await model.refreshPortfolio(refreshMarketData: false)
        let holding = try XCTUnwrap(model.holdings.first)
        if restoresAccountContext {
            let context = try await model.holdingDetailAccountContext(for: holding.ticker)
            await model.cachedHoldingDetail(for: holding).accountSelection.update(context: context)
        }
        try await withSource(inNavigationStack: true) { presenter, key, transition in
            let stack = try XCTUnwrap(presenter as? UINavigationController)
            let root = try XCTUnwrap(stack.topViewController)
            let start = CACurrentMediaTime()
            HoldingDetailContentView.prefetch(holding, model: model)
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: { close in
                AnyView(HoldingDetailView(holding: holding, onClose: close).environment(model))
            }, didEnd: {}))
            let synchronous = CACurrentMediaTime() - start
            print(String(format: "[SecurityOpenLatency] cachedAccounts=%@ synchronous=%.2fms",
                         String(restoresAccountContext), synchronous * 1000))
            XCTAssertLessThan(synchronous, 0.5, "Opening must not synchronously wait for network data")
            try await self.waitUntil { stack.topViewController !== root && stack.transitionCoordinator == nil }
            print(String(format: "[SecurityOpenLatency] settled=%.2fms", (CACurrentMediaTime() - start) * 1000))
            transition.close()
            try await self.waitUntil { stack.topViewController === root && stack.transitionCoordinator == nil }
        }
    }

    func testActionSheetClosesBeforeStockPushAndReturn() async throws {
        try await withSource(inNavigationStack: true) { presenter, key, transition in
            let stack = try XCTUnwrap(presenter as? UINavigationController)
            let root = try XCTUnwrap(stack.topViewController)
            let overlay = UIAlertController(title: "Filter", message: nil, preferredStyle: .actionSheet)
            overlay.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            overlay.popoverPresentationController?.sourceView = root.view
            stack.present(overlay, animated: false)
            try await self.waitUntil { overlay.view.window != nil }
            var ends = 0
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace,
                                          page: Self.page, didEnd: { ends += 1 }))
            try await self.waitUntil {
                stack.presentedViewController == nil && stack.topViewController !== root
                    && stack.transitionCoordinator == nil
            }
            XCTAssertNil(overlay.presentedViewController, "The stock page must never belong to the transient overlay")
            transition.close()
            try await self.waitUntil { stack.topViewController === root && stack.transitionCoordinator == nil }
            XCTAssertEqual(ends, 1)
        }
    }

    func testNormalPresentedPageIsPreservedAndConsumesTap() async throws {
        try await withSource(inNavigationStack: true) { presenter, key, transition in
            let stack = try XCTUnwrap(presenter as? UINavigationController)
            let root = try XCTUnwrap(stack.topViewController)
            let sheet = UIViewController()
            sheet.modalPresentationStyle = .overFullScreen
            stack.present(sheet, animated: false)
            try await self.waitUntil { sheet.view.window != nil }
            var builds = 0
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: { close in
                builds += 1
                return Self.page(close: close)
            }, didEnd: { XCTFail("No stock page was opened") }))
            XCTAssertTrue(stack.presentedViewController === sheet)
            XCTAssertTrue(stack.topViewController === root)
            XCTAssertEqual(builds, 0)
            XCTAssertFalse(transition.isShowingPage)
            sheet.dismiss(animated: false)
        }
    }

    func testNavigationZoomHidesTabBarAndRestoresItOnReturn() async throws {
        try await checkTabBarVisibility(initiallyHidden: false)
    }

    func testNavigationZoomPreservesAnAlreadyHiddenTabBar() async throws {
        try await checkTabBarVisibility(initiallyHidden: true)
    }

    func testRootTitleAndTabBarStayInTheLiveHomeBehindZoom() async throws {
        try await checkRootChromeReturn(cancelled: nil)
    }

    func testInteractiveReturnRevealsTheSameLiveRootBars() async throws {
        try await checkRootChromeReturn(cancelled: false)
    }

    func testCancelledReturnKeepsHomeChromeAndCanReturnAgain() async throws {
        try await checkRootChromeReturn(cancelled: true)
    }

    func testZoomReturnPreservesTheHomesTuckedTabBar() async throws {
        try await checkRootChromeReturn(cancelled: nil, tucked: true)
    }

    func testNextStockOpenedDuringReturnKeepsBothBarsInsideHome() async throws {
        try await checkRootChromeReturn(cancelled: nil, reopenDuringReturn: true)
    }

    private func checkRootChromeReturn(cancelled: Bool?, tucked: Bool = false,
                                       reopenDuringReturn: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        var key: SecurityDetailSources.SourceKey?
        let host = UIHostingController(rootView: SecurityDetailNavigationContainer {
            TabView {
                Tab("Holdings", systemImage: "chart.bar") {
                    RootPageNavigation {
                        ZoomSourceFixture { key = $0 }
                            .toolbarVisibility(.visible, for: .navigationBar)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .topBarLeading) { Text("Holdings") } }
                            .ownsTabBar()
                    }
                }
                Tab("Settings", systemImage: "gearshape") { Text("Settings") }
            }
        }.ignoresSafeArea())
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            RootTabBar.setTucked(false, animated: false)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { key.flatMap { SecurityDetailSources.shared.liveSourceViews(for: $0) } != nil }
        let sourceKey = try XCTUnwrap(key)
        let navigation = try XCTUnwrap(findController(SecurityDetailNavigationController.self, in: host))
        let tabs = try XCTUnwrap(findController(UITabBarController.self, in: host))
        let homeNavigation = try XCTUnwrap(findController(UINavigationController.self,
            in: XCTUnwrap(tabs.selectedViewController)))
        let root = try XCTUnwrap(navigation.topViewController)
        let titleBar = homeNavigation.navigationBar
        let tabBar = tabs.tabBar
        try await waitUntil { self.isVisible(titleBar, in: window) && !tabs.isTabBarHidden }
        XCTAssertTrue(navigation.isNavigationBarHidden, "Only the tab's own navigation bar occupies space")
        RootTabBar.setTucked(tucked, animated: false)
        let titleFrame = titleBar.convert(titleBar.bounds, to: root.view)
        let tabFrame = tabBar.convert(tabBar.bounds, to: root.view)
        let transition = SecurityDetailLiveZoom()
        var dismissals = 0
        XCTAssertTrue(transition.open(id: sourceKey.id, namespace: sourceKey.namespace,
                                      page: Self.page, didEnd: { dismissals += 1 }))
        try await waitUntil { navigation.topViewController !== root && navigation.transitionCoordinator == nil }
        var detail = try XCTUnwrap(navigation.topViewController)
        XCTAssertEqual(homeNavigation.viewControllers.count, 1, "The home stack must remain untouched")
        let zoom = detail.preferredTransition
        let originalDelegate = navigation.delegate
        let driver = InteractiveReturnDriver(forwarding: originalDelegate)
        defer { navigation.delegate = originalDelegate }

        func checkLiveChrome() {
            // These are the original UIKit bars, still descendants of the
            // complete home page. The detail is a sibling above that page.
            XCTAssertTrue(titleBar === homeNavigation.navigationBar)
            XCTAssertTrue(tabBar === tabs.tabBar)
            XCTAssertTrue(titleBar.isDescendant(of: root.view))
            XCTAssertTrue(tabBar.isDescendant(of: root.view))
            XCTAssertFalse(titleBar.isDescendant(of: detail.view))
            XCTAssertFalse(tabBar.isDescendant(of: detail.view))
            XCTAssertFalse(homeNavigation.isNavigationBarHidden)
            XCTAssertFalse(tabs.isTabBarHidden)
            XCTAssertEqual(titleBar.alpha, 1)
            XCTAssertEqual(tabBar.alpha, 1)
            XCTAssertEqual(titleBar.layer.presentation()?.opacity ?? titleBar.layer.opacity, 1)
            XCTAssertEqual(tabBar.layer.presentation()?.opacity ?? tabBar.layer.opacity, 1)
            XCTAssertEqual(RootTabBar.isTucked, tucked)
            if root.view.window != nil {
                XCTAssertEqual(titleBar.convert(titleBar.bounds, to: root.view).minY, titleFrame.minY, accuracy: 1)
                XCTAssertEqual(tabBar.convert(tabBar.bounds, to: root.view).minY, tabFrame.minY, accuracy: 1)
            }
            if root.view.window != nil, detail.view.window != nil {
                self.assertBelow(root.view, detail.view)
            }
        }
        checkLiveChrome()

        if let cancelled {
            // Exercise UIKit's actual percent-driven appearance/cancellation
            // callbacks; the separate native-zoom case covers its animator.
            detail.preferredTransition = nil
            navigation.delegate = driver
            navigation.popViewController(animated: true)
            try await waitUntil { navigation.transitionCoordinator?.isInteractive == true }
            for progress in [0.15, 0.5, 0.25] {
                driver.interaction.update(progress)
                try await Task.sleep(for: .milliseconds(80))
                checkLiveChrome()
                XCTAssertTrue(isVisible(titleBar, in: window))
                XCTAssertEqual(isVisible(tabBar, in: window), !tucked)
            }
            if cancelled { driver.interaction.cancel() } else { driver.interaction.finish() }
        } else {
            transition.close()
            try await waitUntil { navigation.transitionCoordinator != nil }
            if reopenDuringReturn {
                let first = detail
                XCTAssertTrue(transition.open(id: sourceKey.id, namespace: sourceKey.namespace,
                                              page: Self.page, didEnd: { dismissals += 1 }))
                try await waitUntil {
                    navigation.topViewController !== root && navigation.topViewController !== first
                        && navigation.transitionCoordinator == nil && dismissals == 1
                }
                detail = try XCTUnwrap(navigation.topViewController)
                checkLiveChrome()
                transition.close()
                try await waitUntil { navigation.transitionCoordinator != nil }
            }
        }

        var frames = 0
        while navigation.transitionCoordinator != nil {
            checkLiveChrome()
            frames += 1
            try await Task.sleep(for: .milliseconds(20))
            if frames > 200 { XCTFail("Zoom return did not finish"); break }
        }
        XCTAssertGreaterThan(frames, 2, "Sample the transition, not only its endpoints")
        if cancelled == true {
            XCTAssertTrue(navigation.topViewController === detail)
            XCTAssertTrue(transition.isShowingPage)
            checkLiveChrome()
            navigation.delegate = originalDelegate
            detail.preferredTransition = zoom
            transition.close()
            try await waitUntil { navigation.topViewController === root && navigation.transitionCoordinator == nil }
        }
        try await waitUntil {
            self.isVisible(titleBar, in: window) && self.isVisible(tabBar, in: window) != tucked
        }
        XCTAssertTrue(navigation.topViewController === root)
        XCTAssertEqual(dismissals, reopenDuringReturn ? 2 : 1)
        checkLiveChrome()
    }

    private func assertBelow(_ background: UIView, _ foreground: UIView) {
        var backgroundPath: [UIView] = []
        var ancestor: UIView? = background
        while let current = ancestor {
            backgroundPath.append(current)
            ancestor = current.superview
        }
        var foregroundBranch = foreground
        while let parent = foregroundBranch.superview {
            if let index = backgroundPath.firstIndex(where: { $0 === parent }), index > 0 {
                let backgroundBranch = backgroundPath[index - 1]
                if backgroundBranch.layer.zPosition != foregroundBranch.layer.zPosition {
                    XCTAssertLessThan(backgroundBranch.layer.zPosition, foregroundBranch.layer.zPosition)
                } else {
                    XCTAssertLessThan(parent.subviews.firstIndex(of: backgroundBranch)!,
                                      parent.subviews.firstIndex(of: foregroundBranch)!,
                                      "The entire live home, including both bars, must be behind the detail")
                }
                return
            }
            foregroundBranch = parent
        }
        XCTFail("The home and detail must share a native transition container")
    }

    private func checkTabBarVisibility(initiallyHidden: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        var key: SecurityDetailSources.SourceKey?
        // Match the app's hierarchy: the navigation stack belongs to a tab.
        let host = UIHostingController(rootView: SecurityDetailNavigationContainer { TabView {
            Tab("Holdings", systemImage: "chart.bar") {
                NavigationStack {
                    ZoomSourceFixture { key = $0 }
                        .toolbarVisibility(.hidden, for: .navigationBar)
                        .toolbarVisibility(initiallyHidden ? .hidden : .automatic, for: .tabBar)
                }
            }
            Tab("Settings", systemImage: "gearshape") { Text("Settings") }
        }}.ignoresSafeArea())
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await waitUntil { key.flatMap { SecurityDetailSources.shared.liveSourceViews(for: $0) } != nil }
        let sourceKey = try XCTUnwrap(key)
        let tabs = try XCTUnwrap(findController(UITabBarController.self, in: host))
        let stack = try XCTUnwrap(findController(UINavigationController.self, in: host))
        let root = try XCTUnwrap(stack.topViewController)
        let transition = SecurityDetailLiveZoom()
        var dismissals = 0
        try await waitUntil { self.isVisible(tabs.tabBar, in: window) != initiallyHidden }

        for cycle in 1...2 {
            XCTAssertTrue(transition.open(id: sourceKey.id, namespace: sourceKey.namespace,
                page: Self.page, didEnd: { dismissals += 1 }))
            try await waitUntil { stack.topViewController !== root && stack.transitionCoordinator == nil }
            let detail = try XCTUnwrap(stack.topViewController)
            XCTAssertTrue(detail.hidesBottomBarWhenPushed)
            XCTAssertEqual(tabs.isTabBarHidden, initiallyHidden,
                "Covering the home must preserve the tab bar's own visibility state")
            XCTAssertFalse(isVisible(tabs.tabBar, in: window), "The stock page must hide the root tab bar")
            XCTAssertEqual(detail.view.safeAreaInsets.bottom, window.safeAreaInsets.bottom, accuracy: 1,
                "The stock page must not reserve space for the hidden tab bar")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "stock-detail-above-tab-bar-\(cycle)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-stock-tabbar-\(cycle).png"))

            transition.close()
            try await waitUntil { stack.topViewController === root && stack.transitionCoordinator == nil
                && dismissals == cycle }
            try await waitUntil { self.isVisible(tabs.tabBar, in: window) != initiallyHidden }
            XCTAssertEqual(isVisible(tabs.tabBar, in: window), !initiallyHidden,
                "Return must restore the previous page's tab bar visibility")
            XCTAssertFalse(transition.isShowingPage)
        }
    }

    /// The real path the "cannot tap a row again" report came from: a second
    /// page opened while the first is still on its way back. The first page's
    /// stand-in — one picture per page, held here as well as in its closure —
    /// then outlives its own page, and a picture left over the list's logo is a
    /// row that draws as its logo but shows something stale over it.
    ///
    /// What is asserted is the invariant, not the timing: at no point may the
    /// source logo carry two stand-ins, and after the second page is down it may
    /// carry none.
    func testSecondPageOpenedWhileTheFirstFliesBackLeavesOnePictureAtMost() async throws {
        try await withSource(inNavigationStack: true) { presenter, key, transition in
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: Self.page,
                                          didEnd: {}))
            let logo = self.sourceLogo(of: key)
            try await self.waitUntil { logo?.window != nil }
            let opened = self.standInCount(in: logo)
            XCTAssertEqual(opened, 1, "First open must have an artwork source even without a cached logo")

            // The second open, before the first page has finished going: the
            // other page's closure is replaced, so its stand-in must be cleared
            // by this open itself.
            transition.close()
            try await self.waitUntil { !transition.isShowingPage }
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: Self.page,
                                          didEnd: {}))
            XCTAssertLessThanOrEqual(self.standInCount(in: logo), 1,
                                     "a page that never reports must not leave its picture behind")
        }
    }

    private func sourceLogo(of key: SecurityDetailSources.SourceKey) -> UIView? {
        SecurityDetailSources.shared.liveSourceViews(for: key)?.logo
    }

    /// The zoom's stand-in is a `UIImageView` inside the logo; the list draws
    /// its logo through SwiftUI, not as one.
    private func standInCount(in logo: UIView?) -> Int {
        guard let logo else { return 0 }
        return logo.subviews.filter { $0 is UIImageView }.count
    }

    private func findController<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let found = controller as? T { return found }
        return controller.children.lazy.compactMap { self.findController(type, in: $0) }.first
    }

    private func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            let layer = current.layer.presentation() ?? current.layer
            if current.isHidden || layer.opacity <= 0.01 { return false }
            ancestor = current.superview
        }
        let layer = view.layer.presentation() ?? view.layer
        let frame = layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
        return view.window === window && window.bounds.intersects(frame)
    }

    func testCloseAnimatesBackBeforeReleasingSourceAndCanOpenAgain() async throws {
        try await withSource { presenter, key, transition in
            var dismissals = 0
            for cycle in 1...2 {
                XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: Self.page,
                                              didEnd: { dismissals += 1 }))
                let page = try XCTUnwrap(presenter.presentedViewController)
                try await self.waitUntil { !page.isBeingPresented && page.transitionCoordinator == nil }

                transition.close()

                // The real modal must animate all the way back. Dismissing it
                // immediately under a fading screenshot fails these assertions.
                XCTAssertNotNil(page.preferredTransition)
                XCTAssertTrue(page.transitionCoordinator?.isAnimated == true)
                XCTAssertTrue(page.isBeingDismissed)
                XCTAssertEqual(dismissals, cycle - 1)
                transition.close() // A repeated close must not complete twice.

                try await self.waitUntil { presenter.presentedViewController == nil && dismissals == cycle }
                XCTAssertNotNil(SecurityDetailSources.shared.liveSourceViews(for: key))
            }
        }
    }

    func testNestedFullScreenPageDoesNotReleaseStockTransition() async throws {
        try await withSource { presenter, key, transition in
            var dismissals = 0
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: Self.page,
                                          didEnd: { dismissals += 1 }))
            let page = try XCTUnwrap(presenter.presentedViewController)
            try await self.waitUntil { !page.isBeingPresented && page.transitionCoordinator == nil }
            let child = UIViewController()
            child.modalPresentationStyle = .fullScreen
            await withCheckedContinuation { continuation in
                page.present(child, animated: false) { continuation.resume() }
            }
            XCTAssertEqual(dismissals, 0)
            await withCheckedContinuation { continuation in
                child.dismiss(animated: false) { continuation.resume() }
            }
            XCTAssertTrue(presenter.presentedViewController === page)
            XCTAssertNotNil(page.preferredTransition)
            transition.close()
            try await self.waitUntil { presenter.presentedViewController == nil && dismissals == 1 }
        }
    }

    func testTapWhileFlyingBackOpensTheNextPageAtOnce() async throws {
        try await withSource(inNavigationStack: true) { presenter, key, transition in
            let stack = try XCTUnwrap(presenter as? UINavigationController)
            let root = try XCTUnwrap(stack.topViewController)
            var ends = 0
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: Self.page,
                                          didEnd: { ends += 1 }))
            let first = try XCTUnwrap(stack.topViewController)
            XCTAssertFalse(first === root)
            try await self.waitUntil { first.view.window != nil && !first.isMovingToParent
                && stack.transitionCoordinator == nil && first.transitionCoordinator == nil }
            XCTAssertTrue(transition.isShowingPage)

            transition.close()
            try await self.waitUntil { !transition.isShowingPage }
            XCTAssertEqual(ends, 0, "Open the next page before the return animation finishes")
            XCTAssertTrue(stack.transitionCoordinator?.isAnimated == true)
            XCTAssertFalse(transition.isShowingPage, "A page on its way back must not block the next tap")

            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: Self.page,
                                          didEnd: { ends += 1 }))
            try await self.waitUntil { ends == 1 && stack.topViewController !== first
                && stack.topViewController !== root && stack.transitionCoordinator == nil }
            let second = try XCTUnwrap(stack.topViewController)
            XCTAssertNotNil(second.preferredTransition)
            XCTAssertTrue(transition.isShowingPage, "The first page landing must leave the second up")

            transition.close()
            try await self.waitUntil { stack.topViewController === root && ends == 2 }
        }
    }

    private static func page(close: @escaping () -> Void) -> AnyView {
        AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    RoundedRectangle(cornerRadius: 12).fill(.blue)
                        .frame(width: 56, height: 56)
                    Text("Test security")
                    Spacer()
                    Button("Close", action: close)
                }
                Text("Live detail content").frame(height: 1000, alignment: .top)
            }.padding(20)
        }.background(SecurityDetailPresentation.ground))
    }

    private func withSource(inNavigationStack: Bool = false,
                            _ run: (UIViewController, SecurityDetailSources.SourceKey,
                                   SecurityDetailLiveZoom) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        var key: SecurityDetailSources.SourceKey?
        let source = UIHostingController(rootView: ZoomSourceFixture { key = $0 })
        let presenter: UIViewController = inNavigationStack
            ? UINavigationController(rootViewController: source) : source
        let window = UIWindow(windowScene: scene)
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        let transition = SecurityDetailLiveZoom()
        defer {
            presenter.dismiss(animated: false)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { key.flatMap { SecurityDetailSources.shared.liveSourceViews(for: $0) } != nil }
        try await run(presenter, XCTUnwrap(key), transition)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            // UIKit installs the coordinator on the next turn of the main
            // run loop; checking synchronously can mistake a pending push
            // for an already-completed transition.
            try await Task.sleep(for: .milliseconds(20))
            if condition() { return }
        }
        XCTFail("Timed out waiting for the live zoom lifecycle")
    }
}

@MainActor
private final class InteractiveReturnDriver: NSObject, UINavigationControllerDelegate, UIViewControllerAnimatedTransitioning {
    let interaction = UIPercentDrivenInteractiveTransition()
    weak var forwarding: UINavigationControllerDelegate?

    init(forwarding: UINavigationControllerDelegate?) { self.forwarding = forwarding }

    func navigationController(_ navigationController: UINavigationController,
                              animationControllerFor operation: UINavigationController.Operation,
                              from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        operation == .pop ? self : nil
    }

    func navigationController(_ navigationController: UINavigationController,
                              interactionControllerFor animationController: UIViewControllerAnimatedTransitioning)
        -> UIViewControllerInteractiveTransitioning? { interaction }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController,
                              animated: Bool) {
        forwarding?.navigationController?(navigationController, willShow: viewController, animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController,
                              animated: Bool) {
        forwarding?.navigationController?(navigationController, didShow: viewController, animated: animated)
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval { 0.5 }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let from = context.viewController(forKey: .from)!
        let to = context.viewController(forKey: .to)!
        context.containerView.insertSubview(to.view, belowSubview: from.view)
        to.view.frame = context.finalFrame(for: to)
        UIView.animate(withDuration: transitionDuration(using: context), animations: {
            from.view.transform = CGAffineTransform(translationX: context.containerView.bounds.width, y: 0)
        }, completion: { _ in
            from.view.transform = .identity
            context.completeTransition(!context.transitionWasCancelled)
        })
    }
}

private struct ZoomSourceFixture: View {
    @Namespace private var namespace
    let ready: (SecurityDetailSources.SourceKey) -> Void
    private var key: SecurityDetailSources.SourceKey { .init(id: "TEST", namespace: namespace) }

    var body: some View {
        VStack {
            Spacer().frame(height: 160)
            HStack {
                RoundedRectangle(cornerRadius: 8).fill(.blue).frame(width: 44, height: 44)
                    .securityDetailLogoSource("TEST", in: namespace)
                Text("Test security")
                Spacer()
                Text("$100")
            }
            .padding(12)
            .background { SecurityDetailSourceMarker(key: key) }
            Spacer()
        }
        .padding(20)
        .onAppear { ready(key) }
    }
}
