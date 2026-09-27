import SwiftUI
import UIKit

/// The security page's open and close, drawn by us rather than by the
/// system's zoom.
///
/// The system's zoom interpolates the whole page's rectangle; its corner jump,
/// ghost image and bounce come from that model, and its edge swipe back is
/// still broken on iOS 26. Here the sheet is presented and dismissed without
/// animation, and what moves is a card in the window's top layer:
///
/// - Open: the row grows into a card of the page's ground while the row's
///   logo flies on its own to the page header's. On landing the sheet is
///   presented under the card; its first screen is a fixed layout that draws
///   at once, and once it has been drawn the card fades off it. The card
///   carries nothing else: a second drawing of the page on it disagreed with
///   the real one and showed double as they crossed.
/// - Close (✕, or a swipe in from the leading edge): the page, as it was last
///   drawn, sits in a card over the hidden sheet. A swipe drags the card; let
///   go past the threshold, or ✕, and it shrinks back into the row, its logo
///   into the row's; short of it, the card springs back and the sheet shows.
///
/// Presenters with no registered source keep the plain sheet.
@MainActor
final class SecurityDetailSnapshotTransition {
    static let shared = SecurityDetailSnapshotTransition()

    enum OpenStyle {
        /// The card does the motion; the sheet is presented when it lands.
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

    fileprivate struct Flight {
        let key: SourceKey
        let rowFrame: CGRect
        let rowSnapshot: UIView
        /// The row's logo, in the window, when it sits inside the row: the
        /// logo then flies on its own, and the snapshots have a hole where
        /// their own copy is, so only one is ever on screen.
        let logoFrame: CGRect?
    }

    private final class WeakMarker {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var sources: [SourceKey: WeakMarker] = [:]
    private var logoSources: [SourceKey: WeakMarker] = [:]
    /// Every security page header logo on screen — a long-press preview has
    /// one too; the flight uses the one inside the page it concerns.
    private let pageLogos = NSHashTable<UIView>.weakObjects()
    /// The source of the page being opened, until the sheet reports in.
    private var pending: Flight?
    /// The page currently on screen, if it was opened from a row.
    private var presented: Flight?
    private weak var surface: UIView?
    private weak var shade: UIView?
    private var overlay: UIView?
    private var settledActions: [() -> Void] = []
    /// The settled actions a reveal has taken over, until its fade ends.
    private var revealingActions: [() -> Void] = []
    /// Settled actions held back by a close that started before the open had
    /// settled: run if the close is called off, dropped if the page goes.
    private var deferredSettledActions: [() -> Void] = []
    private var openingLogo: LogoFlight?
    /// Watches for the reader's first touch on the page while the landed card
    /// and logo still sit over it: they are pictures, and a page scrolled
    /// under them left the logo standing where the header had been. A touch,
    /// not the scroll view's offset: the scroll view may not exist yet when
    /// the sheet reports in, and then its first scroll went unseen.
    private weak var pageTouchWatcher: UIGestureRecognizer?
    /// The flight while it is in the air, for a finger that catches it.
    private var flightInAir: FlightInAir?
    /// The list behind the page blurs under the dim as the card comes up —
    /// only blurs: it does not shrink.
    fileprivate static let backdropBlur = UIBlurEffect(style: .regular)
    private var closing: CloseSession?
    private weak var edgePan: UIScreenEdgePanGestureRecognizer?

    private(set) var isAnimating = false
    /// Counts opens, so a late callback can tell whether its open is current.
    private var openGeneration: UInt64 = 0
    /// From the tap until the page's content has faded in.
    private var isOpening = false
    /// The opening page's content is in the view tree — which can come
    /// before the sheet has reported in.
    private var contentHasAppeared = false

    /// Where the page header's logo sits in the sheet; measured on each open.
    /// Nil until the first page has been measured.
    private var pageLogoInSheet: CGRect?
    private weak var openingCard: UIView?
    /// The opening scene's dim, which the page's own shade takes over from.
    private weak var openingDim: UIView?
    /// The opening scene's blur, which must not lie over the page once it is
    /// under the card: the card faded off onto a blurred page, which then
    /// snapped sharp as the scene went.
    private weak var openingBlur: UIView?
    private var openingHost: UIHostingController<AnyView>?

    static let openDuration: TimeInterval = 0.46
    static let closeDuration: TimeInterval = 0.40
    static let revealDuration: TimeInterval = 0.25

    // MARK: Sources

    func register(_ marker: UIView, for key: SourceKey) {
        sources[key] = WeakMarker(marker)
    }

    func unregister(_ marker: UIView, for key: SourceKey) {
        if sources[key]?.view === marker { sources[key] = nil }
    }

    func registerLogo(_ marker: UIView, for key: SourceKey) {
        logoSources[key] = WeakMarker(marker)
    }

    func unregisterLogo(_ marker: UIView, for key: SourceKey) {
        if logoSources[key]?.view === marker { logoSources[key] = nil }
    }

    func registerPageLogo(_ marker: UIView) { pageLogos.add(marker) }
    func unregisterPageLogo(_ marker: UIView) { pageLogos.remove(marker) }

    /// Measures where the header's logo sits in `surface`, for the next open.
    private func measureHeader(in surface: UIView) {
        if let logo = pageLogo(in: surface) {
            pageLogoInSheet = logo.convert(logo.bounds, to: surface)
        }
    }

    private func pageLogo(in container: UIView?) -> UIView? {
        guard let container else { return nil }
        return pageLogos.allObjects.first { $0.isDescendant(of: container) && $0.bounds.width > 1 }
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

    /// A list logo's frame in its window, only when it lies inside `row`.
    private func logoFrame(for key: SourceKey, within row: CGRect) -> CGRect? {
        guard let marker = logoSources[key]?.view, let window = marker.window,
              !Self.isHiddenInHierarchy(marker) else { return nil }
        let frame = marker.convert(marker.bounds, to: window)
        return frame.width > 1 && row.insetBy(dx: -1, dy: -1).contains(frame) ? frame : nil
    }

    /// A row on screen and its logo (when the logo sits inside it), for B's
    /// live zoom, which zooms out of the row's marker itself.
    func liveSourceViews(for key: SourceKey) -> (row: UIView, logo: UIView?)? {
        guard let (marker, frame) = liveFrame(for: key) else { return nil }
        let logo = logoFrame(for: key, within: frame) == nil ? nil : logoSources[key]?.view
        return (marker, logo)
    }

    /// Where the header's logo sits in a page, if the page has laid it out.
    func pageLogoFrame(in page: UIView) -> CGRect? {
        pageLogo(in: page).map { $0.convert($0.bounds, to: page) }
    }

    /// Whether a row is on screen for this key. The measurement's auto-drive
    /// reads it in Release too, so it is not `#if DEBUG`.
    func hasLiveSource(id: AnyHashable, namespace: Namespace.ID) -> Bool {
        liveFrame(for: SourceKey(id: id, namespace: namespace)) != nil
    }

    // MARK: Open

    /// Opens a page from a row. The card and the logo fly first; the sheet is
    /// presented only when they land — shown any earlier, it is drawn above
    /// this overlay and covers it from its first frame.
    func beginOpen(id: AnyHashable, namespace: Namespace.ID, opening: (() -> AnyView)? = nil,
                   present: @escaping () -> Void, cancelled: (() -> Void)? = nil) -> OpenStyle {
        guard !isAnimating, pending == nil else { return .busy }
        guard !UIAccessibility.isReduceMotionEnabled else { return .plain }
        let key = SourceKey(id: id, namespace: namespace)
        guard let (marker, frame) = liveFrame(for: key), let window = marker.window,
              let rowSnapshot = Self.snapshot(of: marker) else { return .plain }
        let flight = Flight(key: key, rowFrame: frame, rowSnapshot: rowSnapshot,
                            logoFrame: logoFrame(for: key, within: frame))
        SecurityDetailLoadTrace.begin((id.base as? String) ?? "\(id)")
        isAnimating = true
        isOpening = true
        openGeneration &+= 1
        contentHasAppeared = false
        settledActions = []

        // The page is the whole screen: the card grows to all of it, and the
        // page's first screen starts below the status bar as the page does.
        let top = window.safeAreaInsets.top
        let target = window.bounds
        let widthScale = target.width / max(frame.width, 1)

        let scene = Scene(in: window, traits: window.traitCollection)
        overlay = scene.root
        openingDim = scene.dim
        openingBlur = scene.blur
        // Until the sheet is under it, the flight takes every touch: let
        // through, a tap meant for the page's ✕ landed on the list below —
        // its filter button, whose menu then opened over the page.
        scene.root.isUserInteractionEnabled = true
        let card = scene.card
        card.frame = frame
        card.layer.cornerRadius = Self.sourceRadius(for: frame)
        Self.place(rowSnapshot, size: frame.size, at: .zero, scale: 1)

        var logo: LogoFlight?
        if let rowLogo = flight.logoFrame {
            let landing = (pageLogoInSheet ?? CGRect(x: 20, y: top + 20, width: 56, height: 56))
                .offsetBy(dx: target.minX, dy: target.minY)
            // The image the row is already showing — decoded, and drawn at
            // the page's size so it is sharp there. Only a logo still in its
            // web view is copied from the screen (a GPU copy, no redraw).
            if let id = id.base as? String, let image = AssetLogoShownImages.shared.image(for: id) {
                logo = LogoFlight(image: image, traits: window.traitCollection,
                                  native: landing.size, from: rowLogo, to: landing)
            } else if let copy = Self.snapshot(ofRect: rowLogo, near: marker) {
                logo = LogoFlight(view: copy, native: rowLogo.size, from: rowLogo, to: landing)
            }
            if logo != nil {
                Self.punchHole(in: rowSnapshot, at: rowLogo.offsetBy(dx: -frame.minX, dy: -frame.minY))
            }
        }
        openingLogo = logo
        // The page's fixed first screen — the page's own views — fading in
        // on the card as it grows, scaled to its width and pinned to its top.
        var screen: UIView?
        if let opening {
            let host = UIHostingController(rootView: AnyView(opening().padding(.top, top)))
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            Self.place(host.view, size: target.size, at: .zero, scale: frame.width / max(target.width, 1))
            host.view.alpha = 0
            card.addSubview(host.view)
            openingHost = host
            screen = host.view
        }
        card.addSubview(rowSnapshot)
        logo.map { scene.root.addSubview($0.view) }
        openingCard = card

        let motion = UIViewPropertyAnimator(duration: Self.openDuration, dampingRatio: 0.9) {
            card.frame = target
            card.layer.cornerRadius = SecurityDetailPresentation.cornerRadius
            // Onto the page's header row, below the status bar, so the row
            // and the header it becomes are one row, not two.
            Self.place(rowSnapshot, at: Self.rowInPage(top: top), scale: widthScale)
            Self.place(screen, at: .zero, scale: 1)
            logo?.land()
            scene.dim.alpha = 1
            scene.blur.effect = Self.backdropBlur
            // In the same animator, so a flight that is caught and pulled
            // back, or reversed, unwinds all of it: the row gives way to the
            // bare card in the first third, the page's first screen fades in
            // from a tenth to seven tenths.
            UIView.animateKeyframes(withDuration: 0, delay: 0) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.4) {
                    rowSnapshot.alpha = 0
                }
                UIView.addKeyframe(withRelativeStartTime: 0.1, relativeDuration: 0.6) {
                    screen?.alpha = 1
                }
            }
        }
        motion.addCompletion { [weak self] position in
            guard let self else { return }
            self.flightInAir = nil
            SecurityDetailLoadTrace.mark("card.landed")
            // Pulled back into its row: the page is never presented.
            guard position == .end else {
                self.flightDidReturn(root: scene.root, logo: logo, cancelled: cancelled)
                return
            }
            // The card is where the sheet goes: present it, an empty shell of
            // the same ground, under the card.
            self.pending = flight
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { present() }
            // The sheet's container is added to the window after this
            // overlay, and would be drawn over the card.
            self.raiseOverlay()
            // Never left waiting on a sheet that does not report in.
            let generation = self.openGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.reveal(generation)
        }
        }
        motion.startAnimation()
        flightInAir = FlightInAir(motion: motion)
        // The flight can be caught: a finger on it holds it where it is, a
        // pull to the right or down draws it back towards its row, and let go
        // it either finishes opening or goes home.
        let grab = UIPanGestureRecognizer(target: self, action: #selector(flightGrabbed(_:)))
        grab.maximumNumberOfTouches = 1
        scene.root.addGestureRecognizer(grab)
        return .snapshot
    }

    /// Called by the sheet's backdrop as the sheet appears under the landed
    /// card. The backdrop leaves its shade to us.
    func claimPresentation(surface: UIView, content: UIView, shade: UIView) -> Bool {
        guard let flight = pending else { return false }
        SecurityDetailLoadTrace.mark("page.claimed")
        pending = nil
        presented = flight
        self.surface = surface
        self.shade = shade
        installEdgePan(on: surface)
        hideSystemDimming(around: surface)
        watchFirstTouch(on: surface)
        // From here the page itself is under the card, and its touches are its own.
        overlay?.isUserInteractionEnabled = false
        raiseOverlay()
        // The sheet's own shade takes over from the overlay's.
        openingDim?.alpha = 0
        openingBlur?.isHidden = true
        shade.alpha = 1
        if contentHasAppeared {
            let generation = openGeneration
            FrameWaiter.after(frames: 2) { [weak self] in self?.reveal(generation) }
        }
        return true
    }

    /// The reader's first touch on the page — a scroll, a tap on ✕ — takes
    /// the card and the flying logo away at once, so nothing is left behind.
    private func watchFirstTouch(on surface: UIView) {
        stopWatchingFirstTouch()
        let watcher = UILongPressGestureRecognizer(target: self, action: #selector(pageTouched(_:)))
        watcher.minimumPressDuration = 0
        watcher.cancelsTouchesInView = false
        watcher.delaysTouchesBegan = false
        watcher.delaysTouchesEnded = false
        watcher.delegate = FirstTouchDelegate.shared
        surface.addGestureRecognizer(watcher)
        pageTouchWatcher = watcher
    }

    private func stopWatchingFirstTouch() {
        guard let watcher = pageTouchWatcher else { return }
        watcher.view?.removeGestureRecognizer(watcher)
        pageTouchWatcher = nil
    }

    @objc private func pageTouched(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began else { return }
        dropOpeningOverlay()
    }

    private func dropOpeningOverlay() {
        stopWatchingFirstTouch()
        finishOpeningNow().forEach { $0() }
    }

    /// Never in the way: the page's own scrolling and buttons see every touch.
    private final class FirstTouchDelegate: NSObject, UIGestureRecognizerDelegate {
        static let shared = FirstTouchDelegate()
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    // MARK: Catching the flight

    fileprivate final class FlightInAir {
        let motion: UIViewPropertyAnimator
        /// Where the flight was when the finger caught it.
        var caughtAt: CGFloat = 0
        init(motion: UIViewPropertyAnimator) { self.motion = motion }
    }

    /// How far a pull must travel to draw the card all the way back.
    private static let pullBackDistance: CGFloat = 320

    @objc private func flightGrabbed(_ recognizer: UIPanGestureRecognizer) {
        guard let inAir = flightInAir, let view = recognizer.view else { return }
        let motion = inAir.motion
        let translation = recognizer.translation(in: view)
        let pull = max(0, translation.x, translation.y)
        switch recognizer.state {
        case .began:
            motion.pauseAnimation()
            inAir.caughtAt = motion.fractionComplete
        case .changed:
            motion.fractionComplete = max(0, inAir.caughtAt - pull / Self.pullBackDistance)
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: view)
            let goesHome = recognizer.state == .ended
                && (pull > 60 || max(velocity.x, velocity.y) > 500)
            motion.isReversed = goesHome
            motion.continueAnimation(withTimingParameters: nil, durationFactor: 0)
        default:
            break
        }
    }

    /// The flight wound back to its start: the card is its row again.
    private func flightDidReturn(root: UIView, logo: LogoFlight?, cancelled: (() -> Void)?) {
        logo?.view.removeFromSuperview()
        root.removeFromSuperview()
        if overlay === root { overlay = nil }
        openGeneration &+= 1
        isOpening = false
        settledActions = []
        openingLogo = nil
        openingCard = nil
        openingHost = nil
        isAnimating = false
        cancelled?()
    }

    private func raiseOverlay() {
        guard let overlay, let window = overlay.superview else { return }
        window.bringSubviewToFront(overlay)
    }

    /// The page's content is in the view tree, not yet on screen. Two display
    /// frames on — which on a heavy first build is only once it has finished
    /// — it has been drawn: fade it in while the flying logo fades out.
    func contentDidAppear() {
        guard isOpening, !contentHasAppeared else { return }
        contentHasAppeared = true
        // Before the sheet has reported in, the claim starts the wait.
        guard presented != nil else { return }
        let generation = openGeneration
        FrameWaiter.after(frames: 2) { [weak self] in self?.reveal(generation) }
    }

    /// The live page is drawn under the card: the card and its logo fade off
    /// it, the page's own logo already in the same place underneath.
    /// `generation` is the open that scheduled this. A timer from an earlier
    /// open, closed quickly, fired into the next one's flight and faded its
    /// card off mid-air, leaving the flying logo alone before the page
    /// flashed in.
    private func reveal(_ generation: UInt64) {
        guard isOpening, generation == openGeneration else { return }
        SecurityDetailLoadTrace.mark("card.reveal")
        isOpening = false
        let card = openingCard
        let logo = openingLogo
        openingCard = nil
        openingLogo = nil
        let root = overlay
        revealingActions = settledActions
        settledActions = []
        if let surface { measureHeader(in: surface) }
        // Only the card fades. The flying logo stays whole until the card is
        // gone and is then taken away over the page's own, which sits exactly
        // under it: faded together, each covered half of the other and the
        // logo dimmed by a quarter midway.
        UIView.animate(withDuration: Self.revealDuration, delay: 0, options: [.curveEaseInOut]) {
            card?.alpha = 0
        } completion: { [weak self] _ in
            logo?.view.removeFromSuperview()
            root?.removeFromSuperview()
            // An open already finished by a scroll or a close has moved on;
            // the pieces above were its own, nothing else is.
            guard let self, generation == self.openGeneration else { return }
            self.stopWatchingFirstTouch()
            self.openingHost = nil
            if self.overlay === root { self.overlay = nil }
            self.isAnimating = false
            // Only now: the page's lower cards are a heavy build.
            let actions = self.revealingActions
            self.revealingActions = []
            actions.forEach { $0() }
        }
    }

    /// Ends the open at once, without the reveal's fade: the landed card and
    /// the flying logo go, and the live page under them is all there is.
    /// For a reader who has already started to use the page — to scroll it,
    /// or to close it — while the card still covered it.
    ///
    /// Returns the settled actions still to run (the page's lower cards).
    @discardableResult
    private func finishOpeningNow() -> [() -> Void] {
        guard presented != nil, closing == nil, isOpening || overlay != nil else { return [] }
        // Retires the reveal still to come, its deadline, and a fade already
        // under way.
        openGeneration &+= 1
        isOpening = false
        stopWatchingFirstTouch()
        let actions = revealingActions + settledActions
        revealingActions = []
        settledActions = []
        openingLogo?.view.removeFromSuperview()
        openingLogo = nil
        openingCard = nil
        openingHost = nil
        overlay?.removeFromSuperview()
        overlay = nil
        isAnimating = false
        return actions
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

    // MARK: Close

    /// ✕: the page shrinks back into its row at once.
    func close(perform dismiss: @escaping () -> Void) {
        // Pressed while the landed card still covers the page — the ✕ is
        // the page's own, under it — the card goes and the close goes on.
        // Swallowed here, it left the button dead for as long as the page
        // took to draw.
        deferredSettledActions = finishOpeningNow()
        guard !isAnimating else { return }
        guard let session = beginClose() else {
            dismiss()
            return
        }
        session.finish(dismiss: dismiss)
    }

    /// The page as it was last drawn, in a card over the hidden sheet. Nothing
    /// is redrawn: a GPU copy of what is on screen, then only transforms.
    private func beginClose() -> CloseSession? {
        guard let flight = presented, let surface, let window = surface.window,
              !UIAccessibility.isReduceMotionEnabled,
              let page = surface.snapshotView(afterScreenUpdates: false) else { return nil }
        isAnimating = true
        let start = surface.convert(surface.bounds, to: window)
        var logo: (flight: LogoFlight, inPage: CGRect)?
        if let source = pageLogo(in: surface) {
            let inPage = source.convert(source.bounds, to: surface)
            if let copy = surface.resizableSnapshotView(from: inPage, afterScreenUpdates: false, withCapInsets: .zero) {
                let from = inPage.offsetBy(dx: start.minX, dy: start.minY)
                logo = (LogoFlight(view: copy, native: inPage.size, from: from, to: from), inPage)
            }
        }
        let scene = Scene(in: window, traits: window.traitCollection)
        overlay = scene.root
        scene.blur.effect = Self.backdropBlur
        let session = CloseSession(owner: self, flight: flight, scene: scene, page: page,
                                   start: start, logo: logo, surface: surface, shade: shade)
        surface.alpha = 0
        shade?.alpha = 0
        closing = session
        return session
    }

    fileprivate func closeDidEnd(_ session: CloseSession, dismissed: Bool) {
        if closing === session { closing = nil }
        if overlay === session.scene.root { overlay = nil }
        isAnimating = false
        let deferred = deferredSettledActions
        deferredSettledActions = []
        if !dismissed { deferred.forEach { $0() } }
        if dismissed {
            presented = nil
            surface = nil
            shade = nil
        }
    }

    fileprivate func liveRowFrame(for flight: Flight) -> (row: CGRect, logo: CGRect?) {
        let row = liveFrame(for: flight.key)?.frame ?? flight.rowFrame
        return (row, logoFrame(for: flight.key, within: row))
    }

    // MARK: Edge swipe

    // The sheet's own pan is left alone, and so is its pull-down to close.
    // Switching the pan off stopped a fast flick into the top of the page
    // part-way through the sheet's hand-off with its scroll view, which then
    // stayed pulled down. The page's scroll view holds its own top instead
    // (`HoldingDetailScrollBoundary`); the edge swipe is a second way out.

    /// The system's dimming views — one beside the sheet, one over the page
    /// behind it — take their colour only after the sheet appears, and darkened
    /// the page a second step after the card's fade. Hidden, not faded (UIKit
    /// animates their alpha itself) while the page is up; ours is the page's
    /// only shade. Shown again when it goes.
    /// Weak: a dimming view UIKit has since let go of is not ours to keep.
    /// Only views this page hid are listed, and one shown again by someone
    /// else in the meantime is left as it is.
    private let hiddenDimmingViews = NSHashTable<UIView>.weakObjects()

    private func hideSystemDimming(around surface: UIView) {
        guard let window = surface.window else { return }
        var views: [UIView] = [window]
        var index = 0
        while index < views.count, index < 400 {
            let view = views[index]
            index += 1
            if String(describing: type(of: view)).contains("DimmingView"), !view.isHidden {
                view.isHidden = true
                hiddenDimmingViews.add(view)
                continue
            }
            // The page's own content is no place for dimming views.
            if view === surface { continue }
            views.append(contentsOf: view.subviews)
        }
    }

    private func restoreSystemDimming() {
        for view in hiddenDimmingViews.allObjects where view.isHidden {
            view.isHidden = false
        }
        hiddenDimmingViews.removeAllObjects()
    }

    /// Begins only for a pull downwards with the page at its top; otherwise
    /// the page scrolls. The page's scroll view keeps its touch — held at its
    /// top, it does not move.
    private final class PullDownDelegate: NSObject, UIGestureRecognizerDelegate {
        static let shared = PullDownDelegate()

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            guard velocity.y > 0, velocity.y > abs(velocity.x) else { return false }
            guard let scroll = Self.pageScrollView(in: view) else { return true }
            return scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// The page's own vertical scroll view: the first one at least half
        /// the page's height, breadth first.
        private static func pageScrollView(in root: UIView) -> UIScrollView? {
            var queue: [UIView] = [root]
            var index = 0
            while index < queue.count, index < 400 {
                let view = queue[index]
                index += 1
                if let scroll = view as? UIScrollView, scroll.bounds.height > root.bounds.height * 0.5 {
                    return scroll
                }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
    }

    private func installEdgePan(on surface: UIView) {
        let pull = UIPanGestureRecognizer(target: self, action: #selector(pulledDown(_:)))
        pull.maximumNumberOfTouches = 1
        pull.delegate = PullDownDelegate.shared
        surface.addGestureRecognizer(pull)
        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePanned(_:)))
        pan.edges = .left
        surface.addGestureRecognizer(pan)
        edgePan = pan
    }

    @objc private func edgePanned(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        followClose(recognizer, axis: \.x)
    }

    @objc private func pulledDown(_ recognizer: UIPanGestureRecognizer) {
        followClose(recognizer, axis: \.y)
    }

    /// A swipe from the left edge, or a pull down from the page's top: the
    /// page follows the finger as a card and, let go far enough, shrinks back
    /// into its row — the same close either way.
    private func followClose(_ recognizer: UIPanGestureRecognizer, axis: KeyPath<CGPoint, CGFloat>) {
        let view = recognizer.view
        switch recognizer.state {
        case .began:
            guard closing == nil else { return }
            deferredSettledActions += finishOpeningNow()
            guard !isAnimating else { return }
            _ = beginClose()
        case .changed:
            let translation = recognizer.translation(in: view)
            closing?.drag(to: axis == \CGPoint.x ? CGPoint(x: translation.x, y: 0) : CGPoint(x: 0, y: translation.y))
        case .ended, .cancelled, .failed:
            guard let session = closing else { return }
            let travel = recognizer.translation(in: view)[keyPath: axis]
            let speed = recognizer.velocity(in: view)[keyPath: axis]
            if recognizer.state == .ended, travel > 90 || speed > 700 {
                session.finish(dismiss: dismissAction)
            } else {
                session.cancel()
            }
        default:
            break
        }
    }

    /// How the presenter dismisses the page, for a close the swipe starts.
    var dismissAction: () -> Void = {}

    /// The sheet is gone, however it went.
    func presentationDidEnd() {
        stopWatchingFirstTouch()
        // Nothing an open scheduled may run once its page has gone.
        openGeneration &+= 1
        revealingActions = []
        deferredSettledActions = []
        restoreSystemDimming()
        presented = nil
        pending = nil
        isOpening = false
        settledActions = []
        surface = nil
        shade = nil
        dismissAction = {}
        if overlay == nil { isAnimating = false }
    }

    // MARK: Pieces

    /// A page being closed: its picture in a card, followed by the finger or
    /// sent straight home.
    @MainActor
    fileprivate final class CloseSession {
        unowned let owner: SecurityDetailSnapshotTransition
        let flight: Flight
        let scene: Scene
        let page: UIView
        let start: CGRect
        let logo: (flight: LogoFlight, inPage: CGRect)?
        weak var surface: UIView?
        weak var shade: UIView?

        init(owner: SecurityDetailSnapshotTransition, flight: Flight, scene: Scene, page: UIView,
             start: CGRect, logo: (flight: LogoFlight, inPage: CGRect)?, surface: UIView, shade: UIView?) {
            self.owner = owner
            self.flight = flight
            self.scene = scene
            self.page = page
            self.start = start
            self.logo = logo
            self.surface = surface
            self.shade = shade
            scene.dim.alpha = 1
            let card = scene.card
            card.frame = start
            card.layer.cornerRadius = SecurityDetailPresentation.cornerRadius
            SecurityDetailSnapshotTransition.place(page, size: start.size, at: .zero, scale: 1)
            if let logo { SecurityDetailSnapshotTransition.punchHole(in: page, at: logo.inPage) }
            card.addSubview(page)
            logo.map { scene.root.addSubview($0.flight.view) }
        }

        /// Follows the finger — right from the edge, or down from the top —
        /// a little smaller and rounder the further it goes.
        func drag(to translation: CGPoint) {
            let right = max(0, translation.x)
            let down = max(0, translation.y)
            let progress = min(max(right / max(start.width, 1), down / max(start.height * 0.6, 1)), 1)
            let scale = 1 - 0.14 * progress
            let size = CGSize(width: start.width * scale, height: start.height * scale)
            let frame = CGRect(x: start.minX + right + (start.width - size.width) / 2 * (down > right ? 1 : 0),
                               y: start.minY + (start.height - size.height) / 2 + down,
                               width: size.width, height: size.height)
            scene.card.frame = frame
            scene.card.layer.cornerRadius = SecurityDetailPresentation.cornerRadius + 16 * progress
            SecurityDetailSnapshotTransition.place(page, at: .zero, scale: scale)
            if let logo {
                logo.flight.move(to: CGRect(x: frame.minX + logo.inPage.minX * scale,
                                            y: frame.minY + logo.inPage.minY * scale,
                                            width: logo.inPage.width * scale, height: logo.inPage.height * scale))
            }
            scene.dim.alpha = 1 - 0.6 * progress
        }

        /// Home to the row, from wherever the card is now.
        func finish(dismiss: @escaping () -> Void) {
            // Before the dismissal takes the page out of its window.
            let top = surface?.window?.safeAreaInsets.top ?? scene.root.window?.safeAreaInsets.top ?? 0
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }

            let target = owner.liveRowFrame(for: flight)
            let end = target.row
            let row = flight.rowSnapshot
            let rowSize = flight.rowFrame.size
            row.alpha = 0
            row.layer.mask = nil
            let current = scene.card.frame
            SecurityDetailSnapshotTransition.place(row, size: rowSize,
                                                   at: SecurityDetailSnapshotTransition.rowInPage(top: top),
                                                   scale: current.width / max(rowSize.width, 1))
            let landsLogo = logo != nil && target.logo != nil && flight.logoFrame != nil
            if landsLogo, let rowLogo = flight.logoFrame {
                SecurityDetailSnapshotTransition.punchHole(
                    in: row, at: rowLogo.offsetBy(dx: -flight.rowFrame.minX, dy: -flight.rowFrame.minY))
            }
            scene.card.addSubview(row)
            if !landsLogo { logo?.flight.view.alpha = 0 }

            let motion = UIViewPropertyAnimator(duration: SecurityDetailSnapshotTransition.closeDuration,
                                                dampingRatio: 0.92) { [self] in
                scene.card.frame = end
                scene.card.layer.cornerRadius = SecurityDetailSnapshotTransition.sourceRadius(for: end)
                SecurityDetailSnapshotTransition.place(page, at: .zero, scale: end.width / max(start.width, 1))
                SecurityDetailSnapshotTransition.place(row, at: .zero, scale: end.width / max(rowSize.width, 1))
                if landsLogo, let rowLogo = target.logo { logo?.flight.move(to: rowLogo) }
                scene.dim.alpha = 0
                scene.blur.effect = nil
            }
            motion.addCompletion { [self] _ in
                scene.root.removeFromSuperview()
                owner.closeDidEnd(self, dismissed: true)
            }
            motion.startAnimation()
            UIView.animate(withDuration: SecurityDetailSnapshotTransition.closeDuration * 0.5,
                           delay: SecurityDetailSnapshotTransition.closeDuration * 0.3,
                           options: [.curveEaseInOut]) { [self] in
                page.alpha = 0
                row.alpha = 1
            }
        }

        /// Short of the threshold: back into place, then the real sheet.
        func cancel() {
            let motion = UIViewPropertyAnimator(duration: 0.3, dampingRatio: 0.9) { [self] in
                drag(to: .zero)
            }
            motion.addCompletion { [self] _ in
                surface?.alpha = 1
                shade?.alpha = 1
                scene.root.removeFromSuperview()
                owner.closeDidEnd(self, dismissed: false)
            }
            motion.startAnimation()
        }
    }

    /// A logo moving on its own between the list and the page. Moved by
    /// transform only, never redrawn, and clipped to the logo's own rounded
    /// square so nothing of what was around it comes along.
    @MainActor
    fileprivate struct LogoFlight {
        let view: UIView
        private let landing: CGRect

        /// `view` is drawn at `native` size and scaled to each frame.
        init(view content: UIView, native: CGSize, from start: CGRect, to end: CGRect) {
            let clip = UIView()
            clip.clipsToBounds = true
            clip.layer.cornerCurve = .continuous
            clip.layer.cornerRadius = native.width * 2 / 7
            clip.isUserInteractionEnabled = false
            content.frame = CGRect(origin: .zero, size: native)
            clip.addSubview(content)
            SecurityDetailSnapshotTransition.place(clip, size: native, at: start.origin,
                                                   scale: start.width / max(native.width, 1))
            view = clip
            landing = end
        }

        /// The logo's artwork on its tile, as `AssetLogo` draws it.
        init(image: UIImage, traits: UITraitCollection, native: CGSize, from start: CGRect, to end: CGRect) {
            let tile = UIImageView(image: image)
            tile.contentMode = .scaleAspectFit
            tile.backgroundColor = SettingsTemplate.uiCard.resolvedColor(with: traits)
            self.init(view: tile, native: native, from: start, to: end)
        }

        func land() { move(to: landing) }

        func move(to frame: CGRect) {
            SecurityDetailSnapshotTransition.place(view, at: frame.origin,
                                                   scale: frame.width / max(view.bounds.width, 1))
        }
    }

    /// Lays `view` out at its own size and moves it by transform alone, so a
    /// mask on its layer scales with it and nothing is redrawn mid-flight.
    fileprivate static func place(_ view: UIView?, size: CGSize? = nil, at origin: CGPoint, scale: CGFloat) {
        guard let view else { return }
        if let size {
            view.transform = .identity
            view.layer.anchorPoint = .zero
            view.bounds = CGRect(origin: .zero, size: size)
        }
        view.layer.position = origin
        view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// Cuts the logo out of a snapshot, a point wider than the logo so no
    /// anti-aliased rim of it is left behind.
    fileprivate static func punchHole(in view: UIView, at rect: CGRect) {
        let path = UIBezierPath(rect: view.bounds)
        let hole = rect.insetBy(dx: -1, dy: -1)
        path.append(UIBezierPath(roundedRect: hole, cornerRadius: hole.width * 2 / 7))
        let mask = CAShapeLayer()
        mask.frame = view.bounds
        mask.path = path.cgPath
        mask.fillRule = .evenOdd
        view.layer.mask = mask
    }

    /// The overlay: a shade over everything and the moving card above it,
    /// drawn in the window's own top layer so it sits over the sheet too.
    @MainActor
    fileprivate final class Scene {
        let root: UIView
        /// Blurs the list as it steps back, under the dim.
        let blur = UIVisualEffectView(effect: nil)
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
            blur.frame = root.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            blur.isUserInteractionEnabled = false
            root.addSubview(blur)
            root.addSubview(dim)
            root.addSubview(card)
            window.addSubview(root)
        }
    }

    /// A card painted with the page's ground.
    fileprivate final class GroundCard: UIView {
        init(traits: UITraitCollection) {
            super.init(frame: .zero)
            clipsToBounds = true
            layer.cornerCurve = .continuous
            backgroundColor = SecurityDetailPresentation.uiGround.resolvedColor(with: traits)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }
    }

    /// A snapshot of just the source's own layers — taken from its scroll
    /// view, not the window, so nothing presented over the list is in it.
    private static func snapshot(of marker: UIView) -> UIView? {
        let host = scrollHost(of: marker)
        let rect = marker.convert(marker.bounds, to: host)
        return host.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero)
    }

    /// One rect of the list, from the same host as the row's: a GPU copy.
    private static func snapshot(ofRect rect: CGRect, near marker: UIView) -> UIView? {
        guard let window = marker.window else { return nil }
        let host = scrollHost(of: marker)
        return host.resizableSnapshotView(from: window.convert(rect, to: host),
                                          afterScreenUpdates: false, withCapInsets: .zero)
    }

    private static func scrollHost(of marker: UIView) -> UIView {
        var ancestor = marker.superview
        while let view = ancestor {
            if view is UIScrollView { return view }
            ancestor = view.superview
        }
        return marker.window ?? marker
    }

    /// Where a row sits on the full-screen page: over its header row, which
    /// starts 20pt below the status bar and is 56pt tall — the row's own
    /// middle on the header's middle.
    fileprivate static func rowInPage(top: CGFloat) -> CGPoint {
        CGPoint(x: 0, y: top + 16)
    }

    /// Rows are square-edged and bars are rounded; a card that starts as a
    /// gentle rounded rectangle reads as either.
    fileprivate static func sourceRadius(for frame: CGRect) -> CGFloat {
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

/// Runs a closure after a number of display frames have actually been shown.
@MainActor
private final class FrameWaiter: NSObject {
    private var remaining: Int
    private let action: () -> Void
    private var link: CADisplayLink?

    private init(frames: Int, action: @escaping () -> Void) {
        remaining = frames
        self.action = action
    }

    static func after(frames: Int, _ action: @escaping () -> Void) {
        let waiter = FrameWaiter(frames: frames, action: action)
        let link = CADisplayLink(target: waiter, selector: #selector(tick))
        waiter.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        remaining -= 1
        guard remaining <= 0 else { return }
        link?.invalidate()
        link = nil
        action()
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

/// Marks a logo that flies with the security page: a list row's logo (with
/// the row's key), or the page header's own, where the flight lands.
struct SecurityDetailLogoMarker: UIViewRepresentable {
    enum Role: Equatable {
        case source(SecurityDetailSnapshotTransition.SourceKey)
        case page
    }

    let role: Role

    func makeUIView(context: Context) -> MarkerView { MarkerView() }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.role = role
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        view.unregister()
    }

    final class MarkerView: UIView {
        var role: Role? {
            didSet {
                guard role != oldValue else { return }
                unregister(oldValue)
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
            guard window != nil, let role else { return }
            switch role {
            case .source(let key): SecurityDetailSnapshotTransition.shared.registerLogo(self, for: key)
            case .page: SecurityDetailSnapshotTransition.shared.registerPageLogo(self)
            }
        }

        func unregister(_ role: Role? = nil) {
            switch role ?? self.role {
            case .source(let key): SecurityDetailSnapshotTransition.shared.unregisterLogo(self, for: key)
            case .page: SecurityDetailSnapshotTransition.shared.unregisterPageLogo(self)
            case nil: break
            }
        }
    }
}

extension View {
    /// A list logo the security page's logo flies out of and back into.
    @ViewBuilder
    func securityDetailLogoSource(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            background {
                SecurityDetailLogoMarker(role: .source(.init(id: AnyHashable(id), namespace: namespace)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            self
        }
    }

    /// The security page header's logo, where a flying logo lands.
    func securityDetailLogoTarget() -> some View {
        background {
            SecurityDetailLogoMarker(role: .page)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
