import SwiftUI

struct RootTabView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum TabBarMetrics {
        static let regularIconSize: CGFloat = 27
        static let compactIconSize: CGFloat = 20
        static let regularControlSize: CGFloat = 56
        static let compactControlSize: CGFloat = 44
        static let regularTabButtonHeight: CGFloat = 48
        static let compactTabButtonHeight: CGFloat = 40
        static let nativeVerticalOffset: CGFloat = 6
        static let compactVerticalOffset: CGFloat = 6
    }

    private enum Destination: Hashable {
        case portfolio
        case returns
        case research
        case settings
    }

    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrencyRawValue = DisplayCurrency.usd.rawValue
    @AppStorage(CompanyNameDisplay.preferenceKey) private var companyNameDisplayRawValue = CompanyNameDisplay.original.rawValue
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var selection: Destination
    @State private var showsAIAssistant: Bool
    @State private var isTabBarCompact = false
    @Namespace private var portfolioAssistantZoom
    @Namespace private var returnsAssistantZoom
    @Namespace private var researchAssistantZoom
    @Namespace private var settingsAssistantZoom

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let showsLocalServiceRoute = arguments.contains("--show-local-services")
            || arguments.contains { $0.hasPrefix("--show-local-service-") }
        let initialSelection: Destination
        if arguments.contains("--show-returns-page") || arguments.contains("--show-heatmap")
            || arguments.contains("--show-policy-composer") {
            initialSelection = .returns
        } else if arguments.contains("--show-research-tab") {
            initialSelection = .research
        } else if arguments.contains("--show-settings") || showsLocalServiceRoute {
            initialSelection = .settings
        } else {
            initialSelection = .portfolio
        }
        _selection = State(initialValue: initialSelection)
        _showsAIAssistant = State(initialValue: arguments.contains("--show-ai"))
    }

    private var presentationPreferencesID: String {
        "\(displayCurrencyRawValue)|\(companyNameDisplayRawValue)"
    }

    var body: some View {
        rootTabs
            // Observe selection above the tab pages. Their individual bars
            // disappear/appear during a switch and can miss the triggering
            // change; this single owner stays mounted throughout navigation.
            .sensoryFeedback(.selection, trigger: selection) { _, _ in hapticsEnabled }
            // Have the assistant's conversations in memory before it is opened.
            .task { await LocalChatLibraryCache.warm() }
            #if DEBUG
            // Opens the assistant as the AI button does, for recording it.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--demo-ai-open") else { return }
                try? await Task.sleep(for: .seconds(4))
                presentAI()
            }
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--probe-news") else { return }
                await NewsSourceHub.probe()
            }
            #endif
    }

    private var rootTabs: some View {
        TabView(selection: $selection) {
            Tab(value: .portfolio) {
                tabPage(.portfolio) { PortfolioView() }
            } label: {
                tabIcon(
                    for: .portfolio,
                    selectedAsset: "TabPortfolioSelected",
                    unselectedAsset: "TabPortfolioUnselected",
                    accessibilityLabel: L10n.text("持仓")
                )
            }

            Tab(value: .returns) {
                tabPage(.returns) { ReturnsView() }
            } label: {
                tabIcon(
                    for: .returns,
                    selectedAsset: "TabPerformanceSelected",
                    unselectedAsset: "TabPerformanceUnselected",
                    accessibilityLabel: L10n.text("收益")
                )
            }

            Tab(value: .research) {
                tabPage(.research) { ResearchView() }
            } label: {
                tabIcon(
                    for: .research,
                    selectedAsset: "TabResearchSelected",
                    unselectedAsset: "TabResearchUnselected",
                    accessibilityLabel: L10n.text("研究")
                )
            }

            Tab(value: .settings) {
                tabPage(.settings) { SettingsView() }
            } label: {
                tabIcon(
                    for: .settings,
                    selectedAsset: "TabSettingsSelected",
                    unselectedAsset: "TabSettingsUnselected",
                    accessibilityLabel: L10n.text("设置")
                )
            }

        }
        .id(presentationPreferencesID)
        .tint(.primary)
        .toolbarVisibility(.hidden, for: .tabBar)
        .environment(\.rootTabBarCompact, $isTabBarCompact)
        .onChange(of: selection) { _, _ in isTabBarCompact = false }
    }

    /// A navigation bar observes exactly one tab's root scroll view. Keep its
    /// title, collapsed state and pushed pages out of the other tabs' stacks.
    private func tabPage<Content: View>(
        _ destination: Destination, @ViewBuilder content: () -> Content
    ) -> some View {
        let zoom = assistantNamespace(for: destination)
        return NavigationStack {
            content()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    navigationBar(in: zoom)
                        // Compact controls must not resize the scroll viewport.
                        .frame(height: TabBarMetrics.regularControlSize, alignment: .bottom)
                }
                .navigationDestination(isPresented: Binding(
                    get: { showsAIAssistant && selection == destination },
                    set: { presented in
                        if selection == destination { showsAIAssistant = presented }
                    }
                )) {
                    AIAssistantPage()
                        .toolbarVisibility(.hidden, for: .navigationBar)
                        .navigationTransition(.zoom(sourceID: "ai-bubble", in: zoom))
                }
        }
        .toolbarVisibility(.hidden, for: .tabBar)
    }

    private func navigationBar(in assistantZoom: Namespace.ID) -> some View {
        HStack(spacing: isTabBarCompact ? 10 : 12) {
            HStack(spacing: 0) {
                navigationButton(.portfolio, selected: "TabPortfolioSelected", unselected: "TabPortfolioUnselected", label: L10n.text("持仓"))
                navigationButton(.returns, selected: "TabPerformanceSelected", unselected: "TabPerformanceUnselected", label: L10n.text("收益"))
                navigationButton(.research, selected: "TabResearchSelected", unselected: "TabResearchUnselected", label: L10n.text("研究"))
                navigationButton(.settings, selected: "TabSettingsSelected", unselected: "TabSettingsUnselected", label: L10n.text("设置"))
            }
            .padding(isTabBarCompact ? 2 : 4)
            .navigationGlass()
            .accessibilityIdentifier("root-tab-bar")

            Button(action: presentAI) {
                Image("TabAI")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: tabIconSize, height: tabIconSize)
                    .frame(width: tabControlSize, height: tabControlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .navigationGlass()
            // Half the control's own side, so the source stays a circle at
            // both sizes. The radius was fixed at 28 — exactly half of the
            // regular 56pt control, and so a circle there, but more than half
            // of the compact 44pt one, where a continuous corner past half
            // the side bulges out into a diamond. `matchedTransitionSource`
            // accepts only a RoundedRectangle, so this cannot be a `Circle`.
            .matchedTransitionSource(id: "ai-bubble", in: assistantZoom) { source in
                source.clipShape(
                    RoundedRectangle(cornerRadius: tabControlSize / 2, style: .continuous)
                )
            }
            .accessibilityLabel(L10n.text("AI 助手"))
        }
        .padding(.horizontal, isTabBarCompact ? 48 : 20)
        // Match the lower visual baseline of iOS 26/27's floating tab bar
        // while the safe-area inset continues reserving content space.
        .offset(y: TabBarMetrics.nativeVerticalOffset + (isTabBarCompact
            ? TabBarMetrics.compactVerticalOffset
            : 0))
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: isTabBarCompact)
    }

    private func navigationButton(
        _ destination: Destination,
        selected: String,
        unselected: String,
        label: String
    ) -> some View {
        Button {
            selection = destination
        } label: {
            tabIcon(for: destination, selectedAsset: selected, unselectedAsset: unselected, accessibilityLabel: label)
                .frame(maxWidth: .infinity)
                .frame(height: isTabBarCompact
                    ? TabBarMetrics.compactTabButtonHeight
                    : TabBarMetrics.regularTabButtonHeight)
                .background {
                    if selection == destination {
                        Capsule().fill(.primary.opacity(0.07))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == destination ? .isSelected : [])
    }

    private func tabIcon(
        for destination: Destination,
        selectedAsset: String,
        unselectedAsset: String,
        accessibilityLabel: String
    ) -> some View {
        Image(selection == destination ? selectedAsset : unselectedAsset)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: tabIconSize, height: tabIconSize)
            .accessibilityLabel(accessibilityLabel)
    }

    private var tabIconSize: CGFloat {
        isTabBarCompact ? TabBarMetrics.compactIconSize : TabBarMetrics.regularIconSize
    }

    private var tabControlSize: CGFloat {
        isTabBarCompact ? TabBarMetrics.compactControlSize : TabBarMetrics.regularControlSize
    }

    private func assistantNamespace(for destination: Destination) -> Namespace.ID {
        switch destination {
        case .portfolio: portfolioAssistantZoom
        case .returns: returnsAssistantZoom
        case .research: researchAssistantZoom
        case .settings: settingsAssistantZoom
        }
    }

    private func presentAI() {
        showsAIAssistant = true
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

private extension View {
    @ViewBuilder
    func navigationGlass() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(.ultraThinMaterial, in: Capsule())
        }
    }
}
