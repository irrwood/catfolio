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
        // A provider's first step goes back to this list, not out of the sheet.
        .environment(\.accountProviderBack, provider == nil ? nil : { provider = nil })
        .tint(CatfolioTheme.accent)
    }

    private func row(_ title: String, _ icon: String, _ selection: Provider) -> some View {
        SettingsButtonRow(icon: .symbol(icon), title: title) { provider = selection }
    }
}

private struct AccountProviderBackKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set while a provider was chosen from 添加账户: its first step returns there.
    var accountProviderBack: (() -> Void)? {
        get { self[AccountProviderBackKey.self] }
        set { self[AccountProviderBackKey.self] = newValue }
    }
}

/// The 上一步 a provider's first step shows when opened from 添加账户.
struct AccountProviderBackButton: View {
    @Environment(\.accountProviderBack) private var back

    var body: some View {
        if let back {
            Button(action: back) {
                Label(L10n.text("上一步"), systemImage: "chevron.left")
            }
            .accessibilityIdentifier("account-provider-back")
        }
    }
}
