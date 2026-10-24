import SwiftUI
import UIKit

struct RootTabView: View {
    private let trading212SetupStore: Trading212SetupStore

    init(trading212SetupStore: Trading212SetupStore = .shared) {
        self.trading212SetupStore = trading212SetupStore
    }

    var body: some View {
        RootTabs(trading212SetupStore: trading212SetupStore)
    }
}

/// Keep tab selection and preference observation inside the hosting controller.
/// Replacing its whole TabView on a preference update recreates presented
/// sheets; saving an account-flow resume flag must not reset that same flow.
private struct RootTabs: View {
    @Environment(AppModel.self) private var model
    private let trading212SetupStore: Trading212SetupStore

    private typealias Destination = RootDestination

    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrencyRawValue = DisplayCurrency.usd.rawValue
    @AppStorage(CompanyNameDisplay.preferenceKey) private var companyNameDisplayRawValue = CompanyNameDisplay.original.rawValue
    @State private var selection: Destination
    private let navigationRequests = RootNavigationRequests.shared

    init(trading212SetupStore: Trading212SetupStore = .shared) {
        self.trading212SetupStore = trading212SetupStore
        let arguments = LaunchArguments.all
        let showsLocalServiceRoute = arguments.contains("--show-local-services")
            || arguments.contains { $0.hasPrefix("--show-local-service-") }
            || ServiceAPISetupState.shared.resumesSettingsProviderAtLaunch
        let initialSelection: Destination
        if arguments.contains("--show-ai") {
            initialSelection = .assistant
        } else if arguments.contains("--show-returns-page") || arguments.contains("--show-heatmap") {
            initialSelection = .returns
        } else if arguments.contains("--show-research-tab") || arguments.contains("--show-dca") {
            initialSelection = .research
        } else if arguments.contains("--show-settings") || showsLocalServiceRoute
                    || trading212SetupStore.resumesAtLaunch {
            initialSelection = .settings
        } else {
            initialSelection = .portfolio
        }
        _selection = State(initialValue: initialSelection.resolved)
    }

    private var presentationPreferencesID: String {
        "\(displayCurrencyRawValue)|\(companyNameDisplayRawValue)"
    }

    var body: some View {
        rootInterface
            // The tab bar's haptic is played from its own touches (see
            // `RootTabBarHaptics`), at the finger rather than after the
            // selection has gone through SwiftUI.
            // Have the assistant's conversations in memory before it is opened.
            .task { await LocalChatLibraryCache.warm() }
            // The Mac's Go menu and ⌘, pick a page from outside the tabs.
            .onChange(of: navigationRequests.serial) {
                if let requested = navigationRequests.requested { selection = requested.resolved }
            }
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

    @ViewBuilder private var rootInterface: some View {
        if MacPlatform.usesWorkspace {
            NativeWorkspace(tab: $selection, presentationPreferencesID: presentationPreferencesID,
                            trading212SetupStore: trading212SetupStore)
        } else {
            AdaptivePhoneWorkspace {
                SecurityDetailNavigationContainer { rootTabs }
                    .ignoresSafeArea()
            } workspace: {
                NativeWorkspace(tab: $selection, presentationPreferencesID: presentationPreferencesID,
                                trading212SetupStore: trading212SetupStore)
            }
            .ignoresSafeArea()
        }
    }

    /// The compact phone's system tab bar. The assistant is a tab too: it is built once and kept, rather than pushed and rebuilt —
    /// long conversation included — every time it opens.
    private var rootTabs: some View {
        TabView(selection: $selection) {
            Tab(value: .portfolio) {
                // On the Mac this is the Overview: returns are on it too.
                RootPageNavigation {
                    PortfolioView().ownsTabBar()
                }
                .id(presentationPreferencesID)
            } label: {
                tabIcon(for: .portfolio, artwork: .portfolio, label: Destination.portfolio.title)
            }

            // On the Mac returns sit beside the holdings on the Overview.
            if !MacPlatform.isMac {
                Tab(value: .returns) {
                    RootPageNavigation { ReturnsView().ownsTabBar() }
                        .id(presentationPreferencesID)
                } label: {
                    tabIcon(for: .returns, artwork: .returns, label: L10n.text("收益"))
                }
            }

            Tab(value: .research) {
                RootPageNavigation { ResearchView().ownsTabBar() }
                    .id(presentationPreferencesID)
            } label: {
                tabIcon(for: .research, artwork: .research, label: L10n.text("研究"))
            }

            // The fourth tab, before the account.
            Tab(value: .assistant) {
                RootPageNavigation {
                    AIAssistantPage().ownsTabBar()
                }
                .id(presentationPreferencesID)
            } label: {
                tabIcon(for: .assistant, artwork: .assistant, label: L10n.text("AI 助手"))
            }

            Tab(value: .settings) {
                // Keep the settings navigation stack while its preferences change.
                RootPageNavigation {
                    SettingsView(presentationPreferencesID: presentationPreferencesID,
                                 trading212SetupStore: trading212SetupStore).ownsTabBar()
                }
            } label: {
                tabIcon(for: .settings, artwork: .settings, label: L10n.text("账户"))
            }

            if MacPlatform.isMac {
                Tab(value: .preferences) {
                    RootPageNavigation { AppSettingsView().ownsTabBar() }
                } label: {
                    Label(Destination.preferences.title, image: "AccountSettings")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        // White behind white text in the Mac sidebar's dark selection: the
        // sidebar takes the accent there, and each page sets its own ink back.
        .tint(MacPlatform.isMac ? CatfolioTheme.accent : .primary)
        .modifier(KeepsTabBarFullWidth())
    }

    /// Compact tabs keep their existing icons and VoiceOver labels.
    @ViewBuilder
    private func tabIcon(for destination: Destination, artwork: RootTabArtwork, label: String) -> some View {
        let item = Label {
            Text(label)
        } icon: {
            Image(selection == destination ? artwork.selected : artwork.unselected)
                .renderingMode(.template)
        }
        if MacPlatform.isMac {
            item.labelStyle(.titleAndIcon)
        } else {
            item.labelStyle(.iconOnly).accessibilityLabel(label)
        }
    }
}

/// A native stack per tab keeps its title, toolbar and scroll association
/// on the same page. The root's lifecycle anchor owns tab-bar visibility.
struct RootPageNavigation<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View { stack }

    private var stack: some View {
        NavigationStack { content }
            .environment(\.pageNavigationPresentation, .tabs)
            // Stay behind the entire stack while either page moves during an
            // interactive return, including a gesture that is cancelled.
            .background { PortfolioHomePageBackdrop(colorScheme: colorScheme, isPaused: true) }
            .background(RootNavigationVisibilityAnchor().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// A direct launch can skip the root page's appearance altogether. Observe
/// the stack's container too, including a tab reopened at a pushed page.
private struct RootNavigationVisibilityAnchor: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.prepareBackdrop()
    }

    final class Controller: UIViewController {

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let parent, let navigation = findNavigation(in: parent) else { return }
            navigation.view.backgroundColor = .clear
            RootTabBar.navigationDidAppear(navigation)
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            prepareBackdrop()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard let parent, let navigation = findNavigation(in: parent),
                  let tabs = navigation.tabBarController else { return }
            RootTabBar.layoutDidChange(in: tabs)
        }

        func prepareBackdrop() {
            guard let parent, let navigation = findNavigation(in: parent) else { return }
            navigation.view.backgroundColor = .clear
        }

        private func findNavigation(in controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController { return navigation }
            return controller.children.lazy.compactMap { self.findNavigation(in: $0) }.first
        }
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

/// Revealing the bar may finish during inertia. Reaching the top must also
/// recover it after a bounce or programmatic scroll, even without a drag.
struct RootTabBarScrollState {
    private var direction = RootTabBarScrollDirection()
    private var phase: ScrollPhase = .idle

    mutating func phaseChanged(to phase: ScrollPhase, offset: CGFloat) -> Bool? {
        self.phase = phase
        if phase == .tracking || phase == .idle { direction.reset() }
        if offset <= 4 { return false }
        return nil
    }

    mutating func scrolled(from oldOffset: CGFloat, to newOffset: CGFloat) -> Bool? {
        if newOffset <= 4 {
            direction.reset()
            return false
        }
        guard phase == .interacting ||
                ((phase == .tracking || phase == .decelerating) && newOffset < oldOffset) else { return nil }
        return direction.update(from: oldOffset, to: newOffset)
    }
}

private struct RootTabBarScrollTracking: ViewModifier {
    // Gesture bookkeeping has no visual output. Keep it outside SwiftUI's
    // observation graph; the bar itself is moved in UIKit.
    @State private var tracking = Tracking()
    var onOffsetChange: (CGFloat) -> Void
    var onPhaseChange: (ScrollPhase, ScrollPhase, ScrollPhaseChangeContext) -> Void

    private final class Tracking {
        var scroll = RootTabBarScrollState()
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
                guard let tucked = tracking.scroll.scrolled(from: oldOffset, to: newOffset) else { return }
                RootTabBar.setTucked(tucked)
            }
            .onScrollPhaseChange { oldPhase, phase, context in
                let offset = max(0, context.geometry.contentOffset.y + context.geometry.contentInsets.top)
                if let tucked = tracking.scroll.phaseChanged(to: phase, offset: offset) {
                    RootTabBar.setTucked(tucked)
                }
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

/// Scrolling a root page down slides the tab bar out of the way; scrolling
/// back up or reaching the top restores it. Navigation visibility is owned
/// separately through UIKit's native tab-bar visibility API.
@MainActor
enum RootTabBar {
    private static weak var tabs: UITabBarController? {
        didSet { if let tabs { RootTabBarHaptics.install(on: tabs.tabBar) } }
    }
    private(set) static var isTucked = false

    /// Slides the bar down out of the screen, or back up.
    static func setTucked(_ tucked: Bool, animated: Bool = true) {
        guard !MacPlatform.isMac else { return }
        if let tabs, SecurityDetailNavigationController.preservesChrome(of: tabs) { return }
        if let tabs, !canTuck(in: tabs) {
            layoutDidChange(in: tabs)
            return
        }
        let changed = tucked != isTucked
        isTucked = tucked
        guard let tabs else { return }
        let bar = tabs.tabBar
        let target = tucked ? tuckedTransform(for: bar, in: tabs) : .identity
        guard changed || bar.transform != target else { return }
        let change = { bar.transform = target }
        if animated, !UIAccessibility.isReduceMotionEnabled, bar.window != nil {
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        } else {
            change()
        }
    }

    private static func tuckedTransform(for bar: UITabBar, in tabs: UITabBarController) -> CGAffineTransform {
        guard canTuck(in: tabs) else { return .identity }
        // From where the bar sits to just past the bottom of the screen.
        let top = bar.convert(CGPoint(x: 0, y: bar.bounds.minY), to: tabs.view).y - bar.transform.ty
        return CGAffineTransform(translationX: 0, y: max(0, tabs.view.bounds.maxY - top) + 8)
    }

    private static func canTuck(in owner: UITabBarController) -> Bool {
        if #available(iOS 27.0, *), owner.sidebar.isAvailable { return false }
        let bar = owner.tabBar
        let restingFrame = bar.convert(bar.bounds, to: owner.view)
            .offsetBy(dx: -bar.transform.tx, dy: -bar.transform.ty)
        return AdaptivePhoneTabNavigation.isBottomBar(restingFrame, in: owner.view.bounds)
    }

    fileprivate static func layoutDidChange(in owner: UITabBarController) {
        guard !canTuck(in: owner) else { return }
        owner.tabBar.transform = .identity
        if tabs === owner { isTucked = false }
    }

    fileprivate static func navigationDidAppear(_ navigation: UINavigationController) {
        guard !MacPlatform.isMac else { return }
        guard !SecurityDetailNavigationController.preservesChrome(of: navigation) else { return }
        guard let owner = navigation.tabBarController else { return }
        tabs = owner
        owner.setTabBarHidden(navigation.viewControllers.count > 1, animated: false)
        setTucked(false, animated: false)
    }

    /// A tab's page is on screen: another tab starts with the bar up.
    fileprivate static func pageDidAppear(_ page: UIViewController) {
        guard !MacPlatform.isMac else { return }
        guard !SecurityDetailNavigationController.preservesChrome(of: page) else { return }
        guard let owner = page.tabBarController else { return }
        tabs = owner
        // A launch route may already have pushed its destination before the
        // root's first appearance callback reaches this anchor.
        let hasPushedPage = (page.navigationController?.viewControllers.count ?? 1) > 1
        owner.setTabBarHidden(hasPushedPage, animated: false)
        setTucked(false, animated: false)
    }

    fileprivate static func pageWillAppear(_ page: UIViewController, animated: Bool) {
        guard !MacPlatform.isMac else { return }
        guard !SecurityDetailNavigationController.preservesChrome(of: page) else { return }
        guard let owner = page.tabBarController else { return }
        tabs = owner
        setTucked(false, animated: false)
        // Restore the bottom inset before the native pop lays out its title.
        // A separate tab-bar expansion animates the incoming large title up
        // by one title-row height, then snaps it back during the return.
        owner.setTabBarHidden(false, animated: false)
    }

    fileprivate static func pageWillDisappear(_ page: UIViewController, animated: Bool) {
        guard !MacPlatform.isMac else { return }
        guard !SecurityDetailNavigationController.preservesChrome(of: page) else { return }
        guard let navigation = page.navigationController,
              navigation.viewControllers.count > 1,
              let owner = page.tabBarController else { return }
        // Tab switches and sheets do not hide the bar. A push (or cancelled
        // interactive pop) leaves the root behind another navigation page.
        // Hiding the tab bar changes the safe area and relays out the
        // outgoing large title against the incoming compact bar. Move only
        // the tab bar during the push; release its inset after the root has
        // left the screen. The same completion also handles a cancelled pop.
        guard animated, let transition = navigation.transitionCoordinator else {
            owner.setTabBarHidden(true, animated: false)
            return
        }
        transition.animate(alongsideTransition: { _ in
            owner.tabBar.transform = tuckedTransform(for: owner.tabBar, in: owner)
        }, completion: { [weak navigation, weak owner] _ in
            guard let navigation, let owner, navigation.viewIfLoaded?.window != nil else { return }
            owner.setTabBarHidden(navigation.viewControllers.count > 1, animated: false)
            setTucked(false, animated: false)
        })
    }

    fileprivate static func pageIsAppearing(_ page: UIViewController) {
        guard !MacPlatform.isMac else { return }
        guard SecurityDetailNavigationController.preservesChrome(of: page),
              let owner = page.tabBarController else { return }
        // UIKit lays out the tab bar again when its complete home re-enters
        // the transition container. Keep the scroll position's existing tuck.
        UIView.performWithoutAnimation {
            owner.tabBar.transform = isTucked ? tuckedTransform(for: owner.tabBar, in: owner) : .identity
        }
    }
}

/// Sits on a tab's page and tells `RootTabBar` which page is showing.
private struct RootTabBarAnchor: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Anchor { Anchor() }
    func updateUIViewController(_ controller: Anchor, context: Context) {}

    final class Anchor: UIViewController {
        override func loadView() {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let page = parent else { return }
            RootTabBar.pageDidAppear(page)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let page = parent else { return }
            RootTabBar.pageWillAppear(page, animated: animated)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let page = parent else { return }
            RootTabBar.pageWillDisappear(page, animated: animated)
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            guard let page = parent else { return }
            RootTabBar.pageIsAppearing(page)
        }
    }
}

extension View {
    /// A tab's root page, which the tab bar belongs to. See `RootTabBar`.
    func ownsTabBar() -> some View {
        background(RootTabBarAnchor().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// A click under the finger: when it lands on a tab, and again each time it
/// slides onto another one. Driven by the bar's touches, not the selection —
/// that only changes when the finger lifts, and later still if the new tab is
/// slow to draw, which is what made the old haptic lag behind the hand.
final class RootTabBarHaptics: UIGestureRecognizer {
    private static let name = "root-tab-bar.haptics"
    private let feedback = UISelectionFeedbackGenerator()
    private weak var currentItem: UIView?

    static func install(on bar: UITabBar) {
        guard !(bar.gestureRecognizers ?? []).contains(where: { $0.name == name }) else { return }
        bar.addGestureRecognizer(RootTabBarHaptics())
    }

    init() {
        super.init(target: nil, action: nil)
        name = Self.name
        // Watches only: every touch still reaches the bar unchanged.
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    private var hapticsOn: Bool {
        UserDefaults.standard.object(forKey: ChartInteractionStyle.hapticsPreferenceKey) as? Bool ?? true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, hapticsOn else { return }
        feedback.prepare()
        currentItem = item(at: touch)
        if currentItem != nil {
            feedback.selectionChanged()
            feedback.prepare()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, hapticsOn, let item = item(at: touch),
              item !== currentItem else { return }
        currentItem = item
        feedback.selectionChanged()
        feedback.prepare()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish() }

    private func finish() {
        currentItem = nil
        state = .failed
    }

    override func reset() {
        super.reset()
        currentItem = nil
    }

    /// The tab button under the finger: the nearest control above the view
    /// it is over. Between buttons there is none, and nothing is played.
    private func item(at touch: UITouch) -> UIView? {
        guard let bar = view else { return nil }
        var candidate = bar.hitTest(touch.location(in: bar), with: nil)
        while let current = candidate, current !== bar {
            if current is UIControl { return current }
            candidate = current.superview
        }
        return nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
