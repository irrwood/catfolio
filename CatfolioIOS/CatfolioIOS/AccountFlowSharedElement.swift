import SwiftUI
import UIKit

/// Keeps matching, stationary header pieces above the native page slide. The
/// navigation controller still owns the back button and interactive pop.
struct AccountFlowSharedElement<Content: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    let id: String
    var animatesContentChanges = false
    @ViewBuilder let content: Content

    func makeUIViewController(context: Context) -> AccountFlowSharedElementController {
        let controller = AccountFlowSharedElementController(rootView: AnyView(content.environment(\.self, environment)))
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: AccountFlowSharedElementController, context: Context) {
        controller.elementID = id
        controller.animatesContentChanges = animatesContentChanges
        controller.reduceMotion = environment.accessibilityReduceMotion
        controller.rootView = AnyView(content.environment(\.self, environment))
        controller.view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: AccountFlowSharedElementController,
                     context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(width: proposal.width ?? 560,
                                               height: proposal.height ?? UIView.layoutFittingExpandedSize.height))
    }
}

final class AccountFlowSharedElementController: UIHostingController<AnyView> {
    var elementID = ""
    var reduceMotion = false
    var animatesContentChanges = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        coordinateSharedElements()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        coordinateSharedElements()
    }

    private func coordinateSharedElements() {
        guard !reduceMotion, let transitionCoordinator, transitionCoordinator.isAnimated else { return }
        var overlay: AccountFlowSharedOverlay?
        var contentOverlay: AccountFlowContentTransitionOverlay?
        transitionCoordinator.animate(alongsideTransition: { context in
            // Each header piece receives appearance callbacks. Only one owns
            // the overlay, and it is removed on either finish or cancellation.
            guard !context.containerView.subviews.contains(where: {
                $0 is AccountFlowSharedOverlay || $0 is AccountFlowContentTransitionOverlay
            }),
                  let from = context.viewController(forKey: .from),
                  let to = context.viewController(forKey: .to) else { return }
            UIView.performWithoutAnimation {
                to.view.layoutIfNeeded()
                let shared = AccountFlowSharedOverlay(from: from, to: to, container: context.containerView)
                if let content = AccountFlowContentTransitionOverlay(from: from, to: to,
                    container: context.containerView, shared: shared) {
                    contentOverlay = content
                } else if !shared.elements.isEmpty {
                    context.containerView.addSubview(shared)
                    shared.hideOriginals()
                    overlay = shared
                }
            }
            contentOverlay?.animateContent()
            (contentOverlay?.shared ?? overlay)?.animateContentChanges()
        }, completion: { _ in
            contentOverlay?.restore()
            contentOverlay?.removeFromSuperview()
            overlay?.restore()
            overlay?.removeFromSuperview()
        })
    }
}

final class AccountFlowSharedOverlay: UIView {
    private(set) var elements: [(UIView, CGFloat)] = []
    private var changingContent: [(UIView & UIContentView, AnyView)] = []

    init(from: UIViewController, to: UIViewController, container: UIView) {
        super.init(frame: container.bounds)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        let destinations = Self.elements(in: to)
        for source in Self.elements(in: from) {
            guard let destination = destinations.first(where: { $0.elementID == source.elementID }),
                  !source.reduceMotion, !destination.reduceMotion else { continue }
            let start = source.view.convert(source.view.bounds, to: from.view)
            let end = destination.view.convert(destination.view.bounds, to: to.view)
            // Scrolled-away headers and changed text layouts use the ordinary
            // slide, avoiding a jump or a snapshot over unrelated content.
            guard start.width > 0, start.height > 0,
                  abs(start.minX - end.minX) < 1, abs(start.minY - end.minY) < 1,
                  abs(start.width - end.width) < 1, abs(start.height - end.height) < 1,
                  from.view.bounds.contains(start), to.view.bounds.contains(end) else { continue }
            let snapshot: UIView
            if source.animatesContentChanges && destination.animatesContentChanges {
                // Keep one live native button in place. Its stable SwiftUI
                // identity lets Text use contentTransition when the title changes.
                let host = UIHostingConfiguration { source.rootView }
                    .margins(.all, 0).makeContentView()
                host.backgroundColor = .clear
                snapshot = host
                changingContent.append((host, destination.rootView))
            } else {
                guard let captured = source.view.snapshotView(afterScreenUpdates: false) else { continue }
                snapshot = captured
            }
            var frame = from.view.convert(start, to: container)
            // UIKit has already applied the native slide's destination x to
            // its model layer; use the untransformed page coordinates instead.
            frame.origin.x = start.minX
            snapshot.frame = frame
            snapshot.accessibilityIdentifier = "account-shared.\(source.elementID)"
            addSubview(snapshot)
            snapshot.layoutIfNeeded()
            for view in [source.view!, destination.view!] {
                elements.append((view, view.alpha))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func animateContentChanges() {
        for (host, destination) in changingContent {
            withAnimation(.smooth(duration: 0.25)) {
                host.configuration = UIHostingConfiguration { destination }.margins(.all, 0)
            }
        }
    }

    func hideOriginals() {
        // Snapshot capture may flush a render transaction. Never hide the live
        // header until its replacement is already in the visible hierarchy.
        guard superview != nil else { return }
        for (view, _) in elements { view.alpha = 0 }
    }

    func restore() {
        UIView.performWithoutAnimation {
            for (view, alpha) in elements { view.alpha = alpha }
        }
        elements.removeAll()
        for (host, _) in changingContent {
            host.removeFromSuperview()
        }
        changingContent.removeAll()
    }

    private static func elements(in controller: UIViewController) -> [AccountFlowSharedElementController] {
        if let element = controller as? AccountFlowSharedElementController { return [element] }
        return controller.children.flatMap { elements(in: $0) }
    }
}
