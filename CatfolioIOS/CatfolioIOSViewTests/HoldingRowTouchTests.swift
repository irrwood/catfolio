import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

/// A holding row answers a touch as a row in a system list does: grey only
/// once the finger has rested, a flash for a tap quicker than that, and
/// nothing for a finger that lands to scroll.
@MainActor
final class HoldingRowTouchTests: XCTestCase {
    private let pastDelay = Duration.milliseconds(Int(ImmediateTouchDown.Observer.highlightDelay * 1000) + 120)
    private let pastFlash = Duration.milliseconds(Int(ImmediateTouchDown.Observer.flashHold * 1000) + 120)

    func testAQuickTapFlashesAsItLiftsAndOpensOnce() async throws {
        let observer = ImmediateTouchDown.Observer()
        var taps = 0
        var pressed: [Bool] = []
        observer.onTap = { taps += 1 }
        observer.onChange = { pressed.append($0) }
        observer.beginTouch(at: .zero)
        XCTAssertEqual(pressed, [], "No grey the moment a finger lands")
        observer.endTouch(cancelled: false)
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(pressed, [true], "A tap quicker than the wait still shows the grey")
        observer.endTouch(cancelled: false)
        XCTAssertEqual(taps, 1)
        try await Task.sleep(for: pastFlash)
        XCTAssertEqual(pressed, [true, false])

        observer.reset()
        observer.beginTouch(at: .zero)
        observer.endTouch(cancelled: false)
        XCTAssertEqual(taps, 2, "The next tap does not wait for the flash")
        XCTAssertFalse(observer.delaysTouchesBegan)
        XCTAssertFalse(observer.delaysTouchesEnded)
        XCTAssertFalse(observer.cancelsTouchesInView)
    }

    func testAFingerThatRestsGreysTheRowUntilItLifts() async throws {
        let observer = ImmediateTouchDown.Observer()
        var taps = 0
        var pressed: [Bool] = []
        observer.onTap = { taps += 1 }
        observer.onChange = { pressed.append($0) }
        observer.beginTouch(at: .zero)
        try await Task.sleep(for: pastDelay)
        XCTAssertEqual(pressed, [true])
        observer.endTouch(cancelled: false)
        XCTAssertEqual(pressed, [true, false])
        XCTAssertEqual(taps, 1)
    }

    func testAFingerThatLandsToScrollNeverGreysOrOpensTheRow() async throws {
        let observer = ImmediateTouchDown.Observer()
        var taps = 0
        var pressed: [Bool] = []
        observer.onTap = { taps += 1 }
        observer.onChange = { pressed.append($0) }
        observer.beginTouch(at: .zero)
        observer.moveTouch(to: CGPoint(x: 0, y: 20))
        observer.endTouch(cancelled: false)
        try await Task.sleep(for: pastDelay)
        XCTAssertEqual(pressed, [])
        XCTAssertEqual(taps, 0)
    }

    func testScrollAndCancelledTouchesAfterTheGreyClearItWithoutOpening() async throws {
        for cancelled in [false, true] {
            let observer = ImmediateTouchDown.Observer()
            var taps = 0
            var pressed = false
            observer.onTap = { taps += 1 }
            observer.onChange = { pressed = $0 }
            observer.beginTouch(at: .zero)
            try await Task.sleep(for: pastDelay)
            XCTAssertTrue(pressed)
            if !cancelled { observer.moveTouch(to: CGPoint(x: 0, y: 20)) }
            observer.endTouch(cancelled: cancelled)
            XCTAssertFalse(pressed)
            XCTAssertEqual(taps, 0)
        }
    }

    func testATouchOnAListStillGlidingOnlyStopsIt() throws {
        let scroll = GlidingScrollView()
        let row = UIView()
        scroll.addSubview(row)
        let observer = ImmediateTouchDown.Observer()
        row.addGestureRecognizer(observer)
        var taps = 0
        var pressed: [Bool] = []
        observer.onTap = { taps += 1 }
        observer.onChange = { pressed.append($0) }
        observer.beginTouch(at: .zero)
        observer.endTouch(cancelled: false)
        XCTAssertEqual(pressed, [])
        XCTAssertEqual(taps, 0)

        scroll.gliding = false
        observer.reset()
        observer.beginTouch(at: .zero)
        observer.endTouch(cancelled: false)
        XCTAssertEqual(taps, 1, "Once the list is still, the next tap opens the row")
    }
}

private final class GlidingScrollView: UIScrollView {
    var gliding = true
    override var isDecelerating: Bool { gliding }
}
