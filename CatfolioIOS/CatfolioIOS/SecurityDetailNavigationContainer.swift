import SwiftUI
import UIKit

/// The entire tab interface is one destination in the security-detail stack.
/// Its navigation titles and tab bar therefore stay inside the live home
/// page, underneath a zooming detail, rather than above its transition.
struct SecurityDetailNavigationContainer<Content: View>: UIViewControllerRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder let content: Content

    func makeUIViewController(context: Context) -> SecurityDetailNavigationController {
        let home = UIHostingController(rootView: AnyView(content.environment(\.self, context.environment).environment(\.scenePhase, scenePhase)))
        home.view.backgroundColor = .clear
        return SecurityDetailNavigationController(rootViewController: home)
    }

    func updateUIViewController(_ controller: SecurityDetailNavigationController, context: Context) {
        let home = controller.viewControllers.first as? UIHostingController<AnyView>
        home?.rootView = AnyView(content.environment(\.self, context.environment).environment(\.scenePhase, scenePhase))
    }
}

final class SecurityDetailNavigationController: UINavigationController, UINavigationControllerDelegate {
    private(set) var preservesRootChrome = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setNavigationBarHidden(true, animated: false)
        delegate = self
    }

    override func setNavigationBarHidden(_ hidden: Bool, animated: Bool) {
        // This stack only supplies the detail transition. Each tab owns its
        // own navigation bar; reserving another bar here shifts the live home.
        super.setNavigationBarHidden(true, animated: false)
    }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        if !viewControllers.isEmpty { preservesRootChrome = true }
        super.pushViewController(viewController, animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController,
                              didShow viewController: UIViewController, animated: Bool) {
        // Root appearance callbacks run before didShow. Keep their existing
        // title, scroll offset and tab-bar tuck untouched through cancellation
        // and through the last frame of a completed return.
        preservesRootChrome = viewControllers.count > 1
    }

    static func enclosing(_ controller: UIViewController) -> SecurityDetailNavigationController? {
        var ancestor: UIViewController? = controller
        while let current = ancestor {
            if let navigation = current as? SecurityDetailNavigationController { return navigation }
            ancestor = current.parent
        }
        return nil
    }

    static func preservesChrome(of controller: UIViewController) -> Bool {
        enclosing(controller)?.preservesRootChrome == true
    }
}
