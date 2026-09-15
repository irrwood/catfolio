import SwiftUI
import UIKit

/// The plot finishes preparing after the model has published its chart data.
struct PortfolioHeroReadyPreference: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

@MainActor
private enum PortfolioLoadRippleHistory {
    static var hasPlayed = false
}

/// One completion cue per app launch, independent of tab/view reconstruction.
/// Only the temporary image animates; financial views do not update per frame.
struct PortfolioLoadRipple: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let isReady: Bool
    let isScrolling: Bool
    @State private var isVisible = false
    @State private var isHeroReady = false
    @State private var observesTouches = false
    @State private var captureID: UUID?
    @State private var snapshot: UIImage?
    @State private var startedAt: Date?
    @State private var completionTask: Task<Void, Never>?

    private static let duration: TimeInterval = 1.2

    private var canStart: Bool {
        isVisible && scenePhase == .active && isReady && isHeroReady && !isScrolling
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    ZStack {
                        PortfolioRippleCapture(
                            requestID: captureID,
                            observesTouches: observesTouches,
                            onCapture: receiveSnapshot,
                            onInteraction: stop
                        )
                        if let snapshot, let startedAt {
                            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                                Image(uiImage: snapshot)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .layerEffect(
                                        ShaderLibrary.portfolioLoadRipple(
                                            .float2(Float(geometry.size.width), Float(geometry.size.height)),
                                            .float(timeline.date.timeIntervalSince(startedAt)),
                                            .float(Self.duration)
                                        ),
                                        maxSampleOffset: CGSize(width: 6, height: 6)
                                    )
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .onChange(of: geometry.size) { _, _ in stop() }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onPreferenceChange(PortfolioHeroReadyPreference.self) { isHeroReady = $0 }
            .onAppear { isVisible = true }
            .onDisappear {
                isVisible = false
                stop()
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { stop() }
            }
            .task(id: canStart) {
                guard canStart else {
                    stop()
                    return
                }
                guard !PortfolioLoadRippleHistory.hasPlayed else { return }
                PortfolioLoadRippleHistory.hasPlayed = true
                guard !reduceMotion else { return }
                observesTouches = true
                // The existing plot/bar entrances last at most 0.45 seconds.
                // Let them settle before taking the single completed frame.
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, observesTouches else { return }
                captureID = UUID()
            }
    }

    private func receiveSnapshot(_ image: UIImage?) {
        guard observesTouches, canStart, !reduceMotion, let image else {
            stop()
            return
        }
        snapshot = image
        startedAt = .now
        completionTask?.cancel()
        completionTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(Self.duration)) } catch { return }
            guard !Task.isCancelled else { return }
            stop()
        }
    }

    private func stop() {
        completionTask?.cancel()
        completionTask = nil
        observesTouches = false
        captureID = nil
        startedAt = nil
        snapshot = nil
    }
}

/// UIKit-backed charts and native glass cannot be inputs to a SwiftUI layer
/// shader. Capture only this viewport once, in memory, then shade that image.
/// The live page stays mounted and interactive underneath throughout.
private struct PortfolioRippleCapture: UIViewRepresentable {
    let requestID: UUID?
    let observesTouches: Bool
    let onCapture: (UIImage?) -> Void
    let onInteraction: () -> Void

    func makeUIView(context: Context) -> CaptureView { CaptureView() }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.onCapture = onCapture
        view.onInteraction = onInteraction
        view.setObservesTouches(observesTouches)
        view.requestCapture(requestID)
    }

    static func dismantleUIView(_ view: CaptureView, coordinator: ()) { view.tearDown() }

    final class CaptureView: UIView, UIGestureRecognizerDelegate {
        var onCapture: ((UIImage?) -> Void)?
        var onInteraction: (() -> Void)?
        private var requestID: UUID?
        private var handledID: UUID?
        private var observesTouches = false
        private weak var observedWindow: UIWindow?
        private lazy var touchObserver: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer()
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            return gesture
        }()

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateTouchObserver()
            scheduleCaptureIfNeeded()
        }

        func setObservesTouches(_ enabled: Bool) {
            observesTouches = enabled
            updateTouchObserver()
        }

        func requestCapture(_ id: UUID?) {
            requestID = id
            scheduleCaptureIfNeeded()
        }

        private func scheduleCaptureIfNeeded() {
            guard window != nil, let id = requestID, handledID != id else { return }
            handledID = id
            // Run outside SwiftUI's view update, after the ready content mounts.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requestID == id, self.observesTouches else { return }
                self.captureViewport()
            }
        }

        private func captureViewport() {
            guard let window, bounds.width > 0, bounds.height > 0,
                  !window.isHidden, window.windowScene?.activationState == .foregroundActive else {
                onCapture?(nil)
                return
            }
            let viewport = convert(bounds, to: window)
            guard window.bounds.contains(viewport) else {
                onCapture?(nil)
                return
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            format.preferredRange = .standard
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
            var rendered = false
            let image = renderer.image { context in
                context.cgContext.translateBy(x: -viewport.minX, y: -viewport.minY)
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            onCapture?(rendered ? image : nil)
        }

        private func updateTouchObserver() {
            let nextWindow = observesTouches ? window : nil
            guard observedWindow !== nextWindow else { return }
            observedWindow?.removeGestureRecognizer(touchObserver)
            observedWindow = nextWindow
            nextWindow?.addGestureRecognizer(touchObserver)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Observe the beginning of any touch, then refuse the gesture so
            // taps, chart holds and the native scroll gestures keep ownership.
            onInteraction?()
            return false
        }

        func tearDown() {
            requestID = nil
            observesTouches = false
            observedWindow?.removeGestureRecognizer(touchObserver)
            observedWindow = nil
            onCapture = nil
            onInteraction = nil
        }
    }
}
