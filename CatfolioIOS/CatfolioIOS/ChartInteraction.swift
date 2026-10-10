import ImageIO
import Observation
import SwiftUI
import UIKit

struct ChartDateRange: Equatable {
    let start: Date
    let end: Date

    init(_ first: Date, _ second: Date) {
        start = min(first, second)
        end = max(first, second)
    }
}

struct ChartRangeSummary: View {
    @Environment(\.locale) private var appLocale
    let dateText: String
    let primaryValue: String
    let secondaryValue: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dateText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Spacer(minLength: 0)
                FinancialText(primaryValue)
                    .appNumber(.callout, weight: .bold)
                    .foregroundStyle(color)
                    .lineLimit(1)

                FinancialText(secondaryValue)
                    .appNumber(.callout, weight: .bold)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("区间 \(dateText)，变化 \(primaryValue)，\(secondaryValue)"))
    }
}

/// Shared interaction and visual constants for every chart in the app.
enum ChartInteractionStyle {
    static let activationDuration: TimeInterval = 0.23
    static let preActivationMovementTolerance: CGFloat = 10
    /// The strip along the leading edge that belongs to the system's back
    /// and dismiss swipes; a chart never starts an inspection there.
    static let systemEdgeWidth: CGFloat = 20
    static let dimmedSeriesOpacity = 0.30
    static let selectionHapticMinimumInterval: TimeInterval = 0.035
    static let hapticsPreferenceKey = "catfolio.haptics"
}

struct ChartInteractionValue {
    let primaryLocation: CGPoint
    let secondaryLocation: CGPoint?

    var touchCount: Int { secondaryLocation == nil ? 1 : 2 }

    var horizontalSelectionLocations: [CGPoint] {
        [primaryLocation, secondaryLocation]
            .compactMap { $0 }
            .sorted { $0.x < $1.x }
    }
}

/// The single interaction entry point for charts. SwiftUI gestures expose one
/// pointer location, so this UIKit bridge owns the true multi-touch state and
/// lets every chart share the same ScrollView-safe activation policy.
struct ChartInteractionOverlay: UIViewRepresentable {
    let onValueChanged: (ChartInteractionValue) -> Void
    let onInteractionEnded: (Int) -> Void

    init(
        onValueChanged: @escaping (ChartInteractionValue) -> Void,
        onInteractionEnded: @escaping (Int) -> Void
    ) {
        self.onValueChanged = onValueChanged
        self.onInteractionEnded = onInteractionEnded
    }

    func makeUIView(context: Context) -> TouchCaptureView {
        let view = TouchCaptureView()
        view.onValueChanged = onValueChanged
        view.onInteractionEnded = onInteractionEnded
        return view
    }

    func updateUIView(_ uiView: TouchCaptureView, context: Context) {
        uiView.onValueChanged = onValueChanged
        uiView.onInteractionEnded = onInteractionEnded
    }

    final class TouchCaptureView: UIView {
        var onValueChanged: (ChartInteractionValue) -> Void = { _ in }
        var onInteractionEnded: (Int) -> Void = { _ in }
        private var activePressTouchCount = 0

        private lazy var inspectionPress: ChartDetailGestureRecognizer = {
            let recognizer = ChartDetailGestureRecognizer(
                target: self,
                action: #selector(handleInspectionPress(_:))
            )
            recognizer.minimumPressDuration = ChartInteractionStyle.activationDuration
            recognizer.allowableMovement = ChartInteractionStyle.preActivationMovementTolerance
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = recognizer
            return recognizer
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            isExclusiveTouch = false
            backgroundColor = .clear
            isAccessibilityElement = false
            // A normal swipe exceeds `allowableMovement` before the hold
            // completes, so the ancestor ScrollView keeps vertical gestures.
            // After the hold succeeds, the first finger owns the interaction.
            // A second finger can join or leave without restarting it.
            addGestureRecognizer(inspectionPress)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc
        private func handleInspectionPress(_ recognizer: ChartDetailGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                guard let value = recognizer.currentValue else { return }
                if recognizer.state == .began {
                    playActivationHapticIfEnabled()
                }
                activePressTouchCount = value.touchCount
                onValueChanged(value)
            case .ended, .cancelled:
                if activePressTouchCount > 0 {
                    onInteractionEnded(activePressTouchCount)
                }
                activePressTouchCount = 0
            case .failed:
                // A pre-activation scroll should not clear an existing chart
                // value or emit an interaction-ended callback.
                activePressTouchCount = 0
            default:
                break
            }
        }

        private func playActivationHapticIfEnabled() {
            let defaults = UserDefaults.standard
            let isEnabled = defaults.object(forKey: ChartInteractionStyle.hapticsPreferenceKey) as? Bool ?? true
            guard isEnabled else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
        }

    }

    /// One recognizer owns the complete interaction so adding a second finger
    /// never competes with, cancels, or restarts the active one-finger hover.
    final class ChartDetailGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var minimumPressDuration = ChartInteractionStyle.activationDuration
        var allowableMovement = ChartInteractionStyle.preActivationMovementTolerance

        private weak var primaryTouch: UITouch?
        private var trackedTouches: [UITouch] = []
        private var primaryStartLocation = CGPoint.zero
        private var activationWorkItem: DispatchWorkItem?

        var isInspecting: Bool { state == .began || state == .changed }

        // A moving finger fails the hold after 10pt, letting content backswipe
        // start immediately. A held finger wins instead and keeps the whole
        // inspection (including a second finger) until it ends. Do not replace
        // UIKit's own gesture delegates or disable navigation globally.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard #available(iOS 26.0, *) else { return false }
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController,
                   let navigation = controller.navigationController {
                    return otherGestureRecognizer === navigation.interactiveContentPopGestureRecognizer
                }
                responder = current.next
            }
            return false
        }

        var currentValue: ChartInteractionValue? {
            guard let view, let primaryTouch = trackedTouches.first else { return nil }
            return ChartInteractionValue(
                primaryLocation: primaryTouch.location(in: view),
                secondaryLocation: trackedTouches.dropFirst().first?.location(in: view)
            )
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard state == .possible || state == .began || state == .changed else { return }

            let newTouches = touches
                .filter { touch in !trackedTouches.contains(where: { $0 === touch }) }
                .sorted { lhs, rhs in
                    lhs.timestamp == rhs.timestamp
                        ? lhs.location(in: view).x < rhs.location(in: view).x
                        : lhs.timestamp < rhs.timestamp
                }

            for touch in newTouches where trackedTouches.count < 2 {
                trackedTouches.append(touch)
            }

            if primaryTouch == nil, let firstTouch = trackedTouches.first, let view {
                // A touch that lands on the screen's leading edge is the
                // system's back or dismiss swipe. A slow one stayed inside
                // the hold tolerance long enough for the chart to take it,
                // and the page stuck half-way instead of going back.
                if let window = view.window,
                   firstTouch.location(in: window).x < ChartInteractionStyle.systemEdgeWidth {
                    trackedTouches.removeAll()
                    state = .failed
                    return
                }
                primaryTouch = firstTouch
                primaryStartLocation = firstTouch.location(in: view)
                scheduleActivation()
            } else if state == .began || state == .changed {
                // The second finger upgrades the active hover in place.
                state = .changed
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let primaryTouch, let view else { return }

            if state == .possible {
                let location = primaryTouch.location(in: view)
                let distance = hypot(
                    location.x - primaryStartLocation.x,
                    location.y - primaryStartLocation.y
                )
                if distance > allowableMovement {
                    cancelActivation()
                    state = .failed
                }
            } else if state == .began || state == .changed {
                state = .changed
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            finishTouches(touches, cancelled: false)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            finishTouches(touches, cancelled: true)
        }

        override func reset() {
            cancelActivation()
            primaryTouch = nil
            trackedTouches.removeAll(keepingCapacity: true)
            primaryStartLocation = .zero
            super.reset()
        }

        private func scheduleActivation() {
            cancelActivation()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.state == .possible, self.primaryTouch != nil else { return }
                self.state = .began
            }
            activationWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + minimumPressDuration,
                execute: workItem
            )
        }

        private func cancelActivation() {
            activationWorkItem?.cancel()
            activationWorkItem = nil
        }

        private func finishTouches(_ touches: Set<UITouch>, cancelled: Bool) {
            let primaryEnded = touches.contains { touch in touch === primaryTouch }
            trackedTouches.removeAll { trackedTouch in
                touches.contains { touch in touch === trackedTouch }
            }

            guard primaryEnded else {
                // Removing only the second finger downgrades to one-finger
                // hover and keeps the selected point/tooltip alive.
                if state == .began || state == .changed {
                    state = .changed
                }
                return
            }

            cancelActivation()
            if state == .began || state == .changed {
                state = cancelled ? .cancelled : .ended
            } else if state == .possible {
                state = .failed
            }
        }
    }

    /// Check only the page being dismissed, so a chart in another sheet or
    /// window cannot block this page's navigation.
    static func isInspecting(in view: UIView) -> Bool {
        if view.gestureRecognizers?.contains(where: {
            ($0 as? ChartDetailGestureRecognizer)?.isInspecting == true
        }) == true { return true }
        return view.subviews.contains { isInspecting(in: $0) }
    }
}

/// Convenience adapter for charts that inspect only one point. It still uses
/// the shared interaction state machine, so scroll arbitration, timing,
/// haptics and cleanup cannot drift from time-series charts.
struct ChartPointInteractionOverlay: View {
    @Environment(\.locale) private var appLocale
    let onLocationChanged: (CGPoint) -> Void
    let onInteractionEnded: () -> Void

    var body: some View {
        ChartInteractionOverlay(
            onValueChanged: { value in
                onLocationChanged(value.primaryLocation)
            },
            onInteractionEnded: { _ in
                onInteractionEnded()
            }
        )
    }
}

/// Applies one hard-edged alpha mask to the complete visual series container.
/// Line, fill, markers, endpoints and future effects therefore cannot drift
/// into separate dimming implementations.
struct ChartSeriesInteractionMask: ViewModifier {
    let selectedRange: ClosedRange<CGFloat>?
    let selectedX: CGFloat?
    let dimsAfterSingleSelection: Bool

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    if let selectedRange {
                        let lower = min(width, max(0, selectedRange.lowerBound))
                        let upper = min(width, max(lower, selectedRange.upperBound))

                        Rectangle()
                            .fill(Color.white.opacity(ChartInteractionStyle.dimmedSeriesOpacity))

                        Rectangle()
                            .fill(Color.white)
                            .frame(width: upper - lower)
                            .offset(x: lower)
                    } else if dimsAfterSingleSelection, let selectedX {
                        let boundary = min(width, max(0, selectedX))

                        Rectangle()
                            .fill(Color.white.opacity(ChartInteractionStyle.dimmedSeriesOpacity))

                        Rectangle()
                            .fill(Color.white)
                            .frame(width: boundary)
                    } else {
                        Rectangle().fill(Color.white)
                    }
                }
            }
        }
    }
}

extension View {
    func chartSeriesInteractionMask(
        selectedRange: ClosedRange<CGFloat>?,
        selectedX: CGFloat?,
        dimsAfterSingleSelection: Bool
    ) -> some View {
        modifier(ChartSeriesInteractionMask(
            selectedRange: selectedRange,
            selectedX: selectedX,
            dimsAfterSingleSelection: dimsAfterSingleSelection
        ))
    }
}
