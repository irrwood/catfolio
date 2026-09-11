import SwiftUI
import XCTest
@testable import CatfolioIOS

final class HomeScrollInteractionTests: XCTestCase {
    @MainActor
    func testModeOffAndRepeatedHomeVisitsRestorePersonalHoldings() async throws {
        try await verifyModeSwitchHome(personal: FakePortfolioGenerator.make())
    }

    @MainActor
    func testDevicePortfolioModeOffHomeRemainsResponsive() async throws {
        #if targetEnvironment(simulator)
        let url = URL(fileURLWithPath: "/tmp/catfolio-freeze-evidence/personal-portfolio.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local device diagnostic fixture not present") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let personal = try decoder.decode(LocalPortfolioDocument.self, from: Data(contentsOf: url))
        #else
        let personal = try await LocalPortfolioStore.shared.load()
        #endif
        try await verifyModeSwitchHome(personal: personal)
    }

    @MainActor
    private func verifyModeSwitchHome(personal: LocalPortfolioDocument) async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HomeFreezeTests.\(UUID().uuidString)"))
        defaults.set(true, forKey: PublicInvestorPreferences.enabledKey)
        defaults.set("ark", forKey: PublicInvestorPreferences.selectionKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeModeCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publicDocument = LocalPortfolioDocument(source: PublicInvestorAccountAdapter.source, updatedAt: Date(),
            positions: Array(personal.positions.prefix(1)), snapshots: [], transactions: [])
        let catalog = try PublicInvestorCatalog.loaded.get()
        try JSONEncoder().encode(publicDocument).write(to: directory.appendingPathComponent("v2-\(catalog.releaseId)-ark.json"))
        let store = PublicInvestorSimulationStore(directory: directory, histories: { _, _ in
            XCTFail("The mode-switch regression uses isolated cached data, not network reconstruction")
            return [:]
        })
        let model = AppModel(defaults: defaults, publicInvestorStore: store, personalDocumentLoader: { personal })
        await model.refreshPortfolio(refreshMarketData: false)
        print("FREEZE_PROBE public loaded")
        let probe = HomeModeSwitchProbe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: HomeModeSwitchProbeView(probe: probe).environment(model))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        print("FREEZE_PROBE public home mounted")
        func descendants(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(descendants) }
        for cycle in 0..<4 {
        if let scroll = descendants(host.view).compactMap({ $0 as? UIScrollView }).max(by: { $0.contentSize.height < $1.contentSize.height }) {
            scroll.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
        }
        try await Task.sleep(for: .milliseconds(200))
        probe.selection = 1
        try await Task.sleep(for: .milliseconds(100))
        print("FREEZE_PROBE settings before off")
        model.setPortfolioMode(enabled: false, selection: "ark")
        probe.selection = 0
        await Task.yield()
        print("FREEZE_PROBE off and home requested")
        await model.refreshPortfolio(refreshMarketData: false)
        print("FREEZE_PROBE personal loaded")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(model.isPublicInvestorMode)
        XCTAssertFalse(model.holdings.isEmpty)
        probe.selection = 1
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.selection, 1)
        XCTAssertEqual(Set(model.holdings.map(\.ticker)), Set(try LocalPortfolioEngine.presentation(for: personal).2.map(\.ticker)))
        print("FREEZE_PROBE complete cycle \(cycle)")
        if cycle < 3 {
            model.setPortfolioMode(enabled: true, selection: "ark")
            await Task.yield()
            await model.refreshPortfolio(refreshMarketData: false)
            probe.selection = 0
            try await Task.sleep(for: .milliseconds(100))
        }
        }
    }

    @MainActor
    func testRebindingNativeScrollDelegateDoesNotRecurse() {
        let scroll = UIScrollView()
        let first = PortfolioHomeScrollController()
        let second = PortfolioHomeScrollController()
        first.attach(to: scroll)
        second.attach(to: scroll)
        print("DELEGATE_PROBE before rebind")
        first.attach(to: scroll)
        print("DELEGATE_PROBE after rebind")
        XCTAssertTrue(scroll.delegate === first)
        XCTAssertNil(second.scrollView, "The displaced proxy must not retain a binding")
        for _ in 0..<20 {
            second.attach(to: scroll)
            XCTAssertNil(first.scrollView)
            first.attach(to: scroll)
            XCTAssertNil(second.scrollView)
            first.scrollViewDidScroll(scroll)
        }
        first.detach()
        second.detach()
    }

    func testRefreshPermissionIsCapturedOnlyAtSettledTouchDown() {
        var gate = PortfolioHomeRefreshGate()
        for offset: CGFloat in [343, 800, 1, -1] {
            gate.beginTouch(offset: offset, isSettling: false, isMoving: false)
            XCTAssertFalse(gate.permitsRefresh)
        }
        gate.beginTouch(offset: 0, isSettling: true, isMoving: false)
        XCTAssertFalse(gate.permitsRefresh)
        gate.beginTouch(offset: 0, isSettling: false, isMoving: true)
        XCTAssertFalse(gate.permitsRefresh)
        gate.beginTouch(offset: 0, isSettling: false, isMoving: false)
        XCTAssertTrue(gate.permitsRefresh)
        XCTAssertTrue(gate.beginRefresh())
        XCTAssertFalse(gate.beginRefresh(), "Duplicate refresh must be ignored")
        gate.beginTouch(offset: 0, isSettling: false, isMoving: false)
        XCTAssertFalse(gate.permitsRefresh, "An in-flight refresh cannot be rearmed")
        gate.finishRefresh()
        XCTAssertFalse(gate.permitsRefresh, "Completion does not unlock the old gesture")
        gate.beginTouch(offset: 0, isSettling: false, isMoving: false)
        XCTAssertTrue(gate.permitsRefresh)
    }

    func testSpringCarriesReleaseSpeedAndSettlesWithOneSmallOvershoot() {
        for (start, end): (CGFloat, CGFloat) in [(0, 343), (343, 0)] {
            let spring = PortfolioHomeSnapMotion.Spring(start: start, end: end, velocity: 0)
            let values = (0...240).map { spring.value(at: Double($0) / 200) }
            XCTAssertEqual(values.first, start)
            let overshoot = end > start ? (values.max() ?? 0) - end : end - (values.min() ?? 0)
            XCTAssertGreaterThan(overshoot, 0.5, "A released panel lands with a small overshoot")
            XCTAssertLessThan(overshoot, 343 * 0.05, "Only one small overshoot, not a bounce")
            for i in 1..<values.count {
                XCTAssertLessThan(abs(values[i] - values[i - 1]), 20, "Continuous motion at 200 samples/s")
            }
            XCTAssertTrue(spring.isSettled(at: 0.9), "Settles well inside a second")
            XCTAssertFalse(spring.isSettled(at: 0.1))
        }
        // It leaves at the finger's speed rather than from rest.
        let flick = PortfolioHomeSnapMotion.Spring(start: 100, end: 343, velocity: 3000)
        XCTAssertEqual(flick.speed(at: 0), 3000, accuracy: 1)
        XCTAssertGreaterThan(flick.value(at: 0.05), PortfolioHomeSnapMotion.Spring(start: 100, end: 343, velocity: 0).value(at: 0.05))
        let still = PortfolioHomeSnapMotion.Spring(start: 0, end: 343, velocity: 0, reduceMotion: true)
        XCTAssertEqual(still.value(at: 0.01), 343)
        XCTAssertTrue(still.isSettled(at: 0))
    }

    func testSlowFlickAndReversalResolveOnlyToPanelStops() {
        func target(_ start: CGFloat, _ released: CGFloat, _ velocity: CGFloat = 0) -> CGFloat? {
            PortfolioHomeSnapMotion.target(start: start, released: released, velocity: velocity,
                                           detent: 343, maximum: 1800)
        }
        XCTAssertEqual(target(0, 12), 343)
        XCTAssertEqual(target(0, 3, 1.5), 343)
        XCTAssertEqual(target(343, 330), 0)
        XCTAssertEqual(target(343, 342, -1.5), 0)
        XCTAssertEqual(target(0, 220, -0.5), 0, "Reverse the initial upward drag")
        XCTAssertEqual(target(343, 120, 0.5), 343, "Reverse the initial downward drag")
        XCTAssertEqual(target(0, 4), 0)
        XCTAssertEqual(target(343, 340), 343)
        XCTAssertNil(target(0, -80), "Eligible refresh uses native rebound")
        XCTAssertNil(target(343, 650), "Keep list inertia")
        XCTAssertEqual(target(900, 200), 0, "Actual list-to-panel drag can return to lower stop")
        XCTAssertNil(PortfolioHomeSnapMotion.target(start: 0, released: 100, velocity: 1,
                                                   detent: 343, maximum: 240))
    }

    @MainActor
    func testNativeLockedLongPullNeverMovesAboveDefaultOrShowsRefresh() {
        let controller = PortfolioHomeScrollController()
        let scroll = nativeScroll(controller)
        defer { controller.detach() }
        scroll.contentOffset.y = 343 - scroll.adjustedContentInset.top
        controller.touchBegan()
        controller.scrollViewWillBeginDragging(scroll)
        for position: CGFloat in [280, 100, 0, -80, -240] {
            scroll.contentOffset.y = position - scroll.adjustedContentInset.top
            XCTAssertGreaterThanOrEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0)
            XCTAssertNil(scroll.refreshControl)
            XCTAssertFalse(controller.gate.permitsRefresh)
        }
        controller.requestRefresh()
        XCTAssertFalse(controller.gate.isRefreshing)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: false)
        controller.touchBegan()
        XCTAssertTrue(controller.gate.permitsRefresh, "A new, settled gesture may refresh")
        XCTAssertTrue(scroll.refreshControl === controller.refreshControl)
    }

    @MainActor
    func testAnimationTouchCannotUnlockRefreshEvenAfterZeroCrossing() {
        let controller = PortfolioHomeScrollController()
        let scroll = nativeScroll(controller)
        defer { controller.detach() }
        controller.clock = { 100 }
        scroll.contentOffset.y = 343 - scroll.adjustedContentInset.top
        controller.startSnap(to: 0)
        // Step to the spring's overshoot below zero.
        let spring = PortfolioHomeSnapMotion.Spring(start: 343, end: 0, velocity: 0)
        let belowZero = try! XCTUnwrap(stride(from: 0.01, through: 1.0, by: 0.01).first { spring.value(at: $0) < -1 })
        controller.advanceSnap(at: 100 + belowZero)
        XCTAssertLessThan(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0)
        XCTAssertTrue(controller.isSettling)
        controller.touchBegan()
        XCTAssertFalse(controller.gate.permitsRefresh)
        controller.advanceSnap(at: 100 + PortfolioHomeSnapMotion.maximumDuration)
        XCTAssertFalse(controller.isSettling)
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 0.01)
        controller.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = -200 - scroll.adjustedContentInset.top
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 0.01)
        XCTAssertFalse(controller.gate.permitsRefresh)
        XCTAssertNil(scroll.refreshControl)
        controller.scrollViewDidEndDragging(scroll, willDecelerate: false)
        controller.touchBegan()
        XCTAssertTrue(controller.gate.permitsRefresh)
    }

    @MainActor
    func testBothNativeSnapDirectionsUseOneClockAndSignedHeroOffset() {
        let controller = PortfolioHomeScrollController()
        let scroll = nativeScroll(controller)
        defer { controller.detach() }
        controller.clock = { 100 }
        var renderedOffset: CGFloat = 0
        var renderedPull: CGFloat = 0
        controller.onOffset = { renderedOffset = $0; renderedPull = $1 }
        for (start, end): (CGFloat, CGFloat) in [(0, 343), (343, 0)] {
            scroll.contentOffset.y = start - scroll.adjustedContentInset.top
            controller.startSnap(to: end)
            for elapsed in stride(from: 0.01, through: 0.29, by: 0.01) {
                controller.advanceSnap(at: 100 + elapsed)
                let expected = PortfolioHomeSnapMotion.Spring(start: start, end: end, velocity: 0).value(at: elapsed)
                // UIScrollView rounds its offset to a physical screen pixel.
                XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, expected, accuracy: 0.34)
                XCTAssertEqual(renderedOffset, expected, accuracy: 0.34)
                // Hero's +offset cancels the actual scroll translation even
                // during the negative return overshoot; only the panel moves.
                XCTAssertEqual(renderedOffset - (scroll.contentOffset.y + scroll.adjustedContentInset.top), 0, accuracy: 0.01)
                XCTAssertEqual(renderedPull, 0)
                XCTAssertTrue(controller.isSettling)
            }
            controller.advanceSnap(at: 100 + PortfolioHomeSnapMotion.maximumDuration)
            XCTAssertEqual(renderedOffset, end, accuracy: 0.01)
            XCTAssertFalse(controller.isSettling)
            XCTAssertNil(scroll.refreshControl)
        }
    }

    @MainActor
    func testEligibleNativeRefreshShowsSpinnerAndRunsOnceUntilCompletion() async throws {
        let controller = PortfolioHomeScrollController()
        let scroll = nativeScroll(controller)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view = scroll
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        scroll.contentOffset.y = -scroll.adjustedContentInset.top
        defer {
            controller.detach()
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        var requests = 0
        var finish: CheckedContinuation<Void, Never>?
        controller.refresh = {
            requests += 1
            await withCheckedContinuation { finish = $0 }
        }
        controller.touchBegan()
        controller.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = -90 - scroll.adjustedContentInset.top
        XCTAssertLessThan(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0)
        XCTAssertTrue(scroll.refreshControl === controller.refreshControl)
        controller.refreshControl.beginRefreshing()
        controller.refreshControl.sendActions(for: .valueChanged)
        controller.refreshControl.sendActions(for: .valueChanged)
        for _ in 0..<20 where finish == nil { await Task.yield() }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(controller.refreshControl.isRefreshing)
        XCTAssertTrue(controller.gate.isRefreshing)
        finish?.resume()
        for _ in 0..<20 where controller.gate.isRefreshing { await Task.yield() }
        XCTAssertFalse(controller.refreshControl.isRefreshing)
        XCTAssertFalse(controller.gate.isRefreshing)
    }

    @MainActor
    func testNativeInertiaAndListToPanelBoundary() {
        let controller = PortfolioHomeScrollController()
        let scroll = nativeScroll(controller)
        defer { controller.detach() }
        scroll.contentOffset.y = 600 - scroll.adjustedContentInset.top
        controller.touchBegan()
        controller.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 500 - scroll.adjustedContentInset.top
        var target = CGPoint(x: 0, y: -100 - scroll.adjustedContentInset.top)
        controller.scrollViewWillEndDragging(scroll, withVelocity: CGPoint(x: 0, y: -1),
                                              targetContentOffset: &target)
        XCTAssertEqual(target.y + scroll.adjustedContentInset.top, 343)
        XCTAssertFalse(controller.isSettling, "List inertia is not a panel animation")
        XCTAssertFalse(controller.gate.permitsRefresh)
    }

    @MainActor
    private func nativeScroll(_ controller: PortfolioHomeScrollController) -> UIScrollView {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        scroll.contentInset = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        scroll.contentSize = CGSize(width: 402, height: 2200)
        scroll.contentOffset.y = -scroll.adjustedContentInset.top
        controller.attach(to: scroll)
        return scroll
    }

    @MainActor
    func testBridgeAttachesToSwiftUIScrollViewAndKeepsHeroPinnedThroughBothSnaps() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let probe = HomeScrollBridgeProbe()
        let host = UIHostingController(rootView: HomeScrollBridgeProbeView(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for _ in 0..<50 where probe.controller.scrollView == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scroll = try XCTUnwrap(probe.controller.scrollView)
        XCTAssertTrue(scroll.delegate === probe.controller)
        let headerY = probe.heroY
        for target: CGFloat in [343, 0] {
            probe.controller.startSnap(to: target)
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertTrue(probe.controller.isSettling)
            XCTAssertEqual(probe.heroY, headerY, accuracy: 1)
            for _ in 0..<50 where probe.controller.isSettling {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(probe.offset, target, accuracy: 0.34)
            XCTAssertEqual(probe.heroY, headerY, accuracy: 1)
            XCTAssertTrue(scroll.delegate === probe.controller, "SwiftUI updates retain forwarding")
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            })
            attachment.name = "home-native-stop-\(Int(target))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSlowUpwardScrollingAccumulatesAndCompactsBar() {
        var direction = RootTabBarScrollDirection()
        XCTAssertNil(direction.update(from: 20, to: 23))
        XCTAssertNil(direction.update(from: 23, to: 26))
        XCTAssertNil(direction.update(from: 26, to: 29))
        XCTAssertEqual(direction.update(from: 29, to: 32), true)
    }

    func testDownwardScrollingRestoresBarWithoutFlickeringOnSmallReversal() {
        var direction = RootTabBarScrollDirection()
        XCTAssertEqual(direction.update(from: 20, to: 40), true)
        XCTAssertNil(direction.update(from: 40, to: 38))
        XCTAssertNil(direction.update(from: 38, to: 41))
        XCTAssertNil(direction.update(from: 41, to: 37))
        XCTAssertEqual(direction.update(from: 37, to: 28), false)
    }

    func testReturningToTopRestoresBarAndNewGestureClearsTravel() {
        var direction = RootTabBarScrollDirection()
        XCTAssertEqual(direction.update(from: 20, to: 40), true)
        XCTAssertEqual(direction.update(from: 40, to: 0), false)
        XCTAssertNil(direction.update(from: 20, to: 28))
        direction.reset()
        XCTAssertNil(direction.update(from: 28, to: 32))
    }
}

@MainActor
@Observable
private final class HomeScrollBridgeProbe {
    let controller = PortfolioHomeScrollController()
    var offset: CGFloat = 0
    var heroY: CGFloat = 0
}

private struct HomeScrollBridgeProbeView: View {
    @Bindable var probe: HomeScrollBridgeProbe
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("PINNED HOME HEADER")
                    .frame(maxWidth: .infinity)
                    .frame(height: 476, alignment: .top)
                    .background(Color.cyan.opacity(0.25))
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { probe.heroY = $0 }
                    .offset(y: probe.offset)
                VStack {
                    Text("TODAY")
                    ForEach(0..<30) { index in Text("Holding \(index)").frame(height: 60) }
                }
                .frame(maxWidth: .infinity)
                .background(.background, in: UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38))
            }
            .background {
                PortfolioHomeScrollBridge(controller: probe.controller, detent: 343, reduceMotion: false,
                                          onOffset: { probe.offset = $0; _ = $1 }, refresh: {})
            }
        }
        .tracksRootTabBarScroll()
    }
}

@MainActor @Observable private final class HomeModeSwitchProbe { var selection = 0 }
private struct HomeModeSwitchProbeView: View {
    @Bindable var probe: HomeModeSwitchProbe
    var body: some View {
        TabView(selection: $probe.selection) {
            PortfolioView().tag(0).tabItem { Text("Home") }
            SettingsView().tag(1).tabItem { Text("Settings") }
        }
    }
}
