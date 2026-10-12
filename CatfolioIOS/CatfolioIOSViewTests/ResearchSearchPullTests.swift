import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ResearchSearchPullTests: XCTestCase {
    func testThresholdClicksOnceAndOnlyReleaseDismisses() {
        let feedback = RecordingImpact()
        let observer = ResearchSearchPullToDismiss.Observer(feedback: feedback)
        var dismissals = 0
        observer.onDismiss = { dismissals += 1 }
        observer.beginTouch(at: .zero, in: UIView())
        XCTAssertEqual(feedback.preparations, 1)
        observer.moveTouch(to: CGPoint(x: 0, y: ResearchSearchPullToDismiss.Observer.threshold - 1))
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(feedback.impacts, 0)
        observer.moveTouch(to: CGPoint(x: 0, y: ResearchSearchPullToDismiss.Observer.threshold))
        observer.moveTouch(to: CGPoint(x: 0, y: 350))
        XCTAssertEqual(dismissals, 0, "Crossing the detent only arms dismissal")
        XCTAssertEqual(feedback.impacts, 1)
        XCTAssertTrue(observer.isArmed)
        observer.endTouch()
        XCTAssertEqual(dismissals, 1)

        observer.hapticsEnabled = false
        observer.beginTouch(at: .zero, in: UIView())
        observer.moveTouch(to: CGPoint(x: 0, y: 200))
        observer.endTouch()
        XCTAssertEqual(dismissals, 2)
        XCTAssertEqual(feedback.impacts, 1)
        XCTAssertEqual(feedback.preparations, 1)
    }

    func testPullingBackBelowThresholdDisarmsWithoutRepeatedClicks() {
        let feedback = RecordingImpact()
        let observer = ResearchSearchPullToDismiss.Observer(feedback: feedback)
        var dismissals = 0, cancellations = 0
        observer.onDismiss = { dismissals += 1 }
        observer.onPullCancel = { cancellations += 1 }
        observer.beginTouch(at: .zero, in: UIView())
        for y: CGFloat in [180, 30, 190, 40] { observer.moveTouch(to: CGPoint(x: 0, y: y)) }
        observer.endTouch()
        XCTAssertEqual(feedback.impacts, 1)
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(cancellations, 1)
        observer.beginTouch(at: .zero, in: UIView())
        observer.moveTouch(to: CGPoint(x: 0, y: 200))
        observer.endTouch(cancelled: true)
        XCTAssertEqual(dismissals, 0, "System cancellation cannot commit an armed gesture")
    }

    func testShortCancelledUpwardAndSidewaysGesturesDoNotDismiss() {
        let observer = ResearchSearchPullToDismiss.Observer()
        var dismissals = 0
        observer.onDismiss = { dismissals += 1 }
        for firstMove in [CGPoint(x: 0, y: -20), CGPoint(x: 30, y: 10)] {
            observer.beginTouch(at: .zero, in: UIView())
            observer.moveTouch(to: firstMove)
            observer.moveTouch(to: CGPoint(x: 0, y: 200))
            observer.endTouch()
        }
        observer.beginTouch(at: .zero, in: UIView())
        observer.moveTouch(to: CGPoint(x: 0, y: 30))
        observer.endTouch()
        observer.moveTouch(to: CGPoint(x: 0, y: 200))
        XCTAssertEqual(dismissals, 0)
        XCTAssertFalse(observer.cancelsTouchesInView)
        XCTAssertFalse(observer.canPrevent(UIPanGestureRecognizer()))
        XCTAssertFalse(observer.canBePrevented(by: UIPanGestureRecognizer()))
    }

    func testPullMustStartAtTopEvenIfResultsReachTopDuringTheDrag() {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        scroll.contentInset.top = 40
        scroll.contentSize = CGSize(width: 390, height: 1600)
        let row = UIView()
        scroll.addSubview(row)
        let observer = ResearchSearchPullToDismiss.Observer()
        var dismissals = 0
        observer.onDismiss = { dismissals += 1 }
        scroll.contentOffset.y = 100
        observer.beginTouch(at: .zero, in: row)
        scroll.contentOffset.y = -40
        observer.moveTouch(to: CGPoint(x: 0, y: 200))
        observer.endTouch()
        XCTAssertEqual(dismissals, 0)
        observer.beginTouch(at: .zero, in: row)
        observer.moveTouch(to: CGPoint(x: 0, y: 200))
        XCTAssertEqual(dismissals, 0)
        observer.endTouch()
        XCTAssertEqual(dismissals, 1)
    }

    func testTravelRemainsLongButIncreasinglyResistedAndScaleSettlesEarly() {
        let travel = [CGFloat(0), 50, 100, 200, 400, 800].map(ResearchSearchPullGeometry.translation)
        XCTAssertEqual(travel[0], 0)
        XCTAssertTrue(zip(travel, travel.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertGreaterThan(travel[4], 120)
        XCTAssertLessThan(travel.last!, ResearchSearchPullGeometry.maximumTravel)
        let first = ResearchSearchPullGeometry.translation(for: 100) - ResearchSearchPullGeometry.translation(for: 50)
        let later = ResearchSearchPullGeometry.translation(for: 350) - ResearchSearchPullGeometry.translation(for: 300)
        XCTAssertLessThan(later, first)
        XCTAssertEqual(ResearchSearchPullGeometry.scale(for: 0), 1)
        XCTAssertEqual(ResearchSearchPullGeometry.scale(for: 32), 0.965, accuracy: 0.001)
        XCTAssertEqual(ResearchSearchPullGeometry.scale(for: 400), 0.965, accuracy: 0.001)
    }

    func testReducedMotionKeepsFieldStillAndCompletesWithoutDelay() {
        let view = UIView()
        let motion = ResearchSearchMotion()
        motion.field = view
        motion.reduceMotion = true
        motion.pull(250)
        XCTAssertEqual(view.transform, .identity)
        var completed = false
        motion.finishPull { completed = true }
        XCTAssertTrue(completed)
        XCTAssertTrue(view.isUserInteractionEnabled)
    }

    func testCommittedPullHandsOffHeldGeometryWithoutReturningToToolbar() {
        let view = UIView()
        let motion = ResearchSearchMotion()
        motion.field = view
        motion.pull(180)
        let released = view.transform
        var dismissals = 0
        motion.finishPull { dismissals += 1 }
        XCTAssertEqual(dismissals, 1, "The closing flight starts as soon as the finger releases")
        XCTAssertEqual(view.transform, released)
        motion.finishPull { dismissals += 1 }
        XCTAssertEqual(dismissals, 1)
        motion.presentationEnded()
        XCTAssertEqual(view.transform, released, "The positioning controller owns the return animation")
        motion.reset()
        XCTAssertEqual(view.transform, .identity)
    }

    func testCancelledSearchIgnoresLateKeyboardTextChanges() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The movable field uses iOS 26") }
        var query = "AAPL"
        var presented = true
        let coordinator = ResearchToolbarSearch.Coordinator(
            query: Binding(get: { query }, set: { query = $0 }),
            isPresented: Binding(get: { presented }, set: { presented = $0 }))
        let search = UISearchBar()
        search.text = query
        coordinator.cancel(search)
        coordinator.searchBar(search, textDidChange: "AAPL")
        XCTAssertFalse(presented)
        XCTAssertEqual(query, "")
        XCTAssertEqual(search.text, "")
    }

    func testNewPullInterruptsACancelledReturnWithoutBeingResetLater() async throws {
        let view = UIView()
        let motion = ResearchSearchMotion()
        motion.field = view
        motion.pull(90)
        motion.cancelPull()
        motion.pull(230)
        let held = view.transform
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(view.transform, held)
        XCTAssertEqual(view.transform.ty, ResearchSearchPullGeometry.translation(for: 230), accuracy: 0.01)
        motion.reset()
        XCTAssertEqual(view.transform, .identity)
    }

    private final class RecordingImpact: UIImpactFeedbackGenerator {
        var preparations = 0
        var impacts = 0
        override func prepare() { preparations += 1 }
        override func impactOccurred(intensity: CGFloat) { impacts += 1 }
    }
}
