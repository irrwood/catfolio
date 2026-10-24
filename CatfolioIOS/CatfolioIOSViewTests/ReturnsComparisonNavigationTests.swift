import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ReturnsComparisonNavigationTests: XCTestCase {
    func testComparisonUsesNativeBackAndPreservesPageOnCancelledReturn() async throws {
        try await withPhone { window, host, model, route in
            let navigation = try XCTUnwrap(self.navigation(host))
            let root = try XCTUnwrap(navigation.topViewController)
            let rootScroll = try XCTUnwrap(root.contentScrollView(for: .top))
            rootScroll.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
            try await Task.sleep(for: .milliseconds(250))
            let rootOffset = rootScroll.contentOffset
            route.comparison = true
            try await self.wait { navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil }
            try await Task.sleep(for: .milliseconds(500))
            let comparison = try XCTUnwrap(navigation.topViewController)
            XCTAssertEqual(comparison.navigationItem.title, ReturnsChartDestination.comparison.title)
            XCTAssertFalse(navigation.isNavigationBarHidden)
            XCTAssertFalse(comparison.navigationItem.hidesBackButton)
            XCTAssertNotNil(navigation.navigationBar.backItem)
            XCTAssertFalse(self.controllers(comparison).contains { $0 is ComparisonSwipeBackSupport.Controller })
            XCTAssertTrue(navigation.interactivePopGestureRecognizer?.isEnabled == true)
            XCTAssertNotNil(navigation.interactivePopGestureRecognizer?.delegate)
            let revision = model.comparisonRevision
            let add = try await NativeToolbarTestSupport.button(in: navigation, leading: false,
                                                               identifier: "comparison.add-benchmark")
            try add.tap()
            try await self.wait { comparison.presentedViewController != nil || navigation.presentedViewController != nil }
            let sheet = try XCTUnwrap(comparison.presentedViewController ?? navigation.presentedViewController)
            XCTAssertNotNil(self.navigation(sheet), "The existing benchmark picker remains a sheet")
            sheet.dismiss(animated: false)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(navigation.topViewController === comparison)
            XCTAssertEqual(model.comparisonRevision, revision, "Opening and closing a picker without changes must not recompute")

            let driver = InteractivePop()
            let originalDelegate = navigation.delegate
            navigation.delegate = driver
            navigation.popViewController(animated: true)
            try await self.wait { navigation.transitionCoordinator?.isInteractive == true }
            driver.interaction.update(0.45)
            try await Task.sleep(for: .milliseconds(120))
            driver.interaction.cancel()
            try await self.wait { navigation.transitionCoordinator == nil }
            navigation.delegate = originalDelegate
            XCTAssertTrue(navigation.topViewController === comparison)
            XCTAssertFalse(navigation.isNavigationBarHidden)
            try self.capture(window, "phone-comparison-after-cancel")
            navigation.popViewController(animated: true)
            try await self.wait { navigation.topViewController === root && navigation.transitionCoordinator == nil }
            XCTAssertTrue(root.contentScrollView(for: .top) === rootScroll)
            XCTAssertEqual(rootScroll.contentOffset.y, rootOffset.y, accuracy: 1)
        }
    }

    func testComparisonToolbarFitsNarrowPhoneWithLargeText() async throws {
        try await withPhone(width: 320, largeText: true) { window, host, _, route in
            let navigation = try XCTUnwrap(self.navigation(host))
            route.comparison = true
            try await self.wait { navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(navigation.topViewController?.navigationItem.title, ReturnsChartDestination.comparison.title)
            let add = try await NativeToolbarTestSupport.button(in: navigation, leading: false,
                                                               identifier: "comparison.add-benchmark")
            let frame = add.view.convert(add.view.bounds, to: window)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX + 1)
            XCTAssertNotNil(navigation.navigationBar.backItem)
            try self.capture(window, "phone-comparison-narrow-large-type")
        }
    }

    private func withPhone(width: CGFloat? = nil, largeText: Bool = false, _ action: (UIWindow, UIViewController, AppModel, Route) async throws -> Void) async throws {
        let suite = "ReturnsComparisonNavigationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppModel.fakeDataModeKey)
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let document = FakePortfolioGenerator.make()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { document })
        model.returnsError = "No history in navigation fixture"
        model.isReturnsLoading = true // Test the real page chrome without data requests.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let route = Route()
        let host = UIHostingController(rootView: RootPageNavigation {
            ScrollView { Text("收益").frame(height: 1400) }
                .navigationTitle("收益")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: Binding(get: { route.comparison }, set: { route.comparison = $0 })) {
                ReturnsChartPage(chart: .comparison)
            }
        }
            .environment(model).defaultAppStorage(defaults))
        if let width { window.frame.size.width = width }
        if largeText { host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true); window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible(); defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(900))
        try await action(window, host, model, route)
    }

    @Observable fileprivate final class Route { var comparison = false }

    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
    }
    private func navigation(_ controller: UIViewController) -> UINavigationController? {
        controllers(controller).compactMap { $0 as? UINavigationController }.first
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Navigation did not settle")
    }
    private func capture(_ window: UIWindow, _ name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }

    private final class InteractivePop: NSObject, UINavigationControllerDelegate, UIViewControllerAnimatedTransitioning {
        let interaction = UIPercentDrivenInteractiveTransition()
        func navigationController(_ navigationController: UINavigationController,
                                  animationControllerFor operation: UINavigationController.Operation,
                                  from fromVC: UIViewController, to toVC: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? { self }
        func navigationController(_ navigationController: UINavigationController,
                                  interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning) -> (any UIViewControllerInteractiveTransitioning)? { interaction }
        func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0.4 }
        func animateTransition(using context: any UIViewControllerContextTransitioning) {
            guard let from = context.viewController(forKey: .from), let to = context.viewController(forKey: .to) else { return }
            context.containerView.insertSubview(to.view, belowSubview: from.view)
            to.view.frame = context.finalFrame(for: to)
            UIView.animate(withDuration: 0.4, animations: {
                from.view.frame.origin.x = context.containerView.bounds.width
            }, completion: { _ in context.completeTransition(!context.transitionWasCancelled) })
        }
    }
}
