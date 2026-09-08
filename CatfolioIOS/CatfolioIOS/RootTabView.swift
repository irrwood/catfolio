import SwiftUI

struct RootTabView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Two sizes for the tab bar, and the gap between them is the feature.
    ///
    /// The first pass moved the icon by 4pt and the row height by 4pt, which
    /// is a change you can measure and cannot see — the bar appeared not to
    /// respond to the gesture at all. Shrinking is only worth doing if the
    /// reader notices it happen, so the compact state now takes about a
    /// quarter off the icon and a quarter off the height.
    private enum TabBarMetrics {
        static let regularIconSize: CGFloat = 27
        static let compactIconSize: CGFloat = 20
        static let regularControlSize: CGFloat = 56
        static let compactControlSize: CGFloat = 42
        static let regularTabButtonHeight: CGFloat = 48
        static let compactTabButtonHeight: CGFloat = 36
        static let nativeVerticalOffset: CGFloat = 6
        static let compactVerticalOffset: CGFloat = 6
    }

    private enum Destination: Hashable {
        case portfolio
        case returns
        case settings
    }

    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrencyRawValue = DisplayCurrency.usd.rawValue
    @AppStorage(CompanyNameDisplay.preferenceKey) private var companyNameDisplayRawValue = CompanyNameDisplay.original.rawValue
    @State private var selection: Destination
    @State private var showsAIAssistant: Bool
    @State private var isTabBarCompact = false
    @State private var lastVerticalDragTranslation: CGFloat = 0
    @Namespace private var assistantZoom

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let showsLocalServiceRoute = arguments.contains("--show-local-services")
            || arguments.contains { $0.hasPrefix("--show-local-service-") }
        let initialSelection: Destination
        if arguments.contains("--show-returns-page") {
            initialSelection = .returns
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
        NavigationStack {
            rootTabs
                .navigationDestination(isPresented: $showsAIAssistant) {
                    AIAssistantPage()
                        .toolbarVisibility(.hidden, for: .navigationBar)
                        .navigationTransition(.zoom(sourceID: "ai-bubble", in: assistantZoom))
                }
        }
    }

    private var rootTabs: some View {
        TabView(selection: $selection) {
            Tab(value: .portfolio) {
                PortfolioView()
                    .toolbarVisibility(.hidden, for: .tabBar)
            } label: {
                tabIcon(
                    for: .portfolio,
                    selectedAsset: "TabPortfolioSelected",
                    unselectedAsset: "TabPortfolioUnselected",
                    accessibilityLabel: L10n.text("持仓")
                )
            }

            Tab(value: .returns) {
                ReturnsView()
                    .toolbarVisibility(.hidden, for: .tabBar)
            } label: {
                tabIcon(
                    for: .returns,
                    selectedAsset: "TabPerformanceSelected",
                    unselectedAsset: "TabPerformanceUnselected",
                    accessibilityLabel: L10n.text("收益")
                )
            }

            Tab(value: .settings) {
                SettingsView()
                    .toolbarVisibility(.hidden, for: .tabBar)
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
        .navigationTitle(selection == .settings ? L10n.text("设置") : (selection == .returns ? L10n.text("Performance") : ""))
        .navigationBarTitleDisplayMode(.large)
        .toolbarVisibility(selection == .portfolio ? .hidden : .visible, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .simultaneousGesture(tabBarResizeGesture, including: .subviews)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            navigationBar
        }
    }

    private var navigationBar: some View {
        HStack(spacing: isTabBarCompact ? 10 : 12) {
            HStack(spacing: 0) {
                navigationButton(.portfolio, selected: "TabPortfolioSelected", unselected: "TabPortfolioUnselected", label: L10n.text("持仓"))
                navigationButton(.returns, selected: "TabPerformanceSelected", unselected: "TabPerformanceUnselected", label: L10n.text("收益"))
                navigationButton(.settings, selected: "TabSettingsSelected", unselected: "TabSettingsUnselected", label: L10n.text("设置"))
            }
            .padding(isTabBarCompact ? 2 : 4)
            .navigationGlass()

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
            .matchedTransitionSource(id: "ai-bubble", in: assistantZoom) { source in
                source.clipShape(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
            }
            .accessibilityLabel(L10n.text("AI 助手"))
        }
        .padding(.horizontal, isTabBarCompact ? 28 : 20)
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

    private var tabBarResizeGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                let vertical = value.translation.height
                let horizontal = value.translation.width
                guard abs(vertical) > abs(horizontal) * 1.2 else { return }

                let delta = vertical - lastVerticalDragTranslation
                guard abs(delta) >= 6 else { return }
                lastVerticalDragTranslation = vertical
                let shouldCompact = delta < 0
                guard shouldCompact != isTabBarCompact else { return }

                if reduceMotion {
                    isTabBarCompact = shouldCompact
                } else {
                    withAnimation(.smooth(duration: 0.28)) {
                        isTabBarCompact = shouldCompact
                    }
                }
            }
            .onEnded { _ in
                lastVerticalDragTranslation = 0
            }
    }

    private func presentAI() {
        showsAIAssistant = true
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
