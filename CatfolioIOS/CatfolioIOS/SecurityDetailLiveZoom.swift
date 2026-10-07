import OSLog
import SwiftUI
import UIKit

/// The live security page zooms out of its row's logo and back into it. UIKit
/// owns both directions and the interactive pull/edge gestures, including
/// cancellation.
///
/// As Apple Music does with an album's artwork: the logo's picture is the
/// zoom's source, so the system grows it to the width of the page and
/// cross-fades it with the page on the way out, and shrinks the whole page
/// back into it on the way home. The picture is the one the list already shows
/// (`AssetLogoShownImages`), in the logo's marker, while the list's own logo is
/// hidden (`hiddenLogo`) so only one logo is ever on screen. A source with no
/// logo zooms from the whole of its marker.
///
/// The page is pushed onto the row's navigation stack, not presented: a
/// navigation zoom can be interrupted, so a tap on the list while a page is
/// still flying back opens the next one at once. A modal's return holds every
/// touch until its spring has settled. Without a stack the page is presented.
@MainActor
final class SecurityDetailLiveZoom {
    static let shared = SecurityDetailLiveZoom()

    /// The list logo whose page is up, hidden while its picture, in the
    /// logo's marker, stands in for it — as the system hides a zoom's source.
    @MainActor @Observable
    final class HiddenLogo {
        var key: SecurityDetailSources.SourceKey?
    }

    static let hiddenLogo = HiddenLogo()

    /// The page up now. One flying back is not: a tap on the list opens the
    /// next page at once, as the system's own zoom lets it, and the page on
    /// its way back cleans up after itself when it lands.
    private weak var page: PageController?
    /// A page is up and not on its way back; a tap on the list is ignored.
    var isShowingPage: Bool { page.map { !$0.isLeaving } ?? false }
    /// The logo a page grew out of, and the corner it had before this file
    /// rounded it. Without the second half the list keeps the zoom's corner for
    /// good: the mark-up below is SwiftUI's, which never rebuilds that layer.
    private var roundedLogo: (view: UIView, cornerRadius: CGFloat, clips: Bool)?
    /// The stand-in each page put in its logo, kept here as well as in the
    /// closure. A page whose `didDismiss` is replaced — the next page opened
    /// while this one was still flying back — used to leave its picture in the
    /// list, hiding a row that then drew as nothing.
    private var logoPictures: [ObjectIdentifier: UIImageView] = [:]

    /// Presents the page zooming out of its row's logo. False when the row is
    /// not on screen; the caller then presents the page its own way. A tap
    /// blocked by an existing normal presentation is consumed (true), so it
    /// cannot trigger a second presentation through that fallback.
    func open(id: AnyHashable, namespace: Namespace.ID,
              page content: (_ close: @escaping () -> Void) -> AnyView,
              didEnd: @escaping () -> Void) -> Bool {
        #if DEBUG
        Self.note("open id=\(id) requested")
        #endif
        guard !isShowingPage else {
            #if DEBUG
            Self.note("BLOCKED: a page is up and not leaving (isShowingPage)")
            #endif
            return false
        }
        let key = SecurityDetailSources.SourceKey(id: id, namespace: namespace)
        guard let source = SecurityDetailSources.shared.liveSourceViews(for: key) else {
            #if DEBUG
            Self.note("BLOCKED: no live source for id=\(id)")
            #endif
            return false
        }
        guard let window = source.row.window else {
            #if DEBUG
            Self.note("BLOCKED: the row has no window")
            #endif
            return false
        }
        let stack = Self.navigationController(of: source.row)
        if let presented = stack?.presentedViewController {
            // Only an action sheet is explicitly transient. A normal sheet,
            // full-screen page or unrecognised presenter keeps ownership.
            guard let menu = presented as? UIAlertController,
                  menu.preferredStyle == .actionSheet,
                  menu.presentedViewController == nil else {
                // Consume the tap so the caller cannot start its modal fallback.
                return true
            }
        }
        #if DEBUG
        SecurityDetailTouchProbe.install(on: window)
        #endif
        // The logo the page grows out of, cornered like the list draws it so
        // the crop starts and ends as that logo's rounded square, and holding
        // the logo's picture for the system to grow and cross-fade.
        var origin = source.row
        var picture: UIImageView?
        if let logo = source.logo {
            // Restore a previous interrupted return before keeping this source's state.
            restoreLogoAppearance()
            let shown = (id.base as? String).flatMap(AssetLogoShownImages.shared.image(for:))
                ?? Self.visibleLogoSnapshot(logo, in: window)
            if let shown {
                roundedLogo = (logo, logo.layer.cornerRadius, logo.clipsToBounds)
                let image = Self.rounded(shown, cornerFraction: Self.rowLogoCornerRadius / Self.rowLogoSize)
                let view = UIImageView(image: image)
                view.frame = logo.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.contentMode = .scaleToFill
                view.isUserInteractionEnabled = false
                // The bitmap already carries the 12/44 corner ratio. A second
                // fixed-radius source mask can become circular when UIKit's
                // interactive spring undershoots the destination size.
                logo.layer.cornerRadius = 0
                logo.clipsToBounds = false
                logo.addSubview(view)
                picture = view
                // Snapshot the artwork directly, without the marker container.
                origin = view
            }
        }

        guard let presenter = stack ?? Self.topController(from: window.rootViewController) else {
            #if DEBUG
            Self.note("BLOCKED: no presenter and no stack")
            #endif
            picture?.removeFromSuperview()
            restoreLogoAppearance()
            return false
        }

        // The page has its own close; the stack's bar and back button stay
        // hidden, which the hosted view has to say too or SwiftUI shows them.
        let controller = PageController(rootView: AnyView(
            content { [weak self] in self?.close() }
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)))
        controller.navigationItem.hidesBackButton = true
        controller.view.backgroundColor = SecurityDetailPresentation.uiGround
        controller.modalPresentationStyle = .fullScreen
        controller.hidesBottomBarWhenPushed = true
        if let picture { logoPictures[ObjectIdentifier(controller)] = picture }
        controller.owningTabBarController = stack?.tabBarController
        controller.previousTabBarHidden = stack?.tabBarController?.isTabBarHidden ?? false
        controller.didDismiss = { [weak self, weak controller] in
            guard let controller else { return }
            self?.releaseLogoPicture(for: controller)
            self?.pageDidGo(controller)
            didEnd()
        }

        let options = UIViewController.Transition.ZoomOptions()
        options.dimmingColor = SecurityDetailPresentation.backdropColor
        if origin !== source.row {
            // The logo lines up on a square the page's width at its very top,
            // as an album's artwork does: grown that large it overlies the
            // header while it fades, and the page shrinks whole into it.
            options.alignmentRectProvider = { [weak window] context in
                let width = context.zoomedViewController.view.bounds.width > 1
                    ? context.zoomedViewController.view.bounds.width : (window?.bounds.width ?? 0)
                return CGRect(x: 0, y: 0, width: width, height: width)
            }
        }
        controller.preferredTransition = .zoom(options: options) { [weak origin] _ in origin }

        // A page that landed without reporting left its picture behind, over
        // the logo of a row someone is about to tap. Clear it here as well as
        // on the way out: the picture is not hit-testable, but it hides a logo
        // and the list is what the reader is looking at.
        for (id, view) in logoPictures where id != ObjectIdentifier(controller) {
            view.removeFromSuperview()
            logoPictures.removeValue(forKey: id)
        }
        page = controller
        // Only with a picture to stand in for it: otherwise the list's logo
        // is all there is.
        if picture != nil { Self.hiddenLogo.key = key }
        if let stack {
            if stack.presentedViewController != nil {
                // The action sheet above was explicitly checked before changing
                // the logo or page state. Dismiss only that controller.
                stack.presentedViewController?.dismiss(animated: true) { [weak self, weak stack, controller] in
                    guard let self, let stack, self.page === controller else { return }
                    stack.pushViewController(controller, animated: true)
                }
            } else {
                stack.pushViewController(controller, animated: true)
            }
        } else {
            presenter.present(controller, animated: true)
        }
        #if DEBUG
        Self.note("opened id=\(id) via \(stack != nil ? "push" : "present")")
        #endif
        return true
    }

    /// Keep the same zoom transition for the close button and interactive dismissal.
    func close() {
        #if DEBUG
        Self.note("close requested")
        #endif
        guard let page, !page.isLeaving else {
            #if DEBUG
            Self.note("close IGNORED: no page, or it is already leaving")
            #endif
            return
        }
        if let stack = page.navigationController {
            guard let index = stack.viewControllers.firstIndex(of: page), index > 0 else { return }
            stack.popToViewController(stack.viewControllers[index - 1], animated: true)
        } else if page.presentingViewController != nil {
            page.dismiss(animated: true)
        }
    }

    /// A page has landed back in its row. One that landed after the next page
    /// opened leaves that page be.
    private func pageDidGo(_ gone: UIViewController?) {
        #if DEBUG
        Self.note("landed gone=\(gone.map { ObjectIdentifier($0).debugDescription } ?? "nil")")
        #endif
        if let gone { releaseLogoPicture(for: gone) }
        guard page == nil || page === gone else {
            #if DEBUG
            Self.note("landed: NOT the page up, leaving state alone")
            #endif
            return
        }
        page = nil
        // Unconditional: this page is down, so nothing may still be hidden.
        // Returning early above with the key set would leave a list row with no
        // logo for the rest of the session.
        Self.hiddenLogo.key = nil
        restoreLogoAppearance()
    }

    /// Takes one page's stand-in out of its logo. Whatever else happened, the
    /// logo must not keep a picture of itself over the top of it.
    private func releaseLogoPicture(for controller: UIViewController) {
        logoPictures.removeValue(forKey: ObjectIdentifier(controller))?.removeFromSuperview()
    }

    /// Puts the logo back the way the list drew it before this file rounded it
    /// and clipped it. The mark-up is SwiftUI's and is never rebuilt, so
    /// without this the list keeps the zoom's corner.
    private func restoreLogoAppearance() {
        guard let roundedLogo else { return }
        roundedLogo.view.layer.cornerRadius = roundedLogo.cornerRadius
        roundedLogo.view.clipsToBounds = roundedLogo.clips
        self.roundedLogo = nil
    }

    /// First-open logos may still be loading and have no decoded-image cache.
    /// Capture exactly the visible tile, including its fallback and grey ground.
    static func visibleLogoSnapshot(_ logo: UIView, in window: UIWindow) -> UIImage? {
        let rect = logo.convert(logo.bounds, to: window)
        guard rect.width > 1, rect.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = window.screen.scale
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            context.cgContext.clip(to: rect)
            window.layer.render(in: context.cgContext)
        }
    }

    /// A list row's logo and its corner (`PortfolioDetailsCard`).
    private static let rowLogoSize: CGFloat = 44
    private static let rowLogoCornerRadius: CGFloat = 12

    /// The logo with its corners in its pixels. The system draws the zoom's
    /// source without the marker's own rounding, so a picture that was only
    /// clipped flew as a square; drawn round, it keeps the list's corner at
    /// every size it passes through.
    private static func rounded(_ image: UIImage, cornerFraction: CGFloat) -> UIImage {
        let rect = CGRect(origin: .zero, size: image.size)
        // The logo's own format says opaque, which fills the cut corners black.
        let format = image.imageRendererFormat
        format.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * cornerFraction).addClip()
            image.draw(in: rect)
        }
    }

    #if DEBUG
    private static let log = Logger(subsystem: "com.catfolio.ios", category: "SecurityDetailLiveZoom")

    /// Every path that leaves a tap with nothing happening, and every state a
    /// page changes, on one line. Read with
    /// `log stream --predicate 'subsystem == "com.catfolio.ios"'` while tapping,
    /// so "cannot open again" is answered by the log rather than by guessing
    /// which of the four guards returned.
    static func note(_ what: String) {
        log.debug("liveZoom \(what, privacy: .public) page=\(Self.shared.describe)")
    }

    var describe: String {
        guard let page else { return "none" }
        return "up leaving=\(page.isLeaving) movingFromParent=\(page.isMovingFromParent) beingDismissed=\(page.isBeingDismissed) inStack=\(page.navigationController != nil) presenting=\(page.presentingViewController != nil)"
    }

    #endif

    /// The stack the row's screen sits in, when that screen is on top of it.
    private static func navigationController(of view: UIView) -> UINavigationController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                // Also while a page is still popping: that is the interruption.
                guard let stack = controller.navigationController else { return nil }
                return stack
            }
            responder = next
        }
        return nil
    }

    private static func topController(from root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Reports actual dismissal; a cancelled pull never dismisses the page.
    private final class PageController: UIHostingController<AnyView> {
        var didDismiss: (() -> Void)?
        weak var owningTabBarController: UITabBarController?
        var previousTabBarHidden = false

        /// On its way back to the row: popped or dismissed, and not pulled
        /// back up yet.
        var isLeaving: Bool { isMovingFromParent || isBeingDismissed || popping }
        private var popping = false
        #if DEBUG
        private let createdAt = CACurrentMediaTime()
        private var appearedAt: CFTimeInterval?
        #endif

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // The home stack hides its bar; a pushed page must too.
            if let stack = navigationController, !stack.isNavigationBarHidden {
                stack.setNavigationBarHidden(true, animated: false)
            }
            transitionTabBar(hidden: true, animated: animated)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            popping = isMovingFromParent
            if popping {
                transitionTabBar(hidden: previousTabBarHidden, animated: animated)
            }
            #if DEBUG
            if isMovingFromParent || isBeingDismissed {
                let now = CACurrentMediaTime()
                let appeared = appearedAt.map { String(format: "%.2fs after it appeared", now - $0) } ?? "BEFORE it appeared"
                SecurityDetailLiveZoom.note(String(format: "leaving %.2fs after open, ", now - createdAt) + appeared
                    + " interactive=\(transitionCoordinator?.isInteractive == true)")
            }
            #endif
        }

        /// SwiftUI's tab container ignores the UIKit push's bottom-bar flag.
        /// Enroll its visibility change in the page's transition so scrubbing
        /// and cancelling a return also scrub and restore the tab bar.
        private func transitionTabBar(hidden: Bool, animated: Bool) {
            guard let tabs = owningTabBarController, tabs.isTabBarHidden != hidden else { return }
            guard animated, let coordinator = transitionCoordinator else {
                tabs.setTabBarHidden(hidden, animated: false)
                return
            }
            let wasHidden = tabs.isTabBarHidden
            if coordinator.isInteractive {
                // Keep the home layout and zoom destination stable while the
                // finger scrubs. Changing SwiftUI's tab container here can
                // rebuild the destination on the first interactive frame.
                coordinator.animate(alongsideTransition: nil) { context in
                    // Nothing changed during the gesture. Cancelling must not
                    // relayout SwiftUI's tab container as the page becomes live.
                    guard !context.isCancelled, tabs.isTabBarHidden != hidden else { return }
                    tabs.setTabBarHidden(hidden, animated: false)
                }
                return
            }
            let enrolled = coordinator.animate(alongsideTransition: { _ in
                tabs.setTabBarHidden(hidden, animated: true)
            }, completion: { context in
                tabs.setTabBarHidden(context.isCancelled ? wasHidden : hidden, animated: false)
            })
            if !enrolled { tabs.setTabBarHidden(hidden, animated: animated) }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let stack = navigationController, !stack.isNavigationBarHidden {
                stack.setNavigationBarHidden(true, animated: false)
            }
            popping = false // A pull that was let go of.
            #if DEBUG
            if appearedAt == nil {
                appearedAt = CACurrentMediaTime()
                SecurityDetailLiveZoom.note(String(format: "appeared %.2fs after open", appearedAt! - createdAt))
            }
            #endif
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // Not when the page pushes or presents a page of its own.
            guard isMovingFromParent || isBeingDismissed || popping else { return }
            popping = false
            finish()
        }

        private func finish() {
            didDismiss?()
            didDismiss = nil
        }
    }
}
