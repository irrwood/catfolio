import OSLog
import SwiftUI
import UIKit

/// Which open the security page uses from the home list.
///
/// - A: `SecurityDetailSnapshotTransition` — a drawn card and logo fly, and
///   the real page is presented under them when they land.
/// - B: `SecurityDetailLiveZoom` — the system's zoom on the live page.
///
/// Chosen in Settings, or at launch with `-securityDetail.transitionStyle A`.
enum SecurityDetailTransitionStyle: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"

    static let preferenceKey = "securityDetail.transitionStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a: L10n.text("A · 卡片展开")
        case .b: L10n.text("B · 整体缩放")
        }
    }

    static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .b
    }
}

/// B: the security page opened by the system's own zoom, on the live page.
///
/// A flies a picture of the page and hands over to the real one when it
/// lands; everything that went wrong with A — two lines on top of each other,
/// the flash, a logo left behind, the page uncovered late — happened at that
/// hand-off. Here there is none: from the tap it is the real page that grows,
/// and the system draws it, closes it (✕, pull down, swipe right) and lets a
/// finger catch it mid-way.
///
/// The one thing added to the system's zoom is where the page lines up with
/// its row: `alignmentRectProvider` puts the row's logo on the page header's
/// (centre on centre; see `alignment`), so the row and the page scale as one
/// picture and cross-fade, the logo staying in place between them.
@MainActor
final class SecurityDetailLiveZoom {
    static let shared = SecurityDetailLiveZoom()

    /// The row whose page is up, hidden in the list while its picture stands
    /// in for it — as the system hides a zoom's source.
    @MainActor @Observable
    final class HiddenSource {
        var key: SecurityDetailSnapshotTransition.SourceKey?
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
        let key = SecurityDetailSnapshotTransition.SourceKey(id: id, namespace: namespace)
        guard let source = SecurityDetailSnapshotTransition.shared.liveSourceViews(for: key),
              let window = source.row.window,
              let presenter = Self.topController(from: window.rootViewController),
              let picture = Self.picture(of: source.row) else { return false }

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
        presenter.present(controller, animated: true)
        return true
    }

    /// ✕, and a close the presenter asks for.
    func close() {
        guard let page, page.presentingViewController != nil, !page.isBeingDismissed else { return }
        page.dismiss(animated: true)
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
        let measured = SecurityDetailSnapshotTransition.shared.pageLogoFrame(in: page)
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

    private static func topController(from root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// The page, telling us when it has gone — by ✕ or by the system's own
    /// pull or swipe. A pull let go short of closing does not count.
    private final class PageController: UIHostingController<AnyView> {
        var didDismiss: (() -> Void)?

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard isBeingDismissed || presentingViewController == nil else { return }
            didDismiss?()
            didDismiss = nil
        }
    }
}

/// Hides a zoom source's row, not its marker, while B's page is up.
struct SecurityDetailLiveZoomSourceVisibility: ViewModifier {
    let key: SecurityDetailSnapshotTransition.SourceKey

    func body(content: Content) -> some View {
        content.opacity(SecurityDetailLiveZoom.hiddenSource.key == key ? 0 : 1)
    }
}
