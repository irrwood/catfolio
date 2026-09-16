import SwiftUI
import UIKit

/// The security page's open and close, drawn by us rather than by the
/// system's zoom.
///
/// On iOS 26 `.navigationTransition(.zoom)` owned the geometry and the
/// timing, and we could not steer either: the page cross-faded into a row
/// whose layout did not match it, leaving a double image; the tail of the
/// spring bounced the source; its shadow and curve were fixed. Here the
/// sheet itself is presented and dismissed without animation, and what moves
/// is a card in the window's top layer:
///
/// - Open: a snapshot of the row sits in a card with the page's ground. The
///   card grows from the row's frame to the sheet's while the snapshot fades
///   out and the shade comes up; the sheet, laid out underneath all along,
///   is revealed as the card fades away.
/// - Close (✕): a snapshot of the page sits in the card, the sheet is
///   dismissed at once, and the card shrinks back to wherever the row is
///   now, handing over to the row's snapshot on the way.
///
/// Layout changes, data arriving and chart work in the page or the list
/// cannot touch the snapshots mid-flight. A swipe down still dismisses the
/// sheet the system's way; presenters with no registered source (Research,
/// Returns) keep the plain sheet.
@MainActor
final class SecurityDetailSnapshotTransition {
    static let shared = SecurityDetailSnapshotTransition()

    enum OpenStyle {
        /// Present without animation; the card does the motion.
        case snapshot
        /// No usable source: the ordinary sheet animation.
        case plain
        /// A transition is already running; ignore the tap.
        case busy
    }

    struct SourceKey: Hashable {
        let id: AnyHashable
        let namespace: Namespace.ID
    }

    private struct Flight {
        let key: SourceKey
        let rowFrame: CGRect
        let rowSnapshot: UIView
    }

    private final class WeakMarker {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var sources: [SourceKey: WeakMarker] = [:]
    /// The source of the page being opened, until the sheet reports in.
    private var pending: Flight?
    /// The page currently on screen, if it was opened from a snapshot.
    private var presented: Flight?
    private weak var surface: UIView?
    /// The page's own view, inside `surface`.
    private weak var content: UIView?
    private weak var shade: UIView?
    private var overlay: UIView?
    private var settledActions: [() -> Void] = []

    private(set) var isAnimating = false
    /// From the tap until the card has landed.
    private var isOpening = false

    static let openDuration: TimeInterval = 0.46
    static let closeDuration: TimeInterval = 0.40

    // MARK: Sources

    func register(_ marker: UIView, for key: SourceKey) {
        sources[key] = WeakMarker(marker)
    }

    func unregister(_ marker: UIView, for key: SourceKey) {
        if sources[key]?.view === marker { sources[key] = nil }
    }

    /// The source's frame in its window, if it is on screen now.
    private func liveFrame(for key: SourceKey) -> (view: UIView, frame: CGRect)? {
        guard let marker = sources[key]?.view, let window = marker.window,
              !Self.isHiddenInHierarchy(marker) else { return nil }
        let frame = marker.convert(marker.bounds, to: window)
        guard frame.width > 1, frame.height > 1,
              window.bounds.intersects(frame) else { return nil }
        return (marker, frame)
    }

    #if DEBUG
    func hasLiveSource(id: AnyHashable, namespace: Namespace.ID) -> Bool {
        liveFrame(for: SourceKey(id: id, namespace: namespace)) != nil
    }
    #endif

    // MARK: Open

    func beginOpen(id: AnyHashable, namespace: Namespace.ID) -> OpenStyle {
        guard !isAnimating, pending == nil else { return .busy }
        guard !UIAccessibility.isReduceMotionEnabled else { return .plain }
        let key = SourceKey(id: id, namespace: namespace)
        guard let (marker, frame) = liveFrame(for: key),
              let snapshot = Self.snapshot(of: marker) else { return .plain }
        pending = Flight(key: key, rowFrame: frame, rowSnapshot: snapshot)
        isAnimating = true
        isOpening = true
        settledActions = []
        return .snapshot
    }

    /// Called by the sheet's backdrop as the sheet appears. Returns whether
    /// the open is ours to animate; if so the backdrop leaves its shade and
    /// the sheet hidden until the card lands.
    func claimPresentation(surface: UIView, content: UIView, shade: UIView) -> Bool {
        guard let flight = pending else { return false }
        pending = nil
        presented = flight
        self.surface = surface
        self.content = content
        self.shade = shade
        surface.alpha = 0
        shade.alpha = 0
        // After this pass, so the sheet has its final frame to aim at.
        DispatchQueue.main.async { [weak self] in self?.runOpen(flight) }
        return true
    }

    /// Whether the backdrop should leave this shade alone.
    func owns(shade: UIView) -> Bool {
        isAnimating && self.shade === shade
    }

    /// Runs `action` once the open has landed — at once if nothing is
    /// opening. The page holds back its lower cards until then.
    func whenOpenSettles(_ action: @escaping () -> Void) {
        if isOpening {
            settledActions.append(action)
        } else {
            action()
        }
    }

    private func runOpen(_ flight: Flight) {
        guard let surface, let window = surface.window else {
            finishOpen(revealing: surface)
            return
        }
        let target = surface.convert(surface.bounds, to: window)
        // The page, as it will be when the card lands, to grow inside the
        // card. Its own view, not the hidden sheet around it: showing the
        // sheet for the snapshot put a whole frame of it on screen.
        let page = content?.snapshotView(afterScreenUpdates: true)
        let pageOrigin = content.map { $0.convert($0.bounds, to: surface).origin } ?? .zero
        let pageSize = content?.bounds.size ?? target.size

        let scene = Scene(in: window, traits: window.traitCollection)
        overlay = scene.root

        let card = scene.card
        card.frame = flight.rowFrame
        card.layer.cornerRadius = Self.sourceRadius(for: flight.rowFrame)
        let startScale = flight.rowFrame.width / max(target.width, 1)
        if let page {
            // Scaled to the card's width and pinned to its top, the way the
            // page will sit once it is full size.
            page.frame = CGRect(x: pageOrigin.x * startScale, y: pageOrigin.y * startScale,
                                width: pageSize.width * startScale, height: pageSize.height * startScale)
            page.alpha = 0
            card.addSubview(page)
        }
        let row = flight.rowSnapshot
        row.frame = CGRect(origin: .zero, size: flight.rowFrame.size)
        card.addSubview(row)

        let widthScale = target.width / max(flight.rowFrame.width, 1)
        let motion = UIViewPropertyAnimator(duration: Self.openDuration, dampingRatio: 0.9) {
            card.frame = target
            card.layer.cornerRadius = SecurityDetailPresentation.cornerRadius
            page?.frame = CGRect(origin: pageOrigin, size: pageSize)
            row.frame = CGRect(x: 0, y: 0, width: target.width, height: flight.rowFrame.height * widthScale)
            scene.dim.alpha = 1
        }
        motion.addCompletion { [weak self] _ in self?.finishOpen(revealing: surface, scene: scene) }
        motion.startAnimation()
        // The row gives way to the page in the first third of the flight.
        UIView.animate(withDuration: Self.openDuration * 0.4, delay: 0, options: [.curveEaseInOut]) {
            row.alpha = 0
            page?.alpha = 1
        }
    }

    private func finishOpen(revealing surface: UIView?, scene: Scene? = nil) {
        // The shade under the sheet takes over from the one in the overlay:
        // the same colour at the same strength, in the same frame.
        surface?.alpha = 1
        shade?.alpha = 1
        scene?.dim.alpha = 0
        isOpening = false
        let actions = settledActions
        settledActions = []
        guard let scene else {
            overlay?.removeFromSuperview()
            overlay = nil
            isAnimating = false
            actions.forEach { $0() }
            return
        }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            scene.card.alpha = 0
        } completion: { [weak self] _ in
            scene.root.removeFromSuperview()
            if self?.overlay === scene.root { self?.overlay = nil }
            self?.isAnimating = false
            // Only now: the page's lower cards are a heavy build, and run in
            // the same turn as this fade they held it — the card sat opaque
            // over the finished page for most of a second.
            actions.forEach { $0() }
        }
    }

    // MARK: Close

    /// Closes the page from its ✕. Dismisses at once and shrinks a snapshot
    /// of the page back into its row; without a row on screen, the sheet's
    /// own dismissal.
    func close(perform dismiss: @escaping () -> Void) {
        guard !isAnimating else { return }
        guard let flight = presented, let surface, let window = surface.window,
              !UIAccessibility.isReduceMotionEnabled,
              let page = surface.snapshotView(afterScreenUpdates: false) else {
            dismiss()
            return
        }
        let start = surface.convert(surface.bounds, to: window)
        let end = liveFrame(for: flight.key)?.frame ?? flight.rowFrame
        isAnimating = true

        let scene = Scene(in: window, traits: window.traitCollection)
        overlay = scene.root
        scene.dim.alpha = 1
        let card = scene.card
        card.frame = start
        card.layer.cornerRadius = SecurityDetailPresentation.cornerRadius
        page.frame = CGRect(origin: .zero, size: start.size)
        card.addSubview(page)
        let row = flight.rowSnapshot
        row.alpha = 0
        row.frame = CGRect(x: 0, y: 0, width: start.width,
                           height: end.height * start.width / max(end.width, 1))
        card.addSubview(row)

        // The sheet goes now; the card is what the reader sees leave.
        surface.alpha = 0
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { dismiss() }

        let heightScale = end.width / max(start.width, 1)
        let motion = UIViewPropertyAnimator(duration: Self.closeDuration, dampingRatio: 0.92) {
            card.frame = end
            card.layer.cornerRadius = Self.sourceRadius(for: end)
            page.frame = CGRect(x: 0, y: 0, width: end.width, height: start.height * heightScale)
            row.frame = CGRect(origin: .zero, size: end.size)
            scene.dim.alpha = 0
        }
        motion.addCompletion { [weak self] _ in
            scene.root.removeFromSuperview()
            guard let self else { return }
            if self.overlay === scene.root { self.overlay = nil }
            self.isAnimating = false
        }
        motion.startAnimation()
        UIView.animate(withDuration: Self.closeDuration * 0.5, delay: Self.closeDuration * 0.3,
                       options: [.curveEaseInOut]) {
            page.alpha = 0
            row.alpha = 1
        }
        presented = nil
        self.surface = nil
        self.content = nil
        self.shade = nil
    }

    /// The sheet is gone, however it went — ✕, a swipe, or a presenter.
    func presentationDidEnd() {
        content = nil
        presented = nil
        pending = nil
        isOpening = false
        settledActions = []
        surface = nil
        shade = nil
        if overlay == nil { isAnimating = false }
    }

    // MARK: Pieces

    /// The overlay: a shade over everything and the moving card above it,
    /// drawn in the window's own top layer so it sits over the sheet too.
    @MainActor
    private struct Scene {
        let root: UIView
        let dim: UIView
        let card: GroundCard

        init(in window: UIWindow, traits: UITraitCollection) {
            root = UIView(frame: window.bounds)
            root.isUserInteractionEnabled = false
            root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dim = UIView(frame: root.bounds)
            dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dim.backgroundColor = SecurityDetailPresentation.backdropColor.resolvedColor(with: traits)
            dim.alpha = 0
            card = GroundCard(traits: traits)
            root.addSubview(dim)
            root.addSubview(card)
            window.addSubview(root)
        }
    }

    /// A card painted with the page's ground, top to bottom.
    private final class GroundCard: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        init(traits: UITraitCollection) {
            super.init(frame: .zero)
            clipsToBounds = true
            layer.cornerCurve = .continuous
            let gradient = layer as? CAGradientLayer
            gradient?.colors = [
                SecurityDetailPresentation.uiGroundTop.resolvedColor(with: traits).cgColor,
                SecurityDetailPresentation.uiGroundBottom.resolvedColor(with: traits).cgColor,
            ]
            gradient?.startPoint = CGPoint(x: 0.5, y: 0)
            gradient?.endPoint = CGPoint(x: 0.5, y: 1)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }
    }

    /// A snapshot of just the source's own layers — taken from its scroll
    /// view, not the window, so nothing presented over the list is in it.
    private static func snapshot(of marker: UIView) -> UIView? {
        var host: UIView = marker.window ?? marker
        var ancestor = marker.superview
        while let view = ancestor {
            if view is UIScrollView {
                host = view
                break
            }
            ancestor = view.superview
        }
        let rect = marker.convert(marker.bounds, to: host)
        return host.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero)
    }

    /// Rows are square-edged and bars are rounded; a card that starts as a
    /// gentle rounded rectangle reads as either.
    private static func sourceRadius(for frame: CGRect) -> CGFloat {
        min(12, frame.height / 2)
    }

    private static func isHiddenInHierarchy(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha < 0.01 { return true }
            current = candidate.superview
        }
        return false
    }
}

/// Marks the view a security page opens from, by sitting behind it.
struct SecurityDetailSourceMarker: UIViewRepresentable {
    let key: SecurityDetailSnapshotTransition.SourceKey

    func makeUIView(context: Context) -> MarkerView { MarkerView() }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.key = key
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        view.unregister()
    }

    final class MarkerView: UIView {
        var key: SecurityDetailSnapshotTransition.SourceKey? {
            didSet {
                guard key != oldValue else { return }
                if let oldValue { SecurityDetailSnapshotTransition.shared.unregister(self, for: oldValue) }
                registerIfVisible()
            }
        }

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { unregister() } else { registerIfVisible() }
        }

        private func registerIfVisible() {
            guard window != nil, let key else { return }
            SecurityDetailSnapshotTransition.shared.register(self, for: key)
        }

        func unregister() {
            guard let key else { return }
            SecurityDetailSnapshotTransition.shared.unregister(self, for: key)
        }
    }
}
