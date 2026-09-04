import SwiftUI

struct RootTabView: View {
    private enum TabBarMetrics {
        static let iconSize: CGFloat = 27
    }

    private enum Destination: Hashable {
        case portfolio
        case returns
        case settings
        case assistant
    }

    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrencyRawValue = DisplayCurrency.usd.rawValue
    @AppStorage(CompanyNameDisplay.preferenceKey) private var companyNameDisplayRawValue = CompanyNameDisplay.original.rawValue
    @State private var selection: Destination
    @State private var showsAIAssistant: Bool

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
        TabView(selection: systemTabSelection) {
            Tab(value: .portfolio) {
                PortfolioView()
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
            } label: {
                tabIcon(
                    for: .settings,
                    selectedAsset: "TabSettingsSelected",
                    unselectedAsset: "TabSettingsUnselected",
                    accessibilityLabel: "设置"
                )
            }

            // Search-role tabs receive the system's trailing circular placement
            // on iOS 26. The selection binding turns that native item into the
            // existing floating-assistant action without replacing its artwork.
            Tab(value: .assistant, role: .search) {
                Color.clear
            } label: {
                Image("TabAI")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: TabBarMetrics.iconSize, height: TabBarMetrics.iconSize)
                    .accessibilityLabel("AI 助手")
            }
        }
        .id(presentationPreferencesID)
        .tint(.primary)
        .catfolioTabBarBehavior()
        .allowsHitTesting(!showsAIAssistant)
        .accessibilityHidden(showsAIAssistant)
        .overlay {
            AIFloatingAssistantLayer(isPresented: $showsAIAssistant)
                .ignoresSafeArea(.container, edges: .all)
        }
    }

    private var systemTabSelection: Binding<Destination> {
        Binding(
            get: { selection },
            set: { destination in
                if destination == .assistant {
                    presentAI()
                } else {
                    selection = destination
                }
            }
        )
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
