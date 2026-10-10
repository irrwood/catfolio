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
                NavigationStack { PortfolioView() }
            } label: {
                tabIcon(for: .portfolio, selected: "TabPortfolioSelected",
                        unselected: "TabPortfolioUnselected", label: L10n.text("持仓"))
            }

            Tab(value: .returns) {
                NavigationStack { ReturnsView() }
            } label: {
                tabIcon(for: .returns, selected: "TabPerformanceSelected",
                        unselected: "TabPerformanceUnselected", label: L10n.text("收益"))
            }

            Tab(value: .research) {
                NavigationStack { ResearchView() }
            } label: {
                tabIcon(for: .research, selected: "TabResearchSelected",
                        unselected: "TabResearchUnselected", label: L10n.text("研究"))
            }

            Tab(value: .settings) {
                NavigationStack { SettingsView() }
            } label: {
                tabIcon(for: .settings, selected: "TabSettingsSelected",
                        unselected: "TabSettingsUnselected", label: L10n.text("账户"))
            }

            // The search role is the system's own separate circle at the end
            // of the bar, where the assistant's button used to float.
            Tab(value: .assistant, role: .search) {
                NavigationStack {
                    AIAssistantPage()
                        .toolbarVisibility(.hidden, for: .navigationBar)
                }
            } label: {
                tabIcon(for: .assistant, selected: "TabAI", unselected: "TabAI", label: L10n.text("AI 助手"))
            }
        }
        .id(presentationPreferencesID)
        .tint(.primary)
        .modifier(KeepsTabBarExpanded())
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

/// The tab bar stays full width while the pages scroll: collapsed to a
/// single ball it hid the other tabs behind a tap.
private struct KeepsTabBarExpanded: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    @Entry var rootTabBarCompact: Binding<Bool> = .constant(false)
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
    @Environment(\.rootTabBarCompact) private var compact
    // Gesture bookkeeping has no visual output. Keep it outside SwiftUI's
    // observation graph; only an actual compact/expanded change redraws UI.
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
                      let value = tracking.direction.update(from: oldOffset, to: newOffset),
                      compact.wrappedValue != value else { return }
                compact.wrappedValue = value
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

/// UIKit's `hidesBottomBarWhenPushed` for a SwiftUI page, done by hand: the
/// tab bar leaves with the page beneath as this one pushes in, and comes back
/// with it on the way out, following an interactive swipe and restored if the
/// swipe is let go.
///
/// SwiftUI's own `toolbarVisibility(.hidden, for: .tabBar)` is not used. It
/// flips the bar the moment the page appears or goes, with no animation —
/// the bar blinked out on a push and blinked back on the way home. UIKit's
/// flag alone does nothing either: SwiftUI's tab container ignores it. So the
/// flag only marks the page, and the bar is moved in the push's own
/// transition: hidden at its start, so each page lays out once for where it
/// will end, with a picture of the bar riding on the page it belongs to.
private struct TabBarHidingAnchor: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Anchor { Anchor() }
    func updateUIViewController(_ controller: Anchor, context: Context) {}

    final class Anchor: UIViewController {
        override func loadView() {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            page(from: parent)?.hidesBottomBarWhenPushed = true
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            page(from: parent)?.hidesBottomBarWhenPushed = true
            TabBarPushTransition.update(from: self, animated: animated)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            TabBarPushTransition.update(from: self, animated: animated)
        }

        /// The controller the navigation stack pushed is the one whose
        /// parent is the navigation controller; that is the one to mark.
        private func page(from start: UIViewController?) -> UIViewController? {
            var current = start
            while let controller = current {
                if controller.parent is UINavigationController { return controller }
                current = controller.parent
            }
            return nil
        }
    }
}

/// Shows or hides the tab bar for what a navigation stack will hold once its
/// push or pop is over: hidden while any page in it asks to be.
@MainActor
enum TabBarPushTransition {
    static func update(from anchor: UIViewController, animated: Bool) {
        guard let navigation = anchor.navigationController,
              let tabs = navigation.tabBarController else { return }
        // The stack as it will be: a pop has already taken the leaving page
        // out of it, a push has already put the arriving one in.
        let hidden = navigation.viewControllers.dropFirst().contains { $0.hidesBottomBarWhenPushed }
        guard tabs.isTabBarHidden != hidden else { return }
        guard animated, let coordinator = navigation.transitionCoordinator ?? anchor.transitionCoordinator else {
            tabs.setTabBarHidden(hidden, animated: animated)
            return
        }
        let bar = tabs.tabBar
        // The page the bar belongs to: the one going away on a push, the one
        // coming back on a pop. The bar's picture rides on it.
        let carrier = coordinator.viewController(forKey: hidden ? .from : .to)?.view
        let leaving = coordinator.viewController(forKey: .from)?.view
        let barFrame = tabs.view.convert(bar.bounds, from: bar)
        // Showing or hiding the bar changes every page's bottom safe area, and
        // the page leaving the screen re-laid out while it was still sliding
        // away: its content near the bar tore. It is frozen as a picture of
        // itself first, so that re-layout happens unseen underneath.
        let frozen = leaving?.snapshotView(afterScreenUpdates: false)
        if let frozen, let leaving {
            frozen.frame = leaving.bounds
            frozen.isUserInteractionEnabled = false
            leaving.addSubview(frozen)
        }
        let picture: UIView?
        if hidden {
            picture = bar.snapshotView(afterScreenUpdates: false)
            tabs.setTabBarHidden(true, animated: false)
        } else {
            tabs.setTabBarHidden(false, animated: false)
            picture = carrier == nil ? nil : bar.snapshotView(afterScreenUpdates: true)
            // The real bar waits out of sight until its picture is home.
            bar.alpha = 0
        }
        if let picture, let carrier {
            picture.frame = barFrame
            picture.isUserInteractionEnabled = false
            carrier.addSubview(picture)
        }
        // The arriving page laid out for where it ends before the first frame,
        // not part-way into the slide.
        tabs.view.layoutIfNeeded()

        let finish: (Bool) -> Void = { cancelled in
            if cancelled {
                // Back as it was, laid out again before the picture comes off.
                tabs.setTabBarHidden(!hidden, animated: false)
                tabs.view.layoutIfNeeded()
            }
            picture?.removeFromSuperview()
            frozen?.removeFromSuperview()
            bar.alpha = 1
        }
        let enrolled = coordinator.animate(alongsideTransition: { _ in
            if picture == nil || carrier == nil { bar.alpha = hidden ? 0 : 1 }
        }, completion: { context in
            finish(context.isCancelled)
        })
        // Not taken into the transition: its completion will not run.
        if !enrolled { finish(false) }
    }
}

extension View {
    /// Hides the tab bar while this page is on screen, leaving and returning
    /// with the page beneath as the system's push does.
    func hidesTabBarWhenPushed() -> some View {
        background(TabBarHidingAnchor().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
