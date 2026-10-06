import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SecurityDetailLiveZoomTests: XCTestCase {
    func testProductionSecurityPageOpenLatency() async throws {
        let defaults = UserDefaults(suiteName: "security-open-latency-\(UUID())")!
        defaults.set(true, forKey: "catfolio.fakeDataMode")
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { FakePortfolioGenerator.make() })
        await model.refreshPortfolio(refreshMarketData: false)
        let holding = try XCTUnwrap(model.holdings.first)
        try await withSource(inNavigationStack: true) { presenter, key, transition in
            let stack = try XCTUnwrap(presenter as? UINavigationController)
            let root = try XCTUnwrap(stack.topViewController)
            let start = CACurrentMediaTime()
            HoldingDetailContentView.prefetch(holding, model: model)
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: { close in
                AnyView(HoldingDetailView(holding: holding, onClose: close).environment(model))
            }, didEnd: {}))
            let synchronous = CACurrentMediaTime() - start
            print(String(format: "[SecurityOpenLatency] synchronous=%.2fms", synchronous * 1000))
            XCTAssertLessThan(synchronous, 0.5, "Opening must not synchronously wait for network data")
            try await self.waitUntil { stack.topViewController !== root && stack.transitionCoordinator == nil }
            print(String(format: "[SecurityOpenLatency] settled=%.2fms", (CACurrentMediaTime() - start) * 1000))
            transition.close()
            try await self.waitUntil { stack.topViewController === root && stack.transitionCoordinator == nil }
        }
    }

    func testNavigationZoomHidesTabBarAndRestoresItOnReturn() async throws {
        try await checkTabBarVisibility(initiallyHidden: false)
    }

    func testNavigationZoomPreservesAnAlreadyHiddenTabBar() async throws {
        try await checkTabBarVisibility(initiallyHidden: true)
    }

    private func checkTabBarVisibility(initiallyHidden: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        var key: SecurityDetailSources.SourceKey?
        // Match the app's hierarchy: the navigation stack belongs to a tab.
        let host = UIHostingController(rootView: TabView {
            Tab("Holdings", systemImage: "chart.bar") {
                NavigationStack {
                    ZoomSourceFixture { key = $0 }
                        .toolbarVisibility(.hidden, for: .navigationBar)
                        .toolbarVisibility(initiallyHidden ? .hidden : .automatic, for: .tabBar)
                }
            }
            Tab("Settings", systemImage: "gearshape") { Text("Settings") }
        })
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
            if current.isHidden || current.alpha <= 0.01 { return false }
            ancestor = current.superview
        }
        return view.window === window && window.bounds.intersects(view.convert(view.bounds, to: window))
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
