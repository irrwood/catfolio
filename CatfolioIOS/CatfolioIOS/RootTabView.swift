import SwiftUI
import UIKit

struct RootTabView: View {
    @Environment(AppModel.self) private var model

    private enum Destination: Hashable {
        case portfolio
        case returns
        case research
        case settings
        case assistant
    }

    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrencyRawValue = DisplayCurrency.usd.rawValue
    @AppStorage(CompanyNameDisplay.preferenceKey) private var companyNameDisplayRawValue = CompanyNameDisplay.original.rawValue
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var selection: Destination

    init() {
        let arguments = LaunchArguments.all
        let showsLocalServiceRoute = arguments.contains("--show-local-services")
            || arguments.contains { $0.hasPrefix("--show-local-service-") }
        let initialSelection: Destination
        if arguments.contains("--show-ai") {
            initialSelection = .assistant
        } else if arguments.contains("--show-returns-page") || arguments.contains("--show-heatmap") {
            initialSelection = .returns
        } else if arguments.contains("--show-research-tab") || arguments.contains("--show-dca") {
            initialSelection = .research
        } else if arguments.contains("--show-settings") || showsLocalServiceRoute {
            initialSelection = .settings
        } else {
            initialSelection = .portfolio
        }
        _selection = State(initialValue: initialSelection)
    }

    private var presentationPreferencesID: String {
        "\(displayCurrencyRawValue)|\(companyNameDisplayRawValue)"
    }

    var body: some View {
        rootTabs
            // Observe selection above the tab pages, which stays mounted
            // throughout navigation.
            .sensoryFeedback(.selection, trigger: selection) { _, _ in hapticsEnabled }
            // Have the assistant's conversations in memory before it is opened.
            .task { await LocalChatLibraryCache.warm() }
            // A new IBKR account whose first report was still being built
            // when the app closed: pick the wait up again once the accounts
            // are loaded.
            .task(id: model.accounts.contains { $0.id == IBKRFlexKeys.pendingAccountID }) {
                IBKRFirstSync.shared.startIfNeeded(model: model)
            }
            #if DEBUG
            // Opens the assistant as the AI button does, for recording it.
            .task {
                guard LaunchArguments.contains("--demo-ai-open") else { return }
                try? await Task.sleep(for: .seconds(4))
                selection = .assistant
            }
            .task {
                guard LaunchArguments.contains("--probe-news") else { return }
                await NewsSourceHub.probe()
            }
            // Prints exactly what JEV 今日关注 would send for each holding.
            .task(id: model.holdings.count) {
                guard LaunchArguments.contains("--dump-jev-state"), !model.holdings.isEmpty else { return }
                let started = Date()
                let (facts, _) = await JEVRunner().gather(model.holdings)
                print("[jev-state] gathered \(facts.count) holdings in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                for (holding, fact) in facts {
                    let data = (try? JSONSerialization.data(withJSONObject: fact.state, options: [.sortedKeys])) ?? Data()
                    print("[jev-state] \(holding.ticker) \(String(decoding: data, as: UTF8.self))")
                }
            }
            #endif
    }

    /// The system tab bar, icons only. The assistant is a tab too: it is built once and kept, rather than pushed and rebuilt —
    /// long conversation included — every time it opens.
    private var rootTabs: some View {
        TabView(selection: $selection) {
            Tab(value: .portfolio) {
                NavigationStack { PortfolioView().ownsTabBar() }
                    .id(presentationPreferencesID)
            } label: {
                tabIcon(for: .portfolio, selected: "TabPortfolioSelected",
                        unselected: "TabPortfolioUnselected", label: L10n.text("持仓"))
            }

            Tab(value: .returns) {
                NavigationStack { ReturnsView().ownsTabBar() }
                    .id(presentationPreferencesID)
            } label: {
                tabIcon(for: .returns, selected: "TabPerformanceSelected",
                        unselected: "TabPerformanceUnselected", label: L10n.text("收益"))
            }

            Tab(value: .research) {
                NavigationStack { ResearchView().ownsTabBar() }
                    .id(presentationPreferencesID)
            } label: {
                tabIcon(for: .research, selected: "TabResearchSelected",
                        unselected: "TabResearchUnselected", label: L10n.text("研究"))
            }

            Tab(value: .settings) {
                // Keep the settings navigation stack while its preferences change.
                NavigationStack {
                    SettingsView(presentationPreferencesID: presentationPreferencesID).ownsTabBar()
                }
            } label: {
                tabIcon(for: .settings, selected: "TabSettingsSelected",
                        unselected: "TabSettingsUnselected", label: L10n.text("账户"))
            }

            // The search role is the system's own separate circle at the end
            // of the bar, where the assistant's button used to float.
            Tab(value: .assistant, role: .search) {
                NavigationStack {
                    AIAssistantPage().ownsTabBar()
                        .toolbarVisibility(.hidden, for: .navigationBar)
                }
                .id(presentationPreferencesID)
            } label: {
                tabIcon(for: .assistant, selected: "TabAI", unselected: "TabAI", label: L10n.text("AI 助手"))
            }
        }
        .tint(.primary)
        .modifier(KeepsTabBarFullWidth())
    }

    /// An icon and no title: the label's text stays for VoiceOver only.
    private func tabIcon(for destination: Destination, selected: String, unselected: String, label: String) -> some View {
        Label {
            Text(label)
        } icon: {
            Image(selection == destination ? selected : unselected)
                .renderingMode(.template)
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(label)
    }
}

/// The system's own minimising folds the bar sideways into a single ball;
/// here it stays full width and slides down out of the way instead. See
/// `RootTabBar.setTucked`.
private struct KeepsTabBarFullWidth: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}

// One detector per root scroll view. Accumulate small scroll deltas so slow
// gestures work too; require deliberate travel after a direction reversal.
struct RootTabBarScrollDirection {
    private var travel: CGFloat = 0

    mutating func reset() { travel = 0 }

    mutating func update(from oldOffset: CGFloat, to newOffset: CGFloat) -> Bool? {
        let delta = newOffset - oldOffset
        guard abs(delta) > 0.01 else { return nil }
        if newOffset <= 4 {
            reset()
            return false
        }
        if (delta > 0) != (travel > 0) { travel = 0 }
        travel += delta
        guard abs(travel) >= 12 else { return nil }
        let compact = travel > 0
        reset()
        return compact
    }
}

private struct RootTabBarScrollTracking: ViewModifier {
    // Gesture bookkeeping has no visual output. Keep it outside SwiftUI's
    // observation graph; the bar itself is moved in UIKit.
    @State private var tracking = Tracking()
    var onOffsetChange: (CGFloat) -> Void
    var onPhaseChange: (ScrollPhase, ScrollPhase, ScrollPhaseChangeContext) -> Void

    private final class Tracking {
        var direction = RootTabBarScrollDirection()
        var isInteracting = false
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let maximum = max(0, geometry.contentSize.height
                    + geometry.contentInsets.top + geometry.contentInsets.bottom
                    - geometry.containerSize.height)
                return min(maximum, max(0, geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { oldOffset, newOffset in
                onOffsetChange(newOffset)
                guard tracking.isInteracting,
                      let tucked = tracking.direction.update(from: oldOffset, to: newOffset) else { return }
                RootTabBar.setTucked(tucked)
            }
            .onScrollPhaseChange { oldPhase, phase, context in
                // Inertia and rubber-band recovery must not undo the state
                // chosen by the user's swipe, nor should programmatic scrolling.
                tracking.isInteracting = phase == .interacting
                if phase == .tracking || phase == .idle { tracking.direction.reset() }
                onPhaseChange(oldPhase, phase, context)
            }
    }
}

extension View {
    func tracksRootTabBarScroll(
        onPhaseChange: @escaping (ScrollPhase, ScrollPhase, ScrollPhaseChangeContext) -> Void = { _, _, _ in },
        onOffsetChange: @escaping (CGFloat) -> Void = { _ in }
    ) -> some View {
        modifier(RootTabBarScrollTracking(onOffsetChange: onOffsetChange, onPhaseChange: onPhaseChange))
    }
}

/// The tab bar is part of a tab's root page, not a layer over every page.
///
/// A page pushed over the root covers the bar as it covers the rest of the
/// root: at the push the bar is pictured onto the root page and the real one
/// put away, so the picture slides off with the root; on the way back it
/// returns with the root and the real bar takes its place as the pop lands.
/// An interactive swipe that is called off puts everything back. Pushed pages
/// need nothing of their own — every page above the root is without the bar.
///
/// Scrolling a root page down slides the bar straight down out of the way,
/// and scrolling back up (or reaching the top) brings it back — never the
/// system's sideways fold into a single ball.
///
/// UIKit's `hidesBottomBarWhenPushed` would do the push part, but it has to
/// be set before the push, and SwiftUI's navigation stack makes its pages
/// itself; SwiftUI's own `toolbarVisibility(.hidden, for: .tabBar)` only pops
/// the bar in and out.
@MainActor
enum RootTabBar {
    private static weak var tabs: UITabBarController?
    /// The bar as pictured onto a root page at the last push over it, until
    /// that root page is back.
    private static var picture: (image: UIView, root: Weak)?
    private static weak var visibleRoot: UIViewController?
    private(set) static var isTucked = false

    final class Weak {
        weak var controller: UIViewController?
        init(_ controller: UIViewController) { self.controller = controller }
    }

    // MARK: Scrolling

    /// Slides the bar down out of the screen, or back up.
    static func setTucked(_ tucked: Bool, animated: Bool = true) {
        guard tucked != isTucked else { return }
        isTucked = tucked
        guard let tabs else { return }
        let bar = tabs.tabBar
        let change = { bar.transform = tucked ? tuckedTransform(for: bar, in: tabs) : .identity }
        if animated, !UIAccessibility.isReduceMotionEnabled, !tabs.isTabBarHidden, bar.window != nil {
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        } else {
            change()
        }
    }

    private static func tuckedTransform(for bar: UITabBar, in tabs: UITabBarController) -> CGAffineTransform {
        // From where the bar sits to just past the bottom of the screen.
        let top = bar.convert(CGPoint(x: 0, y: bar.bounds.minY), to: tabs.view).y
        return CGAffineTransform(translationX: 0, y: max(0, tabs.view.bounds.maxY - top) + 8)
    }

    // MARK: Pushes and pops over a root page

    /// A page is about to be pushed over `root`.
    fileprivate static func rootWillBeCovered(_ root: UIViewController) {
        guard let stack = root.navigationController, let tabs = stack.tabBarController,
              !tabs.isTabBarHidden else { return }
        self.tabs = tabs
        let bar = tabs.tabBar
        // Putting the bar away changes every page's bottom safe area, and the
        // root re-laid out while still sliding away: its content near the bar
        // tore. It is frozen as a picture of itself first, so that happens
        // unseen underneath.
        let frozen = freeze(root.view)
        // A tucked bar is already out of sight: nothing to carry.
        let image = isTucked ? nil : stand(in: bar, tabs: tabs)
        if let image {
            let barTop = bar.convert(CGPoint.zero, to: root.view).y
            image.frame = CGRect(x: 0, y: barTop - scrollEdgeOverhang,
                                 width: root.view.bounds.width, height: image.bounds.height)
            image.isUserInteractionEnabled = false
            image.accessibilityElementsHidden = true
            root.view.addSubview(image)
            picture = (image, Weak(root))
        }
        tabs.setTabBarHidden(true, animated: false)
        // The arriving page laid out for where it ends before the first frame.
        tabs.view.layoutIfNeeded()
        guard let coordinator = root.transitionCoordinator ?? stack.transitionCoordinator else {
            frozen?.removeFromSuperview()
            return
        }
        let finish: (Bool) -> Void = { cancelled in
            if cancelled {
                // The push was called off: the root keeps its bar, laid out
                // for it again before its picture comes off.
                tabs.setTabBarHidden(false, animated: false)
                tabs.view.layoutIfNeeded()
                dropPicture()
            }
            frozen?.removeFromSuperview()
        }
        // A transition already under way does not take the completion, and
        // the frozen picture would stay over the page for good.
        if !coordinator.animate(alongsideTransition: nil, completion: { finish($0.isCancelled) }) {
            finish(false)
        }
    }

    /// `root` is coming back into view: its picture of the bar comes with
    /// it, and the real bar takes over as it lands.
    fileprivate static func rootWillAppear(_ root: UIViewController) {
        guard let tabs = root.tabBarController else { return }
        self.tabs = tabs
        guard tabs.isTabBarHidden,
              let coordinator = root.transitionCoordinator ?? root.navigationController?.transitionCoordinator
        else { return }
        if let saved = picture, saved.root.controller === root, saved.image.superview !== root.view {
            root.view.addSubview(saved.image)
        }
        // The bar is back from the first frame, out of sight behind its
        // picture, so the root slides in laid out as it will land rather
        // than re-laying out as it arrives. The page leaving is frozen first:
        // the bar coming back changes its safe area too.
        let frozen = freeze(coordinator.viewController(forKey: .from)?.view)
        let bar = tabs.tabBar
        bar.alpha = 0
        tabs.setTabBarHidden(false, animated: false)
        tabs.view.layoutIfNeeded()
        let finish: (Bool) -> Void = { cancelled in
            bar.alpha = 1
            if cancelled {
                // Still covered: away again, laid out before the page leaving
                // comes back to life.
                tabs.setTabBarHidden(true, animated: false)
                tabs.view.layoutIfNeeded()
            } else {
                reveal(on: root)
            }
            frozen?.removeFromSuperview()
        }
        if !coordinator.animate(alongsideTransition: nil, completion: { finish($0.isCancelled) }) {
            finish(false)
        }
    }

    /// Covers `view` with a picture of itself, for while its layout changes
    /// under a transition.
    private static func freeze(_ view: UIView?) -> UIView? {
        guard let view, let frozen = view.snapshotView(afterScreenUpdates: false) else { return nil }
        frozen.frame = view.bounds
        frozen.isUserInteractionEnabled = false
        frozen.accessibilityElementsHidden = true
        view.addSubview(frozen)
        return frozen
    }

    /// Whatever the way back was, the root page on screen has its bar.
    fileprivate static func rootDidAppear(_ root: UIViewController) {
        guard let tabs = root.tabBarController else { return }
        self.tabs = tabs
        if visibleRoot !== root {
            // Another tab: its page starts at its own scroll position, with
            // the bar up.
            visibleRoot = root
            setTucked(false, animated: false)
        }
        // A page on top of this one (shown without a push animation) still
        // covers it.
        if root.navigationController?.topViewController === root { reveal(on: root) }
    }

    private static func reveal(on root: UIViewController) {
        guard let tabs = root.tabBarController else { return }
        dropPicture()
        if tabs.isTabBarHidden { tabs.setTabBarHidden(false, animated: false) }
        tabs.tabBar.transform = isTucked ? tuckedTransform(for: tabs.tabBar, in: tabs) : .identity
    }

    /// What rides on the root page in the bar's place: the bottom of the
    /// screen as it is, glass included. iOS 26 draws the glass at
    /// composition, so the screen is pictured rather than the bar's own
    /// layers, which picture as a bare selection pill.
    ///
    /// The picture reaches above the bar: the soft blur a scroll view lays
    /// under a bar rises well past the bar's top, and goes when the bar is
    /// put away. Pictured with the bar, it stays on the root the whole way
    /// instead of popping back in as the root lands.
    private static func stand(in bar: UITabBar, tabs: UITabBarController) -> UIView? {
        let barFrame = bar.convert(bar.bounds, to: tabs.view)
        let area = CGRect(x: 0, y: barFrame.minY - scrollEdgeOverhang,
                          width: tabs.view.bounds.width, height: tabs.view.bounds.maxY - barFrame.minY + scrollEdgeOverhang)
        return tabs.view.resizableSnapshotView(from: area, afterScreenUpdates: false, withCapInsets: .zero)
    }

    /// How far the scroll edge blur rises above the tab bar (65 pt on
    /// iOS 26), with a little to spare.
    private static let scrollEdgeOverhang: CGFloat = 72

    private static func dropPicture() {
        picture?.image.removeFromSuperview()
        picture = nil
    }
}

/// Sits on a tab's root page and tells `RootTabBar` when a page is pushed
/// over the root and when the root is back.
private struct RootTabBarAnchor: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Anchor { Anchor() }
    func updateUIViewController(_ controller: Anchor, context: Context) {}

    final class Anchor: UIViewController {
        override func loadView() {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            self.view = view
        }

        /// The page the navigation stack holds: the one whose parent is the
        /// navigation controller.
        private var root: UIViewController? {
            var current = parent
            while let controller = current {
                if controller.parent is UINavigationController { return controller }
                current = controller.parent
            }
            return nil
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if let root { RootTabBar.rootWillAppear(root) }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let root { RootTabBar.rootDidAppear(root) }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Only a push covers the root. Switching tabs or presenting a
            // sheet leaves it on top of its own stack.
            guard let root, let stack = root.navigationController,
                  stack.topViewController !== root, stack.viewControllers.contains(root) else { return }
            RootTabBar.rootWillBeCovered(root)
        }
    }
}

extension View {
    /// A tab's root page, which the tab bar belongs to. Every page pushed
    /// over it is shown without the bar. See `RootTabBar`.
    func ownsTabBar() -> some View {
        background(RootTabBarAnchor().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
