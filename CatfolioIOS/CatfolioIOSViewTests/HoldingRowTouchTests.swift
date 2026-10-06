import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class HoldingRowTouchTests: XCTestCase {
    func testTapTriggersOnReleaseExactlyOnceAndCanRepeatImmediately() {
        let observer = ImmediateTouchDown.Observer()
        var taps = 0
        var pressed: [Bool] = []
        observer.onTap = { taps += 1 }
        observer.onChange = { pressed.append($0) }
        observer.beginTouch(at: .zero)
        XCTAssertEqual(taps, 0)
        XCTAssertEqual(pressed, [true])
        observer.endTouch(cancelled: false)
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(pressed, [true, false])
        observer.endTouch(cancelled: false)
        XCTAssertEqual(taps, 1)
        observer.reset()
        observer.beginTouch(at: .zero)
        observer.endTouch(cancelled: false)
        XCTAssertEqual(taps, 2)
        XCTAssertFalse(observer.delaysTouchesBegan)
        XCTAssertFalse(observer.delaysTouchesEnded)
        XCTAssertFalse(observer.cancelsTouchesInView)
    }

    func testScrollAndCancelledTouchesCannotOpenARow() {
        for cancelled in [false, true] {
            let observer = ImmediateTouchDown.Observer()
            var taps = 0
            var pressed = false
            observer.onTap = { taps += 1 }
            observer.onChange = { pressed = $0 }
            observer.beginTouch(at: .zero)
            if !cancelled { observer.moveTouch(to: CGPoint(x: 0, y: 20)) }
            observer.endTouch(cancelled: cancelled)
            XCTAssertFalse(pressed)
            XCTAssertEqual(taps, 0)
        }
    }
}
