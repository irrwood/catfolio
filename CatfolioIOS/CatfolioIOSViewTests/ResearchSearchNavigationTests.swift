import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ResearchSearchNavigationTests: XCTestCase {
    func testAnimatedPopCarriesSearchWithPageBeforeReturnFinishes() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The movable field uses iOS 26") }
        for offset: CGFloat in [0, 400] {
            try await withResearch { window, host, route in
                let placement = try XCTUnwrap(self.controller(ResearchToolbarSearch.PositionController.self, in: host))
                let navigation = try XCTUnwrap(placement.navigationController)
                let root = try XCTUnwrap(navigation.topViewController)
                let scroll = try XCTUnwrap(root.contentScrollView(for: .top))
                scroll.setContentOffset(CGPoint(x: 0, y: offset - scroll.adjustedContentInset.top), animated: false)
                try await Task.sleep(for: .milliseconds(200))
                let original = placement.field.convert(placement.field.bounds, to: root.view)

                route.path = [1]
                try await self.waitUntil { navigation.topViewController !== root && navigation.transitionCoordinator == nil }
                navigation.popViewController(animated: true)
                var samples = 0
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(16))
                    guard navigation.transitionCoordinator != nil, root.view.window === window else { continue }
                    samples += 1
                    XCTAssertTrue(placement.field.window === window,
                                  "Search must already be visible while the parent returns, not appear after pop")
                    XCTAssertTrue(placement.field.isDescendant(of: root.view),
                                  "Search must travel with the incoming page instead of floating above the child")
                    guard placement.field.window === window else { continue }
                    let frame = placement.field.convert(placement.field.bounds, to: root.view)
                    XCTAssertEqual(frame.minX, original.minX, accuracy: 1)
                    XCTAssertEqual(frame.minY, original.minY, accuracy: 2)
                    if samples == 6 {
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                        }
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "Search during return at scroll offset \(Int(offset))"
                        attachment.lifetime = .keepAlways
                        self.add(attachment)
                        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-search-return-\(Int(offset)).png"))
                    }
                }
                XCTAssertGreaterThan(samples, 4, "Exercise the in-flight native return")
                try await self.waitUntil { navigation.transitionCoordinator == nil && placement.field.window === window }
                let restored = placement.field.convert(placement.field.bounds, to: root.view)
                XCTAssertEqual(restored.minY, original.minY, accuracy: 1)
            }
        }
    }

    func testSwiftUIPushAndTabReentryKeepSearchOutOfChildUntilPop() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The movable field uses iOS 26") }
        try await withResearch { window, host, route in
            let placement = try XCTUnwrap(self.controller(ResearchToolbarSearch.PositionController.self, in: host))
            let navigation = try XCTUnwrap(placement.navigationController)
            let root = try XCTUnwrap(navigation.topViewController)
            let search = placement.field.searchBar
            let origin = search.searchTextField.convert(search.searchTextField.bounds, to: window)
            let point = CGPoint(x: origin.midX, y: origin.midY)
            XCTAssertTrue(window.hitTest(point, with: nil)?.isDescendant(of: search) == true)

            route.path = [1]
            try await self.waitUntil { navigation.topViewController !== root && navigation.transitionCoordinator == nil }
            self.assertSearchCannotReceiveTouch(placement, at: point, in: window)

            let tabs = try XCTUnwrap(self.controller(UITabBarController.self, in: host))
            route.tab = 1
            try await self.waitUntil { tabs.selectedIndex == 1 }
            self.assertSearchCannotReceiveTouch(placement, at: point, in: window)
            route.tab = 0
            try await self.waitUntil { tabs.selectedIndex == 0 && navigation.view.window === window }
            XCTAssertTrue(navigation.topViewController !== root, "Reopening a tab must retain its child page")
            placement.viewDidLayoutSubviews()
            self.assertSearchCannotReceiveTouch(placement, at: point, in: window)

            route.path = []
            try await self.waitUntil {
                navigation.topViewController === root && navigation.transitionCoordinator == nil
                    && placement.field.window === window
            }
            let restored = search.searchTextField.convert(search.searchTextField.bounds, to: window)
            let restoredPoint = CGPoint(x: restored.midX, y: restored.midY)
            XCTAssertTrue(window.hitTest(restoredPoint, with: nil)?.isDescendant(of: search) == true)
            XCTAssertTrue(search.searchTextField.becomeFirstResponder(), "Returning to Research must restore keyboard input")
            search.searchTextField.resignFirstResponder()
        }
    }

    func testCancelledOuterPopKeepsSearchOnItsPageAndCompletedPopRestoresInput() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The movable field uses iOS 26") }
        try await withResearch { window, host, _ in
            let placement = try XCTUnwrap(self.controller(ResearchToolbarSearch.PositionController.self, in: host))
            let navigation = try XCTUnwrap(self.controller(SecurityDetailNavigationController.self, in: host))
            let home = try XCTUnwrap(navigation.topViewController)
            let detail = UIViewController()
            detail.view.backgroundColor = .systemBackground
            navigation.pushViewController(detail, animated: false)
            try await self.waitUntil { navigation.topViewController === detail && placement.field.window == nil }

            // Drive a real UIKit interactive transition through cancellation;
            // appearance callbacks and the stack are managed by UIKit itself.
            let driver = InteractivePop()
            let previousDelegate = navigation.delegate
            navigation.delegate = driver
            defer { navigation.delegate = previousDelegate }
            navigation.popViewController(animated: true)
            try await self.waitUntil { navigation.transitionCoordinator?.isInteractive == true }
            driver.interaction.update(0.4)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(placement.field.window === window)
            XCTAssertTrue(placement.field.isDescendant(of: home.view))
            XCTAssertNil(placement.field.hitTest(CGPoint(x: 20, y: 20), with: nil))
            driver.interaction.cancel()
            try await self.waitUntil { navigation.transitionCoordinator == nil }
            XCTAssertTrue(navigation.topViewController === detail)
            XCTAssertNil(placement.field.window, "Cancelling the return must keep search off the detail page")

            navigation.delegate = previousDelegate
            navigation.popViewController(animated: true)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNotNil(navigation.transitionCoordinator)
            XCTAssertTrue(placement.field.window === window)
            XCTAssertTrue(placement.field.isDescendant(of: home.view))
            try await self.waitUntil { navigation.transitionCoordinator == nil && placement.field.window === window }
            let field = placement.field.searchBar.searchTextField
            let frame = field.convert(field.bounds, to: window)
            XCTAssertTrue(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)?.isDescendant(of: field) == true)
            XCTAssertTrue(field.becomeFirstResponder())
            field.resignFirstResponder()
        }
    }

    func testLateRootAppearanceAndLayoutCannotReattachSearchOverPushedPage() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The movable field uses iOS 26") }
        try await withResearch { window, host, route in
            let placement = try XCTUnwrap(self.controller(ResearchToolbarSearch.PositionController.self, in: host))
            let navigation = try XCTUnwrap(placement.navigationController)
            let root = try XCTUnwrap(navigation.topViewController)
            let rootFrame = root.view.frame
            let searchFrame = placement.field.convert(placement.field.bounds, to: window)
            let point = CGPoint(x: searchFrame.midX, y: searchFrame.midY)

            route.path = [1]
            try await self.waitUntil { navigation.topViewController !== root && navigation.transitionCoordinator == nil }

            // Keep the outgoing page mounted, as it can be during a native
            // transition. A late appearance/layout callback must not make that
            // retained page the owner of the front page's input area.
            navigation.view.insertSubview(root.view, at: 0)
            root.view.frame = rootFrame
            defer { if navigation.topViewController !== root { root.view.removeFromSuperview() } }
            XCTAssertTrue(placement.placement.slot?.window === window)
            placement.viewDidAppear(false)
            placement.placement.onLayout?()
            placement.viewDidLayoutSubviews()

            XCTAssertNil(placement.field.superview, "A retained root must not attach its field to the shared navigation view")
            self.assertSearchCannotReceiveTouch(placement, at: point, in: window)
        }
    }

    func testOuterSecurityDetailStackBlocksRetainedInnerSearch() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The movable field uses iOS 26") }
        try await withResearch { window, host, _ in
            let placement = try XCTUnwrap(self.controller(ResearchToolbarSearch.PositionController.self, in: host))
            let innerNavigation = try XCTUnwrap(placement.navigationController)
            let outerNavigation = try XCTUnwrap(self.controller(SecurityDetailNavigationController.self, in: host))
            let home = try XCTUnwrap(outerNavigation.topViewController)
            let homeFrame = home.view.frame
            let innerRoot = innerNavigation.topViewController
            let detail = UIViewController()
            detail.view.backgroundColor = .systemBackground
            outerNavigation.pushViewController(detail, animated: false)
            try await self.waitUntil { outerNavigation.topViewController === detail }
            XCTAssertTrue(innerNavigation.topViewController === innerRoot,
                          "The inner stack still owns its root while the outer stack covers all tabs")

            outerNavigation.view.insertSubview(home.view, at: 0)
            home.view.frame = homeFrame
            defer { if outerNavigation.topViewController !== home { home.view.removeFromSuperview() } }
            XCTAssertTrue(placement.placement.slot?.window === window)
            placement.viewDidAppear(false)
            placement.layoutSearch()
            XCTAssertNil(placement.field.superview, "Ownership must be checked through the outer detail stack too")

            // Also cover the interval before the next layout can remove a
            // stale field: the UIKit input itself must reject the touch.
            innerNavigation.view.addSubview(placement.field)
            placement.field.isUserInteractionEnabled = true
            let point = CGPoint(x: placement.field.bounds.midX, y: placement.field.bounds.midY)
            XCTAssertNil(placement.field.hitTest(point, with: nil),
                         "A field left attached for one layout pass must not activate behind a detail")
            placement.field.removeFromSuperview()
        }
    }

    @available(iOS 26.0, *)
    private func assertSearchCannotReceiveTouch(_ placement: ResearchToolbarSearch.PositionController,
                                               at point: CGPoint, in window: UIWindow,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let hit = window.hitTest(point, with: nil)
        XCTAssertFalse(hit?.isDescendant(of: placement.field) == true,
                       "The previous search position must belong to the visible page", file: file, line: line)
        XCTAssertFalse(placement.field.searchBar.searchTextField.isFirstResponder, file: file, line: line)
    }

    @available(iOS 26.0, *)
    private func withResearch(_ run: (UIWindow, UIViewController, Route) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let route = Route()
        let suite = "research-navigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: SecurityDetailNavigationContainer {
            SearchTabs(route: route).defaultAppStorage(defaults)
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await waitUntil {
            guard let placement = self.controller(ResearchToolbarSearch.PositionController.self, in: host),
                  placement.field.window === window else { return false }
            let search = placement.field.searchBar
            let frame = search.searchTextField.convert(search.searchTextField.bounds, to: window)
            return window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)?.isDescendant(of: search) == true
        }
        try await run(window, host, route)
    }

    @Observable final class Route {
        var path: [Int] = []
        var tab = 0
    }

    private final class InteractivePop: NSObject, UINavigationControllerDelegate, UIViewControllerAnimatedTransitioning {
        let interaction = UIPercentDrivenInteractiveTransition()

        func navigationController(_ navigationController: UINavigationController,
                                  animationControllerFor operation: UINavigationController.Operation,
                                  from fromVC: UIViewController,
                                  to toVC: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? { self }

        func navigationController(_ navigationController: UINavigationController,
                                  interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning)
            -> (any UIViewControllerInteractiveTransitioning)? { interaction }

        func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0.4 }

        func animateTransition(using context: any UIViewControllerContextTransitioning) {
            guard let from = context.viewController(forKey: .from),
                  let to = context.viewController(forKey: .to) else { return }
            context.containerView.insertSubview(to.view, belowSubview: from.view)
            to.view.frame = context.finalFrame(for: to)
            UIView.animate(withDuration: transitionDuration(using: context), animations: {
                from.view.frame.origin.x = context.containerView.bounds.width
            }, completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            })
        }
    }

    private struct SearchTabs: View {
        let route: Route
        @State private var isSearchPresented = false

        var body: some View {
            TabView(selection: Binding(get: { route.tab }, set: { route.tab = $0 })) {
                Tab("Research", systemImage: "magnifyingglass", value: 0) {
                    NavigationStack(path: Binding(get: { route.path }, set: { route.path = $0 })) {
                        SettingsPage {
                            ResearchSearchSlot()
                            Text("Research content").frame(maxWidth: .infinity, minHeight: 1200, alignment: .top)
                        }
                        .navigationTitle(ResearchMarketSearch.navigationTitle)
                        .navigationBarTitleDisplayMode(.large)
                        .modifier(ResearchMarketSearch(holdings: [], onSelect: { _ in },
                                                       isPresented: $isSearchPresented))
                        .navigationDestination(for: Int.self) { _ in
                            ScrollView { Text("Child content").frame(maxWidth: .infinity, minHeight: 1200, alignment: .top) }
                                .navigationTitle("Child")
                                .navigationBarTitleDisplayMode(.inline)
                                .background(Color(uiColor: .systemBackground))
                        }
                    }
                }
                Tab("Other", systemImage: "circle", value: 1) {
                    NavigationStack { Text("Other tab").navigationTitle("Other") }
                }
            }
        }
    }

    private func controller<T: UIViewController>(_ type: T.Type, in root: UIViewController) -> T? {
        if let match = root as? T { return match }
        return root.children.lazy.compactMap { self.controller(type, in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the research navigation state", file: file, line: line)
        throw NSError(domain: "ResearchSearchNavigationTests", code: 1)
    }
}
