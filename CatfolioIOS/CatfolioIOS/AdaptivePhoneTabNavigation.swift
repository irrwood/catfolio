import SwiftUI
import UIKit

/// Duo's expanded window uses the same workspace as iPad. The compact
/// window keeps the phone tabs; neither hierarchy is rebuilt by a fold.
struct AdaptivePhoneWorkspace<Phone: View, Workspace: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewBuilder let phone: Phone
    @ViewBuilder let workspace: Workspace

    var body: some View {
        RetainedPhoneWorkspace(showWorkspace: AdaptivePhoneTabNavigation.prefersWorkspace(
            horizontal: horizontalSizeClass, vertical: verticalSizeClass),
            phone: phone, workspace: workspace)
    }
}

enum AdaptivePhoneTabNavigation {
    static func prefersWorkspace(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Bool {
        horizontal == .regular && vertical == .regular
    }

    /// Existing scroll-tucking belongs only to a horizontal bottom bar.
    /// A sidebar, top bar or Duo's vertical bar must remain system-managed.
    static func isBottomBar(_ frame: CGRect, in bounds: CGRect) -> Bool {
        frame.width > frame.height && frame.height > 0 && frame.minY >= bounds.midY
    }
}

/// Cache the hosting controllers, detaching the inactive one so its controls,
/// gestures and appearance tasks are not running underneath the active UI.
private struct RetainedPhoneWorkspace<Phone: View, Workspace: View>: UIViewControllerRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    let showWorkspace: Bool
    let phone: Phone
    let workspace: Workspace

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(showWorkspace: showWorkspace,
            phone: AnyView(phone.environment(\.self, context.environment).environment(\.scenePhase, scenePhase)),
            workspace: AnyView(workspace.environment(\.self, context.environment).environment(\.scenePhase, scenePhase)))
    }

    final class Controller: UIViewController {
        private var phoneHost: UIHostingController<AnyView>?
        private var workspaceHost: UIHostingController<AnyView>?
        private var activeHost: UIHostingController<AnyView>?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
        }

        func update(showWorkspace: Bool, phone: AnyView, workspace: AnyView) {
            phoneHost?.rootView = phone
            workspaceHost?.rootView = workspace
            if showWorkspace, workspaceHost == nil { workspaceHost = makeHost(workspace) }
            if !showWorkspace, phoneHost == nil { phoneHost = makeHost(phone) }
            guard let next = showWorkspace ? workspaceHost : phoneHost, next !== activeHost else { return }
            let visible = isViewLoaded && view.window != nil
            if let previous = activeHost {
                if visible { previous.beginAppearanceTransition(false, animated: false) }
                previous.willMove(toParent: nil)
                previous.view.removeFromSuperview()
                previous.removeFromParent()
                if visible { previous.endAppearanceTransition() }
            }
            addChild(next)
            next.view.frame = view.bounds
            next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if visible { next.beginAppearanceTransition(true, animated: false) }
            view.addSubview(next.view)
            next.didMove(toParent: self)
            activeHost = next
            if visible { next.endAppearanceTransition() }
        }

        private func makeHost(_ content: AnyView) -> UIHostingController<AnyView> {
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            return host
        }
    }
}
