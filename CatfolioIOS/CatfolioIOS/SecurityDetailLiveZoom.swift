import OSLog
import SwiftUI
import UIKit

/// Opens the live security page from its row; closing uses a short fade.
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

    private weak var page: UIViewController?
    /// The row as it was drawn at the tap, inside the row's marker: the view
    /// the system zooms out of and back into.
    private weak var standIn: UIView?
    private var didEnd: (() -> Void)?
    /// Where the header's logo sat on the last page, for a page that has not
    /// been laid out yet when the system asks.
    private var pageLogoInPage: CGRect?

    /// Presents the page zooming out of its row. False when the row is not on
    /// screen; the caller then presents the page its own way.
    func open(id: AnyHashable, namespace: Namespace.ID,
              page content: (_ close: @escaping () -> Void) -> AnyView,
              didEnd: @escaping () -> Void) -> Bool {
        guard page == nil else { return false }
        SecurityDetailQuickClose.shared.removeOverlay()
        let key = SecurityDetailSources.SourceKey(id: id, namespace: namespace)
        guard let source = SecurityDetailSources.shared.liveSourceViews(for: key),
              let window = source.row.window,
              let presenter = Self.topController(from: window.rootViewController),
              let drawn = Self.picture(of: source.row) else { return false }
        // Without the list card's fill behind it: only the logo and the
        // text zoom, not a slab of the card's colour.
        let picture = Self.removingBackground(from: drawn) ?? drawn

        let standIn = UIImageView(image: picture)
        standIn.frame = source.row.bounds
        standIn.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        source.row.addSubview(standIn)
        self.standIn = standIn

        let controller = PageController(rootView: content { [weak self] in self?.close() })
        controller.view.backgroundColor = SecurityDetailPresentation.uiGround
        controller.modalPresentationStyle = .fullScreen
        controller.didDismiss = { [weak self] in self?.pageDidGo() }

        let options = UIViewController.Transition.ZoomOptions()
        // Our short, cancellable close gesture replaces the reverse zoom.
        options.interactiveDismissShouldBegin = { _ in false }
        options.dimmingColor = SecurityDetailPresentation.backdropColor
        options.dimmingVisualEffect = UIBlurEffect(style: .regular)
        options.alignmentRectProvider = { [weak self, weak rowLogo = source.logo] context in
            self?.alignment(row: context.sourceView, rowLogo: rowLogo, page: context.zoomedViewController.view)
        }
        controller.preferredTransition = .zoom(options: options) { [weak row = source.row] _ in row }

        self.didEnd = didEnd
        page = controller
        // The row goes from the list in the same transaction as the tap; its
        // picture, behind it in the marker, is what shows until the zoom takes it.
        Self.hiddenSource.key = key
        presenter.present(controller, animated: true) { [weak controller, weak self] in
            guard let controller else { return }
            controller.closeGesture = SecurityDetailCloseGesture(controller: controller) { [weak self] in
                self?.close()
            }
        }
        return true
    }

    /// Dismiss the actual page immediately; a short picture fades above the list.
    func close() {
        guard let page else { return }
        SecurityDetailQuickClose.shared.dismiss(page)
    }

    private func pageDidGo() {
        standIn?.removeFromSuperview()
        standIn = nil
        page = nil
        Self.hiddenSource.key = nil
        let didEnd = didEnd
        self.didEnd = nil
        didEnd?()
    }

    /// The rect of the page that lines up with the row: the row laid over the
    /// page's header with its logo's centre on the header logo's centre. For a
    /// row with no logo, the row across the header row.
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
        // Laid out now if it can be, so the header is measured rather than assumed.
        if page.window != nil { page.layoutIfNeeded() }
        let pageSize = page.bounds.width > 1 ? page.bounds.size : (row.window?.bounds.size ?? page.bounds.size)
        // The header's logo where it sits on the page's first screen. A page
        // scrolled away from its top is lined up as if at its top: its logo,
        // off the screen, would have put the row somewhere above the page.
        let measured = SecurityDetailSources.shared.pageLogoFrame(in: page)
            .flatMap { CGRect(origin: .zero, size: pageSize).contains($0) ? $0 : nil }
        if let measured { pageLogoInPage = measured }
        let pageLogo = measured ?? pageLogoInPage ?? CGRect(x: 20, y: top + 20, width: 56, height: 56)
        if let rowLogo, rowLogo.window != nil {
            let logo = rowLogo.convert(rowLogo.bounds, to: row)
            if logo.width > 1 {
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
                let source = measured == nil ? "assumed" : "measured"
                Self.log.debug("align row \(rowSize.debugDescription, privacy: .public) logo \(logo.debugDescription, privacy: .public) → page logo \(pageLogo.debugDescription, privacy: .public) (\(source, privacy: .public)) scale \(Double(scale), format: .fixed(precision: 3)) rect \(rect.debugDescription, privacy: .public)")
                #endif
                return rect
            }
        }
        let scale = pageSize.width / rowSize.width
        return CGRect(x: 0, y: top + 16, width: pageSize.width, height: rowSize.height * scale)
    }

    #if DEBUG
    private static let log = Logger(subsystem: "com.catfolio.ios", category: "SecurityDetailLiveZoom")
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

        var closeGesture: SecurityDetailCloseGesture?

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard isBeingDismissed || presentingViewController == nil else { return }
            finish()
        }

        private func finish() {
            didDismiss?()
            didDismiss = nil
        }
    }
}

/// Hides a zoom source's row, not its marker, while its page is up.
struct SecurityDetailLiveZoomSourceVisibility: ViewModifier {
    let key: SecurityDetailSources.SourceKey

    func body(content: Content) -> some View {
        content.opacity(SecurityDetailLiveZoom.hiddenSource.key == key ? 0 : 1)
    }
}
