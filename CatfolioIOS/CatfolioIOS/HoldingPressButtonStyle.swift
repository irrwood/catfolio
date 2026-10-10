import ImageIO
import Observation
import SwiftUI
import UIKit

/// Keeps financial colours intact while the system Button owns recognition,
/// scrolling cancellation and the dismissal of menus over the list.
struct HoldingPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoldingPressBody(configuration: configuration)
    }
}

/// A pressed row turns grey under the finger — the settings rows' pressed
/// fill, reaching a little past the row's content — rather than changing size.
/// The system's pressed state determines when the grey comes and goes.
struct HoldingPressBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration

    private var isPressed: Bool { configuration.isPressed && isEnabled }

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(SettingsTemplate.rowPressed)
                    .padding(.horizontal, -10)
                    .padding(.vertical, -2)
                    .opacity(isPressed ? 1 : 0)
                    // On at once; off with a short fade, as a system row does.
                    .animation(isPressed || reduceMotion ? nil : .easeOut(duration: 0.25), value: isPressed)
            }
    }
}

/// Follows a touch the way a row in a system list does. The grey comes a
/// moment after touch-down — the wait a scroll view takes to tell a tap from
/// a scroll — so a finger that lands to scroll never lights a row; a tap
/// quicker than that flashes it as the finger lifts; and a touch that lands on
/// a list still moving only stops the list. It never recognizes, so it cannot
/// take a tap from the button or a drag from the scroll view.
struct ImmediateTouchDown: UIGestureRecognizerRepresentable {
    let onChange: (Bool) -> Void
    var onTap: () -> Void = {}

    func makeUIGestureRecognizer(context: Context) -> Observer { Observer() }

    func updateUIGestureRecognizer(_ recognizer: Observer, context: Context) {
        recognizer.onChange = onChange
        recognizer.onTap = onTap
    }

    final class Observer: UIGestureRecognizer {
        /// A little under UIScrollView's own touch-down delay of 150 ms.
        static let highlightDelay: TimeInterval = 0.12
        /// How long a quick tap's flash holds before it fades.
        static let flashHold: TimeInterval = 0.1

        var onChange: (Bool) -> Void = { _ in }
        var onTap: () -> Void = {}
        private var start: CGPoint?
        private var isHighlighted = false
        private var pendingHighlight: DispatchWorkItem?
        private var pendingFlashEnd: DispatchWorkItem?

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = touches.first else { return }
            beginTouch(at: touch.location(in: view))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = touches.first else { return }
            moveTouch(to: touch.location(in: view))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { endTouch(cancelled: false) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { endTouch(cancelled: true) }

        func beginTouch(at point: CGPoint) {
            guard start == nil else { return }
            endFlash()
            // A list still scrolling stops under the finger; the row stays
            // as it is and the lift is not a tap.
            guard !isScrolling else { state = .failed; return }
            start = point
            let highlight = DispatchWorkItem { [weak self] in self?.highlightIfStillDown() }
            pendingHighlight = highlight
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightDelay, execute: highlight)
        }

        /// The finger has rested long enough to mean the row.
        func highlightIfStillDown() {
            pendingHighlight = nil
            guard start != nil, !isScrolling else { return }
            setHighlighted(true)
        }

        func moveTouch(to point: CGPoint) {
            guard let start else { return }
            if hypot(point.x - start.x, point.y - start.y) > 10 || isScrolling { finish() }
        }

        func endTouch(cancelled: Bool) {
            let isTap = start != nil && !cancelled
            let flashes = isTap && !isHighlighted
            finish()
            if flashes { flash() }
            if isTap { onTap() }
        }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func reset() {
            super.reset()
            if start != nil { clearTouch() }
        }

        private func finish() {
            clearTouch()
            state = .failed
        }

        private func clearTouch() {
            start = nil
            pendingHighlight?.cancel()
            pendingHighlight = nil
            setHighlighted(false)
        }

        /// A tap that lifted before the grey came still shows it, briefly.
        private func flash() {
            setHighlighted(true)
            let end = DispatchWorkItem { [weak self] in self?.endFlash() }
            pendingFlashEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashHold, execute: end)
        }

        private func endFlash() {
            guard let pendingFlashEnd else { return }
            pendingFlashEnd.cancel()
            self.pendingFlashEnd = nil
            setHighlighted(false)
        }

        private func setHighlighted(_ highlighted: Bool) {
            guard highlighted != isHighlighted else { return }
            isHighlighted = highlighted
            onChange(highlighted)
        }

        /// Any scroll view the row sits in is being dragged or still gliding.
        private var isScrolling: Bool {
            sequence(first: view, next: { $0?.superview }).contains { ancestor in
                guard let scroll = ancestor as? UIScrollView else { return false }
                return scroll.isDragging || scroll.isDecelerating
            }
        }
    }
}
