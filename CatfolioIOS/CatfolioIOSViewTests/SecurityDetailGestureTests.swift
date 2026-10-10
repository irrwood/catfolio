import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SecurityDetailGestureTests: XCTestCase {
    func testRightSwipeCanStartAtAnyScrollPositionWithoutEnablingVerticalDismissal() {
        let page = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 850))
        let scroll = UIScrollView(frame: page.bounds)
        scroll.contentSize = CGSize(width: 400, height: 2400)
        page.addSubview(scroll)
        for y in [0.0, 600, 1500] {
            scroll.contentOffset.y = y
            XCTAssertTrue(SecurityDetailDismissal.shouldBegin(in: page,
                velocity: CGVector(dx: 200, dy: 30), systemAllows: false))
            XCTAssertFalse(SecurityDetailDismissal.shouldBegin(in: page,
                velocity: CGVector(dx: 30, dy: 200), systemAllows: false))
            XCTAssertFalse(SecurityDetailDismissal.shouldBegin(in: page,
                velocity: CGVector(dx: -200, dy: 0), systemAllows: false))
        }
        XCTAssertTrue(SecurityDetailDismissal.shouldBegin(in: page,
            velocity: CGVector(dx: 0, dy: 200), systemAllows: true))
    }

    func testSwipeBeforeHoldActivationYieldsToPageAndDoesNotActivateLater() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let touch = TestTouch(view: fixture.chart, point: CGPoint(x: 160, y: 80))
        fixture.press.touchesBegan([touch], with: UIEvent())
        touch.point.x += ChartInteractionStyle.preActivationMovementTolerance + 1
        fixture.press.touchesMoved([touch], with: UIEvent())
        XCTAssertFalse(fixture.press.isInspecting)
        XCTAssertTrue(fixture.canDismiss)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(fixture.press.isInspecting, "A failed hold's timer must not steal the back swipe")
    }

    func testHeldChartKeepsRightwardDragAndSecondFingerUntilPrimaryLifts() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let first = TestTouch(view: fixture.chart, point: CGPoint(x: 140, y: 80))
        fixture.press.touchesBegan([first], with: UIEvent())
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fixture.press.isInspecting)
        XCTAssertFalse(fixture.canDismiss)
        first.point.x += 100
        fixture.press.touchesMoved([first], with: UIEvent())
        XCTAssertEqual(fixture.press.currentValue?.primaryLocation.x, first.point.x)
        XCTAssertFalse(fixture.canDismiss)

        let second = TestTouch(view: fixture.chart, point: CGPoint(x: 300, y: 80))
        fixture.press.touchesBegan([second], with: UIEvent())
        XCTAssertEqual(fixture.press.currentValue?.touchCount, 2)
        XCTAssertFalse(fixture.canDismiss)
        fixture.press.touchesEnded([second], with: UIEvent())
        XCTAssertEqual(fixture.press.currentValue?.touchCount, 1)
        XCTAssertFalse(fixture.canDismiss)
        fixture.press.touchesEnded([first], with: UIEvent())
        XCTAssertTrue(fixture.canDismiss, "Releasing the chart must restore dismissal")
        fixture.press.reset()
        XCTAssertFalse(fixture.press.isInspecting)
    }

    func testCancellationAndAnotherPageCannotLeaveDismissalBlocked() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let touch = TestTouch(view: fixture.chart, point: CGPoint(x: 160, y: 80))
        fixture.press.touchesBegan([touch], with: UIEvent())
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(fixture.canDismiss)
        XCTAssertTrue(SecurityDetailDismissal.shouldBegin(in: UIView(),
            velocity: CGVector(dx: 200, dy: 0), systemAllows: true))
        fixture.press.touchesCancelled([touch], with: UIEvent())
        XCTAssertTrue(fixture.canDismiss)
        fixture.press.reset()
        XCTAssertNil(fixture.press.currentValue)
    }

    func testLeadingEdgeRemainsAvailableEvenForASlowSwipe() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let point = fixture.chart.convert(CGPoint(x: 5, y: 230), from: fixture.window)
        let touch = TestTouch(view: fixture.chart, point: point)
        XCTAssertLessThan(touch.location(in: fixture.window).x, ChartInteractionStyle.systemEdgeWidth)
        fixture.press.touchesBegan([touch], with: UIEvent())
        XCTAssertFalse(fixture.press.isInspecting)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fixture.canDismiss)
    }

    func testChartHasPriorityOverContentBackswipeButNotTheScreenEdge() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Content backswipe requires iOS 26") }
        let fixture = try await Fixture()
        defer { fixture.close() }
        let content = try XCTUnwrap(fixture.navigation.interactiveContentPopGestureRecognizer)
        let edge = try XCTUnwrap(fixture.navigation.interactivePopGestureRecognizer)
        XCTAssertTrue(fixture.press.delegate === fixture.press)
        XCTAssertTrue(fixture.press.gestureRecognizer(fixture.press, shouldBeRequiredToFailBy: content))
        XCTAssertFalse(fixture.press.gestureRecognizer(fixture.press, shouldBeRequiredToFailBy: edge))
        XCTAssertFalse(fixture.press.gestureRecognizer(fixture.press, shouldBeRequiredToFailBy: UIPanGestureRecognizer()))
    }
}

@MainActor
private final class Fixture {
    let window: UIWindow
    let previous: UIWindow?
    let navigation: UINavigationController
    let page = UIViewController()
    let chart = ChartInteractionOverlay.TouchCaptureView(frame: CGRect(x: 0, y: 150, width: 400, height: 240))
    var press: ChartInteractionOverlay.ChartDetailGestureRecognizer {
        chart.gestureRecognizers!.compactMap { $0 as? ChartInteractionOverlay.ChartDetailGestureRecognizer }.first!
    }
    var canDismiss: Bool {
        SecurityDetailDismissal.shouldBegin(in: page.view, velocity: CGVector(dx: 300, dy: 0), systemAllows: true)
    }
    init() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        navigation = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.pushViewController(page, animated: false)
        page.view.addSubview(chart)
        window.layoutIfNeeded()
        navigation.view.layoutIfNeeded()
        page.view.layoutIfNeeded()
        for _ in 0..<20 where chart.window == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try XCTUnwrap(chart.window)
    }
    func close() {
        press.isEnabled = false
        window.isHidden = true
        previous?.makeKeyAndVisible()
    }
}

private final class TestTouch: UITouch {
    weak var touchedView: UIView?
    var point: CGPoint
    init(view: UIView, point: CGPoint) {
        touchedView = view
        self.point = point
        super.init()
    }
    override var view: UIView? { touchedView }
    override func location(in view: UIView?) -> CGPoint {
        touchedView?.convert(point, to: view) ?? point
    }
}
