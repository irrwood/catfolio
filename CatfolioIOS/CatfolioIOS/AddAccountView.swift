import SwiftUI

/// One entry for account creation; existing account rows remain management entries.
struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider?

    private enum Provider { case trading212, ibkr, moomoo, robinhood, snaptrade, csv }

    var body: some View {
        Group {
            switch provider {
            case .trading212: Trading212View(context: .create)
            case .ibkr: IBKRFlexView(context: .create)
            case .moomoo: MoomooOAuthView(context: .create)
            case .robinhood: RobinhoodConnectionView(context: .create)
            case .snaptrade: SnapTradeView(context: .create)
            case .csv: CSVImportView(context: .create)
            case nil:
                NavigationStack {
                    SettingsPage(bottomInset: 32) {
                        SettingsSectionHeader(L10n.text("选择券商或导入方式"))
                        SettingsCard {
                            row("Trading 212", "chart.line.uptrend.xyaxis", .trading212)
                            row("Interactive Brokers", "doc.text", .ibkr)
                            row("Moomoo", "person.badge.key", .moomoo)
                            row("Robinhood", "link", .robinhood)
                            row(L10n.text("链接 2000+交易所"), "link", .snaptrade)
                        }
                        SettingsCard {
                            row(L10n.text("CSV 导入"), "doc.badge.plus", .csv)
                        }
                        SettingsFootnote(L10n.text("Trading 212 和 IBKR 提供逐步连接教程。已有凭证可以直接填写。"))
                    }
                    .navigationTitle(L10n.text("添加账户"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            AppModalDoneButton { dismiss() }
                        }
                    }
                }
            }
        }
        .tint(CatfolioTheme.accent)
    }

    private func row(_ title: String, _ icon: String, _ selection: Provider) -> some View {
        SettingsButtonRow(icon: .symbol(icon), title: title) { provider = selection }
    }
}
