import SwiftUI
import UIKit

/// A permission captured at touch-down, not inferred again at the bottom of
/// a long drag. Completing a snap while the finger is down cannot unlock it.
struct PortfolioHomeRefreshGate {
    private(set) var permitsRefresh = false
    private(set) var isRefreshing = false

    mutating func beginTouch(offset: CGFloat, isSettling: Bool, isMoving: Bool) {
        permitsRefresh = abs(offset) <= 0.5 && !isSettling && !isMoving && !isRefreshing
    }

    mutating func beginRefresh() -> Bool {
        guard permitsRefresh, !isRefreshing else { return false }
        isRefreshing = true
        permitsRefresh = false
        return true
    }

    mutating func finishRefresh() { isRefreshing = false }
    mutating func lockRefresh() { permitsRefresh = false }
}

enum PortfolioHomeSnapMotion {
    /// A damped spring, the motion UIKit's own sheets and snaps use, in place
    /// of a fixed 300ms cubic curve. The panel leaves at the speed the finger
    /// let go — a flick lands quickly, a slow release lands softly — and
    /// settles with one small overshoot instead of running the same shape
    /// whatever the gesture was.
    static let response: Double = 0.42
    static let dampingRatio: Double = 0.82
    /// Never run a snap longer than this, whatever the spring would do.
    static let maximumDuration: TimeInterval = 1.2
    /// A release faster than this adds nothing but overshoot.
    static let maximumVelocity: CGFloat = 5000

    struct Spring {
        let start: CGFloat
        let end: CGFloat
        /// Points per second, positive towards a larger offset.
        let velocity: CGFloat
        var reduceMotion = false

        private var omega: Double { 2 * .pi / PortfolioHomeSnapMotion.response }
        private var zeta: Double { PortfolioHomeSnapMotion.dampingRatio }
        private var omegaD: Double { omega * (1 - zeta * zeta).squareRoot() }
        private var d0: Double { Double(start - end) }
        private var b: Double { (Double(velocity) + zeta * omega * d0) / omegaD }

        /// Exact position of an underdamped spring released at `start` with
        /// `velocity`; only its own overshoot leaves the two endpoints.
        func value(at time: TimeInterval) -> CGFloat {
            guard !reduceMotion, time > 0 else { return reduceMotion ? end : start }
            let decay = exp(-zeta * omega * time)
            let displacement = decay * (d0 * cos(omegaD * time) + b * sin(omegaD * time))
            return end + CGFloat(displacement)
        }

        func speed(at time: TimeInterval) -> CGFloat {
            guard !reduceMotion else { return 0 }
            let decay = exp(-zeta * omega * time)
            let c = cos(omegaD * time), s = sin(omegaD * time)
            return CGFloat(decay * (-zeta * omega * (d0 * c + b * s) + omegaD * (b * c - d0 * s)))
        }

        func isSettled(at time: TimeInterval) -> Bool {
            reduceMotion || time >= PortfolioHomeSnapMotion.maximumDuration
                || (abs(value(at: time) - end) < 0.5 && abs(speed(at: time)) < 20)
        }
    }

    static func target(start: CGFloat, released: CGFloat, velocity: CGFloat,
                       detent: CGFloat, maximum: CGFloat) -> CGFloat? {
        guard maximum >= detent else { return nil }
        if start < detent - 8 {
            if released <= 0 { return nil } // Native, eligible refresh rebound.
            if velocity > 0.2 { return detent }
            if velocity < -0.2 { return 0 }
            let travel = released - start
            if abs(travel) > 8 { return travel > 0 ? detent : 0 }
            return released >= detent / 2 ? detent : 0
        }
        // Lists return to their top before the panel can fall. A drag that
        // actually enters the panel interval can fall in the same gesture,
        // but never becomes a refresh gesture on its way through zero.
        if released < detent - 0.5 {
            if velocity > 0.2 { return detent }
            if velocity < -0.2 || released < detent - 8 { return 0 }
            return detent
        }
        return nil // Keep native free scrolling above the panel's upper stop.
    }
}

/// Adapts just the home ScrollView. UIKit retains the pan, list inertia and
/// the pull's rebound; the two panel landings run one explicit spring clock.
/// Unimplemented delegate methods are forwarded to SwiftUI's own delegate.
@MainActor
final class PortfolioHomeScrollController: NSObject, UIScrollViewDelegate {
    weak var scrollView: UIScrollView?
    private weak var forwardedDelegate: UIScrollViewDelegate?
    /// The spinner in the gap a pull opens above the page. Not a
    /// UIRefreshControl: that holds the page open while it refreshes, and
    /// ended early it broke the rebound and did not fire on the next pull.
    let pullIndicator = UIActivityIndicatorView(style: .medium)
    private(set) var gate = PortfolioHomeRefreshGate()
    private(set) var isSettling = false
    private(set) var gestureStart: CGFloat = 0
    var detent: CGFloat = 343
    var reduceMotion = false
    var onOffset: (CGFloat, CGFloat) -> Void = { _, _ in }
    var refresh: () async -> Void = {}
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    private var touchObserver: PortfolioHomeTouchObserver?
    private var hasTouch = false
    private var isMoving = false
    private var isCorrectingOffset = false
    private var pendingTarget: CGFloat?
    private var releaseVelocity: CGFloat = 0
    private var animation: (spring: PortfolioHomeSnapMotion.Spring, time: CFTimeInterval)?
    private var displayLink: CADisplayLink?
    private var refreshTask: Task<Void, Never>?
    /// How far past the top a released pull has to be to refresh.
    static let refreshPull: CGFloat = 90
    /// The overscroll on screen belongs to a pull that began settled at the
    /// top: until the page is back up it rebounds natively and the hero
    /// follows it, even once the refresh it started has run.
    private(set) var eligiblePull = false
    private var generation = 0
    private var isChangingAttachment = false
    /// When the latest touch came down on a list that was still moving.
    private var motionCaughtAt: CFTimeInterval?
    private var touchSequence = 0

    /// Whether the touch now ending came down on a moving list — a flick
    /// still decelerating, or the snap to a stop. That touch stops and catches
    /// the list; it is not a tap on whichever row slid under
    /// the finger, which is how a tap used to open the row above or below.
    var touchCaughtMotion: Bool {
        motionCaughtAt != nil
    }

    override init() {
        super.init()
        pullIndicator.color = .label
        pullIndicator.hidesWhenStopped = false
        pullIndicator.isUserInteractionEnabled = false
        pullIndicator.alpha = 0
        pullIndicator.accessibilityIdentifier = "home-refresh"
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardedDelegate?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        forwardedDelegate?.responds(to: selector) == true ? forwardedDelegate : super.forwardingTarget(for: selector)
    }

    func attach(to scroll: UIScrollView) {
        guard !isChangingAttachment else { return }
        isChangingAttachment = true
        defer { isChangingAttachment = false }
        // A disappearing/recreated bridge can briefly share UIKit's scroll
        // view. Never forward to another home proxy: A -> B -> A recurses
        // inside UIScrollView's delegate capability checks before any touch.
        if let previous = scroll.delegate as? PortfolioHomeScrollController, previous !== self {
            previous.detach()
            // An attachment already inside a UIKit callback must finish first.
            guard !(scroll.delegate is PortfolioHomeScrollController) else { return }
        }
        if scrollView !== scroll {
            detachBinding()
            scrollView = scroll
            let observer = PortfolioHomeTouchObserver()
            observer.onTouchBegan = { [weak self] in self?.touchBegan() }
            observer.onTouchEnded = { [weak self] in self?.touchEnded() }
            scroll.addGestureRecognizer(observer)
            touchObserver = observer
            scroll.addSubview(pullIndicator)
            layoutPullIndicator()
        }
        if scroll.delegate !== self {
            forwardedDelegate = scroll.delegate
            scroll.delegate = self
        }
    }

    func detach() {
        guard !isChangingAttachment else { return }
        isChangingAttachment = true
        defer { isChangingAttachment = false }
        detachBinding()
    }

    private func detachBinding() {
        generation += 1
        displayLink?.invalidate()
        displayLink = nil
        animation = nil
        pendingTarget = nil
        isSettling = false
        let scroll = scrollView
        let delegate = forwardedDelegate
        let observer = touchObserver
        // Clear our binding before UIKit can synchronously lay out after
        // removing the indicator and call BoundaryView.connect again.
        scrollView = nil
        forwardedDelegate = nil
        touchObserver = nil
        if let scroll {
            if scroll.delegate === self { scroll.delegate = delegate }
            if pullIndicator.superview === scroll { pullIndicator.removeFromSuperview() }
            if let observer { scroll.removeGestureRecognizer(observer) }
        }
        hasTouch = false
        isMoving = false
        eligiblePull = false
        motionCaughtAt = nil
    }

    private var offset: CGFloat {
        guard let scroll = scrollView else { return 0 }
        return scroll.contentOffset.y + scroll.adjustedContentInset.top
    }

    private var maximum: CGFloat {
        guard let scroll = scrollView else { return 0 }
        return max(0, scroll.contentSize.height + scroll.adjustedContentInset.top
                   + scroll.adjustedContentInset.bottom - scroll.bounds.height)
    }

    func touchBegan() {
        guard !hasTouch, let scroll = scrollView else { return }
        hasTouch = true
        touchSequence += 1
        gestureStart = offset
        motionCaughtAt = isSettling || isMoving || scroll.isDecelerating ? clock() : nil
        gate.beginTouch(offset: offset, isSettling: isSettling,
                        isMoving: isMoving || scroll.isDecelerating)
        eligiblePull = gate.permitsRefresh
        // Native deceleration stops under a finger; our display-link spring
        // must do the same. Otherwise each further tap catches the still-moving
        // sheet and is rejected until the spring eventually finishes.
        if isSettling {
            cancelSnap()
            let stopped = min(maximum, max(0, offset))
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                y: stopped - scroll.adjustedContentInset.top), animated: false)
            isMoving = false
        }
        layoutPullIndicator()
    }

    func touchEnded() {
        hasTouch = false
        let sequence = touchSequence
        // Keep the stopped-motion guard through this event's button callbacks,
        // then release it so accessibility actions cannot inherit an old touch.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasTouch, self.touchSequence == sequence else { return }
            self.motionCaughtAt = nil
        }
    }

    private func cancelSnap() {
        generation += 1
        displayLink?.invalidate()
        displayLink = nil
        animation = nil
        pendingTarget = nil
        isSettling = false
    }

    /// Centred in the gap the pull opens, clearer as the pull nears the
    /// refresh distance, and back up with the page. A locked pull shows none.
    func layoutPullIndicator() {
        guard let scroll = scrollView else { return }
        let pull = max(0, -offset)
        let shown = eligiblePull && pull > 0
        pullIndicator.alpha = shown ? min(1, pull / Self.refreshPull) : 0
        pullIndicator.center = CGPoint(x: scroll.bounds.width / 2, y: -pull / 2)
        if shown, scroll.subviews.last !== pullIndicator { scroll.bringSubviewToFront(pullIndicator) }
        if shown != pullIndicator.isAnimating {
            shown ? pullIndicator.startAnimating() : pullIndicator.stopAnimating()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if !hasTouch { touchBegan() }
        cancelSnap()
        // Snapshot permission is retained, even when interrupting an animation
        // exactly on the zero crossing. Only a new, settled touch can unlock it.
        gestureStart = offset
        isMoving = true
        forwardedDelegate?.scrollViewWillBeginDragging?(scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isCorrectingOffset else { return }
        let raw = offset
        if !isSettling && !gate.isRefreshing && isMoving {
            // A touch can catch the curve a few pixels below zero. Preserve
            // that captured position (no jump), but allow no further pull.
            let floor: CGFloat = eligiblePull ? -.greatestFiniteMagnitude : min(0, gestureStart)
            let ceiling = gestureStart < detent - 8 && maximum >= detent
                ? detent : CGFloat.greatestFiniteMagnitude
            let constrained = min(ceiling, max(floor, raw))
            if constrained != raw {
                isCorrectingOffset = true
                scrollView.contentOffset.y = constrained - scrollView.adjustedContentInset.top
                isCorrectingOffset = false
            }
        }
        forwardedDelegate?.scrollViewDidScroll?(scrollView)
        if !hasTouch, offset >= 0 { eligiblePull = false }
        layoutPullIndicator()
        publishOffset()
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        forwardedDelegate?.scrollViewDidChangeAdjustedContentInset?(scrollView)
        // An inset change can arrive without a didScroll event. Keep the
        // header's cached geometry in sync with that native change.
        publishOffset()
    }

    private func publishOffset() {
        // Signed animation offsets also pin the hero during the lower-stop
        // overshoot. Only eligible native pulls are exposed as pull distance.
        let pulling = eligiblePull || gate.permitsRefresh || gate.isRefreshing
        onOffset(isSettling || !pulling ? offset : max(0, offset), pulling ? max(0, -offset) : 0)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        forwardedDelegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity,
                                                       targetContentOffset: targetContentOffset)
        guard !gate.isRefreshing else { return }
        let released = offset
        // A pull let go this far down refreshes, once; the page then
        // rebounds natively whatever the refresh is doing.
        if eligiblePull, released < -Self.refreshPull { startRefresh() }
        // UIScrollView reports points per millisecond; the spring wants seconds.
        releaseVelocity = min(PortfolioHomeSnapMotion.maximumVelocity,
                              max(-PortfolioHomeSnapMotion.maximumVelocity, velocity.y * 1000))
        pendingTarget = PortfolioHomeSnapMotion.target(start: gestureStart, released: released,
                                                       velocity: velocity.y, detent: detent, maximum: maximum)
        if released < 0 && !eligiblePull { pendingTarget = 0 }
        if pendingTarget != nil {
            // Cancel native deceleration *before* starting the one snap clock.
            targetContentOffset.pointee = scrollView.contentOffset
            gate.lockRefresh()
            isSettling = true
        } else if !eligiblePull {
            let floor: CGFloat = released >= detent ? detent : 0
            targetContentOffset.pointee.y = max(floor - scrollView.adjustedContentInset.top,
                                                 targetContentOffset.pointee.y)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        forwardedDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        hasTouch = false
        if let target = pendingTarget {
            let token = generation
            let velocity = releaseVelocity
            // Let UIKit finish the pan callback before taking over its offset.
            // This is an event boundary, not a delay for refresh eligibility.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.startSnap(to: target, velocity: velocity)
            }
        } else if !decelerate { isMoving = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        forwardedDelegate?.scrollViewDidEndDecelerating?(scrollView)
        if !isSettling { isMoving = false }
    }

    /// `velocity` is the finger's release speed in points per second, so the
    /// panel carries on from the gesture rather than restarting from rest.
    func startSnap(to target: CGFloat, velocity: CGFloat = 0) {
        guard let scroll = scrollView else { return }
        gate.lockRefresh()
        pendingTarget = nil
        displayLink?.invalidate()
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        eligiblePull = false
        if abs(offset - target) <= 0.5 {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                                           y: target - scroll.adjustedContentInset.top), animated: false)
            isSettling = false
            isMoving = false
            animation = nil
            displayLink = nil
            return
        }
        isSettling = true
        isMoving = false
        animation = (PortfolioHomeSnapMotion.Spring(start: offset, end: target, velocity: velocity,
                                                    reduceMotion: reduceMotion), clock())
        let link = CADisplayLink(target: self, selector: #selector(displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        advanceSnap(at: link.timestamp)
    }

    func advanceSnap(at timestamp: CFTimeInterval) {
        guard let animation, let scroll = scrollView else { return }
        let elapsed = timestamp - animation.time
        let settled = animation.spring.isSettled(at: elapsed)
        // Only the spring's own small overshoot leaves the two stops; the
        // last frame lands exactly on the stop.
        let value = settled ? animation.spring.end : animation.spring.value(at: elapsed)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                                       y: value - scroll.adjustedContentInset.top), animated: false)
        if settled {
            displayLink?.invalidate()
            displayLink = nil
            self.animation = nil
            isSettling = false
            isMoving = false
            // Do not mutate the captured gesture permission here.
        }
    }

    /// Once per pull. The refresh runs behind the page — the line above
    /// the total says what it is doing — so nothing holds the page open.
    func startRefresh() {
        guard gate.beginRefresh() else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            self.gate.finishRefresh()
            self.refreshTask = nil
            self.publishOffset()
        }
    }
}

/// Records touch-down even if the pan recognizer has not yet crossed its
/// threshold. Never recognizes, cancels or delays a chart/button/scroll touch.
private final class PortfolioHomeTouchObserver: UIGestureRecognizer {
    var onTouchBegan: () -> Void = {}
    var onTouchEnded: () -> Void = {}

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { onTouchBegan() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchEnded()
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchEnded()
        state = .failed
    }
}

struct PortfolioHomeScrollBridge: UIViewRepresentable {
    let controller: PortfolioHomeScrollController
    let detent: CGFloat
    let reduceMotion: Bool
    let onOffset: (CGFloat, CGFloat) -> Void
    let refresh: () async -> Void

    func makeUIView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: BoundaryView, context: Context) {
        controller.detent = detent
        controller.reduceMotion = reduceMotion
        controller.onOffset = onOffset
        controller.refresh = refresh
        view.controller = controller
        view.connect()
        DispatchQueue.main.async { [weak view] in view?.connect() }
    }

    static func dismantleUIView(_ view: BoundaryView, coordinator: ()) {
        view.controller?.detach()
        view.controller = nil
    }

    final class BoundaryView: UIView {
        weak var controller: PortfolioHomeScrollController?
        override func didMoveToWindow() { super.didMoveToWindow(); connect() }
        override func layoutSubviews() { super.layoutSubviews(); connect() }
        func connect() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    controller?.attach(to: scroll)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
