import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

final class SecurityDetailQuickCloseTests: XCTestCase {
    @MainActor
    func testNativeZoomDismissalReleasesPresenterBeforeDecorativeFadeEnds() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        presenter.view.backgroundColor = .white
        let source = UIView(frame: CGRect(x: 20, y: 180, width: 320, height: 60))
        source.backgroundColor = .systemBlue
        presenter.view.addSubview(source)
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        let closer = SecurityDetailQuickClose()
        defer {
            closer.removeOverlay()
            presenter.dismiss(animated: false)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }

        let page = UIViewController()
        page.view.backgroundColor = .systemGray6
        page.modalPresentationStyle = .fullScreen
        page.preferredTransition = .zoom { _ in source }
        await withCheckedContinuation { continuation in
            presenter.present(page, animated: true) { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            closer.dismiss(page) { continuation.resume() }
        }

        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertNotNil(closer.overlay, "Dismissal finishes while the decorative fade is still running")
        }
        XCTAssertNil(presenter.presentedViewController, "The fading picture must not keep a modal open")
        if let overlay = closer.overlay {
            XCTAssertFalse(overlay.isUserInteractionEnabled)
            XCTAssertTrue(overlay.accessibilityElementsHidden)
        }
        let next = UIViewController()
        next.view.backgroundColor = .systemGreen
        await withCheckedContinuation { continuation in
            presenter.present(next, animated: false) { continuation.resume() }
        }
        XCTAssertTrue(presenter.presentedViewController === next, "A second stock can open immediately")
        closer.removeOverlay()
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertNil(closer.overlay)
        XCTAssertTrue(presenter.presentedViewController === next)
    }

    @MainActor
    func testRepeatedCloseDoesNotDismissTheNextPage() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        let closer = SecurityDetailQuickClose()
        defer {
            closer.removeOverlay()
            presenter.dismiss(animated: false)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        let first = UIViewController()
        first.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            presenter.present(first, animated: false) { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            closer.dismiss(first) { continuation.resume() }
        }
        let next = UIViewController()
        await withCheckedContinuation { continuation in
            presenter.present(next, animated: false) { continuation.resume() }
        }
        closer.dismiss(first)
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertTrue(presenter.presentedViewController === next)
    }

    @MainActor
    func testDownwardCloseOnlyBeginsAtTopAndEdgeSwipeStillWorks() {
        let controller = UIViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let scroll = UIScrollView(frame: controller.view.bounds)
        scroll.contentSize = CGSize(width: 400, height: 1800)
        scroll.contentInset.top = 24
        controller.view.addSubview(scroll)
        let gesture = SecurityDetailCloseGesture(controller: controller, close: {})
        let pan = TestPan()
        controller.view.addGestureRecognizer(pan)
        pan.speed = CGPoint(x: 10, y: 200)
        pan.start = CGPoint(x: 200, y: 100)

        scroll.contentOffset.y = 100
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan), "Scrolling content must not close the page")
        scroll.contentOffset.y = -24
        XCTAssertTrue(gesture.gestureRecognizerShouldBegin(pan))
        pan.speed = CGPoint(x: 0, y: -200)
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan))

        scroll.contentOffset.y = 100
        pan.start.x = 12
        pan.speed = CGPoint(x: 200, y: 10)
        XCTAssertTrue(gesture.gestureRecognizerShouldBegin(pan), "The edge swipe works even after scrolling")
        pan.start.x = 200
        XCTAssertFalse(gesture.gestureRecognizerShouldBegin(pan), "Horizontal chart drags are not close gestures")
    }

    @MainActor
    private final class TestPan: UIPanGestureRecognizer {
        var speed = CGPoint.zero
        var start = CGPoint.zero
        override func velocity(in view: UIView?) -> CGPoint { speed }
        override func location(in view: UIView?) -> CGPoint { start }
        override func translation(in view: UIView?) -> CGPoint { .zero }
    }

    @MainActor
    func testCloseGestureAllowsCancellationAndRejectsTinyFastTouches() {
        XCTAssertFalse(SecurityDetailCloseGesture.shouldFinish(distance: 30, velocity: 100))
        XCTAssertFalse(SecurityDetailCloseGesture.shouldFinish(distance: 2, velocity: 900))
        XCTAssertTrue(SecurityDetailCloseGesture.shouldFinish(distance: 64, velocity: 0))
        XCTAssertTrue(SecurityDetailCloseGesture.shouldFinish(distance: 20, velocity: 700))
    }
}
