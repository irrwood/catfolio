import OSLog
import SwiftUI
import UIKit

/// The live security page zooms out of its row and back into it. UIKit owns
/// both directions and the interactive pull/edge gestures, including cancellation.
///
/// The page is pushed onto the row's navigation stack, not presented: a
/// navigation zoom can be interrupted, so a tap on the list while a page is
/// still flying back opens the next one at once. A modal's return holds every
/// touch until its spring has settled. Without a stack the page is presented.
@MainActor
final class SecurityDetailLiveZoom {
    static let shared = SecurityDetailLiveZoom()

    /// The row whose page is up, hidden in the list while its picture stands
    /// in for it — as the system hides a zoom's source.
    @MainActor @Observable
    final class HiddenSource {
        var key: SecurityDetailSources.SourceKey?
    }

    static let hiddenSource = HiddenSource()

    /// The page up now. One flying back is not: a tap on the list opens the
    /// next page at once, as the system's own zoom lets it, and the page on
    /// its way back cleans up after itself when it lands.
    private weak var page: PageController?
    /// The last row's picture. Tapped again while its page flies back, the
    /// row is hidden and would draw as nothing, so this is used instead.
    private var picture: (key: SecurityDetailSources.SourceKey, image: UIImage)?
    /// The picture standing in for each page's row, held here rather than only
    /// by the row's subview list and the dismissal closure. A page whose
    /// `didDismiss` never runs — replaced while it was still flying back, or
    /// torn down with the screen — used to leave its picture covering the row
    /// for good, which is a row that draws correctly and takes no tap.
    private var standIns: [ObjectIdentifier: UIImageView] = [:]

    /// A page is up and not on its way back; a tap on the list is ignored.
    var isShowingPage: Bool { page.map { !$0.isLeaving } ?? false }

    /// Presents the page zooming out of its row. False when the row is not on
    /// screen; the caller then presents the page its own way.
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
        #if DEBUG
        SecurityDetailTouchProbe.install(on: window)
        #endif
        let picture: UIImage
        if Self.hiddenSource.key == key, let kept = self.picture, kept.key == key {
            picture = kept.image
        } else {
            guard let drawn = Self.picture(of: source.row) else {
                #if DEBUG
                Self.note("BLOCKED: the row could not be drawn")
                #endif
                return false
            }
            // Without the list card's fill behind it: only the logo and the
            // text zoom, not a slab of the card's colour.
            picture = Self.removingBackground(from: drawn) ?? drawn
        }
        self.picture = (key, picture)

        // The row as it was drawn at the tap, inside the row's marker: the
        // view the system zooms out of and back into.
        let standIn = UIImageView(image: picture)
        standIn.frame = source.row.bounds
        standIn.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        standIn.isUserInteractionEnabled = false
        source.row.addSubview(standIn)

        let stack = Self.navigationController(of: source.row)
        guard let presenter = stack ?? Self.topController(from: window.rootViewController) else {
            #if DEBUG
            Self.note("BLOCKED: no presenter and no stack")
            #endif
            standIn.removeFromSuperview()
            return false
        }

        // The page has its own close; the stack's bar and back button stay
        // hidden, which the hosted view has to say too or SwiftUI shows them.
        let controller = PageController(rootView: AnyView(
            content { [weak self] in self?.close() }
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)))
        controller.navigationItem.hidesBackButton = true
        standIns[ObjectIdentifier(controller)] = standIn
        controller.view.backgroundColor = SecurityDetailPresentation.uiGround
        controller.modalPresentationStyle = .fullScreen
        controller.hidesBottomBarWhenPushed = true
        controller.didDismiss = { [weak self, weak controller] in
            guard let controller else { return }
            self?.standIns.removeValue(forKey: ObjectIdentifier(controller))?.removeFromSuperview()
            self?.pageDidGo(controller)
            didEnd()
        }

        let options = UIViewController.Transition.ZoomOptions()
        options.dimmingColor = SecurityDetailPresentation.backdropColor
        options.dimmingVisualEffect = UIBlurEffect(style: .regular)
        options.alignmentRectProvider = { [weak self, weak rowLogo = source.logo] context in
            self?.alignment(row: context.sourceView, rowLogo: rowLogo, page: context.zoomedViewController.view)
        }
        controller.preferredTransition = .zoom(options: options) { [weak row = source.row] _ in row }

        // Any picture left by a page that never reported: it would cover a row.
        for (id, view) in standIns where id != ObjectIdentifier(controller) {
            view.removeFromSuperview()
            standIns.removeValue(forKey: id)
        }
        page = controller
        // The row goes from the list in the same transaction as the tap; its
        // picture, behind it in the marker, is what shows until the zoom takes it.
        Self.hiddenSource.key = key
        if let stack {
            stack.pushViewController(controller, animated: true)
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

    /// A page has landed back in its row. Only the page up now owns the
    /// hidden row: one that landed after the next page opened leaves it be.
    private func pageDidGo(_ gone: UIViewController?) {
        #if DEBUG
        Self.note("landed gone=\(gone.map { ObjectIdentifier($0).debugDescription } ?? "nil")")
        #endif
        // This page's own picture goes whatever else has happened: it stands
        // over a row the reader is about to tap.
        if let gone {
            standIns.removeValue(forKey: ObjectIdentifier(gone))?.removeFromSuperview()
        }
        guard page == nil || page === gone else {
            #if DEBUG
            Self.note("landed: NOT the page up, leaving state alone")
            #endif
            return
        }
        page = nil
        Self.hiddenSource.key = nil
        // Nothing is up, so nothing may be covered.
        for view in standIns.values { view.removeFromSuperview() }
        standIns.removeAll()
    }

    /// The rect of the page that lines up with the row: the row laid over the
    /// page's header with its logo's centre on the header logo's centre. For a
    /// row with no logo, the row across the header row.
    ///
    /// The header logo is where the header puts it, not measured: the page may
    /// not be laid out when the system asks, or be scrolled on the way back.
    ///
    /// The rect stays inside the page. Grown until its 44pt logo matched the
    /// header's 56pt one, a row is wider than the screen, and a rect reaching
    /// off the page is not what the system lines up. So the row grows only as
    /// far as it fits either side of the logo: the centres meet exactly, the
    /// sizes within a few points.
    private func alignment(row: UIView, rowLogo: UIView?, page: UIView) -> CGRect? {
        let top = row.window?.safeAreaInsets.top ?? page.safeAreaInsets.top
        let rowSize = row.bounds.size
        guard rowSize.width > 1 else { return nil }
        let pageSize = page.bounds.width > 1 ? page.bounds.size : (row.window?.bounds.size ?? page.bounds.size)
        if let rowLogo, rowLogo.window != nil {
            let logo = rowLogo.convert(rowLogo.bounds, to: row)
            if logo.width > 1 {
                let pageLogo = HoldingDetailHeader.logoFrame(safeAreaTop: top)
                let centre = CGPoint(x: pageLogo.midX, y: pageLogo.midY)
                // As large as the logos want, as long as the row still fits
                // on the page on every side of the logo's centre.
                let scale = min(pageLogo.width / logo.width,
                                centre.x / max(logo.midX, 1),
                                (pageSize.width - centre.x) / max(rowSize.width - logo.midX, 1),
                                centre.y / max(logo.midY, 1),
                                (pageSize.height - centre.y) / max(rowSize.height - logo.midY, 1))
                let rect = CGRect(x: centre.x - logo.midX * scale, y: centre.y - logo.midY * scale,
                                  width: rowSize.width * scale, height: rowSize.height * scale)
                #if DEBUG
                Self.log.debug("align row \(rowSize.debugDescription, privacy: .public) logo \(logo.debugDescription, privacy: .public) → page logo \(pageLogo.debugDescription, privacy: .public) scale \(Double(scale), format: .fixed(precision: 3)) rect \(rect.debugDescription, privacy: .public)")
                #endif
                return rect
            }
        }
        let scale = pageSize.width / rowSize.width
        return CGRect(x: 0, y: top + HoldingDetailHeader.topInset, width: pageSize.width,
                      height: rowSize.height * scale)
    }

    #if DEBUG
    private static let log = Logger(subsystem: "com.catfolio.ios", category: "SecurityDetailLiveZoom")

    /// Every path that leaves a tap with nothing happening, and every state a
    /// page changes, on one line. Read with
    /// `log stream --predicate 'subsystem == "com.catfolio.ios"'` while tapping,
    /// so "cannot open again" is answered by the log rather than by guessing
    /// which of the four guards returned.
    static func note(_ what: String) {
        log.debug("liveZoom \(what, privacy: .public) page=\(Self.shared.describe) hidden=\(Self.shared.hiddenKey, privacy: .public)")
    }

    var describe: String {
        guard let page else { return "none" }
        return "up leaving=\(page.isLeaving) movingFromParent=\(page.isMovingFromParent) beingDismissed=\(page.isBeingDismissed) inStack=\(page.navigationController != nil) presenting=\(page.presentingViewController != nil)"
    }

    var hiddenKey: String {
        guard let k = Self.hiddenSource.key else { return "none" }
        return "\(k.id)"
    }
    #endif

    /// The row as it is drawn now, from the scroll view it sits in, so nothing
    /// floating over the list comes with it. A bitmap rather than a snapshot
    /// view, which the system's zoom would draw through a portal as empty.
    private static func picture(of row: UIView) -> UIImage? {
        var host: UIView = row.window ?? row
        var ancestor = row.superview
        while let view = ancestor {
            if view is UIScrollView { host = view; break }
            ancestor = view.superview
        }
        let rect = row.convert(row.bounds, to: host)
        guard rect.width > 1, rect.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: row.traitCollection)
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            let visible = host.bounds
            host.drawHierarchy(in: CGRect(x: visible.minX - rect.minX, y: visible.minY - rect.minY,
                                          width: visible.width, height: visible.height),
                               afterScreenUpdates: false)
        }
    }

    /// The row's picture with its background taken out: the colour at its
    /// corner — the card's fill — becomes transparent, and every other pixel
    /// keeps what it adds over that colour ("colour to alpha"), so text and
    /// its antialiased edges come out clean, with no fringe of the fill.
    private static func removingBackground(from image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        guard width > 2, height > 2 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let made = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: space, bitmapInfo: info) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let p = buffer.bindMemory(to: UInt8.self)
            // The fill: a pixel just inside the top-left corner.
            let corner = 2 * bytesPerRow + 2 * 4
            let bg = (Double(p[corner]) / 255, Double(p[corner + 1]) / 255, Double(p[corner + 2]) / 255)
            func share(_ c: Double, _ b: Double) -> Double {
                if c > b { return b < 1 ? (c - b) / (1 - b) : 0 }
                if c < b { return b > 0 ? (b - c) / b : 0 }
                return 0
            }
            for i in stride(from: 0, to: bytesPerRow * height, by: 4) {
                let a0 = Double(p[i + 3]) / 255
                guard a0 > 0 else { continue }
                let c = (Double(p[i]) / 255 / a0, Double(p[i + 1]) / 255 / a0, Double(p[i + 2]) / 255 / a0)
                let alpha = min(1, max(share(c.0, bg.0), share(c.1, bg.1), share(c.2, bg.2))) * a0
                if alpha <= 0.001 {
                    p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0
                    continue
                }
                let k = a0 / alpha
                func channel(_ c: Double, _ b: Double) -> UInt8 {
                    let straight = min(1, max(0, (c - b) * k + b))
                    return UInt8((straight * alpha * 255).rounded())
                }
                p[i] = channel(c.0, bg.0)
                p[i + 1] = channel(c.1, bg.1)
                p[i + 2] = channel(c.2, bg.2)
                p[i + 3] = UInt8((alpha * 255).rounded())
            }
            return context.makeImage()
        }
        return made.map { UIImage(cgImage: $0, scale: image.scale, orientation: image.imageOrientation) }
    }

    /// The stack the row's screen sits in, when that screen is on top of it.
    private static func navigationController(of view: UIView) -> UINavigationController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                // Also while a page is still popping: that is the interruption.
                guard let stack = controller.navigationController,
                      stack.presentedViewController == nil else { return nil }
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

        /// On its way back to the row: popped or dismissed, and not pulled
        /// back up yet.
        var isLeaving: Bool { isMovingFromParent || isBeingDismissed || popping }
        private var popping = false

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // The home stack hides its bar; a pushed page must too.
            navigationController?.setNavigationBarHidden(true, animated: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            popping = isMovingFromParent
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.setNavigationBarHidden(true, animated: false)
            popping = false // A pull that was let go of.
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

/// Hides a zoom source's row, not its marker, while its page is up.
///
/// By colour, not opacity: SwiftUI does not hit-test a view at (or near) zero
/// opacity, and the row must take a tap while its page is still flying back
/// into it. Multiplying by clear draws nothing and leaves hit-testing alone.
struct SecurityDetailLiveZoomSourceVisibility: ViewModifier {
    let key: SecurityDetailSources.SourceKey

    func body(content: Content) -> some View {
        content.colorMultiply(SecurityDetailLiveZoom.hiddenSource.key == key ? .clear : .white)
    }
}
