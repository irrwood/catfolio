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
    private var openingLogo: LogoFlight?
    private var closing: CloseSession?
    private weak var edgePan: UIScreenEdgePanGestureRecognizer?

    private(set) var isAnimating = false
    /// From the tap until the page's content has faded in.
    private var isOpening = false
    /// The opening page's content is in the view tree — which can come
    /// before the sheet has reported in.
    private var contentHasAppeared = false

    /// Where the page header's logo sits in the sheet; measured on each open.
    private var pageLogoInSheet = CGRect(x: 20, y: 20, width: 56, height: 56)
    private weak var openingCard: UIView?
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

    #if DEBUG
    func hasLiveSource(id: AnyHashable, namespace: Namespace.ID) -> Bool {
        liveFrame(for: SourceKey(id: id, namespace: namespace)) != nil
    }
    #endif

    // MARK: Open

    /// Opens a page from a row. The card and the logo fly first; the sheet is
    /// presented only when they land — shown any earlier, it is drawn above
    /// this overlay and covers it from its first frame.
    func beginOpen(id: AnyHashable, namespace: Namespace.ID, opening: (() -> AnyView)? = nil,
                   present: @escaping () -> Void) -> OpenStyle {
        guard !isAnimating, pending == nil else { return .busy }
        guard !UIAccessibility.isReduceMotionEnabled else { return .plain }
        let key = SourceKey(id: id, namespace: namespace)
        guard let (marker, frame) = liveFrame(for: key), let window = marker.window,
              let rowSnapshot = Self.snapshot(of: marker) else { return .plain }
        let flight = Flight(key: key, rowFrame: frame, rowSnapshot: rowSnapshot,
                            logoFrame: logoFrame(for: key, within: frame))
        isAnimating = true
        isOpening = true
        contentHasAppeared = false
        settledActions = []

        let top = window.safeAreaInsets.top
        let target = CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.height - top)
        let widthScale = target.width / max(frame.width, 1)

        let scene = Scene(in: window, traits: window.traitCollection)
        overlay = scene.root
        let card = scene.card
        card.frame = frame
        card.layer.cornerRadius = Self.sourceRadius(for: frame)
        Self.place(rowSnapshot, size: frame.size, at: .zero, scale: 1)

        var logo: LogoFlight?
        if let rowLogo = flight.logoFrame {
            let landing = pageLogoInSheet.offsetBy(dx: target.minX, dy: target.minY)
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
            let host = UIHostingController(rootView: opening())
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
            Self.place(rowSnapshot, at: .zero, scale: widthScale)
            Self.place(screen, at: .zero, scale: 1)
            logo?.land()
            scene.dim.alpha = 1
        }
        UIView.animate(withDuration: Self.openDuration * 0.6, delay: Self.openDuration * 0.1,
                       options: [.curveEaseOut]) {
            screen?.alpha = 1
        }
        motion.addCompletion { [weak self] _ in
            guard let self else { return }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reveal() }
        }
        motion.startAnimation()
        // The row gives way to the bare card in the first third of the flight.
        UIView.animate(withDuration: Self.openDuration * 0.4, delay: 0, options: [.curveEaseInOut]) {
            rowSnapshot.alpha = 0
        }
        return .snapshot
    }

    /// Called by the sheet's backdrop as the sheet appears under the landed
    /// card. The backdrop leaves its shade to us.
    func claimPresentation(surface: UIView, content: UIView, shade: UIView) -> Bool {
        guard let flight = pending else { return false }
        pending = nil
        presented = flight
        self.surface = surface
        self.shade = shade
        installEdgePan(on: surface)
        hideSystemDimming(around: surface)
        raiseOverlay()
        // The sheet's own shade takes over from the overlay's.
        (overlay?.subviews.first)?.alpha = 0
        shade.alpha = 1
        if contentHasAppeared { FrameWaiter.after(frames: 2) { [weak self] in self?.reveal() } }
        return true
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
        FrameWaiter.after(frames: 2) { [weak self] in self?.reveal() }
    }

    /// The live page is drawn under the card: the card and its logo fade off
    /// it, the page's own logo already in the same place underneath.
    private func reveal() {
        guard isOpening else { return }
        isOpening = false
        let card = openingCard
        let logo = openingLogo
        openingCard = nil
        openingLogo = nil
        let root = overlay
        let actions = settledActions
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
            self?.openingHost = nil
            root?.removeFromSuperview()
            if let self, self.overlay === root { self.overlay = nil }
            self?.isAnimating = false
            // Only now: the page's lower cards are a heavy build.
            actions.forEach { $0() }
        }
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

    // The sheet's own pan is left alone. Switching it off stopped a fast
    // flick into the top of the page part-way through the sheet's hand-off
    // with its scroll view, which then stayed pulled down. The presenter sets
    // `interactiveDismissDisabled` instead: the pull only rubber-bands.

    /// The system's dimming views — one beside the sheet, one over the page
    /// behind it — take their colour only after the sheet appears, and darkened
    /// the page a second step after the card's fade. Hidden, not faded (UIKit
    /// animates their alpha itself) while the page is up; ours is the page's
    /// only shade. Shown again when it goes.
    private var hiddenDimmingViews: [UIView] = []

    private func hideSystemDimming(around surface: UIView) {
        guard let window = surface.window else { return }
        var views: [UIView] = [window]
        var index = 0
        while index < views.count, index < 400 {
            let view = views[index]
            index += 1
            if String(describing: type(of: view)).contains("DimmingView"), !view.isHidden {
                view.isHidden = true
                hiddenDimmingViews.append(view)
                continue
            }
            // The page's own content is no place for dimming views.
            if view === surface { continue }
            views.append(contentsOf: view.subviews)
        }
    }

    private func restoreSystemDimming() {
        hiddenDimmingViews.forEach { $0.isHidden = false }
        hiddenDimmingViews = []
    }

    private func installEdgePan(on surface: UIView) {
        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePanned(_:)))
        pan.edges = .left
        surface.addGestureRecognizer(pan)
        edgePan = pan
    }

    @objc private func edgePanned(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        let view = recognizer.view
        switch recognizer.state {
        case .began:
            guard !isAnimating, closing == nil else { return }
            _ = beginClose()
        case .changed:
            closing?.drag(to: recognizer.translation(in: view).x)
        case .ended, .cancelled, .failed:
            guard let session = closing else { return }
            let travel = recognizer.translation(in: view).x
            let speed = recognizer.velocity(in: view).x
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

        /// Follows the finger: right, a little smaller, rounder.
        func drag(to translation: CGFloat) {
            let travel = max(0, translation)
            let progress = min(travel / max(start.width, 1), 1)
            let scale = 1 - 0.14 * progress
            let size = CGSize(width: start.width * scale, height: start.height * scale)
            let frame = CGRect(x: start.minX + travel, y: start.minY + (start.height - size.height) / 2,
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
            SecurityDetailSnapshotTransition.place(row, size: rowSize, at: .zero,
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
                drag(to: 0)
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
    fileprivate final class GroundCard: UIView {
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
