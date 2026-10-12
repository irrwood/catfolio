import SwiftUI
import UIKit

struct CloudPreferencesSettingsSection: View {
    @Environment(\.locale) private var locale
    let sync: CloudPreferenceSync

    var body: some View {
        SettingsSection("iCloud") {
            SettingsToggleRow(
                icon: .symbol("icloud"),
                title: L10n.text("同步偏好设置"),
                isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) })
            )
            .accessibilityIdentifier("settings.icloud.enabled")
            SettingsValueRow(title: L10n.text("同步状态"), value: statusText, valueIsNumeric: false)
                .accessibilityIdentifier("settings.icloud.status")
            if let received = sync.lastReceivedAt {
                SettingsValueRow(title: L10n.text("最近接收更新"),
                    value: received.formatted(.dateTime.month().day().hour().minute().locale(locale)),
                    valueIsNumeric: false)
            }
            if sync.status == .unavailable || sync.status == .quotaExceeded {
                SettingsButtonRow(icon: .symbol("arrow.clockwise"), title: L10n.text("重试同步")) {
                    sync.refresh()
                }
                .accessibilityIdentifier("settings.icloud.retry")
            }
        }
        SettingsFootnote([
            L10n.text("仅同步偏好；账户、持仓、交易和密钥留在本机。"),
            detailText
        ].compactMap { $0 }.joined(separator: "\n"))
    }

    private var statusText: String {
        switch sync.status {
        case .off: L10n.text("未开启")
        case .automatic: L10n.text("由系统自动同步")
        case .unavailable: L10n.text("暂时无法同步")
        case .quotaExceeded: L10n.text("同步存储已满")
        case .valueTooLarge: L10n.text("部分设置过大")
        }
    }

    private var detailText: String? {
        switch sync.status {
        case .off:
            L10n.text("开启时优先使用已有的 iCloud 偏好。")
        case .automatic:
            nil
        case .unavailable:
            L10n.text("检查 iCloud 权限和网络后重试。")
        case .quotaExceeded:
            L10n.text("iCloud 空间不足；缩短筛选规则或提示词后重试。")
        case .valueTooLarge:
            L10n.text("部分设置过大；缩短筛选规则或提示词后重试。")
        }
    }
}

struct AccountNicknameField: View {
    @Environment(AppModel.self) private var model
    @Binding var nickname: String
    @Binding var edited: Bool

    var body: some View {
        HStack {
            TextField(L10n.text("账户昵称"), text: Binding(
                get: { nickname },
                set: { nickname = $0; edited = true }
            ))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            Button {
                let used = Set(model.accounts.map {
                    AccountNaming.nickname(from: $0.displayName, provider: AccountNaming.providerName(for: $0.source))
                })
                let candidates = AccountNaming.generatedNicknames.filter { $0 != nickname && !used.contains($0) }
                nickname = candidates.randomElement()
                    ?? AccountNaming.generatedNicknames.filter { $0 != nickname }.randomElement()
                    ?? nickname
                edited = true
            } label: {
                Image(systemName: "shuffle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.text("随机生成一个新昵称"))
        }
    }
}

struct SettingsView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let showsCloseButton: Bool
    let presentationPreferencesID: String
    @State private var showsPaywallPreview = false
    @State private var showsAddAccount = false
    @State private var showsCSVImport = false
    @State private var showsTrading212 = false
    @State private var showsIBKRFlex = false
    @State private var showsSnapTrade = false
    @State private var showsMoomooOAuth = false
    @State private var showsRobinhood = false
    @State private var showsLocalServices = false
    #if DEBUG
    @State private var showsRotationPreview = LaunchArguments.contains("--show-sector-rotation")
    @State private var showsSentimentPreview = LaunchArguments.contains("--show-industry-sentiment")
    @State private var showsStockChartsPreview = LaunchArguments.contains("--show-stockcharts-rrg")
    @State private var showsScreenerPreview = LaunchArguments.contains("--show-screener")
    @State private var showsHistoryPreview = LaunchArguments.contains("--show-history-preview")
    @State private var showsResearchPreview = LaunchArguments.contains("--preview-research-analysis")
    @State private var showsOIPreview = LaunchArguments.contains("--preview-options-oi")
    @State private var showsIsometricHeatmap = LaunchArguments.contains("--show-isometric-heatmap")
    #endif

    init(showsCloseButton: Bool = false, presentationPreferencesID: String = "") {
        self.showsCloseButton = showsCloseButton
        self.presentationPreferencesID = presentationPreferencesID
    }

    var body: some View {
        SettingsPage(title: L10n.text("账户"), pageBackground: .clear) {
            // Portfolio mode, account activity and scope stay here; app preferences have one entry.
            if !model.accounts.isEmpty {
                SettingsHistoryOverview()
                    .id(presentationPreferencesID)
            }

            if !model.accounts.isEmpty {
                SettingsSection {
                    allAccountsRow
                    ForEach(model.accounts) { account in
                        accountScopeRow(account)
                    }
                }
                .id(presentationPreferencesID)
            }

            SettingsCard {
                SettingsNavigationRow(icon: .asset("AccountSettings"), title: L10n.text("设置")) {
                    AppSettingsView()
                }
                .accessibilityIdentifier("account.settings")
            }

            PublicInvestorSettingsSection()
        }
        .homeTabBackground()
        .tracksRootTabBarScroll()
            .toolbarVisibility(.visible, for: .navigationBar)
            .accessibilityIdentifier("settings-root")
            #if DEBUG
            .navigationDestination(isPresented: $showsRotationPreview) {
                SectorRotationView()
            }
            .navigationDestination(isPresented: $showsStockChartsPreview) {
                StockChartsRotationView()
            }
            .navigationDestination(isPresented: $showsScreenerPreview) {
                StockScreenerView()
            }
            .navigationDestination(isPresented: $showsHistoryPreview) { HistoryView().environment(model) }
            .navigationDestination(isPresented: $showsSentimentPreview) { IndustrySentimentView().environment(model) }
            .navigationDestination(isPresented: $showsResearchPreview) { TodayAttentionView().environment(model) }
            .navigationDestination(isPresented: $showsOIPreview) {
                ScrollView { OptionsOIView(symbol: "TEST", currency: "USD", price: 108, costUSD: 104).padding(24) }
                    .softTopScrollEdge()
                    .navigationTitle(L10n.text("OI 布局验证"))
            }
            .navigationDestination(isPresented: $showsIsometricHeatmap) { IsometricHeatmapLabView().environment(model) }
            #endif
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("关闭"), systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel(L10n.text("关闭设置"))
                    }
                }
                // Floating in the bar's top-right glass rather than a full-width
                // button over the page.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("添加账户"), systemImage: "plus") { showsAddAccount = true }
                        .labelStyle(.iconOnly)
                        // The ink colour: black by day, white at night.
                        .tint(CatfolioTheme.primaryText)
                        .accessibilityLabel(L10n.text("添加账户"))
                        .accessibilityIdentifier("settings-add-account")
                }
            }
            .task {
                let arguments = LaunchArguments.all
                showsPaywallPreview = arguments.contains("--show-paywall")
                showsAddAccount = arguments.contains("--show-add-account")
                showsCSVImport = arguments.contains("--show-csv")
                showsTrading212 = arguments.contains("--show-trading212")
                showsIBKRFlex = arguments.contains("--show-flex")
                showsSnapTrade = arguments.contains("--show-snaptrade")
                showsMoomooOAuth = arguments.contains("--show-moomoo")
                showsLocalServices = arguments.contains("--show-local-services")
                    || arguments.contains { $0.hasPrefix("--show-local-service-") }
                if model.overview == nil { await model.refreshPortfolio() }
            }
            .fullScreenCover(isPresented: $showsPaywallPreview) {
                PaywallView()
            }
            .appSheet(isPresented: $showsAddAccount) {
                AddAccountView().environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .appSheet(isPresented: $showsCSVImport) {
                CSVImportView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .appSheet(isPresented: $showsTrading212) {
                Trading212View(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .appSheet(isPresented: $showsSnapTrade) {
                SnapTradeView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .appSheet(isPresented: $showsIBKRFlex) {
                IBKRFlexView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .appSheet(isPresented: $showsRobinhood) {
                RobinhoodConnectionView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .appSheet(isPresented: $showsMoomooOAuth) {
                MoomooOAuthView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
        // A launch argument opens the providers as if their row were tapped.
        .navigationDestination(isPresented: $showsLocalServices) { LocalServicesSettingsView() }
        .tint(CatfolioTheme.accent)
    }

    private var allAccountsRow: some View {
        SettingsSelectionRow(
            isSelected: model.selectedAccountKeys.count == model.accounts.count,
            title: L10n.text("全部账户"),
            subtitle: L10n.text("\(model.accounts.count) 个账户 · \(DisplayFormat.money(allAccountsMarketValueUSD))"),
            selectionAccessibilityLabel: model.selectedAccountKeys.count == model.accounts.count
                ? L10n.text("全部账户已计入")
                : L10n.text("计入全部账户"),
            selectionAccessibilityHint: L10n.text("只更改全局组合的账户范围")
        ) {
            if model.selectedAccountKeys.count != model.accounts.count {
                Task { await model.selectAllAccounts() }
            }
        }
    }

    private var allAccountsMarketValueUSD: Double {
        model.accounts.reduce(0) { total, account in
            total + account.marketValueUSD
        }
    }

    /// A new IBKR account says what its first sync is doing; the report can
    /// take minutes, and "awaiting first sync" alone looked like nothing was.
    private func firstSyncSubtitle(for account: PortfolioAccount) -> String {
        guard account.id == IBKRFlexKeys.pendingAccountID, let phase = IBKRFirstSync.shared.phase else {
            return L10n.text("等待首次同步")
        }
        switch phase {
        case let .waiting(seconds):
            return seconds < 3 ? L10n.text("正在向 IBKR 请求报表…")
                               : L10n.text("IBKR 正在生成报表… 已等待 \(seconds) 秒")
        case .importing:
            return L10n.text("正在导入持仓…")
        case let .failed(message):
            return L10n.text("首次同步失败：\(message)")
        }
    }

    private func accountScopeRow(_ account: PortfolioAccount) -> some View {
        let isSelected = model.selectedAccountKeys.contains(account.id)
        return SettingsSelectionRow(
            isSelected: isSelected,
            title: account.localizedDisplayName,
            subtitle: account.awaitsFirstSync
                ? (model.isPublicInvestorMode ? L10n.text("暂无数据") : firstSyncSubtitle(for: account))
                : L10n.text("\(account.positionCount) 项 · \(DisplayFormat.money(account.marketValueUSD))"),
            // Not the accent: in this row the filled circle already means
            // "included in the portfolio", and reusing its colour for a sync
            // state makes an unsynced account read as a selected one.
            subtitleColor: account.awaitsFirstSync ? CatfolioTheme.warning : SettingsTemplate.secondaryText,
            selectionAccessibilityLabel: isSelected
                ? L10n.text("不计入\(account.localizedDisplayName)")
                : L10n.text("计入\(account.localizedDisplayName)"),
            selectionAccessibilityHint: L10n.text("只更改全局组合的账户范围"),
            toggle: { Task { await model.toggleAccount(account.id) } }
        ) {
            AccountDetailView(accountID: account.id, initialAccount: account)
                .environment(model)
        }
        .accountFlowBrand(account.brandProvider)
    }

    /// A row that opens a broker flow in a sheet.
    private func connector(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        SettingsButtonRow(
            icon: .symbol(icon),
            title: title,
            action: action
        )
    }
}

/// What the account rebuild assumed or had to leave out. None of it stops
/// the home chart; this is where it is said.
struct AccountDataIssuesView: View {
    @Environment(\.locale) private var appLocale
    let issues: [String]

    var body: some View {
        SettingsPage {
            SettingsSection(L10n.text("不影响出图")) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { index, issue in
                        if index > 0 { Divider() }
                        Text(L10n.message(issue))
                            .appText(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
                            .padding(.vertical, SettingsTemplate.rowVerticalPadding)
                            .textSelection(.enabled)
                    }
                }
            }
            SettingsFootnote(L10n.text("图表仍可查看；补充完整交易记录可提高准确性。"))
        }
        .navigationTitle(L10n.text("数据问题"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - News
