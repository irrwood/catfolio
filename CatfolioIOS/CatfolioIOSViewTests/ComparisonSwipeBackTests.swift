import XCTest
import SwiftUI
import UIKit
@testable import CatfolioIOS

@MainActor
final class ComparisonSwipeBackTests: XCTestCase {
    func testSwiftUINavigationStackRestoresBothGesturesAfterBarUpdates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationFixture())
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(1500))
        func findSupport(_ controller: UIViewController) -> ComparisonSwipeBackSupport.Controller? {
            if let support = controller as? ComparisonSwipeBackSupport.Controller { return support }
            return controller.children.lazy.compactMap { findSupport($0) }.first
        }
        let support = try XCTUnwrap(findSupport(host))
        let navigation = try XCTUnwrap(support.navigationController)
        XCTAssertEqual(navigation.viewControllers.count, 2)
        let edge = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        XCTAssertTrue(edge.delegate === support, "Delegate: \(String(describing: edge.delegate)); support: \(support)")
        XCTAssertTrue(edge.isEnabled)
        let replacement = Delegate()
        edge.delegate = replacement
        edge.isEnabled = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(edge.isEnabled)
        XCTAssertTrue(edge.delegate === support, "Delegate: \(String(describing: edge.delegate)); support: \(support)")
        if #available(iOS 26.0, *) {
            let content = try XCTUnwrap(navigation.interactiveContentPopGestureRecognizer)
            XCTAssertTrue(content.delegate === support)
            XCTAssertTrue(content.isEnabled)
            XCTAssertTrue(support.gestureRecognizerShouldBegin(content))
        }
    }

    private struct NavigationFixture: View {
        @State private var path = [1]
        var body: some View {
            NavigationStack(path: $path) {
                Text("Root").navigationDestination(for: Int.self) { _ in
                    ScrollView { Text("Comparison").frame(height: 900) }
                        .background { ComparisonSwipeBackSupport().frame(width: 0, height: 0) }
                        .toolbarVisibility(.hidden, for: .navigationBar)
                }
            }
        }
    }

    func testHiddenBarEnablesPopAndRestoresOriginalDelegate() throws {
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.loadViewIfNeeded()
        let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        let originalDelegate = gesture.delegate
        gesture.isEnabled = false
        navigation.setNavigationBarHidden(true, animated: false)
        let page = UIViewController()
        navigation.setViewControllers([root, page], animated: false)
        let support = ComparisonSwipeBackSupport.Controller()
        page.addChild(support)
        page.view.addSubview(support.view)
        support.didMove(toParent: page)
        support.install()
        XCTAssertTrue(gesture.isEnabled)
        XCTAssertTrue(gesture.delegate === support)
        XCTAssertTrue(support.gestureRecognizerShouldBegin(gesture))
        let pan = DirectedPan()
        pan.testVelocity = CGPoint(x: 500, y: 30)
        XCTAssertTrue(support.gestureRecognizerShouldBegin(pan))
        pan.testVelocity = CGPoint(x: -500, y: 30)
        XCTAssertFalse(support.gestureRecognizerShouldBegin(pan))
        pan.testVelocity = CGPoint(x: 30, y: 500)
        XCTAssertFalse(support.gestureRecognizerShouldBegin(pan))
        support.restore()
        XCTAssertTrue(gesture.delegate === originalDelegate)
        XCTAssertFalse(gesture.isEnabled)
    }

    func testRootDoesNotBeginPopAndReplacementDelegateIsNotOverwritten() throws {
        let navigation = UINavigationController()
        let support = ComparisonSwipeBackSupport.Controller()
        navigation.setViewControllers([support], animated: false)
        navigation.loadViewIfNeeded()
        let gesture = try XCTUnwrap(navigation.interactivePopGestureRecognizer)
        support.install()
        XCTAssertFalse(support.gestureRecognizerShouldBegin(gesture))
        let replacement = Delegate()
        gesture.delegate = replacement
        support.restore()
        XCTAssertTrue(gesture.delegate === replacement)
    }

    private final class Delegate: NSObject, UIGestureRecognizerDelegate {}
    private final class DirectedPan: UIPanGestureRecognizer {
        var testVelocity = CGPoint.zero
        override func velocity(in view: UIView?) -> CGPoint { testVelocity }
    }
}
