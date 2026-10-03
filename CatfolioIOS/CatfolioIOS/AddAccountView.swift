import SwiftUI

/// One entry for account creation; existing account rows remain management entries.
///
/// One navigation stack, as the system's own add flows are: a provider is
/// pushed onto the list with the native slide, the bar's back button and an
/// edge swipe return to it, and finishing closes the whole sheet.
struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider?

    private enum Provider: Hashable { case trading212, ibkr, moomoo, robinhood, snaptrade, csv }

    var body: some View {
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
            .navigationDestination(item: $provider) { provider in
                destination(provider)
            }
        }
        // A pushed provider's 完成 closes the sheet, not just its own page.
        .environment(\.accountFlowClose, { dismiss() })
        .tint(CatfolioTheme.accent)
    }

    @ViewBuilder private func destination(_ provider: Provider) -> some View {
        switch provider {
        case .trading212: Trading212View(context: .create)
        case .ibkr: IBKRFlexView(context: .create)
        case .moomoo: MoomooOAuthView(context: .create)
        case .robinhood: RobinhoodConnectionView(context: .create)
        case .snaptrade: SnapTradeView(context: .create)
        case .csv: CSVImportView(context: .create)
        }
    }

    private func row(_ title: String, _ icon: String, _ selection: Provider) -> some View {
        SettingsButtonRow(icon: .symbol(icon), title: title) { provider = selection }
    }
}

private struct AccountFlowCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set inside 添加账户: closes the whole flow. A provider pushed there
    /// would otherwise only pop itself with `dismiss`.
    var accountFlowClose: (() -> Void)? {
        get { self[AccountFlowCloseKey.self] }
        set { self[AccountFlowCloseKey.self] = newValue }
    }
}

/// A provider's own navigation stack — unless it was pushed onto 添加账户's,
/// where a second stack inside the first would break the push and the back
/// swipe.
struct AccountFlowStack<Content: View>: View {
    @Environment(\.accountFlowClose) private var flowClose
    @ViewBuilder let content: Content

    var body: some View {
        if flowClose != nil {
            content
        } else {
            NavigationStack { content }
        }
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
