import ImageIO
import Observation
import SwiftUI
import UIKit

/// A slightly raised ground for app-owned modal pages in dark appearance.
/// Keep this separate from the security detail's designed presentation.
enum AppModalStyle {
    static let uiDarkBackground = UIColor(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1A / 255.0, alpha: 1)
    static let darkBackground = Color(uiColor: uiDarkBackground)
    static let systemBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? uiDarkBackground : .systemBackground
    })
}

private struct AppModalEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isAppModal: Bool {
        get { self[AppModalEnvironmentKey.self] }
        set { self[AppModalEnvironmentKey.self] = newValue }
    }
}

private struct AppPageBackgroundModifier: ViewModifier {
    @Environment(\.isAppModal) private var isModal
    @Environment(\.colorScheme) private var colorScheme
    let fallback: Color

    func body(content: Content) -> some View {
        content.background(isModal && colorScheme == .dark ? AppModalStyle.darkBackground : fallback)
    }
}

private struct AppModalSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder func body(content: Content) -> some View {
        if colorScheme == .dark {
            content
                .scrollContentBackground(.hidden)
                .background(AppModalStyle.darkBackground.ignoresSafeArea())
                .presentationBackground(AppModalStyle.darkBackground)
                .toolbarBackground(AppModalStyle.darkBackground, for: .navigationBar)
        } else {
            content
        }
    }
}

extension View {
    /// Apply to the scrolling page inside a navigation stack, so its own
    /// opaque fill cannot cover the presentation's ground.
    func appPageBackground(_ fallback: Color = .clear) -> some View {
        modifier(AppPageBackgroundModifier(fallback: fallback))
    }

    func appModalSurface() -> some View {
        modifier(AppModalSurfaceModifier()).environment(\.isAppModal, true)
    }

    func appSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                              @ViewBuilder content: @escaping () -> Sheet) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().appModalSurface() }
    }

    func appSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                   @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).appModalSurface() }
    }

    func appFullScreenCover<Cover: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Cover) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { content().appModalSurface() }
    }

    func appFullScreenCover<Item: Identifiable, Cover: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                           @ViewBuilder content: @escaping (Item) -> Cover) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { content($0).appModalSurface() }
    }
}

/// Shared treatment for the oversized financial values used as page and card
/// headlines: SF Rounded, with a smaller currency/sign prefix aligned to the
/// numeral baseline.
///
/// No manual tracking. The 5% letterspacing here was cut for Montserrat,
/// whose numerals are narrow; SF carries Apple's own optical tracking per
/// size, and adding to it at display sizes visibly loosens the figure.
struct CatfolioDisplayAmountText: View {
    @Environment(\.locale) private var appLocale
    let text: String
    var size: CGFloat = 32
    var symbolSize: CGFloat = 20.64
    var color: Color = .primary

    private var splitText: (prefix: String, number: String) {
        guard let digitIndex = text.firstIndex(where: \.isNumber) else { return ("", text) }
        return (String(text[..<digitIndex]), String(text[digitIndex...]))
    }

    var body: some View {
        let parts = splitText
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(parts.prefix)
                .font(Typography.number(size: symbolSize))
            Text(parts.number)
                .font(Typography.number(size: size))
        }
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
}

/// Defers expensive sheet content until UIKit reports that the system
/// presentation transition has completed. This keeps the interactive spring
/// free of chart preparation, decoding and network callbacks.
struct PresentationDidAppearReader: UIViewControllerRepresentable {
    let action: () -> Void

    func makeUIViewController(context: Context) -> ObserverViewController {
        ObserverViewController(action: action)
    }

    func updateUIViewController(_ controller: ObserverViewController, context: Context) {
        controller.action = action
    }

    final class ObserverViewController: UIViewController {
        var action: () -> Void
        private var hasReported = false

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !hasReported else { return }
            hasReported = true
            let callback = action
            DispatchQueue.main.async(execute: callback)
        }
    }
}

/// Content scrolling under a top bar fades out through a progressive blur
/// instead of meeting it at a hard line.
///
/// Set explicitly rather than left to `.automatic`, which on some screens
/// resolves to the hard edge — a visible boundary under the bar exactly where
/// the page should dissolve into it. Top edge only: the bottom edge and the
/// tab bar keep whatever the system gives them.
///
/// Applied per page, next to the page's navigation title, not once at the
/// root: the modifier reaches every scroll view below it, and the root stack
/// also holds the portfolio home, which has no top bar to blur under.
extension View {
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

extension UIScrollView {
    /// The same decision for a scroll view SwiftUI does not reach — one owned
    /// by a UIKit container, such as the History pager's pages.
    func applySoftTopScrollEdge() {
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = .soft
        }
    }
}

/// How a security page is presented, and what it stands on.
///
/// One definition for every place that opens `HoldingDetailView`, because each
/// used to set its own background, corners and indicator, and none of them
/// agreed with the design (Figma `282:2003`).
///
/// The rule the whole thing rests on: the page draws **no background of its
/// own**. The ground is the sheet's `presentationBackground`, which the system
/// clips to the sheet's rounded shape in every frame — at rest, through the
/// zoom morph and while the reader drags it down. A background drawn inside
/// the page is not under that clip the whole time, and every square corner
/// that showed during a drag or a morph was one of those.
enum SecurityDetailPresentation {
    /// The sheet's top corners. The design drew 38, but the moment a back or
    /// dismiss swipe begins, the zoom transition takes the card over at its
    /// own radius of about 50pt, measured on an iPhone 17 Pro recording — so
    /// at 38 the corners jumped outward under the finger. At rest the sheet
    /// now matches what the swipe will use.
    static let cornerRadius: CGFloat = 50

    /// The shade behind an open security page. A 28% black over the white
    /// home page turned it a dirty grey; in light mode it is kept light enough
    /// to read as depth rather than a stain.
    static let backdropColor = UIColor { trait in
        UIColor.black.withAlphaComponent(trait.userInterfaceStyle == .dark ? 0.28 : 0.10)
    }

    /// The top of the designed ground. Figma paints `rgba(45,50,57,0.5)` over a
    /// black frame; composited, that is this colour, drawn opaque so the dimmed
    /// page behind a sheet never shows through it.
    static let uiGroundTop = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 23 / 255, green: 25 / 255, blue: 29 / 255, alpha: 1)
            : UIColor(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255, alpha: 1)
    }
    static let uiGroundBottom = UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .white
    }

    /// Blue-grey at the top of the sheet, black by its bottom edge. The design
    /// draws this on a rectangle as long as the content, reaching black at
    /// 43% — which on that rectangle is exactly the height of one screen. It is
    /// fixed to the sheet here rather than to the scrolling content: attached
    /// to the content, pulling down at the top dragged the rectangle's square
    /// upper edge into view over the black beneath it.
    static var ground: LinearGradient {
        LinearGradient(
            colors: [Color(uiColor: uiGroundTop), Color(uiColor: uiGroundBottom)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The open is confirmed with a click, not a thud — a rigid impact, which
    /// is the crisp one — and at the instant the row is let go, not when the
    /// sheet finishes arriving.
    static let openFeedback = SensoryFeedback.impact(flexibility: .rigid, intensity: 0.8)
}

/// A backdrop in the presentation container, outside the sheet's zooming
/// surface. Its opacity uses the same coordinator as the native transition,
/// including interactive dismissal and cancellation.
private struct SecurityDetailBackdrop: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.tearDown()
    }

    final class Controller: UIViewController {
        private weak var sheetController: UIViewController?
        // Keep the hit barrier opaque in UIKit's hit-testing sense even while
        // its separate shade fades to zero. Background taps must not leak.
        private let hitBarrier = UIView()
        private let shade = UIView()
        private var hasPresented = false
        private var isDismissing = false
        private var transitionInFlight = false

        override func loadView() {
            let observer = UIView(frame: .zero)
            observer.backgroundColor = .clear
            observer.isUserInteractionEnabled = false
            view = observer

            hitBarrier.backgroundColor = .clear
            hitBarrier.accessibilityElementsHidden = true
            hitBarrier.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shade.backgroundColor = SecurityDetailPresentation.backdropColor
            shade.alpha = 0
            shade.isUserInteractionEnabled = false
            shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hitBarrier.addSubview(shade)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            presentBackdropIfNeeded(animated: animated)
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            // Some presentations attach their container after willAppear.
            // This is still before the first rendered frame.
            presentBackdropIfNeeded(animated: animated)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            dismissBackdropIfNeeded(animated: animated)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard hasPresented, !isDismissing,
                  !SecurityDetailSnapshotTransition.shared.owns(shade: shade) else { return }
            transitionInFlight = false
            shade.alpha = 1
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard isDismissing || sheetController?.presentingViewController == nil else { return }
            transitionInFlight = false
            hitBarrier.removeFromSuperview()
        }

        private func presentBackdropIfNeeded(animated: Bool) {
            guard !hasPresented else { return }
            var owner: UIViewController = self
            while let parent = owner.parent { owner = parent }
            guard owner.presentingViewController != nil,
                  let presentation = owner.presentationController,
                  let container = presentation.containerView,
                  let presentedView = presentation.presentedView else { return }
            var surface = presentedView
            // Use the public presentation surface and its ancestry, never
            // private dimming-view names or UIKit's transition delegate.
            while let parent = surface.superview, parent !== container { surface = parent }
            guard surface.superview === container else { return }
            sheetController = owner
            hitBarrier.frame = container.bounds
            shade.frame = hitBarrier.bounds
            container.insertSubview(hitBarrier, belowSubview: surface)
            hasPresented = true
            // Opened from a row, the snapshot transition brings the shade up
            // with its card and hands it over when the card lands.
            if SecurityDetailSnapshotTransition.shared.claimPresentation(
                surface: surface, content: presentedView, shade: shade) {
                return
            }
            animateBackdrop(presenting: true, animated: animated)
        }

        private func dismissBackdropIfNeeded(animated: Bool) {
            // Pushing research or presenting another sheet is not dismissal
            // of this page: its backdrop must stay in place underneath it.
            guard hasPresented, !isDismissing,
                  sheetController?.isBeingDismissed == true else { return }
            isDismissing = true
            animateBackdrop(presenting: false, animated: animated)
        }

        private func animateBackdrop(presenting: Bool, animated: Bool) {
            let target: CGFloat = presenting ? 1 : 0
            // Opening, the shade fades on its own Core Animation clock. Run
            // alongside the zoom it was stepped by the main thread, which is
            // busiest building the page in exactly those frames — it came in
            // in two or three visible jumps. Closing stays with the coordinator
            // so an interactive swipe drives it and a cancelled one restores it.
            // An explicit layer animation: UIKit calls this from inside the
            // transition's setup, where `UIView.animate` is suppressed and the
            // shade simply appeared.
            if presenting, animated {
                transitionInFlight = true
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    self?.finishTransition(presenting: true, cancelled: false)
                }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = shade.layer.presentation()?.opacity ?? Float(shade.alpha)
                fade.toValue = 1
                fade.duration = 0.35
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shade.alpha = target
                shade.layer.add(fade, forKey: "catfolio.backdrop.fade")
                CATransaction.commit()
                return
            }
            if let coordinator = sheetController?.transitionCoordinator ?? transitionCoordinator,
               coordinator.isAnimated {
                transitionInFlight = true
                let scheduled = coordinator.animateAlongsideTransition(in: hitBarrier, animation: { _ in
                    self.shade.alpha = target
                }, completion: { context in
                    self.finishTransition(presenting: presenting, cancelled: context.isCancelled)
                })
                if !scheduled {
                    // The completion can still run when queuing fails. Leave
                    // cleanup to it (or didDisappear), never to a second timer.
                    UIView.animate(withDuration: 0.25, delay: 0,
                                   options: [.beginFromCurrentState, .curveEaseInOut]) {
                        self.shade.alpha = target
                    }
                }
                return
            }

            // An unanimated presentation has no coordinator. If UIKit attaches
            // this observer late, still fade instead of flashing a black layer.
            transitionInFlight = true
            UIView.animate(withDuration: animated ? 0.25 : 0,
                           delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                self.shade.alpha = target
            } completion: { _ in
                self.finishTransition(presenting: presenting, cancelled: false)
            }
        }

        private func finishTransition(presenting: Bool, cancelled: Bool) {
            // A close requested during opening may already have started the
            // next transition; its opacity and cleanup now belong to the exit.
            guard presenting != isDismissing else { return }
            transitionInFlight = false
            if presenting ? cancelled : !cancelled {
                hitBarrier.removeFromSuperview()
            } else {
                shade.alpha = 1
            }
            if !presenting, cancelled { isDismissing = false }
        }

        func tearDown() {
            // SwiftUI may dismantle content before UIKit finishes its exit.
            // The coordinator's completion retains us and removes the barrier.
            guard !transitionInFlight else { return }
            if sheetController?.isBeingDismissed == true {
                dismissBackdropIfNeeded(animated: true)
            } else {
                hitBarrier.removeFromSuperview()
            }
        }
    }
}

/// Keeps financial colours intact while the row responds to a press. Button
/// owns recognition and cancellation, so starting a scroll never opens it.
struct HoldingPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82),
                       value: configuration.isPressed)
    }
}

/// Which row a security page opens from. The motion itself is
/// `SecurityDetailSnapshotTransition`'s; this keeps the presenter's side —
/// one open at a time, and the source it came from.
@MainActor @Observable
final class SecurityDetailZoomState {
    struct Source {
        let id: AnyHashable
        let namespace: Namespace.ID
    }

    private(set) var activeSource: Source?

    /// Presents in the same update as the tap. With a source on screen the
    /// sheet appears without animation and the snapshot card moves instead.
    func prepare(id: AnyHashable, namespace: Namespace.ID, present: @escaping () -> Void) {
        guard activeSource == nil else { return }
        switch SecurityDetailSnapshotTransition.shared.beginOpen(id: id, namespace: namespace) {
        case .busy:
            return
        case .plain:
            activeSource = Source(id: id, namespace: namespace)
            present()
        case .snapshot:
            activeSource = Source(id: id, namespace: namespace)
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { present() }
        }
    }

    func didDismiss() {
        // Called by sheet onDismiss, not by the selection becoming nil or a
        // view disappearing at the start of an interactive dismissal.
        activeSource = nil
        SecurityDetailSnapshotTransition.shared.presentationDidEnd()
    }
}

private struct SecurityDetailZoomOriginKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var securityDetailZoomOrigin: Namespace.ID? {
        get { self[SecurityDetailZoomOriginKey.self] }
        set { self[SecurityDetailZoomOriginKey.self] = newValue }
    }
}

extension View {
    /// Kept so presenters read the same; the snapshot transition needs
    /// nothing from the host.
    func securityDetailZoomHost(_ state: SecurityDetailZoomState, in namespace: Namespace.ID) -> some View {
        self
    }

    /// Kept so presenters read the same. The system zoom is no longer used:
    /// on iOS 26 its geometry, timing, shadow and cross-fade were fixed and
    /// its tail left a double image of the row.
    func securityDetailZoomTransition(_ source: SecurityDetailZoomState.Source?, in namespace: Namespace.ID) -> some View {
        self
    }
}

private struct HoldingDetailPreviewModifier: ViewModifier {
    // Standalone ImageRenderer trees do not inherit the app environment.
    // A visual copy can render its label without constructing a live preview.
    @Environment(AppModel.self) private var model: AppModel?
    let holding: Holding?
    let onOpen: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let holding, let model {
            content
                // UIKit's context menu rather than SwiftUI's `.contextMenu`:
                // the moment a finger lands, the menu starts lifting the row
                // onto a platter with a wide soft shadow — before it knows the
                // press is a hold — and on the white list every tap flashed a
                // dark grey band. SwiftUI has no say over that shadow; UIKit's
                // preview parameters do.
                .background {
                    ShadowlessContextMenuRegion(
                        cornerRadius: 12,
                        actionTitle: L10n.text("打开个股"),
                        actionImage: "arrow.up.forward.app",
                        previewSize: {
                            let screen = UIScreen.main.bounds.size
                            return CGSize(width: min(390, screen.width - 48), height: min(640, screen.height * 0.66))
                        },
                        preview: {
                            // The actual detail page shares its cache with a
                            // subsequent open.
                            AnyView(
                                HoldingDetailView(holding: holding, onClose: {}, isPreview: true)
                                    .environment(model)
                                    .background(SecurityDetailPresentation.ground)
                                    .allowsHitTesting(false)
                            )
                        },
                        onOpen: onOpen
                    )
                }
                .accessibilityHint(L10n.text("轻点打开个股，长按预览"))
        } else {
            content
        }
    }
}

/// Marks the view it sits behind as a context-menu region. The menu itself is
/// one `UIContextMenuInteraction` on the nearest scroll view (or the window),
/// shared by every region in it, so taps and scrolling stay with SwiftUI; the
/// interaction only starts over a region, and lifts a snapshot of it with an
/// empty shadow path.
private struct ShadowlessContextMenuRegion: UIViewRepresentable {
    let cornerRadius: CGFloat
    let actionTitle: String
    let actionImage: String
    let previewSize: () -> CGSize
    let preview: () -> AnyView
    let onOpen: () -> Void

    func makeUIView(context: Context) -> RegionView { RegionView() }

    func updateUIView(_ view: RegionView, context: Context) {
        view.cornerRadius = cornerRadius
        view.actionTitle = actionTitle
        view.actionImage = actionImage
        view.previewSize = previewSize
        view.preview = preview
        view.onOpen = onOpen
    }

    static func dismantleUIView(_ view: RegionView, coordinator: ()) {
        view.unregister()
    }

    final class RegionView: UIView {
        var cornerRadius: CGFloat = 12
        var actionTitle = ""
        var actionImage = ""
        var previewSize: () -> CGSize = { .zero }
        var preview: () -> AnyView = { AnyView(EmptyView()) }
        var onOpen: () -> Void = {}
        private weak var menuHost: ShadowlessContextMenuHost?

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
            guard let window else {
                unregister()
                return
            }
            var ancestor = superview
            var host: UIView = window
            while let view = ancestor {
                if view is UIScrollView {
                    host = view
                    break
                }
                ancestor = view.superview
            }
            let menu = ShadowlessContextMenuHost.host(for: host)
            if menuHost !== menu {
                unregister()
                menu.add(self)
                menuHost = menu
            }
        }

        func unregister() {
            menuHost?.remove(self)
            menuHost = nil
        }

        var isShowing: Bool {
            guard window != nil else { return false }
            var view: UIView? = self
            while let current = view {
                if current.isHidden || current.alpha < 0.01 { return false }
                view = current.superview
            }
            return true
        }
    }
}

@MainActor
private final class ShadowlessContextMenuHost: NSObject, UIContextMenuInteractionDelegate {
    private static var key: UInt8 = 0
    typealias Region = ShadowlessContextMenuRegion.RegionView

    private let regions = NSHashTable<Region>.weakObjects()
    private weak var active: Region?

    static func host(for view: UIView) -> ShadowlessContextMenuHost {
        if let existing = objc_getAssociatedObject(view, &key) as? ShadowlessContextMenuHost {
            return existing
        }
        let host = ShadowlessContextMenuHost()
        view.addInteraction(UIContextMenuInteraction(delegate: host))
        objc_setAssociatedObject(view, &key, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return host
    }

    func add(_ region: Region) { regions.add(region) }
    func remove(_ region: Region) { regions.remove(region) }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let view = interaction.view,
              let region = regions.allObjects.last(where: { region in
                  region.isShowing && region.bounds.contains(region.convert(location, from: view))
              }) else { return nil }
        active = region
        return UIContextMenuConfiguration(identifier: nil, previewProvider: { [weak region] in
            guard let region else { return nil }
            let controller = UIHostingController(rootView: region.preview())
            controller.preferredContentSize = region.previewSize()
            controller.view.backgroundColor = .clear
            return controller
        }, actionProvider: { [weak region] _ in
            guard let region else { return nil }
            return UIMenu(children: [
                UIAction(title: region.actionTitle, image: UIImage(systemName: region.actionImage)) { [weak region] _ in
                    region?.onOpen()
                }
            ])
        })
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        active.flatMap(targetedPreview)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        active.flatMap(targetedPreview)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                                animator: any UIContextMenuInteractionCommitAnimating) {
        // Tapping the preview opens the page, as the menu's action does.
        let region = active
        animator.addCompletion { region?.onOpen() }
    }

    /// A snapshot of the region, lifted in place with no shadow. The empty
    /// shadow path is the point of all this: a nil one means "use the visible
    /// path", which is the dark band.
    private func targetedPreview(for region: Region) -> UITargetedPreview? {
        guard let window = region.window else { return nil }
        let frame = region.convert(region.bounds, to: window)
        guard frame.width > 1, frame.height > 1,
              let snapshot = window.resizableSnapshotView(from: frame, afterScreenUpdates: false,
                                                          withCapInsets: .zero) else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: snapshot.bounds, cornerRadius: region.cornerRadius)
        parameters.shadowPath = UIBezierPath()
        return UITargetedPreview(view: snapshot, parameters: parameters,
                                 target: UIPreviewTarget(container: window, center: CGPoint(x: frame.midX, y: frame.midY)))
    }
}

extension View {
    func holdingDetailPreview(_ holding: Holding?, onOpen: @escaping () -> Void) -> some View {
        modifier(HoldingDetailPreviewModifier(holding: holding, onOpen: onOpen))
    }
}

extension View {
    /// Presents a security page as a sheet: the designed ground, the designed
    /// corners, no grabber.
    func securityDetailSheet() -> some View {
        presentationDetents([.large])
            .environment(\.isAppModal, false)
            // Suppress the system's separate dimming layer. The coordinated
            // backdrop supplies both the shade and a background hit barrier.
            .presentationBackgroundInteraction(.enabled(upThrough: .large))
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(SecurityDetailPresentation.cornerRadius)
            .presentationBackground { SecurityDetailPresentation.ground }
            .background { SecurityDetailBackdrop() }
    }

    /// The same ground for a security page pushed onto a navigation stack,
    /// where there is no sheet to carry it.
    func securityDetailPushedBackground() -> some View {
        background(SecurityDetailPresentation.ground.ignoresSafeArea())
    }

    /// Marks the view a zoom grows out of.
    ///
    /// Deliberately without a `clipShape` configuration. That configuration
    /// does not only shape the transition — it clips the source view at rest,
    /// all the time. Clipping every holding row to the sheet's 38pt corner cut
    /// the trailing figures off each row and shaved the corners off each logo
    /// on the home page. The square corners that showed mid-morph came from
    /// the page's own backgrounds, which the sheet's single ground now
    /// replaces; the sources did not need reshaping.
    func catfolioZoomSource(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        background {
            SecurityDetailSourceMarker(key: .init(id: AnyHashable(id), namespace: namespace))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Clicks when a security page is asked for — in the same run-loop turn
    /// as the tap that set `trigger`, which is before the zoom has begun.
    /// Nothing fires on the way back: the reader already feels the drag.
    func securityDetailOpenFeedback<ID: Equatable>(trigger: ID?, enabled: Bool) -> some View {
        sensoryFeedback(SecurityDetailPresentation.openFeedback, trigger: trigger) { _, new in
            enabled && new != nil
        }
    }
}

/// Binds this page's scroll view before its large title first appears. Only
/// the page directly owned by the nearest navigation controller is changed;
/// never nominate a scroll view on a shared tab or outer navigation container.
struct NavigationBarScrollAnchor: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.nominateIfVisible()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.releaseRegistration()
    }

    final class Controller: UIViewController {
        private weak var registeredOwner: UIViewController?
        private weak var registeredScrollView: UIScrollView?

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            nominateIfVisible()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            nominateIfVisible()
        }

        func nominateIfVisible() {
            guard isViewLoaded, view.window != nil else { return }
            var candidate = view.superview
            while let current = candidate, !(current is UIScrollView) {
                candidate = current.superview
            }
            guard let scrollView = candidate as? UIScrollView else { return }
            var owner: UIViewController = self
            while let parent = owner.parent {
                if let navigation = parent as? UINavigationController {
                    guard navigation.topViewController === owner else { return }
                    if registeredOwner !== owner || registeredScrollView !== scrollView {
                        releaseRegistration()
                    }
                    if owner.contentScrollView(for: .top) !== scrollView {
                        owner.setContentScrollView(scrollView, for: .top)
                    }
                    registeredOwner = owner
                    registeredScrollView = scrollView
                    return
                }
                guard !(parent is UITabBarController) else { return }
                owner = parent
            }
        }

        func releaseRegistration() {
            if let owner = registeredOwner, let scrollView = registeredScrollView,
               owner.contentScrollView(for: .top) === scrollView {
                owner.setContentScrollView(nil, for: .top)
            }
            registeredOwner = nil
            registeredScrollView = nil
        }
    }
}

enum CatfolioStyle {
    static let green = Color(red: 47 / 255, green: 138 / 255, blue: 62 / 255)
    static let red = Color(red: 228 / 255, green: 0, blue: 20 / 255)
    static let blue = Color(red: 112 / 255, green: 140 / 255, blue: 255 / 255)
    /// Shared page-edge alignment used by the home content regions.
    static let pageHorizontalInset: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 12
}

/// The expanded Catfolio palette. Screens opt into these tokens explicitly so
/// a palette preview can be evaluated without silently recolouring the app.
enum CatfolioPalette {
    static let coral50 = color(0xFFECEB)
    static let coral200 = color(0xFFB3B1)
    static let coral500 = color(0xFF5D5B)
    static let coral700 = color(0xD32F2D)
    static let coral900 = color(0x7A1615)

    static let rose50 = color(0xFFE6EC)
    static let rose300 = color(0xD1526C)
    static let rose500 = color(0xE30045)
    static let rose700 = color(0xA80033)
    static let rose900 = color(0x5E001C)

    static let magenta50 = color(0xF9E5FD)
    static let magenta200 = color(0xE274F5)
    static let magenta500 = color(0xC702E8)
    static let magenta700 = color(0xB42B81)
    static let magenta900 = color(0x4E005B)

    static let violet50 = color(0xEBE4FF)
    static let violet100 = color(0xE6D8FF)
    static let violet200 = color(0xCAAEFA)
    static let violet500 = color(0x804DDE)
    static let violet700 = color(0x5A2CA8)
    static let violet900 = color(0x31165C)

    static let blue50 = color(0xE4F1FF)
    static let blue100 = color(0xCCEBFF)
    static let blue200 = color(0xA0CDFF)
    static let blue500 = color(0x027DFF)
    static let blue700 = color(0x2B47D1)
    static let blue900 = color(0x142A7A)

    static let sky50 = color(0xCAFDFF)
    static let sky200 = color(0x7FE8FF)
    static let sky300 = color(0x91D2FC)
    static let sky700 = color(0x016D97)
    static let sky900 = color(0x084A63)

    static let teal50 = color(0xDBFBF4)
    static let teal200 = color(0x70D7C2)
    static let teal400 = color(0x00E1B2)
    static let teal500 = color(0x00C6A3)
    static let teal900 = color(0x0A6B62)

    static let green50 = color(0xE4FBEE)
    static let green200 = color(0x84F4AD)
    static let green500 = color(0x05AE5B)
    static let green700 = color(0x027D50)
    static let green900 = color(0x006645)
    /// Exact Figma green used by the Today contribution bars.
    static let contributionGreen = color(0x00CC00)
    /// Categorical segment colours from the dividend card, Figma 322:2262.
    static let dividendSeries: [Color] = [
        color(0x3475FF), color(0xA0CDFF), color(0xC8CD00), color(0xFF9500),
        color(0x13BA8E), color(0xEB74FE), color(0x00CC00)
    ]
    static let dividendSelection = dynamic(light: 0x1F46FF, dark: 0x8BA7FF)
    /// Holding-detail transaction markers from the shared chart language.
    static let tradeBuy = color(0x01B801)
    static let tradeSellLight = color(0xFF9500)
    static let tradeSellDark = yellow500
    static let securityPriceLine = color(0x3475FF)
    /// A statement's two directions, for the flow diagrams on the financials
    /// page. What a company earns, keeps or generates reads as one identity;
    /// what is subtracted from it — cost of revenue, operating expenses,
    /// liabilities, capital expenditure — reads as the other.
    ///
    /// Blue against amber. Violet was the second colour until it was judged
    /// unattractive; amber is blue's complement, so the two sides separate at
    /// a glance, and it is not the red a reader takes for a loss.
    ///
    /// The ribbons carry their own colour rather than a translucent copy of the
    /// bar. A tint chosen directly can be lighter than an opacity of the bar
    /// would ever be while keeping enough saturation to still read as the same
    /// identity.
    ///
    /// Each value has a dark counterpart. The light-mode ribbons are pale tints
    /// meant to sit on white; on a black page the same tints glared like lit
    /// bands, so dark mode draws deep tints of the same hues and lifts the
    /// bars a step so they still stand off the ribbons.
    ///
    /// Neither side is `gain` or `loss`: revenue is not a gain and a liability
    /// is not a loss, so borrowing either would tell the reader something
    /// untrue about a statement.
    static let statementInflow = dynamic(light: 0x027DFF, dark: 0x3D9BFF)
    static let statementInflowRibbon = dynamic(light: 0xCCEBFF, dark: 0x0F3257)
    static let statementOutflow = dynamic(light: 0xEF7A00, dark: 0xFFA238)
    static let statementOutflowRibbon = dynamic(light: 0xFFE4C7, dark: 0x4A2C0C)
    /// Figures printed in a flow diagram's colours: a step darker than the bar
    /// in light mode, where amber on white would be too faint to read.
    static let statementInflowText = dynamic(light: 0x0068D6, dark: 0x6CB4FF)
    static let statementOutflowText = dynamic(light: 0xB85C00, dark: 0xFFB366)
    /// Figma Today-card negative series and its ambient dark-mode light source.
    static let contributionRed = color(0xD5312C)
    static let contributionRedGlow = color(0xE2433C)

    static let yellow50 = color(0xFFFACC)
    static let yellow300 = color(0xFFF904)
    static let yellow500 = color(0xF7D700)
    static let yellow700 = color(0xC8CD01)
    static let yellow900 = color(0x5E5100)

    static let orange50 = color(0xFFEEE1)
    static let orange200 = color(0xFFD2BD)
    static let orange400 = color(0xFF6B43)
    static let orange500 = color(0xEF7A00)
    static let orange900 = color(0x6B3200)

    static let clay50 = color(0xF6EBE3)
    static let clay200 = color(0xFFAB7D)
    static let clay500 = color(0xB57347)
    static let clay700 = color(0x8A5231)
    static let clay900 = color(0x4A2A17)

    static let neutral50 = color(0xF8FAFA)
    static let neutral100 = color(0xEFF2F2)
    static let neutral200 = color(0xE2E7E7)
    static let neutral300 = color(0xCBD2D3)
    static let neutral400 = color(0xA7B0B1)
    static let neutral500 = color(0x7F8A8B)
    static let neutral600 = color(0x5F6A6B)
    static let neutral700 = color(0x454E4F)
    static let neutral800 = color(0x2C3334)
    static let neutral900 = color(0x1A1F20)

    static let white = color(0xFFFFFF)
    static let paper = color(0xF1FDFE)
    static let black = color(0x000000)

    static let muted100 = color(0xE7F1F2)
    static let muted200 = color(0xC1E1E4)
    static let muted300 = color(0xB4D0D2)
    static let muted500 = color(0x80B9BB)

    static let berryGradient = LinearGradient(
        colors: [rose500, violet500],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
    static let mistGradient = LinearGradient(
        colors: [color(0xB5DCF0), paper],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
    static let jadeGradient = LinearGradient(
        colors: [teal500, green50],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
    static let emberGradient = LinearGradient(
        stops: [
            .init(color: yellow500, location: 0),
            .init(color: orange400, location: 0.55),
            .init(color: clay500, location: 1),
        ],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// One swatch for each appearance.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let light = uiColor(light)
        let dark = uiColor(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Semantic application colors. Views should depend on these roles instead of
/// palette swatches so changing one token updates every related screen.
enum CatfolioTheme {
    // Figma 241:45228: white stationery on a black backdrop.
    static let paperFold = Color(white: 239.0 / 255.0)
    static let accent = CatfolioPalette.blue500
    static let positive = CatfolioPalette.green500
    static let danger = CatfolioPalette.rose500
    static let warning = CatfolioPalette.orange500

    static let trading212 = accent
    static let moomoo = CatfolioPalette.orange400
    static let interactiveBrokers = danger
    static let csvImport = positive
    static let services = CatfolioPalette.violet500
    static let preference = CatfolioPalette.teal500
    static let localData = CatfolioPalette.sky700
    static let neutralIcon = Color(uiColor: .secondaryLabel)
    static let neutralFill = Color(uiColor: .secondarySystemFill)
    static let subtleFill = Color(uiColor: .quaternarySystemFill)
    static let skeletonFill = Color(uiColor: .tertiarySystemFill)
    static let skeletonEmphasis = Color(uiColor: .systemFill)

    static let disclosure = accent.opacity(0.68)

    /// A rise and a fall. One definition each, resolved per appearance here
    /// rather than at the call sites.
    ///
    /// There were nine different greens and five different reds in the app
    /// all meaning these two things, because every screen picked its own. A
    /// reader comparing two rows cannot tell a deliberate shade from an
    /// accidental one, so there is exactly one of each and the light and dark
    /// variants live together where they can be compared.
    static func gain(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 0, green: 0.53, blue: 0.14)
            : Color(red: 0.204, green: 0.780, blue: 0.349)
    }

    static func loss(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? CatfolioPalette.rose500
            : Color(red: 1.000, green: 0.271, blue: 0.404)
    }

    /// Readable performance text over Home's blue hero background.
    static func heroPerformance(for value: Double, scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return value >= 0 ? gain(for: scheme) : loss(for: scheme)
        }
        return value >= 0
            ? Color(red: 13 / 255, green: 125 / 255, blue: 41 / 255)
            : loss(for: scheme).mix(with: .black, by: 0.12)
    }

    /// For contexts with no `ColorScheme` to hand — a `Canvas` closure, a
    /// value computed off the view tree. Prefer the scheme-aware pair.
    static let gainDefault = Color(red: 0.204, green: 0.780, blue: 0.349)
    static let lossDefault = CatfolioPalette.rose500
    /// Points at the settings template so a screen that has not been moved
    /// over yet still sits on the same ground as one that has.
    static let settingsBackground = SettingsTemplate.pageBackground

    static func pageBackground(for colorScheme: ColorScheme) -> Color {
        Color(uiColor: .systemGroupedBackground)
    }

    static func surface(for colorScheme: ColorScheme) -> Color {
        Color(uiColor: .secondarySystemGroupedBackground)
    }
}

enum DisplayCurrency: String, CaseIterable, Identifiable {
    case usd = "USD"
    case gbp = "GBP"
    case eur = "EUR"
    case cny = "CNY"
    case hkd = "HKD"
    case cad = "CAD"
    case aud = "AUD"
    case sgd = "SGD"
    case jpy = "JPY"

    static let preferenceKey = "catfolio.displayCurrency"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usd: L10n.text("USD · 美元")
        case .gbp: L10n.text("GBP · 英镑")
        case .eur: L10n.text("EUR · 欧元")
        case .cny: L10n.text("CNY · 人民币")
        case .hkd: L10n.text("HKD · 港币")
        case .cad: L10n.text("CAD · 加元")
        case .aud: L10n.text("AUD · 澳元")
        case .sgd: L10n.text("SGD · 新加坡元")
        case .jpy: L10n.text("JPY · 日元")
        }
    }

    static var current: DisplayCurrency {
        let saved = UserDefaults.standard.string(forKey: preferenceKey)
        return saved.flatMap(DisplayCurrency.init(rawValue:)) ?? .usd
    }

    func fromUSD(_ value: Double) -> Double {
        guard let usdPerUnit = LocalPortfolioEngine.usdRate(for: rawValue), usdPerUnit > 0 else {
            return value
        }
        return value / usdPerUnit
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let preferenceKey = "catfolio.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .light: L10n.text("浅色")
        case .dark: L10n.text("深色")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum CompanyNameDisplay: String, CaseIterable, Identifiable {
    case original = "原始名称"
    case chineseShort = "中文简称"

    static let preferenceKey = "catfolio.companyNameDisplay"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: L10n.text("原文简称")
        case .chineseShort: L10n.text("中文简称")
        }
    }

    static var current: CompanyNameDisplay {
        let saved = UserDefaults.standard.string(forKey: preferenceKey)
        return saved.flatMap(CompanyNameDisplay.init(rawValue:)) ?? .original
    }
}

enum CompanyNameCatalog {
    static func displayName(ticker: String, fallback: String, mode: CompanyNameDisplay = .current) -> String {
        let ticker = ticker.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let conciseName = commonNames[ticker] ?? removingLegalSuffixes(fallback)
        guard mode == .chineseShort else { return conciseName.isEmpty ? ticker : conciseName }
        if let name = chineseShortNames[ticker] { return name }

        let suffixes = [".L", ".SW", ".AS", ".DE", ".PA", ".MI", ".HK", ".TO"]
        if let suffix = suffixes.first(where: ticker.hasSuffix) {
            let baseTicker = String(ticker.dropLast(suffix.count))
            if let name = chineseShortNames[baseTicker] { return name }
        }

        return conciseName.isEmpty ? ticker : conciseName
    }

    // Display aliases only: the source name and security identifier remain intact.
    // Match exact listings; stripping arbitrary exchange suffixes can alias another company.
    private static let commonNames: [String: String] = [
        "AAPL": "Apple", "ADBE": "Adobe", "AMD": "AMD", "AMZN": "Amazon",
        "ARM": "Arm", "ASML": "ASML", "AVGO": "Broadcom", "BABA": "Alibaba",
        "BAC": "Bank of America", "BIDU": "Baidu", "BRK-A": "Berkshire Hathaway",
        "BRK-B": "Berkshire Hathaway", "BRK.A": "Berkshire Hathaway", "BRK.B": "Berkshire Hathaway",
        "COST": "Costco", "CSCO": "Cisco", "CVX": "Chevron", "DIS": "Disney",
        "GOOG": "Alphabet", "GOOGL": "Alphabet", "GS": "Goldman Sachs", "IBM": "IBM",
        "INTC": "Intel", "JD": "JD.com", "JNJ": "Johnson & Johnson", "JPM": "JPMorgan Chase",
        "KO": "Coca-Cola", "LLY": "Eli Lilly", "MA": "Mastercard", "MCD": "McDonald’s",
        "META": "Meta", "MS": "Morgan Stanley", "MSFT": "Microsoft", "MU": "Micron",
        "NFLX": "Netflix", "NKE": "Nike", "NVDA": "NVIDIA", "ORCL": "Oracle",
        "PEP": "PepsiCo", "PFE": "Pfizer", "PLTR": "Palantir", "QCOM": "Qualcomm",
        "SBUX": "Starbucks", "TSLA": "Tesla", "TSM": "TSMC", "UBER": "Uber",
        "UNH": "UnitedHealth", "V": "Visa", "WMT": "Walmart", "XOM": "ExxonMobil"
    ]

    private static let legalSuffix = try! NSRegularExpression(
        pattern: #"[\s,]+(?:incorporated|corporation|limited|inc|corp|ltd|plc|co)\.?$"#,
        options: [.caseInsensitive]
    )
    private static let fundDescriptor = try! NSRegularExpression(
        pattern: #"\b(?:ETF|ETN|UCITS|fund|trust)\b"#, options: [.caseInsensitive]
    )

    private static func removingLegalSuffixes(_ source: String) -> String {
        var name = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fund names carry product, share-class and distribution information.
        guard fundDescriptor.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil else { return name }
        while let match = legalSuffix.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range, in: name) {
            let shortened = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shortened.isEmpty else { break }
            name = shortened
        }
        return name
    }

    // Only include established everyday names. An unknown symbol keeps the broker name
    // instead of receiving an unreliable machine-translated corporate name.
    private static let chineseShortNames: [String: String] = [
        "AAPL": "苹果",
        "ABBV": "艾伯维",
        "ADBE": "奥多比",
        "AMD": "超威半导体",
        "AMZN": "亚马逊",
        "ARM": "Arm",
        "ASML": "阿斯麦",
        "ASMLA": "阿斯麦",
        "AVGO": "博通",
        "BABA": "阿里巴巴",
        "BAC": "美国银行",
        "BIDU": "百度",
        "BMO": "蒙特利尔银行",
        "BMY": "百时美施贵宝",
        "BRK-B": "伯克希尔",
        "BRK.B": "伯克希尔",
        "CSCO": "思科",
        "COST": "好市多",
        "CVX": "雪佛龙",
        "DIA": "道琼斯30",
        "DIS": "迪士尼",
        "EQQQ": "纳斯达克100",
        "GLD": "黄金ETF",
        "GOOG": "谷歌",
        "GOOGL": "谷歌",
        "GS": "高盛",
        "IBM": "IBM",
        "INTC": "英特尔",
        "IUSA": "iShares 标普500",
        "IWM": "罗素2000",
        "JD": "京东",
        "JNJ": "强生",
        "JPM": "摩根大通",
        "KO": "可口可乐",
        "LLY": "礼来",
        "LI": "理想汽车",
        "MA": "万事达",
        "MCD": "麦当劳",
        "META": "Meta",
        "MRK": "默沙东",
        "MS": "摩根士丹利",
        "MSFT": "微软",
        "MU": "美光",
        "NFLX": "奈飞",
        "NIO": "蔚来",
        "NKE": "耐克",
        "NTDOY": "任天堂",
        "NVDA": "英伟达",
        "ORCL": "甲骨文",
        "PDD": "拼多多",
        "PEP": "百事",
        "PFE": "辉瑞",
        "PLTR": "帕兰提尔",
        "QCOM": "高通",
        "QQQ": "纳斯达克100",
        "RR": "劳斯莱斯",
        "SBUX": "星巴克",
        "SPY": "SPDR 标普500",
        "TD": "多伦多道明银行",
        "TCEHY": "腾讯",
        "TSLA": "特斯拉",
        "TSM": "台积电",
        "UBER": "优步",
        "UNH": "联合健康",
        "V": "Visa",
        "VEU": "美国以外市场",
        "VHVG": "Vanguard 发达市场",
        "VOO": "Vanguard 标普500",
        "VUSA": "Vanguard 标普500",
        "VUAG": "Vanguard 标普500",
        "VTI": "美国全市场",
        "VWCE": "Vanguard 全球市场",
        "VWRL": "Vanguard 全球市场",
        "VWRP": "Vanguard 全球市场",
        "WMT": "沃尔玛",
        "XPEV": "小鹏汽车"
    ]
}

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
                Text(primaryValue)
                    .appNumber(.callout, weight: .bold)
                    .foregroundStyle(color)
                    .lineLimit(1)

                Text(secondaryValue)
                    .appNumber(.callout, weight: .bold)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("区间 \(dateText)，变化 \(primaryValue)，\(secondaryValue)")
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
    final class ChartDetailGestureRecognizer: UIGestureRecognizer {
        var minimumPressDuration = ChartInteractionStyle.activationDuration
        var allowableMovement = ChartInteractionStyle.preActivationMovementTolerance

        private weak var primaryTouch: UITouch?
        private var trackedTouches: [UITouch] = []
        private var primaryStartLocation = CGPoint.zero
        private var activationWorkItem: DispatchWorkItem?

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
private struct ChartSeriesInteractionMask: ViewModifier {
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

struct ContentCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            }
    }
}

struct StatusNotice: View {
    @Environment(\.locale) private var appLocale
    enum Kind {
        case error
        case success
        case info
    }

    let text: String
    var kind: Kind = .error

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
                .frame(width: 20)

            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            accentColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: CatfolioStyle.controlRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CatfolioStyle.controlRadius, style: .continuous)
                .stroke(accentColor.opacity(0.14), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var accentColor: Color {
        switch kind {
        case .error:
            return CatfolioTheme.warning
        case .success:
            return CatfolioTheme.positive
        case .info:
            return CatfolioTheme.accent
        }
    }

    private var iconName: String {
        switch kind {
        case .error:
            return "exclamationmark.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }
}

extension View {
    func contentCard() -> some View {
        modifier(ContentCard())
    }

    @ViewBuilder
    func catfolioTabBarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

struct GlassChoiceBar: View {
    @Environment(\.locale) private var appLocale
    let choices: [String]
    @Binding var selection: String

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.self) { choice in
                        Button(choice) { selection = choice }
                            .buttonStyle(.glass(glass(for: choice)))
                            .font(.caption.weight(.bold))
                            .accessibilityAddTraits(selection == choice ? .isSelected : [])
                    }
                }
            }
        } else {
            HStack(spacing: 4) {
                ForEach(choices, id: \.self) { choice in
                    Button(choice) { selection = choice }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selection == choice ? CatfolioTheme.accent.opacity(0.18) : .clear, in: Capsule())
                }
            }
            .padding(4)
            .background(.thinMaterial, in: Capsule())
        }
    }

    @available(iOS 26.0, *)
    private func glass(for choice: String) -> Glass {
        selection == choice
            ? .regular.tint(CatfolioTheme.accent.opacity(0.28)).interactive()
            : .regular.interactive()
    }
}

/// A compact chart range selector with a single floating selected capsule.
/// Unselected choices remain plain text so the control does not read as a
/// traditional segmented bar.
private enum ChartTimeRangePickerMetrics {
    static let horizontalInset: CGFloat = 16
    static let itemWidth: CGFloat = 44
    static let itemHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 10
}

/// The single time-window vocabulary used by every chart in the app.
/// The picker presents these eight ranges in five stable slots; tapping an
/// already-selected slot advances to the next value in that slot.
enum ChartTimeRange: String, CaseIterable, Identifiable {
    case oneDay = "1D"
    case oneWeek = "1W"
    case oneMonth = "1M"
    case twoMonths = "2M"
    case yearToDate = "YTD"
    case sixMonths = "6M"
    case oneYear = "1Y"
    case twoYears = "2Y"
    case fiveYears = "5Y"
    case maximum = "MAX"

    var id: String { rawValue }
    var title: String { L10n.label(rawValue) }

    static let choiceGroups: [[ChartTimeRange]] = [
        [.oneWeek, .oneDay],
        [.oneMonth, .twoMonths],
        [.yearToDate, .sixMonths],
        [.oneYear, .twoYears],
        // Paired like every other slot. MAX was the only singleton, so it
        // was the one place a tap did nothing.
        [.maximum, .fiveYears],
    ]

    func includes(
        _ date: Date,
        through lastDate: Date,
        previousTradingDate: Date? = nil,
        calendar: Calendar = financeCalendar
    ) -> Bool {
        let start: Date?
        switch self {
        case .oneDay:
            start = previousTradingDate ?? lastDate
        case .oneWeek:
            start = calendar.date(byAdding: .day, value: -7, to: lastDate)
        case .oneMonth:
            start = calendar.date(byAdding: .month, value: -1, to: lastDate)
        case .twoMonths:
            start = calendar.date(byAdding: .month, value: -2, to: lastDate)
        case .yearToDate:
            start = calendar.date(from: calendar.dateComponents([.year], from: lastDate))
        case .sixMonths:
            start = calendar.date(byAdding: .month, value: -6, to: lastDate)
        case .oneYear:
            start = calendar.date(byAdding: .year, value: -1, to: lastDate)
        case .twoYears:
            start = calendar.date(byAdding: .year, value: -2, to: lastDate)
        case .fiveYears:
            start = calendar.date(byAdding: .year, value: -5, to: lastDate)
        case .maximum:
            start = nil
        }
        return start.map { date >= $0 } ?? true
    }

    static var financeCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

/// A compact Torph-style label transition for the grouped range picker.
/// Characters keep their place-value slot, so unchanged glyphs stay still
/// while changed glyphs travel vertically and cross-fade. The outer picker
/// owns a fixed hit target, leaving this HStack free to animate its intrinsic
/// width when a label changes between values such as `YTD` and `6M`.
private struct ChartTimeRangeMorphingLabel: View {
    @Environment(\.locale) private var appLocale
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var characters: [(offset: Int, element: Character)] {
        Array(text.enumerated())
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(characters, id: \.offset) { item in
                Text(String(item.element))
                    .id("\(item.offset)-\(item.element)")
                    .transition(characterTransition)
            }
        }
        .animation(textAnimation, value: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var characterTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .offset(y: 5).combined(with: .opacity),
            removal: .offset(y: -5).combined(with: .opacity)
        )
    }

    private var textAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.32, dampingFraction: 0.82, blendDuration: 0.06)
    }
}

struct ChartTimeRangePicker: View {
    @Environment(\.locale) private var appLocale
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @Binding var selection: ChartTimeRange
    var isDisabled = false
    var usesBrightSelectedBackground = false
    /// On a tinted field — the gain-sources hero — the strip carries the
    /// field's colour, so the selected range is a white pill with dark text
    /// in both schemes rather than the page's own fill.
    var isOnTintedField = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ChartTimeRange.choiceGroups.indices, id: \.self) { index in
                let group = ChartTimeRange.choiceGroups[index]
                let choice = displayedChoice(in: group)
                let isSelected = group.contains(selection)
                Button {
                    select(group)
                } label: {
                    ChartTimeRangeMorphingLabel(text: choice.title)
                        .appText(.footnote, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(textColor(isSelected: isSelected))
                        .lineLimit(1)
                        .frame(
                            width: ChartTimeRangePickerMetrics.itemWidth,
                            height: ChartTimeRangePickerMetrics.itemHeight
                        )
                        .background {
                            if isSelected {
                                RoundedRectangle(
                                    cornerRadius: ChartTimeRangePickerMetrics.cornerRadius,
                                    style: .continuous
                                )
                                    .fill(selectedBackgroundColor)
                            }
                        }
                        .contentShape(RoundedRectangle(
                            cornerRadius: ChartTimeRangePickerMetrics.cornerRadius,
                            style: .continuous
                        ))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(accessibilityHint(for: group, displayedChoice: choice))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, ChartTimeRangePickerMetrics.horizontalInset)
        .disabled(isDisabled)
        // Fires on the change, so tapping the range already selected stays
        // silent — there is nothing for the tap to confirm.
        .sensoryFeedback(.selection, trigger: selection) { _, _ in hapticsEnabled }
        .opacity(isDisabled ? 0.55 : 1)
    }

    private func displayedChoice(in group: [ChartTimeRange]) -> ChartTimeRange {
        group.first(where: { $0 == selection }) ?? group[0]
    }

    private func select(_ group: [ChartTimeRange]) {
        guard let first = group.first else { return }
        guard let selectedIndex = group.firstIndex(of: selection) else {
            selection = first
            return
        }
        selection = group[(selectedIndex + 1) % group.count]
    }

    private func accessibilityHint(
        for group: [ChartTimeRange],
        displayedChoice: ChartTimeRange
    ) -> String {
        guard group.count > 1,
              let index = group.firstIndex(of: displayedChoice) else { return "" }
        let next = group[(index + 1) % group.count]
        return L10n.text("再次轻点切换到 \(next.title)")
    }

    private func textColor(isSelected: Bool) -> Color {
        if isOnTintedField {
            if isSelected { return Color(red: 0.10, green: 0.10, blue: 0.10) }
            return colorScheme == .dark ? Color.white.opacity(0.82) : Color.black.opacity(0.58)
        }
        if isSelected {
            return colorScheme == .light ? .black : .white
        }
        return .secondary
    }

    private var selectedBackgroundColor: Color {
        if isOnTintedField { return .white }
        if usesBrightSelectedBackground, colorScheme == .light {
            return .white
        }
        return CatfolioTheme.subtleFill
    }
}

/// Geometry-matched loading state for the shared time-range picker. Keeping
/// this beside `ChartTimeRangePicker` prevents each chart screen from
/// inventing a different set of placeholder widths and selected-pill bounds.
struct ChartTimeRangePickerSkeleton: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme

    var itemCount = ChartTimeRange.choiceGroups.count
    var selectedIndex = 1

    private var skeletonColor: Color {
        CatfolioTheme.skeletonFill
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, itemCount), id: \.self) { index in
                ZStack {
                    if index == selectedIndex {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(skeletonColor.opacity(1.18))
                            .frame(width: 44, height: 30)
                    }

                    Capsule()
                        .fill(skeletonColor)
                        .frame(width: index == itemCount - 1 ? 23 : 14, height: 9)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct GlassPrimaryButton: View {
    @Environment(\.locale) private var appLocale
    let title: String
    var systemImage: String? = nil
    /// Not ready to be tapped — an incomplete form, say. Renders as a plain
    /// disabled button.
    var isDisabled = false
    /// Work actually in flight. Renders the spinner.
    ///
    /// Separate from `isDisabled` because a form that is merely incomplete is
    /// not loading anything: every connector screen passed its "nickname is
    /// empty" check here and so showed a permanent spinner before the user had
    /// typed a thing, which reads as a hang.
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                button
                    .buttonStyle(.glassProminent)
            } else {
                button
                    .buttonStyle(.borderedProminent)
            }
        }
        .disabled(isDisabled || isBusy)
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .font(.body.weight(.semibold))
        .controlSize(.large)
        .tint(CatfolioTheme.accent)
    }
}

/// Presentation rules use image geometry and its canvas, not ticker-specific
/// guesses about which companies have wordmarks. Run once when decoding.
struct AssetLogoLayout: Equatable {
    let insetFraction: CGFloat
    let usesWhiteCanvas: Bool
    var usesDarkCanvas: Bool = false

    static func resolve(_ image: UIImage) -> Self {
        let ratio = image.size.width / max(1, image.size.height)
        let isSquare = (0.9...1.1).contains(ratio)
        guard let cgImage = image.cgImage else {
            return Self(insetFraction: isSquare ? 0 : 0.08, usesWhiteCanvas: !isSquare)
        }
        let edge = 32
        var pixels = [UInt8](repeating: 0, count: edge * edge * 4)
        guard let context = CGContext(data: &pixels, width: edge, height: edge,
            bitsPerComponent: 8, bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Self(insetFraction: 0.08, usesWhiteCanvas: true)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        let corners = [(0, 0), (31, 0), (0, 31), (31, 31)]
        let transparentCanvas = corners.allSatisfy { pixels[($0.1 * edge + $0.0) * 4 + 3] < 24 }
        func isCanvas(_ x: Int, _ y: Int) -> Bool {
            let i = (y * edge + x) * 4
            // Transparent or near-white padding. Dark/coloured square tiles
            // retain their complete background and original optical size.
            return pixels[i + 3] < 24 || (!transparentCanvas && pixels[i + 3] > 240
                && pixels[i] > 240 && pixels[i + 1] > 240 && pixels[i + 2] > 240)
        }
        let hasNeutralCorners = corners.allSatisfy { isCanvas($0.0, $0.1) }
        guard hasNeutralCorners || !isSquare else {
            return Self(insetFraction: 0, usesWhiteCanvas: false)
        }
        // Do not double-pad assets that already include a generous safe area.
        // The scan measures padding only; it never crops or deforms artwork.
        let occupiedEdge = (0..<edge).contains { position in
            (0..<3).contains { margin in
                !isCanvas(margin, position) || !isCanvas(edge - 1 - margin, position)
                    || !isCanvas(position, margin) || !isCanvas(position, edge - 1 - margin)
            }
        }
        // White artwork on transparency needs a dark backing in either app
        // theme. Count only opaque ink so antialiased edges cannot dominate.
        var opaqueInk = 0, lightInk = 0
        if transparentCanvas {
            for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 240 {
                opaqueInk += 1
                if min(pixels[i], pixels[i + 1], pixels[i + 2]) > 210 { lightInk += 1 }
            }
        }
        let needsDarkCanvas = opaqueInk > 0 && Double(lightInk) / Double(opaqueInk) > 0.8
        return Self(insetFraction: occupiedEdge ? 0.08 : 0,
                    usesWhiteCanvas: !needsDarkCanvas, usesDarkCanvas: needsDarkCanvas)
    }
}

struct AssetLogoArtwork: View {
    let image: UIImage
    let layout: AssetLogoLayout
    let size: CGFloat

    var body: some View {
        ZStack {
            if layout.usesDarkCanvas { Color(white: 0.12) }
            else if layout.usesWhiteCanvas { Color.white }
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(size * layout.insetFraction)
        }
        .frame(width: size, height: size)
    }
}

private final class AssetLogoImageCache: @unchecked Sendable {
    static let shared = AssetLogoImageCache()

    private let images = NSCache<NSURL, Entry>()

    private final class Entry {
        let image: UIImage
        let layout: AssetLogoLayout
        init(_ image: UIImage) {
            self.image = image
            self.layout = AssetLogoLayout.resolve(image)
        }
    }

    private init() {
        // Asset logos are bundled at 96 px and decoded only when visible.
        // Keeping roughly two long scrolling screens avoids churn without
        // allowing the full logo library to become resident at once.
        images.countLimit = 120
        images.totalCostLimit = 6 * 1_024 * 1_024
    }

    func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)?.image
    }

    func insert(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        images.setObject(Entry(image), forKey: url as NSURL, cost: cost)
    }

    func layout(for url: URL) -> AssetLogoLayout? {
        images.object(forKey: url as NSURL)?.layout
    }
}

private actor AssetLogoRepository {
    struct DecodedImage: @unchecked Sendable {
        let value: UIImage
    }

    static let shared = AssetLogoRepository()

    private let session: URLSession
    private var requests: [URL: Task<Data, Error>] = [:]

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1_024 * 1_024,
            diskCapacity: 32 * 1_024 * 1_024
        )
        session = URLSession(configuration: configuration)
    }

    func data(for url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        if let request = requests[url] {
            return try await request.value
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 15
        let session = session
        let request = Task<Data, Error> {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return data
        }
        requests[url] = request
        defer { requests[url] = nil }
        return try await request.value
    }

    func image(for url: URL) async throws -> DecodedImage {
        if let cached = AssetLogoImageCache.shared.image(for: url) {
            return DecodedImage(value: cached)
        }
        let data = try await data(for: url)
        if let cached = AssetLogoImageCache.shared.image(for: url) {
            return DecodedImage(value: cached)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 96,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else {
            throw URLError(.cannotDecodeContentData)
        }
        let image = UIImage(cgImage: cgImage)
        AssetLogoImageCache.shared.insert(image, for: url)
        return DecodedImage(value: image)
    }
}

private struct AssetLogoResolvedKey: EnvironmentKey {
    static let defaultValue: (URL) -> Void = { _ in }
}

extension EnvironmentValues {
    /// A snapshot owner can redraw when a visible logo replaces its fallback.
    var assetLogoDidResolve: (URL) -> Void {
        get { self[AssetLogoResolvedKey.self] }
        set { self[AssetLogoResolvedKey.self] = newValue }
    }
}

struct AssetLogo: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.assetLogoDidResolve) private var didResolve
    let ticker: String
    let logoSymbol: String?
    var size: CGFloat = 28
    var onBrandColorResolved: ((Color) -> Void)? = nil
    @State private var loadedImage: UIImage?
    @State private var loadedLayout: AssetLogoLayout?

    var body: some View {
        Group {
            if let image = displayedImage {
                AssetLogoArtwork(image: image,
                    layout: loadedLayout ?? logoURL.flatMap { AssetLogoImageCache.shared.layout(for: $0) }
                        ?? AssetLogoLayout.resolve(image),
                    size: size)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: size * 2 / 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 2 / 7, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: size * 2 / 7, style: .continuous))
        .accessibilityHidden(true)
        .task(id: logoURL) {
            // SwiftUI may reuse this view when a ranked chart slot changes
            // ticker. Clear the old decoded image before resolving the new URL.
            loadedImage = nil
            loadedLayout = nil
            await loadLogo()
        }
    }

    private var displayedImage: UIImage? {
        loadedImage ?? logoURL.flatMap { AssetLogoImageCache.shared.image(for: $0) }
    }

    @MainActor
    private func loadLogo() async {
        guard loadedImage == nil, let logoURL else {
            onBrandColorResolved?(AssetBrandColor.fallback(for: logoSymbol ?? ticker))
            return
        }
        if let cached = AssetLogoImageCache.shared.image(for: logoURL) {
            loadedLayout = AssetLogoImageCache.shared.layout(for: logoURL) ?? AssetLogoLayout.resolve(cached)
            loadedImage = cached
            didResolve(logoURL)
            onBrandColorResolved?(AssetBrandColor.resolved(from: cached, fallbackKey: logoSymbol ?? ticker))
            return
        }
        guard let decoded = try? await AssetLogoRepository.shared.image(for: logoURL),
              !Task.isCancelled else {
            onBrandColorResolved?(AssetBrandColor.fallback(for: logoSymbol ?? ticker))
            return
        }
        loadedLayout = AssetLogoImageCache.shared.layout(for: logoURL) ?? AssetLogoLayout.resolve(decoded.value)
        loadedImage = decoded.value
        didResolve(logoURL)
        onBrandColorResolved?(AssetBrandColor.resolved(from: decoded.value, fallbackKey: logoSymbol ?? ticker))
    }

    private var fallback: some View {
        ZStack {
            fallbackColor
            Text(String(ticker.prefix(1)).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private var fallbackColor: Color {
        AssetBrandColor.fallback(for: logoSymbol ?? ticker)
    }

    private var logoURL: URL? {
        let symbol = (logoSymbol ?? ticker).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty, symbol != "ETF 其他" else { return nil }
        if let bundled = Bundle.main.url(
            forResource: symbol.uppercased(),
            withExtension: "png",
            subdirectory: "AssetLogos"
        ) {
            return bundled
        }
        return URL(string: "https://financialmodelingprep.com")?
            .appendingPathComponent("image-stock")
            .appendingPathComponent("\(symbol).png")
    }
}

/// Resolves a usable brand accent from the actual logo while ignoring the
/// transparent/white canvas common in market-data logo assets.
enum AssetBrandColor {
    private struct Bucket {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weight = 0.0
    }

    static func resolved(from image: UIImage, fallbackKey: String) -> Color {
        guard let color = dominantColor(from: image) else {
            return fallback(for: fallbackKey)
        }
        return Color(uiColor: vivid(color))
    }

    static func fallback(for key: String) -> Color {
        let normalized = key.uppercased()

        if normalized.contains("NVDA") { return Color(red: 0.45, green: 0.72, blue: 0.10) }
        if normalized.contains("VUSA") || normalized.contains("VUAG") || normalized.contains("VTI") {
            return Color(red: 0.67, green: 0.08, blue: 0.12)
        }
        if normalized.contains("DWS") || normalized.contains("XS2D") {
            return Color(red: 0.05, green: 0.58, blue: 0.66)
        }
        if normalized.contains("QQQ") || normalized.contains("EQGB") || normalized.contains("OKTA") {
            return Color(red: 0.12, green: 0.37, blue: 0.90)
        }

        let colors = [
            Color(red: 0.26, green: 0.47, blue: 0.96),
            Color(red: 0.20, green: 0.62, blue: 0.36),
            Color(red: 0.92, green: 0.47, blue: 0.16),
            Color(red: 0.55, green: 0.36, blue: 0.86),
            Color(red: 0.12, green: 0.60, blue: 0.62),
            Color(red: 0.82, green: 0.32, blue: 0.56),
            Color(red: 0.34, green: 0.37, blue: 0.78),
            Color(red: 0.62, green: 0.43, blue: 0.28),
        ]
        let hash = normalized.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1.value)) &* 1_099_511_628_211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }

    private static func vivid(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else { return color }

        return UIColor(
            hue: hue,
            saturation: min(max(saturation, 0.58), 0.92),
            brightness: min(max(brightness, 0.72), 0.94),
            alpha: 1
        )
    }

    private static func dominantColor(from image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        let width = 24
        let height = 24
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var buckets = Array(repeating: Bucket(), count: 18)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.18 else { continue }

            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            let saturation = maximum == 0 ? 0 : delta / maximum

            // White/grey image canvases are not brand colours. Very dark marks
            // fall back to a stable accessible accent instead of muddying glass.
            guard saturation > 0.18, maximum > 0.12 else { continue }

            let hue: Double
            if delta == 0 {
                hue = 0
            } else if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
            } else if maximum == green {
                hue = (((blue - red) / delta) + 2) / 6
            } else {
                hue = (((red - green) / delta) + 4) / 6
            }
            let normalizedHue = hue < 0 ? hue + 1 : hue
            let index = min(Int(normalizedHue * Double(buckets.count)), buckets.count - 1)
            let weight = saturation * saturation * (0.35 + min(maximum, 0.9)) * alpha
            buckets[index].red += red * weight
            buckets[index].green += green * weight
            buckets[index].blue += blue * weight
            buckets[index].weight += weight
        }

        guard let winner = buckets.max(by: { $0.weight < $1.weight }), winner.weight > 0.10 else {
            return nil
        }
        return UIColor(
            red: winner.red / winner.weight,
            green: winner.green / winner.weight,
            blue: winner.blue / winner.weight,
            alpha: 1
        )
    }
}

/// Cached, fully-configured currency formatters.
///
/// `NumberFormatter` costs far more to allocate and configure than to run, and
/// `DisplayFormat.money` is called once per figure in every holding row, so a
/// single list re-render was building dozens of them. Formatters are keyed by
/// their configuration and never mutated after being published, which is the
/// documented-safe way to share one across threads.
///
/// The date side already avoids this cost (see `DayDateCodec` in Models.swift);
/// this is the currency equivalent.
private enum CurrencyFormatterCache {
    private struct Key: Hashable {
        let currencyCode: String
        let minimumFractionDigits: Int
        let maximumFractionDigits: Int
    }

    private static let lock = NSLock()
    private static var formatters: [Key: NumberFormatter] = [:]

    static func formatter(
        currencyCode: String,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int
    ) -> NumberFormatter {
        let key = Key(
            currencyCode: currencyCode,
            minimumFractionDigits: minimumFractionDigits,
            maximumFractionDigits: maximumFractionDigits
        )
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        if currencyCode == "USD" {
            formatter.currencySymbol = "$"
        }
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        formatters[key] = formatter
        return formatter
    }

    /// The currency symbol alone, for callers that render the number themselves.
    static func symbol(for currencyCode: String) -> String {
        formatter(currencyCode: currencyCode, minimumFractionDigits: 0, maximumFractionDigits: 2)
            .currencySymbol ?? "\(currencyCode) "
    }
}

enum DisplayFormat {
    static func shares(_ value: Double) -> String {
        value.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(0...4))
        )
    }

    static func money(
        _ value: Double,
        currency: String? = nil,
        signed: Bool = false,
        fractionDigits: Int? = nil
    ) -> String {
        guard value.isFinite else { return "—" }
        let targetCurrency: String
        let adjusted: Double
        if let currency {
            let normalizedCurrency = currency.uppercased()
            targetCurrency = normalizedCurrency == "GBX" ? "GBP" : normalizedCurrency
            adjusted = normalizedCurrency == "GBX" ? value / 100 : value
        } else {
            let displayCurrency = DisplayCurrency.current
            targetCurrency = displayCurrency.rawValue
            adjusted = displayCurrency.fromUSD(value)
        }

        // Apply the display threshold after currency/GBX conversion, including
        // callers that otherwise request fixed cents for headlines and holdings.
        let displayedFractionDigits = abs(adjusted) > 1_000_000 ? 0 : fractionDigits
        let formatter = CurrencyFormatterCache.formatter(
            currencyCode: targetCurrency,
            minimumFractionDigits: displayedFractionDigits ?? 0,
            maximumFractionDigits: displayedFractionDigits ?? (abs(adjusted) >= 1_000 ? 0 : 2)
        )
        let text = formatter.string(from: NSNumber(value: abs(adjusted))) ?? "\(adjusted)"
        guard signed else { return text }
        return "\(adjusted >= 0 ? "+" : "-")\(text)"
    }

    /// How many digits an abbreviated figure keeps.
    enum CompactPrecision {
        /// Whole units. Axis labels, where a decimal point is noise.
        case whole
        /// Up to one decimal. The default for a figure read at a glance.
        case tenth
        /// Three significant digits, which is what a statement line needs:
        /// 1.23万 / 12.3亿 / 3910亿, or 1.23M / 12.3B / 391B. A fixed two
        /// decimals would print 3910.35亿, which is six digits of precision
        /// nobody asked for.
        case statement
    }

    /// The one magnitude ladder. Everything abbreviated in this app comes
    /// through here; nothing else divides by a million.
    ///
    /// The suffix follows the language: 万, 亿 and 万亿 under zh-Hans, K/M/B/T
    /// under English. That is one convention, not two — the app had a
    /// hand-rolled K/M/B/T table on some screens and `.compactName` on others,
    /// and they disagreed in Chinese.
    ///
    /// The locale is passed explicitly. `formatted()` would otherwise follow
    /// `Locale.current`, which tracks the device; the language preference here
    /// lives in `AppLanguage` and does not set `AppleLanguages`, so a person
    /// reading the app in Chinese on an English phone would still be shown K
    /// and M.
    static func compact(
        _ value: Double,
        precision: CompactPrecision = .tenth
    ) -> String {
        guard value.isFinite else { return "—" }
        let locale = Locale(identifier: AppLanguage.currentIdentifier)
        let compact: String
        switch precision {
        case .whole:
            compact = value.formatted(
                .number.notation(.compactName).precision(.fractionLength(0...0)).locale(locale))
        case .tenth:
            compact = value.formatted(
                .number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
        case .statement:
            compact = value.formatted(
                .number.notation(.compactName).precision(.significantDigits(3)).locale(locale))
        }
        // Below the first step there is nothing to abbreviate, and compact
        // notation drops the thousands separator while it is at it — 1500
        // rather than 1,500, which looks wrong beside a 1.23亿 on the same
        // axis. Detected by the absence of a suffix rather than by comparing
        // against a threshold, because where that threshold falls is the
        // locale's business (10,000 in Chinese, 1,000 in English).
        if !compact.contains(where: { $0.isLetter || ($0.unicodeScalars.first?.value ?? 0) > 0x2E80 }) {
            return value.formatted(.number.precision(.fractionLength(0...0)).locale(locale))
        }
        return compact
    }

    /// An abbreviated amount carrying its currency symbol.
    static func compactMoney(
        _ value: Double,
        currency: String? = nil,
        precision: CompactPrecision = .tenth
    ) -> String {
        guard value.isFinite else { return "—" }
        let targetCurrency: String
        let adjusted: Double
        if let currency {
            targetCurrency = currency.uppercased()
            adjusted = value
        } else {
            let displayCurrency = DisplayCurrency.current
            targetCurrency = displayCurrency.rawValue
            adjusted = displayCurrency.fromUSD(value)
        }
        var symbol = CurrencyFormatterCache.symbol(for: targetCurrency)
        // A currency with no glyph prints its code, and a code run straight
        // into a digit reads as one token: "SEK1.00T". money() spaces these,
        // so this does too.
        if let last = symbol.last, last.isLetter { symbol += "\u{00A0}" }
        let body = compact(abs(adjusted), precision: precision)
        // The sign leads the whole amount. The statement formatter this
        // replaced put it after the symbol — "$-1.50K" — which reads as a
        // negative quantity of dollars rather than a negative amount.
        return "\(adjusted < 0 ? "-" : "")\(symbol)\(body)"
    }

    static func percent(_ value: Double, signed: Bool = true) -> String {
        "\(signed && value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    static func ratioPercent(_ value: Double?) -> String {
        guard let value else { return "暂无" }
        return percent(value * 100)
    }
}

struct ContributionStripePattern: View {
    @Environment(\.locale) private var appLocale
    let color: Color

    var body: some View {
        Canvas { context, size in
            var stripes = Path()
            // Match the exported Figma stripe asset: 13pt strokes on a
            // 35.5pt cadence. The previous 18pt bands covered almost half of
            // each bar and made the whole gradient read much darker.
            let bandWidth: CGFloat = 13
            let spacing: CGFloat = 35.5
            // Start and end every diagonal band outside the rendered bounds.
            // If a stroke begins at y = 0 its cap remains visible just inside
            // the rounded mask, which reads as a short line head at the top.
            let overscan = bandWidth * 2
            var x = -size.height - overscan
            while x < size.width + size.height {
                stripes.move(to: CGPoint(x: x - overscan, y: -overscan))
                stripes.addLine(to: CGPoint(
                    x: x + size.height + overscan,
                    y: size.height + overscan
                ))
                x += spacing
            }
            context.stroke(stripes, with: .color(color), lineWidth: bandWidth)
        }
        .allowsHitTesting(false)
    }
}

/// A card's surface drawn by the app rather than by Liquid Glass.
///
/// On an iPhone with an HDR screen the system glass lights its rim and body
/// above normal white, so every glass card glowed brighter than the page and
/// its shadow read as heavy against it; the simulator and screenshots, being
/// standard range, never show it. There is no public switch to hold the glass
/// to standard range, so cards draw the parts of it they used — a pale body,
/// a lit top edge and a short shadow — in ordinary colours.
struct CardSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S

    private var isDark: Bool { colorScheme == .dark }

    func body(content: Content) -> some View {
        content.background {
            shape
                .fill(Color.white.opacity(isDark ? 0.06 : 0.55))
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: isDark
                                ? [.white.opacity(0.16), .white.opacity(0.04)]
                                : [.white.opacity(0.95), .white.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(isDark ? 0.3 : 0.05), radius: 10, y: 3)
        }
    }
}

extension View {
    func cardSurface<S: InsettableShape>(in shape: S) -> some View {
        modifier(CardSurface(shape: shape))
    }
}
