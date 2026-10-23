import SwiftUI
import UIKit

/// An independently rendered backdrop lets the transition capture foreground
/// content without baking a moving page surface into it.
struct AccountFlowBackdrop: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    let theme: AccountFlowTheme
    let isPreparation: Bool
    let sharedBackground: Bool

    func makeUIViewController(context: Context) -> AccountFlowBackdropController {
        let controller = AccountFlowBackdropController(rootView: AnyView(Color.clear))
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: AccountFlowBackdropController, context: Context) {
        controller.style = .init(accent: theme.accent, isPreparation: isPreparation,
                                 colorScheme: environment.colorScheme)
        controller.rootView = AnyView(AccountConnectionBackground(theme: theme, isPreparation: isPreparation)
            .environment(\.self, environment))
        controller.view.alpha = sharedBackground ? 0 : 1
    }
}

final class AccountFlowBackdropController: UIHostingController<AnyView> {
    struct Style: Equatable {
        let accent: Color
        let isPreparation: Bool
        let colorScheme: ColorScheme
    }
    var style: Style?

    static func find(in controller: UIViewController) -> AccountFlowBackdropController? {
        if let backdrop = controller as? AccountFlowBackdropController { return backdrop }
        for child in controller.children {
            if let backdrop = find(in: child) { return backdrop }
        }
        return nil
    }
}

/// UIKit still drives navigation and interactive cancellation. Transparent
/// foreground snapshots move above one opaque canvas; native surfaces stay hidden.
final class AccountFlowContentTransitionOverlay: UIView {
    let outgoing = UIView()
    let incoming = UIView()
    let shared: AccountFlowSharedOverlay
    private let pages: [(UIView, CGFloat)]
    private let direction: CGFloat
    private var initialCover: UIImageView?
    private var displayLink: CADisplayLink?
    private var presentedFrames = 0

    init?(from: UIViewController, to: UIViewController, container: UIView, shared: AccountFlowSharedOverlay) {
        guard let source = AccountFlowBackdropController.find(in: from),
              let destination = AccountFlowBackdropController.find(in: to),
              source.style != nil, source.style == destination.style,
              let sourceContent = AccountFlowForegroundController.find(in: from),
              let destinationContent = AccountFlowForegroundController.find(in: to),
              let initialContent = Self.visibleCover(in: container) else { return nil }
        // Render the pure SwiftUI backdrop offscreen. Making a hidden first-run
        // backdrop visible to snapshot it can commit a moving native surface.
        let renderer = ImageRenderer(content: source.rootView.frame(width: container.bounds.width,
                                                                   height: container.bounds.height))
        renderer.scale = container.window?.screen.scale ?? source.traitCollection.displayScale
        guard let backgroundImage = renderer.uiImage else { return nil }
        let background = UIImageView(image: backgroundImage)
        self.shared = shared
        initialCover = initialContent
        pages = [(from.view, from.view.alpha), (to.view, to.view.alpha)]
        let navigation = to.navigationController ?? from.navigationController
        let isPush = navigation?.viewControllers.contains(where: { $0 === from }) == true
        let layoutDirection: CGFloat = container.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        direction = (isPush ? 1 : -1) * layoutDirection
        super.init(frame: container.bounds)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true

        func restingFrame(_ view: UIView, page: UIView) -> CGRect {
            let local = view.convert(view.bounds, to: page)
            var frame = page.convert(local, to: container)
            frame.origin.x = local.minX
            return frame
        }
        let outgoingFrame = restingFrame(sourceContent.view, page: from.view)
        let incomingFrame = restingFrame(destinationContent.view, page: to.view)
        background.frame = bounds
        addSubview(background)
        initialContent.frame = bounds
        addSubview(initialContent)
        // Keep the complete source frame visible while updated snapshots render.
        // afterScreenUpdates can commit intermediate header/background changes;
        // mounting the canvas first prevents those changes reaching the screen.
        container.addSubview(self)
        shared.isHidden = true
        addSubview(shared)
        shared.hideOriginals()
        guard let outgoingSnapshot = sourceContent.view.snapshotView(afterScreenUpdates: true),
              let incomingSnapshot = destinationContent.view.snapshotView(afterScreenUpdates: true) else {
            shared.restore()
            shared.isHidden = false
            removeFromSuperview()
            return nil
        }
        addSubview(outgoing)
        addSubview(incoming)
        outgoing.autoresizingMask = []
        incoming.autoresizingMask = []
        outgoing.frame = outgoingFrame
        incoming.frame = incomingFrame
        for (snapshot, foreground) in [(outgoingSnapshot, outgoing), (incomingSnapshot, incoming)] {
            snapshot.frame = foreground.bounds
            foreground.addSubview(snapshot)
        }
        incoming.transform = CGAffineTransform(translationX: direction * bounds.width, y: 0)
        bringSubviewToFront(shared)
        shared.isHidden = false
        for (page, _) in pages { page.alpha = 0 }
        bringSubviewToFront(initialContent)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func animateContent() {
        outgoing.transform = CGAffineTransform(translationX: -direction * bounds.width, y: 0)
        incoming.transform = .identity
        // Deferred UIKit snapshot views need one presented frame before they
        // contain pixels. Keep the already-rendered source image above them
        // until that first presentation, including on high-refresh-rate screens.
        let link = CADisplayLink(target: self, selector: #selector(didPresentFrame))
        displayLink = link
        link.add(to: .main, forMode: .common)
        // A scene can throttle display callbacks while navigation is active.
        // Do not let the protective frame obscure the rest of the slide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.releaseCover()
        }
    }

    @objc private func didPresentFrame() {
        presentedFrames += 1
        guard presentedFrames >= 2 else { return }
        releaseCover()
    }

    private func releaseCover() {
        displayLink?.invalidate()
        displayLink = nil
        initialCover?.removeFromSuperview()
        initialCover = nil
    }

    private static func visibleCover(in container: UIView) -> UIImageView? {
        guard let window = container.window, !container.bounds.isEmpty else { return nil }
        let origin = container.convert(container.bounds.origin, to: window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = container.traitCollection.displayScale
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: container.bounds.size, format: format).image { context in
            context.cgContext.translateBy(x: -origin.x, y: -origin.y)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return UIImageView(image: image)
    }

    func restore() {
        UIView.performWithoutAnimation {
            for (page, alpha) in pages { page.alpha = alpha }
            shared.restore()
            releaseCover()
        }
    }
}

/// A dedicated SwiftUI rendering host can be captured independently of the
/// native navigation surface. Inputs keep their original controller and state.
struct AccountFlowForeground<Content: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    @ViewBuilder let content: Content

    func makeUIViewController(context: Context) -> AccountFlowForegroundController {
        let controller = AccountFlowForegroundController(rootView: AnyView(content.environment(\.self, environment)))
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: AccountFlowForegroundController, context: Context) {
        controller.rootView = AnyView(content.environment(\.self, environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: AccountFlowForegroundController,
                     context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(width: proposal.width ?? 560,
                                               height: proposal.height ?? UIView.layoutFittingExpandedSize.height))
    }
}

final class AccountFlowForegroundController: UIHostingController<AnyView> {
    static func find(in controller: UIViewController) -> AccountFlowForegroundController? {
        if let foreground = controller as? AccountFlowForegroundController { return foreground }
        for child in controller.children {
            if let foreground = find(in: child) { return foreground }
        }
        return nil
    }
}
