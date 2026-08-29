import SwiftUI

struct RootTabView: View {
    enum Destination: Hashable {
        case portfolio
        case returns
        case ai
        case settings
    }

    @State private var selection: Destination

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let initial: Destination
        if arguments.contains("--show-returns") {
            initial = .returns
        } else if arguments.contains("--show-ai") {
            initial = .ai
        } else if arguments.contains("--show-settings") {
            initial = .settings
        } else {
            initial = .portfolio
        }
        _selection = State(initialValue: initial)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("持仓", systemImage: "chart.line.uptrend.xyaxis", value: .portfolio) {
                PortfolioView()
            }

            Tab("收益", systemImage: "chart.xyaxis.line", value: .returns) {
                ReturnsView()
            }

            Tab("AI", systemImage: "sparkles", value: .ai) {
                AIView()
            }

            Tab("设置", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
        .catfolioTabBarBehavior()
    }
}
