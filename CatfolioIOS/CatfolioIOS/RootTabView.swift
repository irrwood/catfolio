import SwiftUI

struct RootTabView: View {
    private enum TabBarMetrics {
        static let iconSize: CGFloat = 27
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
                    accessibilityLabel: "持仓"
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
                    accessibilityLabel: "收益"
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
                    accessibilityLabel: "设置"
                )
            }

        }
        .id(presentationPreferencesID)
        .tint(.primary)
        .navigationTitle(selection == .settings ? "设置" : (selection == .returns ? "Performance" : ""))
        .navigationBarTitleDisplayMode(.large)
        .toolbarVisibility(selection == .portfolio ? .hidden : .visible, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            navigationBar
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                navigationButton(.portfolio, selected: "TabPortfolioSelected", unselected: "TabPortfolioUnselected", label: "持仓")
                navigationButton(.returns, selected: "TabPerformanceSelected", unselected: "TabPerformanceUnselected", label: "收益")
                navigationButton(.settings, selected: "TabSettingsSelected", unselected: "TabSettingsUnselected", label: "设置")
            }
            .padding(4)
            .navigationGlass()

            Button(action: presentAI) {
                Image("TabAI")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: TabBarMetrics.iconSize, height: TabBarMetrics.iconSize)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .navigationGlass()
            .matchedTransitionSource(id: "ai-bubble", in: assistantZoom) { source in
                source.clipShape(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
            }
            .accessibilityLabel("AI 助手")
        }
        .padding(.horizontal, 20)
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
                .frame(height: 48)
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
            .frame(width: TabBarMetrics.iconSize, height: TabBarMetrics.iconSize)
            .accessibilityLabel(accessibilityLabel)
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
