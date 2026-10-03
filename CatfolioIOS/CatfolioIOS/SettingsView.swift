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
    private let dataSourceHealth = DataSourceHealth.shared
    let showsCloseButton: Bool
    @AppStorage(AppLanguage.preferenceKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage("catfolio.haptics") private var hapticsEnabled = true
    @AppStorage(AppAppearance.preferenceKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrencyRawValue = DisplayCurrency.usd.rawValue
    @AppStorage(CompanyNameDisplay.preferenceKey) private var companyNameDisplayRawValue = CompanyNameDisplay.original.rawValue
    @AppStorage(AssetLogoStyle.preferenceKey) private var assetLogoStyleRawValue = AssetLogoStyle.automatic.rawValue
    @AppStorage(HomeBackgroundStyle.preferenceKey) private var homeBackgroundStyleRawValue = HomeBackgroundStyle.flowing.rawValue
    @State private var showsPaywallPreview = false
    @State private var showsAddAccount = false
    @State private var showsCSVImport = false
    @State private var showsTrading212 = false
    @State private var showsIBKRFlex = false
    @State private var showsSnapTrade = false
    @State private var showsMoomooOAuth = false
    @State private var showsRobinhood = false
    @State private var showsLocalServices = false
    @State private var showsPortfolioResetConfirmation = false
    @State private var isResettingPortfolio = false
    @State private var portfolioResetError: String?
    @State private var reconciliation: LedgerReconciliation.Report?
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

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        SettingsPage(title: L10n.text("账户")) {
            // The ledger first — the quick history tiles and 全部历史 — then
            // which accounts are shown, then the settings themselves.
            if !model.accounts.isEmpty {
                SettingsHistoryOverview()
            }

            PublicInvestorSettingsSection()

            if !model.accounts.isEmpty {
                SettingsSection(L10n.text("账户范围")) {
                    allAccountsRow
                    ForEach(model.accounts) { account in
                        accountScopeRow(account)
                    }
                }

            }

            SettingsSection(L10n.text("行情与 AI")) {
                SettingsNavigationRow(icon: .symbol("key"), title: L10n.text("服务商")) {
                    LocalServicesSettingsView()
                }
                SettingsNavigationRow(
                    icon: .symbol("newspaper"),
                    title: L10n.text("新闻")
                ) {
                    NewsSettingsView()
                }
            }

            SettingsSectionHeader(L10n.text("偏好设置"))
            SettingsCard {
                SettingsToggleRow(
                    icon: .symbol("hand.tap"),
                    title: L10n.text("触控反馈"),
                    isOn: $hapticsEnabled
                )

                SettingsMenuRow(
                    // The drawing's 语言 row: the region globe, the current
                    // answer in the primary colour, and the caret that says it
                    // opens.
                    icon: .asset("SettingsRegion"),
                    title: L10n.text("语言"),
                    value: AppLanguage(rawValue: languageRawValue)?.title ?? AppLanguage.system.title,
                    selection: $languageRawValue
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.language")

                SettingsMenuRow(
                    icon: .symbol("circle.lefthalf.filled"),
                    title: L10n.text("外观"),
                    value: L10n.label(AppAppearance(rawValue: appearanceRawValue)?.title ?? AppAppearance.system.title),
                    selection: $appearanceRawValue
                ) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(L10n.label(appearance.title)).tag(appearance.rawValue)
                    }
                }

                SettingsMenuRow(
                    icon: .symbol("sparkles"),
                    title: L10n.text("首页背景"),
                    value: HomeBackgroundStyle(rawValue: homeBackgroundStyleRawValue)?.title ?? HomeBackgroundStyle.flowing.title,
                    selection: $homeBackgroundStyleRawValue
                ) {
                    ForEach(HomeBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.homeBackground")

                SettingsMenuRow(
                    icon: .symbol("square.on.square"),
                    title: L10n.text("Logo 样式"),
                    value: AssetLogoStyle(rawValue: assetLogoStyleRawValue)?.title ?? AssetLogoStyle.automatic.title,
                    selection: $assetLogoStyleRawValue
                ) {
                    ForEach(AssetLogoStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .accessibilityIdentifier("settings.logoStyle")

                SettingsMenuRow(
                    icon: .symbol("character.bubble"),
                    title: L10n.text("公司名称"),
                    value: CompanyNameDisplay(rawValue: companyNameDisplayRawValue)?.title ?? CompanyNameDisplay.original.title,
                    selection: $companyNameDisplayRawValue
                ) {
                    ForEach(CompanyNameDisplay.allCases) { display in
                        Text(display.title).tag(display.rawValue)
                    }
                }

                SettingsMenuRow(
                    icon: .symbol("dollarsign.circle"),
                    title: L10n.text("数据货币"),
                    value: L10n.label(DisplayCurrency(rawValue: displayCurrencyRawValue)?.title ?? DisplayCurrency.usd.title),
                    selection: $displayCurrencyRawValue
                ) {
                    ForEach(DisplayCurrency.allCases) { currency in
                        Text(L10n.label(currency.title)).tag(currency.rawValue)
                    }
                }
            }
            SettingsFootnote(LocalPortfolioEngine.fxStatus)

            CloudPreferencesSettingsSection(sync: CloudPreferences.shared)

            SettingsSection(L10n.text("本机数据")) {
                SettingsValueRow(
                    icon: .symbol("iphone.gen3"),
                    title: L10n.text("数据来源"),
                    value: L10n.label(model.localSource),
                    valueIsNumeric: false
                )
                SettingsValueRow(
                    icon: .symbol("chart.pie"),
                    title: L10n.text("持仓"),
                    value: L10n.text("\(model.holdings.count) 项")
                )
                if let reconciliation, !reconciliation.reconciles {
                    SettingsValueRow(
                        icon: .symbol("exclamationmark.triangle"),
                        title: L10n.text("交易记录"),
                        value: L10n.text("\(reconciliation.mismatches.count) 项对不上")
                    )
                } else if let reconciliation {
                    SettingsValueRow(
                        icon: .symbol("checkmark.seal"),
                        title: L10n.text("交易记录"),
                        value: L10n.text("\(reconciliation.transactionCount) 笔 · 与持仓一致")
                    )
                }
                if let updatedAt = model.localUpdatedAt {
                    SettingsValueRow(
                        icon: .symbol("clock"),
                        title: L10n.text("行情更新"),
                        value: compactDate(updatedAt)
                    )
                }
                // Problems with the history never stop the chart: they are
                // listed here, each with what was assumed in its place.
                let issues = Array(NSOrderedSet(array: (model.portfolioChart?.dataIssues ?? []) + (model.comparison?.dataIssues ?? []))) as? [String] ?? []
                if !issues.isEmpty {
                    SettingsNavigationRow(
                        icon: .symbol("exclamationmark.triangle"),
                        title: L10n.text("数据问题"),
                        value: L10n.text("\(issues.count) 项")
                    ) {
                        AccountDataIssuesView(issues: issues)
                    }
                    .accessibilityIdentifier("settings.data-issues")
                }
                SettingsNavigationRow(
                    icon: .symbol("network"),
                    title: L10n.text("数据源状态"),
                    value: dataSourceHealth.statuses.isEmpty
                        ? L10n.text("尚无记录")
                        : (dataSourceHealth.failingCount == 0
                            ? L10n.text("最近正常")
                            : L10n.text("\(dataSourceHealth.failingCount) 个异常")),
                    valueColor: dataSourceHealth.failingCount > 0 ? CatfolioTheme.danger : nil
                ) {
                    DataSourceStatusView()
                }
                .accessibilityIdentifier("settings.data-source-health")
            }
            if let reconciliation, !reconciliation.reconciles {
                SettingsFootnote(reconciliationDetail(reconciliation))
            }

            SettingsSectionHeader(L10n.text("本机组合数据"))
            SettingsCard {
                SettingsButtonRow(
                    icon: .symbol("trash"),
                    title: L10n.text("重置本机组合数据"),
                    showsChevron: false,
                    role: .destructive
                ) {
                    showsPortfolioResetConfirmation = true
                }
                .disabled(isResettingPortfolio || model.isPortfolioLoading || model.isReturnsLoading || model.isPublicInvestorMode)
            }
            if let notice = model.portfolioRecoveryNotice {
                SettingsFootnote(notice)
                    .textSelection(.enabled)
            }

            // 实验 · 等距热力图 was removed from Settings (2026-09-24). The page
            // is kept in IsometricHeatmapLab.swift; DEBUG builds still open it
            // with --show-isometric-heatmap.

            // Features still being tried out, kept together off the main pages.
            SettingsCard {
                SettingsNavigationRow(icon: .symbol("flask"), title: L10n.text("Lab 实验室")) {
                    SettingsLabView()
                }
                .accessibilityIdentifier("settings-lab")
            }

            SettingsSection(L10n.text("关于")) {
                SettingsValueRow(
                    icon: .symbol("info.circle"),
                    title: L10n.text("版本"),
                    value: appVersion,
                    valueIsNumeric: true
                )
                // Every test entry lives on this one page.
                SettingsNavigationRow(icon: .symbol("testtube.2"), title: L10n.text("测试")) {
                    SettingsTestView()
                }
                .accessibilityIdentifier("settings-test")
            }
        }
        .tracksRootTabBarScroll()
            .accessibilityIdentifier("settings-root")
            #if DEBUG
            .navigationDestination(isPresented: $showsRotationPreview) {
                SectorRotationView().toolbarVisibility(.hidden, for: .tabBar)
            }
            .navigationDestination(isPresented: $showsStockChartsPreview) {
                StockChartsRotationView().toolbarVisibility(.hidden, for: .tabBar)
            }
            .navigationDestination(isPresented: $showsScreenerPreview) {
                StockScreenerView().toolbarVisibility(.hidden, for: .tabBar)
            }
            .navigationDestination(isPresented: $showsHistoryPreview) { HistoryView().environment(model) }
            .navigationDestination(isPresented: $showsSentimentPreview) { IndustrySentimentView().environment(model) }
            .navigationDestination(isPresented: $showsResearchPreview) { TodayAttentionView().environment(model) }
            .navigationDestination(isPresented: $showsOIPreview) {
                ScrollView { OptionsOIView(symbol: "TEST", currency: "USD", price: 108, costUSD: 104).padding(24) }
                    .softTopScrollEdge()
                    .navigationTitle(L10n.text("OI 布局验证"))
                    .toolbarVisibility(.hidden, for: .tabBar)
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
                await loadReconciliation()
            }
            .confirmationDialog(L10n.text("重置本机组合数据？"), isPresented: $showsPortfolioResetConfirmation, titleVisibility: .visible) {
                Button(L10n.text("备份并重置"), role: .destructive) {
                    isResettingPortfolio = true
                    Task {
                        defer { isResettingPortfolio = false }
                        do { try await model.resetLocalPortfolio() }
                        catch { portfolioResetError = error.localizedDescription }
                    }
                }
            } message: {
                Text(L10n.text("将清空当前持仓、交易和历史快照，并保留一份本机备份。券商授权、API 密钥及 AI 对话会保留。"))
            }
            .alert(L10n.text("无法重置组合"), isPresented: Binding(
                get: { portfolioResetError != nil },
                set: { if !$0 { portfolioResetError = nil } }
            )) {
                Button(L10n.text("好"), role: .cancel) { portfolioResetError = nil }
            } message: {
                Text(L10n.message(portfolioResetError ?? ""))
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func compactDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .year()
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
                .locale(Locale(identifier: AppLanguage.currentIdentifier))
        )
    }

    /// Checks the ledger against the holdings, off the main actor.
    ///
    /// Runs whether or not anything is currently asking the ledger a
    /// question, because the whole point is that an incomplete history is
    /// silent until something downstream produces a number from it.
    private func loadReconciliation() async {
        let accountIDs = model.accounts.map(\.id)
        var transactions: [LocalTransactionRecord] = []
        for id in accountIDs {
            transactions += (try? await model.transactions(for: id)) ?? []
        }
        guard !transactions.isEmpty || !model.holdings.isEmpty else { return }
        let holdings = model.holdings.map { (ticker: $0.ticker, shares: $0.shares) }
        reconciliation = await Task.detached(priority: .utility) {
            LedgerReconciliation.report(
                transactions: transactions,
                holdings: holdings,
                splits: try? StockSplitCatalog.bundled.get()
            )
        }.value
    }

    /// Says what does not add up, and what to do about it.
    ///
    /// Deliberately concrete about the direction: shares the ledger accounts
    /// for but are not held means disposals are missing, which is what a
    /// sync that returned only purchases looks like. The opposite reads as a
    /// transfer in or a missed acquisition. The remedy is the same, but a
    /// reader trying to work out whether to trust a number is not helped by
    /// being told only that something is wrong.
    private func reconciliationDetail(_ report: LedgerReconciliation.Report) -> String {
        var parts: [String] = []
        if report.hasUnexplainedDisposals {
            let disposed = report.fullyDisposed
            parts.append(disposed > 0
                ? L10n.text("账本记录的股数多于实际持仓，其中 \(disposed) 项已清仓却没有卖出记录")
                : L10n.text("账本记录的股数多于实际持仓，可能缺少卖出记录"))
        }
        if report.hasUnexplainedHoldings {
            parts.append(L10n.text("有持仓在账本里找不到买入记录"))
        }
        parts.append(L10n.text("重新同步以补齐；在补齐前，按税务口径的成本与损益不会计算。"))
        return L10n.sentences(parts)
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

private enum AccountManagementSheet: String, Identifiable {
    case robinhood
    case snaptrade
    case trading212
    case moomoo
    case ibkr
    case csv
    case manualTransaction

    var id: String { rawValue }
}

private struct AccountNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct AccountDetailView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let accountID: String
    let initialAccount: PortfolioAccount

    @State private var activeSheet: AccountManagementSheet?
    @State private var showsRenamePrompt = false
    @State private var showsDeleteConfirmation = false
    @State private var accountNameDraft = ""
    @State private var notice: AccountNotice?
    @State private var isWorking = false
    @State private var dataMatchStatus = L10n.text("无异常")

    private var account: PortfolioAccount {
        model.accounts.first(where: { $0.id == accountID }) ?? initialAccount
    }

    var body: some View {
        SettingsPage(
            // The account names the screen and the holding count sits under
            // it, so both fold into the small two-line title on scroll. The
            // value stays in the page, where it is the largest thing on it.
            title: account.localizedDisplayName,
            subtitle: L10n.text("\(account.positionCount) 个持仓"),
            bottomInset: 24
        ) {
            CatfolioDisplayAmountText(text: DisplayFormat.money(account.marketValueUSD), size: 34, symbolSize: 22)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.isFakeDataMode {
                SettingsFootnote(L10n.text("这里是独立演示账户，与真实持仓无关。"))
            }

            SettingsSection(L10n.text("账户信息")) {
                SettingsButtonRow(
                    title: L10n.text("账户名称"),
                    value: account.localizedDisplayName
                ) {
                    accountNameDraft = account.displayName
                    showsRenamePrompt = true
                }
                .disabled(model.isFakeDataMode || model.isPublicInvestorMode)

                // Trading 212's API cannot say whether an account is an ISA, so
                // this is the one type the person states rather than the app
                // reading it; every other broker's type stays a value.
                if account.source == "Trading 212" {
                    SettingsMenuRow(
                        title: L10n.text("账户类型"),
                        value: L10n.label(account.accountType),
                        selection: accountTypeSelection
                    ) {
                        ForEach(Trading212AccountType.allCases) { type in
                            Text(type.displayName).tag(Optional(type))
                        }
                    }
                    .disabled(model.isFakeDataMode || model.isPublicInvestorMode)
                } else {
                    SettingsValueRow(title: L10n.text("账户类型"), value: L10n.label(account.accountType), valueIsNumeric: false)
                }
                SettingsValueRow(title: L10n.text("基础币种"), value: account.baseCurrency, valueIsNumeric: false)
                SettingsValueRow(title: L10n.text("Broker"), value: L10n.label(account.brokerName), valueIsNumeric: false)
            }

            SettingsSection(L10n.text("数据来源")) {
                SettingsButtonRow(title: primarySourceTitle, value: primarySourceStatus) {
                    activeSheet = syncSheet
                }
                .disabled(model.isFakeDataMode || model.isPublicInvestorMode)

                if account.source != "CSV" {
                    SettingsButtonRow(title: L10n.text("CSV 导入"), value: csvImportStatus) {
                        activeSheet = .csv
                    }
                    .disabled(model.isFakeDataMode || model.isPublicInvestorMode)
                }

                SettingsButtonRow(title: L10n.text("手动补充"), value: L10n.text("\(manualTransactionCount) 笔")) {
                    activeSheet = .manualTransaction
                }
                .disabled(model.isFakeDataMode || model.isPublicInvestorMode)
            }

            SettingsSection(L10n.text("数据记录")) {
                SettingsNavigationRow(
                    title: L10n.text("History"),
                    value: L10n.text("\(account.transactionCount) 笔交易记录")
                ) {
                    HistoryView(initialAccountIDs: [account.id])
                        .environment(model)
                }

                SettingsButtonRow(
                    title: L10n.text("数据匹配与去重"),
                    showsChevron: !isWorking,
                    value: isWorking ? nil : dataMatchStatus,
                    showsProgress: isWorking
                ) {
                    deduplicateTransactions()
                }
                .disabled(isWorking || model.isFakeDataMode || model.isPublicInvestorMode)
            }

            SettingsSection(L10n.text("账户设置")) {
                SettingsButtonRow(
                    icon: .symbol("trash"),
                    title: L10n.text("删除账户"),
                    showsChevron: false,
                    role: .destructive
                ) {
                    showsDeleteConfirmation = true
                }
                .disabled(model.isFakeDataMode || model.isPublicInvestorMode)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .alert(L10n.text("编辑账户名称"), isPresented: $showsRenamePrompt) {
            TextField(L10n.text("账户名称"), text: $accountNameDraft)
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("保存")) { renameAccount() }
                .disabled(accountNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(L10n.text("名称只保存在这台 iPhone 上。"))
        }
        .alert(L10n.text("删除账户？"), isPresented: $showsDeleteConfirmation) {
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("删除"), role: .destructive) { deleteAccount() }
        } message: {
            Text(L10n.text("将删除 \(account.localizedDisplayName) 的持仓、交易和历史快照，此操作无法撤销。"))
        }
        .alert(
            Text(notice?.title ?? ""),
            isPresented: Binding(
                get: { notice != nil },
                set: { isPresented in
                    if !isPresented { notice = nil }
                }
            ),
            presenting: notice
        ) { _ in
            Button(L10n.text("好"), role: .cancel) { notice = nil }
        } message: { notice in
            Text(L10n.message(notice.message))
        }
        .appSheet(item: $activeSheet) { sheet in
            accountSheet(sheet)
                .environment(model)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func accountSheet(_ sheet: AccountManagementSheet) -> some View {
        switch sheet {
        case .trading212:
            Trading212View(context: .manage(account))
        case .moomoo:
            MoomooOAuthView(context: .manage(account))
        case .robinhood:
            RobinhoodConnectionView(context: .manage(account))
        case .snaptrade:
            SnapTradeView(context: .manage(account))
        case .ibkr:
            IBKRFlexView(context: .manage(account))
        case .csv:
            CSVImportView(context: .manage(account))
        case .manualTransaction:
            ManualTransactionView(account: account)
        }
    }

    private var syncSheet: AccountManagementSheet {
        switch account.source {
        case "Trading 212": .trading212
        case "Moomoo": .moomoo
        case "Robinhood": .robinhood
        case "SnapTrade": .snaptrade
        case "IBKR Flex": .ibkr
        default: .csv
        }
    }

    private var primarySourceTitle: String {
        switch account.source {
        case "Trading 212": L10n.text("Trading 212 同步")
        case "Moomoo": L10n.text("Moomoo 同步")
        case "Robinhood": L10n.text("Robinhood 同步")
        case "SnapTrade": L10n.text("SnapTrade 同步")
        case "IBKR Flex": L10n.text("IBKR 同步")
        case "CSV": L10n.text("CSV 导入")
        case "假数据": L10n.text("本机演示数据")
        default: account.syncedSourceTitle
        }
    }

    private var primarySourceStatus: String {
        if account.source == "假数据" { return L10n.text("已启用") }
        let connection = account.source == "CSV" ? L10n.text("已导入") : L10n.text("已连接")
        guard let updatedAt = model.localUpdatedAt else { return connection }
        let interval = max(0, Date().timeIntervalSince(updatedAt))
        if interval < 60 { return L10n.text("\(connection) · 刚刚同步") }
        if interval < 3_600 { return L10n.text("\(connection) · \(max(1, Int(interval / 60))) 分钟前") }
        if interval < 86_400 { return L10n.text("\(connection) · \(max(1, Int(interval / 3_600))) 小时前") }
        return "\(connection) · \(updatedAt.formatted(.dateTime.month().day()))"
    }

    private var csvImportStatus: String {
        account.hasCSVImport ? L10n.text("已导入") : L10n.text("未导入")
    }

    private var manualTransactionCount: Int {
        account.manualTransactionCount
    }

    private func renameAccount() {
        let name = accountNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await model.renameAccount(accountID, to: name)
            } catch {
                notice = AccountNotice(title: L10n.text("无法保存名称"), message: error.localizedDescription)
            }
        }
    }

    /// Trading 212's API reports an account number and a currency, never the
    /// product, so the type is chosen here and saved on its own.
    private var accountTypeSelection: Binding<Trading212AccountType?> {
        Binding(
            get: { account.chosenAccountType },
            set: { type in
                guard let type else { return }
                Task {
                    do {
                        try await model.setTrading212AccountType(type, for: accountID)
                    } catch {
                        notice = AccountNotice(title: L10n.text("无法保存账户类型"), message: error.localizedDescription)
                    }
                }
            }
        )
    }

    private func deduplicateTransactions() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let removed = try await model.deduplicateTransactions(for: accountID)
                dataMatchStatus = removed == 0 ? L10n.text("无异常") : L10n.text("已处理 \(removed) 笔")
                notice = AccountNotice(
                    title: L10n.text("数据去重完成"),
                    message: removed == 0 ? L10n.text("未发现重复交易。") : L10n.text("已移除 \(removed) 笔重复交易。")
                )
            } catch {
                dataMatchStatus = L10n.text("检查失败")
                notice = AccountNotice(title: L10n.text("去重失败"), message: error.localizedDescription)
            }
        }
    }

    private func deleteAccount() {
        Task {
            do {
                try await model.deleteAccount(accountID)
                dismiss()
            } catch {
                notice = AccountNotice(title: L10n.text("无法删除账户"), message: error.localizedDescription)
            }
        }
    }
}

/// One History figure, laid out as Figma 487:5391: the icon and chevron on
/// top, the title over the amount at the foot. The colours stay the
/// settings card's own.
private struct SettingsHistoryOverviewTile: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let icon: String
    let caption: String
    let value: String
    let valueColor: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 18, height: 24)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                // One line: a wrapped caption would push this tile's figures
                // out of line with its neighbour's.
                Text(caption)
                    .appText(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image("SettingsChevron")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(height: 24)
            Spacer(minLength: 8)
            // Figma's gap is between trimmed text boxes; the line boxes
            // here already carry most of it.
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Typography.text(size: 14, weight: .bold))
                    .textCase(.uppercase)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(Typography.number(size: 20, weight: .semibold))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(CatfolioTheme.primaryText)
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: 109, alignment: .leading)
        .modifier(SettingsHistoryTileGlass())
        .contentShape(shape)
    }
}

private struct SettingsHistoryTileGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// Uses the same prepared ledger and fund charges as History, across all
/// accounts and years. Display currency remains a presentation preference.
private struct SettingsHistoryOverview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrency = DisplayCurrency.usd.rawValue
    @State private var prepared: HistoryPreparedLedger?
    @State private var annualFees: Double?
    @State private var failed = false
    @State private var loadedKey: LoadKey?

    private struct LoadKey: Hashable {
        let updatedAt: Date?
        let accountIDs: Set<String>
        let investorSelection: String
        let locale: String
    }

    private var loadKey: LoadKey {
        LoadKey(updatedAt: model.localUpdatedAt,
                accountIDs: Set(model.accounts.map(\.id)),
                investorSelection: model.publicInvestorSelection, locale: locale.identifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                     count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                overviewCard(.orders, title: L10n.text("已实现盈亏"), icon: "arrow.up.arrow.down",
                             caption: realisedCaption, amount: realisedAmount, signed: true)
                overviewCard(.dividends, title: L10n.text("股息"), icon: "banknote",
                             caption: "", amount: total(for: .dividends))
                overviewCard(.interest, title: L10n.text("利息"), icon: "percent",
                             caption: "", amount: total(for: .interest))
                overviewCard(.fees, title: L10n.text("年费用"), icon: "creditcard",
                             caption: "", amount: annualFees)
            }
            SettingsCard {
                SettingsNavigationRow(icon: .asset("SettingsInvoice"), title: L10n.text("全部历史")) {
                    HistoryView().environment(model)
                }
                .accessibilityIdentifier("settings.history-overview.all")
            }
            if failed {
                Button(L10n.text("无法读取速览，轻点重试")) {
                    Task { await load() }
                }
                .font(.caption)
                .tint(.primary)
            } else if prepared == nil {
                ProgressView(L10n.text("正在读取历史汇总…"))
                    .font(.caption)
            }
        }
        .accessibilityIdentifier("settings.history-overview")
        .task(id: loadKey) {
            guard loadedKey != loadKey else { return }
            await load()
        }
    }

    private var realisedAmount: Double? {
        guard let calculation = prepared?.realisedTotal,
              calculation.brokerCount + calculation.estimatedCount > 0 else { return nil }
        return calculation.combinedUSD
    }

    private var realisedCaption: String {
        guard let calculation = prepared?.realisedTotal else { return "" }
        if calculation.saleCount == 0 { return L10n.text("暂无卖出") }
        if !calculation.isComplete { return L10n.text("部分数据") }
        return ""
    }

    private func total(for category: HistoryCategory) -> Double? {
        prepared?.page(category: category, basis: .calendar, year: nil).totalUSD
    }

    private func overviewCard(_ category: HistoryCategory, title: String, icon: String,
                              caption: String, amount: Double?, signed: Bool = false) -> some View {
        let validAmount = amount.flatMap { $0.isFinite ? $0 : nil }
        let currency = DisplayCurrency(rawValue: displayCurrency) ?? .usd
        let value = validAmount.map {
            DisplayFormat.money(currency.fromUSD($0), currency: currency.rawValue,
                                signed: signed, fractionDigits: 2)
        } ?? "—"
        let color: Color = category == .fees || validAmount == nil || validAmount == 0
            ? .primary : ((validAmount ?? 0) < 0 ? CatfolioTheme.danger : CatfolioTheme.positive)
        return NavigationLink {
            HistoryView(initialCategory: category).environment(model)
        } label: {
            SettingsHistoryOverviewTile(title: title, icon: icon, caption: caption,
                                        value: value, valueColor: color)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(caption.isEmpty ? value : "\(caption) · \(value)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("settings.history-overview.\(category.rawValue.lowercased())")
    }

    @MainActor
    /// A reload keeps the figures that are already up. Clearing them first
    /// blanked all four cards and put a progress line under the grid, which
    /// changed the section's height and shifted everything below it — the
    /// jump a reader saw on coming back from a page that changes the key.
    private func load() async {
        failed = false
        let requestKey = loadKey
        do {
            let ledger = try await model.activityLedger()
            let accountIDs = Set(ledger.accounts.map(\.id))
            let locale = locale
            async let holdings = model.holdings(forAccounts: accountIDs)
            let worker = Task.detached(priority: .utility) {
                try HistoryPreparedLedger.build(ledger: ledger, accountIDs: accountIDs, locale: locale)
            }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            let positions = try? await holdings
            try Task.checkCancellation()
            if let positions {
                let charges = HistoryFeeCharge.build(holdings: positions)
                annualFees = charges.isEmpty ? nil : charges.reduce(0) { $0 + $1.annual }
            }
            prepared = result
            loadedKey = requestKey
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

private struct ManualTransactionView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: PortfolioAccount

    @State private var date = Date()
    @State private var action = "BUY"
    @State private var ticker = ""
    @State private var quantity = ""
    @State private var price = ""
    @State private var currency: DisplayCurrency = .usd
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var numericQuantity: Double? { Double(quantity.replacingOccurrences(of: ",", with: ".")) }
    private var numericPrice: Double? { Double(price.replacingOccurrences(of: ",", with: ".")) }
    private var canSave: Bool {
        !ticker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (numericQuantity ?? 0) > 0
            && (numericPrice ?? 0) > 0
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            SettingsPage(bottomInset: 32) {
                SettingsCard {
                    SettingsValueRow(
                        title: L10n.text("账户"),
                        value: account.localizedDisplayName,
                        valueIsNumeric: false
                    )

                    SettingsRowContainer {
                        DatePicker(L10n.text("交易日期"), selection: $date, displayedComponents: .date)
                            .appText(.subheading)
                    }

                    // `.menu` explicitly: a `Picker` shows a menu inside a
                    // grouped Form and would pick a different style outside
                    // one, which would change how the row is operated.
                    SettingsMenuRow(
                        title: L10n.text("交易类型"),
                        value: action == "BUY" ? L10n.text("买入") : L10n.text("卖出"),
                        selection: $action
                    ) {
                        Text(L10n.text("买入")).tag("BUY")
                        Text(L10n.text("卖出")).tag("SELL")
                    }
                }

                SettingsSection(L10n.text("交易内容")) {
                    SettingsFieldRow(L10n.text("代码，如 AAPL"), text: $ticker)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SettingsFieldRow(L10n.text("数量"), text: $quantity)
                        .keyboardType(.decimalPad)
                    SettingsFieldRow(L10n.text("成交价"), text: $price)
                        .keyboardType(.decimalPad)
                    SettingsMenuRow(
                        title: L10n.text("币种"),
                        value: currency.rawValue,
                        selection: $currency
                    ) {
                        ForEach(DisplayCurrency.allCases) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                }

                if let errorMessage {
                    SettingsFootnote(errorMessage, color: CatfolioTheme.danger)
                }
            }
            .softTopScrollEdge()
            .navigationTitle(L10n.text("补充历史交易"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("保存")) { save() }
                        .disabled(!canSave)
                }
            }
        }
        .tint(CatfolioTheme.accent)
    }

    private func save() {
        guard let numericQuantity, let numericPrice else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await model.addHistoricalTransaction(
                    to: account,
                    date: date,
                    action: action,
                    ticker: ticker.trimmingCharacters(in: .whitespacesAndNewlines),
                    quantity: numericQuantity,
                    price: numericPrice,
                    currency: currency.rawValue
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

enum LocalServiceProvider: String, CaseIterable, Identifiable, Hashable {
    case massive
    case fmp
    case deepSeek
    case openRouter
    case finnhub
    case jev

    var id: String { rawValue }

    var title: String {
        switch self {
        case .massive: "Massive"
        case .fmp: "Financial Modeling Prep"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .finnhub: "Finnhub"
        case .jev: "Jev (Cloudflare)"
        }
    }

    var shortTitle: String {
        switch self {
        case .fmp: "FMP"
        case .jev: "Jev"
        default: title
        }
    }

    var purpose: String {
        switch self {
        case .massive: L10n.text("美股成交量与历史行情")
        case .fmp: L10n.text("估值矩阵与行情备用")
        case .deepSeek: L10n.text("云端问答与自动回退")
        case .openRouter: L10n.text("用一个 Key 调用多家模型")
        case .finnhub: L10n.text("美股公司新闻")
        case .jev: L10n.text("JEV 今日关注的买卖判断")
        }
    }

    var detail: String {
        switch self {
        case .massive:
            L10n.text("读取美股价格和成交量。")
        case .fmp:
            L10n.text("读取估值数据，备用历史行情。")
        case .deepSeek:
            L10n.text("组合摘要和问题会发送给 DeepSeek。")
        case .openRouter:
            L10n.text("组合摘要和问题会经 OpenRouter 发送给所选模型。")
        case .finnhub:
            L10n.text("仅发送股票代码，读取公司新闻。")
        case .jev:
            L10n.text("发送行情、仓位占比和盈亏比例；不发送账户、股数或金额。")
        }
    }

    var keychainKey: String {
        switch self {
        case .massive: LocalServiceKeys.massive
        case .fmp: LocalServiceKeys.fmp
        case .deepSeek: LocalServiceKeys.deepSeek
        case .openRouter: LocalServiceKeys.openRouter
        case .finnhub: LocalServiceKeys.finnhub
        case .jev: LocalServiceKeys.cloudflareAIToken
        }
    }

    var iconName: String {
        switch self {
        case .massive: "chart.bar.xaxis"
        case .fmp: "chart.xyaxis.line"
        case .deepSeek: "sparkles"
        case .openRouter: "arrow.triangle.branch"
        case .finnhub: "newspaper"
        case .jev: "bolt.fill"
        }
    }

    var tint: Color {
        switch self {
        case .massive: CatfolioTheme.accent
        case .fmp: CatfolioTheme.warning
        case .deepSeek, .openRouter: CatfolioTheme.services
        case .finnhub: CatfolioTheme.accent
        case .jev: CatfolioTheme.services
        }
    }

    func validate(apiKey: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await performValidation(apiKey: apiKey)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 35_000_000_000)
                throw LocalServiceError.remote(L10n.text("验证超时，请检查网络后重试"))
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw LocalServiceError.invalidResponse
            }
            return result
        }
    }

    private func performValidation(apiKey: String) async throws -> String {
        switch self {
        case .massive:
            let sessions = try await LocalMarketDataClient().testMassiveConnection(apiKey: apiKey)
            return L10n.text("连接成功，已读取 AAPL 的 \(sessions) 个交易日")
        case .fmp:
            return try await LocalReturnsAnalyticsClient().testFMPValuationConnection(apiKey: apiKey)
        case .deepSeek:
            try await LocalAIClient().testDeepSeekConnection(apiKey: apiKey)
            return L10n.text("连接成功，DeepSeek 模型列表可用")
        case .openRouter:
            try await LocalAIClient().testOpenRouterConnection(apiKey: apiKey)
            return L10n.text("连接成功，OpenRouter Key 可用")
        case .finnhub:
            let items = try await FinnhubNewsProvider.companyNews(symbol: "AAPL", days: 7, apiKey: apiKey)
            return L10n.text("连接成功，已读取 AAPL 的 \(items.count) 条新闻")
        case .jev:
            try await JEVClient(provider: .cloudflare, apiToken: apiKey).test()
            return L10n.text("连接成功，Jev 可用")
        }
    }
}

enum LocalServiceStatus: Equatable {
    case unconfigured
    case configured
    case verified

    var title: String {
        switch self {
        case .unconfigured: L10n.text("未配置")
        case .configured: L10n.text("已配置")
        case .verified: L10n.text("验证通过")
        }
    }

    var iconName: String {
        switch self {
        case .unconfigured: "circle"
        case .configured: "checkmark.circle"
        case .verified: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unconfigured: .secondary
        case .configured, .verified: CatfolioTheme.positive
        }
    }
}

/// Connection state belongs beside the entire provider description, aligned
/// with the disclosure arrow. At accessibility sizes it gets its own line.
private struct LocalServiceRowLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let iconName: String
    let title: String
    let subtitle: String
    let status: String
    let statusColor: Color

    private var statusText: some View {
        Text(status)
            .appText(.subheading)
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
    }

    var body: some View {
        SettingsRowContainer {
            HStack(alignment: .center, spacing: SettingsTemplate.iconSpacing) {
                VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                    SettingsRowLabel(icon: .symbol(iconName), title: title,
                        subtitle: subtitle, subtitleSpacing: 2)
                    if dynamicTypeSize.isAccessibilitySize {
                        statusText.padding(.leading, SettingsTemplate.iconSize + SettingsTemplate.iconSpacing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    statusText
                }
                SettingsChevron()
            }
        }
    }
}

private struct LocalServicesSettingsView: View {
    @Environment(\.locale) private var appLocale
    @AppStorage(AIProviderPreference.storageKey) private var aiProviderRaw = AIProviderPreference.automatic.rawValue
    @AppStorage(CodexOAuthClient.connectedStorageKey) private var codexConnected = false
    /// A provider opened by launch argument rather than a tap.
    @State private var routedProvider: LocalServiceProvider?
    @State private var statuses: [LocalServiceProvider: LocalServiceStatus] = [:]
    @State private var hasAppliedLaunchRoute = false

    @State private var showsAPISetupGuide = false

    /// A page of Settings' own stack, not a modal with a stack of its own.
    var body: some View {
            SettingsPage(
                title: L10n.text("服务商"),
                bottomInset: 32
            ) {
                SettingsCard {
                    SettingsButtonRow(icon: .symbol("list.number"), title: L10n.text("API 配置引导")) {
                        showsAPISetupGuide = true
                    }
                }

                SettingsSection(L10n.text("行情与估值")) {
                    providerLink(.massive)
                    providerLink(.fmp)
                }

                SettingsSection(L10n.text("新闻")) {
                    providerLink(.finnhub)
                }

                SettingsSectionHeader("AI")
                SettingsCard {
                    // The one row on these pages that is not a row: choosing a
                    // model is a choice between five — too many to segment on
                    // a phone — so the choice is a menu at the row's trailing
                    // edge. It sits on the card's own 20/16 padding so it
                    // lines up with every row under it.
                    SettingsRowContainer(minHeight: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(L10n.text("默认模型"))
                                    .appText(.label, weight: .medium)
                                    .foregroundStyle(SettingsTemplate.sectionHeader)
                                Spacer(minLength: 12)
                                Picker(L10n.text("默认模型"), selection: $aiProviderRaw) {
                                    ForEach(AIProviderPreference.allCases) { provider in
                                        Text(L10n.label(provider.title)).tag(provider.rawValue)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .padding(.trailing, -12)
                            }

                            Text(selectedAIProvider.detail)
                                .appText(.label, weight: .regular)
                                .foregroundStyle(SettingsTemplate.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            if selectedAIProvider == .automatic || selectedAIProvider == .apple {
                                Text(LocalAIClient.appleModelStatus.message)
                                    .appText(.label, weight: .medium)
                                    .foregroundStyle(
                                        LocalAIClient.appleModelStatus.isAvailable
                                            ? CatfolioTheme.positive
                                            : SettingsTemplate.secondaryText
                                    )
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    codexLink
                    providerLink(.openRouter)
                    providerLink(.deepSeek)
                    providerLink(.jev)
                }
            }
            .sheet(isPresented: $showsAPISetupGuide, onDismiss: refreshStatuses) {
                ServiceAPIOnboardingView()
            }
            .navigationDestination(item: $routedProvider) { provider in detail(provider) }
            .toolbarVisibility(.hidden, for: .tabBar)
            .onAppear {
                refreshStatuses()
                applyLaunchRouteIfNeeded()
            }
            .tint(CatfolioTheme.accent)
    }

    private func detail(_ provider: LocalServiceProvider) -> some View {
        LocalServiceDetailView(provider: provider) { status in
            statuses[provider] = status
        }
        .toolbarVisibility(.hidden, for: .tabBar)
    }

    private var selectedAIProvider: AIProviderPreference {
        AIProviderPreference(rawValue: aiProviderRaw) ?? .automatic
    }

    private var codexLink: some View {
        NavigationLink {
            CodexOAuthSettingsView()
                .toolbarVisibility(.hidden, for: .tabBar)
        } label: {
            LocalServiceRowLabel(iconName: "bubble.left.and.text.bubble.right",
                title: "ChatGPT Codex", subtitle: L10n.text("使用 ChatGPT 订阅进行组合问答"),
                status: codexConnected ? L10n.text("已连接") : L10n.text("未连接"),
                statusColor: codexConnected ? CatfolioTheme.positive : SettingsTemplate.readOnlyValue)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityLabel(L10n.text("ChatGPT Codex，使用 ChatGPT 订阅进行组合问答"))
        .accessibilityValue(codexConnected ? L10n.text("已连接") : L10n.text("未连接"))
    }

    private func providerLink(_ provider: LocalServiceProvider) -> some View {
        let status = statuses[provider] ?? .unconfigured
        return NavigationLink {
            detail(provider)
        } label: {
            LocalServiceRowLabel(iconName: provider.iconName,
                title: provider.shortTitle, subtitle: provider.purpose,
                status: status.title,
                statusColor: status == .unconfigured ? SettingsTemplate.readOnlyValue : status.color)
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("\(provider.title)，\(provider.purpose)"))
        .accessibilityValue(status.title)
        .accessibilityHint(L10n.text("打开服务商设置"))
    }

    private func refreshStatuses() {
        for provider in LocalServiceProvider.allCases {
            let key = KeychainStore.string(for: provider.keychainKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if statuses[provider] != .verified {
                statuses[provider] = key.isEmpty ? .unconfigured : .configured
            }
        }
    }

    private func applyLaunchRouteIfNeeded() {
        guard !hasAppliedLaunchRoute else { return }
        hasAppliedLaunchRoute = true
        let arguments = LaunchArguments.all
        if arguments.contains("--show-local-service-massive") {
            routedProvider = .massive
        } else if arguments.contains("--show-local-service-fmp") {
            routedProvider = .fmp
        } else if arguments.contains("--show-local-service-deepseek") {
            routedProvider = .deepSeek
        } else if arguments.contains("--show-local-service-openrouter") {
            routedProvider = .openRouter
        } else if arguments.contains("--show-local-service-finnhub") {
            routedProvider = .finnhub
        } else if arguments.contains("--show-local-service-jev") {
            routedProvider = .jev
        }
    }
}

private struct CodexOAuthSettingsView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @AppStorage(CodexOAuthClient.connectedStorageKey) private var connected = false
    @AppStorage(CodexOAuthClient.accountEmailStorageKey) private var accountEmail = ""
    @AppStorage(CodexOAuthClient.accountPlanStorageKey) private var accountPlan = ""

    @State private var loginSession: CodexLoginSession?
    @State private var isWorking = false
    @State private var feedback: LocalServiceFeedback?
    @State private var pollingTask: Task<Void, Never>?
    @State private var didCopyCode = false

    var body: some View {
        SettingsPage(
            title: "ChatGPT Codex",
            bottomInset: 32
        ) {
            SettingsSectionHeader(L10n.text("连接状态"))
            SettingsCard {
                SettingsRowContainer {
                    HStack(spacing: SettingsTemplate.iconSpacing) {
                        SettingsRowIcon(.symbol("bubble.left.and.text.bubble.right"))
                        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                            Text(connected ? L10n.text("已连接 ChatGPT") : L10n.text("尚未连接"))
                                .appText(.subheading)
                                .foregroundStyle(CatfolioTheme.primaryText)
                            if connected && (!accountEmail.isEmpty || !planLabel.isEmpty) {
                                Text([accountEmail, planLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .appText(.label, weight: .regular)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if let loginSession {
                SettingsSectionHeader(L10n.text("一次性验证码"))
                SettingsCard {
                    SettingsRowContainer {
                        HStack(spacing: SettingsTemplate.iconSpacing) {
                            Text(loginSession.userCode)
                                .font(.title2.monospaced().weight(.bold))
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button(didCopyCode ? L10n.text("已复制") : L10n.text("复制")) {
                                UIPasteboard.general.string = loginSession.userCode
                                didCopyCode = true
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                Task {
                                    try? await Task.sleep(for: .seconds(1.4))
                                    didCopyCode = false
                                }
                            }
                            .appText(.subheading)
                            .foregroundStyle(didCopyCode ? CatfolioTheme.positive : CatfolioTheme.accent)
                        }
                    }
                }

                Button(L10n.text("打开 ChatGPT 登录页"), systemImage: "safari") {
                    openURL(loginSession.verificationURL)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: SettingsTemplate.cardRadius))
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }

            if let feedback {
                StatusNotice(text: feedback.text, kind: feedback.kind)
            }

            if connected {
                SettingsCard {
                    SettingsButtonRow(
                        icon: .symbol("rectangle.portrait.and.arrow.right"),
                        title: isWorking ? L10n.text("正在断开…") : L10n.text("退出 ChatGPT"),
                        showsChevron: false,
                        showsProgress: isWorking,
                        role: .destructive,
                        action: logout
                    )
                    .disabled(isWorking)
                }
            } else {
                Button(action: startLogin) {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView().tint(.white) }
                        Text(isWorking ? L10n.text("等待网页授权…") : L10n.text("登录 ChatGPT"))
                            .appText(.subheading, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: SettingsTemplate.cardRadius))
                .disabled(isWorking)
            }
        }
        .task { await refreshStatus() }
        .onDisappear {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    private var planLabel: String {
        guard !accountPlan.isEmpty else { return "" }
        return accountPlan == "plus" ? "Plus" : accountPlan.capitalized
    }

    private func startLogin() {
        pollingTask?.cancel()
        isWorking = true
        feedback = nil
        pollingTask = Task {
            do {
                let client = CodexOAuthClient()
                let session = try await client.startLogin()
                guard !Task.isCancelled else { return }
                loginSession = session
                UIPasteboard.general.string = session.userCode
                openURL(session.verificationURL)
                try await waitForLogin(client: client, session: session)
            } catch is CancellationError {
                isWorking = false
            } catch {
                isWorking = false
                feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            }
            pollingTask = nil
        }
    }

    private func refreshStatus() async {
        do {
            let client = CodexOAuthClient()
            let status = try await client.status()
            connected = status.connected
            if status.pending,
               pollingTask == nil,
               let session = try client.pendingLoginSession() {
                loginSession = session
                resumeLogin(client: client, session: session)
            }
        } catch {
            connected = false
        }
    }

    private func resumeLogin(client: CodexOAuthClient, session: CodexLoginSession) {
        pollingTask?.cancel()
        isWorking = true
        feedback = LocalServiceFeedback(text: L10n.text("正在确认网页授权…"), kind: .info)
        pollingTask = Task {
            do {
                try await waitForLogin(client: client, session: session, pollImmediately: true)
            } catch is CancellationError {
                isWorking = false
            } catch {
                isWorking = false
                feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            }
            pollingTask = nil
        }
    }

    private func waitForLogin(
        client: CodexOAuthClient,
        session: CodexLoginSession,
        pollImmediately: Bool = false
    ) async throws {
        for attempt in 0..<150 {
            if !pollImmediately || attempt > 0 {
                try await Task.sleep(for: .seconds(session.intervalSeconds))
            }
            let status: CodexConnectionStatus
            do {
                status = try await client.status(loginID: session.loginID)
            } catch let error where CodexOAuthClient.isTransientNetworkError(error) {
                continue
            }
            guard !Task.isCancelled else { throw CancellationError() }
            if status.connected {
                connected = true
                loginSession = nil
                isWorking = false
                feedback = LocalServiceFeedback(text: L10n.text("ChatGPT 已连接"), kind: .success)
                return
            }
            if let error = status.error, !status.pending {
                throw LocalServiceError.remote(error)
            }
        }
        throw LocalServiceError.remote(L10n.text("登录等待超时，请重新开始"))
    }

    private func logout() {
        isWorking = true
        feedback = nil
        Task {
            do {
                try await CodexOAuthClient().logout()
                connected = false
                loginSession = nil
                feedback = LocalServiceFeedback(text: L10n.text("已退出 ChatGPT"), kind: .success)
            } catch {
                feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            }
            isWorking = false
        }
    }
}

private struct LocalServiceFeedback {
    let text: String
    let kind: StatusNotice.Kind
}

struct LocalServiceDetailView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    let provider: LocalServiceProvider
    let onStatusChanged: (LocalServiceStatus) -> Void

    @State private var apiKey = ""
    @State private var originalKey = ""
    @State private var revealsKey = false
    @State private var isTesting = false
    @State private var feedback: LocalServiceFeedback?
    @State private var showsRemoveConfirmation = false
    @State private var hasLoaded = false
    @State private var validationTask: Task<Void, Never>?
    @AppStorage(LocalServiceKeys.openRouterModel) private var openRouterModel = ""
    @AppStorage(LocalServiceKeys.deepSeekModel) private var deepSeekModel = ""
    @State private var showsModelPicker = false
    @AppStorage(LocalServiceKeys.cloudflareAccountIDKey) private var cloudflareAccountID = ""

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var modelBinding: Binding<String> {
        provider == .deepSeek ? $deepSeekModel : $openRouterModel
    }

    private var defaultModel: String {
        provider == .deepSeek ? LocalServiceKeys.defaultDeepSeekModel : LocalServiceKeys.defaultOpenRouterModel
    }

    private var keyPlaceholder: String {
        provider == .jev ? L10n.text("输入 Cloudflare API Token") : L10n.text("输入 \(provider.shortTitle) API Key")
    }

    var body: some View {
        SettingsPage(title: provider.shortTitle, bottomInset: 32) {
            SettingsSectionHeader(L10n.text("服务用途"))
            SettingsCard {
                SettingsRowContainer {
                    HStack(alignment: .top, spacing: SettingsTemplate.iconSpacing) {
                        SettingsRowIcon(.symbol(provider.iconName))
                        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                            Text(provider.title)
                                .appText(.subheading)
                                .foregroundStyle(CatfolioTheme.primaryText)
                            Text(provider.detail)
                                .appText(.label, weight: .regular)
                                .foregroundStyle(SettingsTemplate.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            SettingsSectionHeader(L10n.text("API 密钥"))
            SettingsCard {
                SettingsRowContainer {
                    HStack(spacing: SettingsTemplate.iconSpacing) {
                        Group {
                            if revealsKey {
                                TextField(keyPlaceholder, text: $apiKey)
                            } else {
                                SecureField(keyPlaceholder, text: $apiKey)
                            }
                        }
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .submitLabel(.done)

                        // On the icon artboard and in the row's own greys, so
                        // the control reads as part of the row rather than a
                        // tinted button dropped into it.
                        Button {
                            revealsKey.toggle()
                        } label: {
                            SettingsRowIcon(.symbol(revealsKey ? "eye.slash" : "eye"))
                                .foregroundStyle(SettingsTemplate.secondaryText)
                                .padding(.vertical, SettingsTemplate.rowVerticalPadding)
                                .contentShape(Rectangle())
                                .padding(.vertical, -SettingsTemplate.rowVerticalPadding)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(revealsKey ? L10n.text("隐藏 API 密钥") : L10n.text("显示 API 密钥"))
                    }
                }
                .disabled(isTesting)
            }
            SettingsFootnote(L10n.text("仅保存在此 iPhone 的 Keychain"))

            if provider == .jev {
                SettingsSectionHeader("Account ID")
                SettingsCard {
                    SettingsRowContainer {
                        TextField(L10n.text("Cloudflare Account ID"), text: $cloudflareAccountID)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                    }
                }
                SettingsFootnote(L10n.text("Account ID 和 API Token 可在 Cloudflare 控制台获取。"))
            }

            if AIModelCatalog.supports(provider) {
                SettingsSectionHeader(L10n.text("模型"))
                SettingsCard {
                    SettingsButtonRow(icon: .symbol("list.bullet.rectangle"), title: L10n.text("获取模型"),
                                      value: modelBinding.wrappedValue.isEmpty ? L10n.text("默认") : modelBinding.wrappedValue) {
                        showsModelPicker = true
                    }
                    .accessibilityIdentifier("local-service.model-picker")
                    SettingsRowContainer {
                        TextField(defaultModel, text: modelBinding)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.done)
                    }
                }
                SettingsFootnote(L10n.text("从服务商读取可用模型后选择，也可直接填写模型 ID；留空使用 \(defaultModel)。"))
            }

            if let feedback {
                StatusNotice(text: feedback.text, kind: feedback.kind)
            }

            VStack(spacing: 12) {
                Button {
                    startValidation()
                } label: {
                    HStack(spacing: 9) {
                        if isTesting {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isTesting ? L10n.text("正在验证…") : L10n.text("保存并验证"))
                            .appText(.subheading, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: SettingsTemplate.cardRadius))
                .tint(CatfolioTheme.accent)
                .disabled(trimmedKey.isEmpty || isTesting || (provider == .jev && cloudflareAccountID.trimmingCharacters(in: .whitespaces).isEmpty))
                .accessibilityLabel(isTesting ? L10n.text("正在验证") : L10n.text("保存并验证"))
                .accessibilityHint(L10n.text("保存 API 密钥并验证连接"))

                Button {
                    saveWithoutValidation()
                } label: {
                    Text(L10n.text("仅保存，不验证"))
                        .appText(.subheading, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: SettingsTemplate.cardRadius))
                .tint(CatfolioTheme.accent)
                .disabled(trimmedKey.isEmpty || isTesting)
                .accessibilityLabel(L10n.text("仅保存，不验证"))
                .accessibilityHint(L10n.text("保存 API 密钥但不验证连接"))
            }

            if !originalKey.isEmpty {
                SettingsCard {
                    SettingsButtonRow(
                        icon: .symbol("trash"),
                        title: L10n.text("移除此密钥"),
                        showsChevron: false,
                        role: .destructive
                    ) {
                        showsRemoveConfirmation = true
                    }
                    .disabled(isTesting)
                }
            }
        }
        .onAppear { loadKeyIfNeeded() }
        .onDisappear {
            validationTask?.cancel()
            validationTask = nil
        }
        .onChange(of: apiKey) { _, newValue in
            let edited = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if edited != originalKey { feedback = nil }
        }
        .appSheet(isPresented: $showsModelPicker) {
            AIModelPickerView(provider: provider, key: trimmedKey.isEmpty ? nil : trimmedKey,
                              defaultModel: defaultModel, selection: modelBinding)
        }
        .confirmationDialog(
            L10n.text("移除 \(provider.title) 密钥？"),
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("移除密钥"), role: .destructive) { removeKey() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("移除后，依赖此服务的数据可能无法加载。"))
        }
    }

    private func loadKeyIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let saved = KeychainStore.string(for: provider.keychainKey) ?? ""
        apiKey = saved
        originalKey = saved
    }

    @MainActor
    private func saveAndValidate() async {
        guard !trimmedKey.isEmpty else { return }
        let candidate = trimmedKey
        isTesting = true
        feedback = nil
        defer { isTesting = false }

        do {
            let message = try await provider.validate(apiKey: candidate)
            try Task.checkCancellation()
            do {
                try KeychainStore.set(candidate, for: provider.keychainKey)
            } catch {
                let saveMessage = L10n.text("连接已验证，但无法保存到 Keychain：\(error.localizedDescription)")
                feedback = LocalServiceFeedback(text: saveMessage, kind: .error)
                announce(saveMessage)
                return
            }
            originalKey = candidate
            if provider == .fmp {
                await LocalReturnsAnalyticsClient.resetFailedFundamentalAttempts()
            }
            feedback = LocalServiceFeedback(text: message, kind: .success)
            onStatusChanged(.verified)
            announce(message)
            ToastCenter.shared.show(L10n.text("已验证并保存"))
        } catch is CancellationError {
            return
        } catch {
            let suffix = originalKey.isEmpty ? L10n.text("未保存这次输入。") : L10n.text("原密钥未更改。")
            let message = "\(error.localizedDescription) \(suffix)"
            feedback = LocalServiceFeedback(text: message, kind: .error)
            announce(L10n.text("验证失败。\(message)"))
            ToastCenter.shared.show(L10n.text("验证失败"), kind: .error)
        }
    }

    private func startValidation() {
        guard !isTesting else { return }
        validationTask?.cancel()
        validationTask = Task { await saveAndValidate() }
    }

    private func saveWithoutValidation() {
        guard !trimmedKey.isEmpty else { return }
        do {
            try KeychainStore.set(trimmedKey, for: provider.keychainKey)
            originalKey = trimmedKey
            feedback = LocalServiceFeedback(text: L10n.text("已安全保存到此 iPhone"), kind: .success)
            onStatusChanged(.configured)
            if provider == .fmp {
                Task { await LocalReturnsAnalyticsClient.resetFailedFundamentalAttempts() }
            }
            ToastCenter.shared.show(L10n.text("密钥已保存"))
        } catch {
            feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            announce(L10n.text("保存失败。\(error.localizedDescription)"))
            ToastCenter.shared.show(L10n.text("保存失败"), kind: .error)
        }
    }

    private func removeKey() {
        do {
            try KeychainStore.set("", for: provider.keychainKey)
            apiKey = ""
            originalKey = ""
            revealsKey = false
            feedback = LocalServiceFeedback(text: L10n.text("密钥已从此 iPhone 移除"), kind: .info)
            onStatusChanged(.unconfigured)
            if provider == .fmp {
                Task { await LocalReturnsAnalyticsClient.resetFailedFundamentalAttempts() }
            }
            ToastCenter.shared.show(L10n.text("密钥已移除"), kind: .info)
        } catch {
            feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            announce(L10n.text("移除失败。\(error.localizedDescription)"))
        }
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

/// The tinted rounded-square an iOS settings row puts its symbol in.
///
/// The rows previously drew a bare tinted glyph, which left each symbol a
/// different optical weight and width — a `globe` outline and a
/// `chart.pie.fill` next to each other read as two different kinds of
/// control. Boxing them equalises that: the tile is the constant, the symbol
/// varies inside it, and the row's text starts at the same x every time.

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

/// Which feeds news leads come from, which sites never count, and how each
/// holding is searched. Read by the attention scan, a security's
/// developments and today's move alike, from the next refresh on.
private struct NewsSettingsView: View {
    @AppStorage(NewsProvider.googleNews.enabledKey) private var googleNews = true
    @AppStorage(NewsProvider.yahooFinance.enabledKey) private var yahooFinance = true
    @AppStorage(NewsProvider.secEdgar.enabledKey) private var secEdgar = true
    @AppStorage(NewsProvider.gdelt.enabledKey) private var gdelt = true
    @AppStorage(NewsProvider.finnhub.enabledKey) private var finnhub = true
    @AppStorage(NewsSettings.queryPlanKey) private var usesQueryPlan = true
    @AppStorage(NewsSettings.readsArticlesKey) private var readsArticles = true
    @AppStorage(AttentionEvidenceRules.excludeAggregatorsKey) private var excludesAggregators = true
    @AppStorage(NewsSettings.blockedSitesKey) private var blockedSitesText = ""
    @State private var newSite = ""
    @State private var hasFinnhubKey = LocalServiceKeys.hasFinnhubKey
    @FocusState private var addsSite: Bool

    private var blockedSites: [String] { NewsSettings.sites(from: blockedSitesText) }

    var body: some View {
        SettingsPage(title: L10n.text("新闻"), bottomInset: 32) {
            SettingsSection(L10n.text("新闻来源")) {
                toggle(.googleNews, isOn: $googleNews)
                toggle(.yahooFinance, isOn: $yahooFinance)
                toggle(.secEdgar, isOn: $secEdgar)
                toggle(.gdelt, isOn: $gdelt)
                if hasFinnhubKey {
                    toggle(.finnhub, isOn: $finnhub)
                } else {
                    SettingsNavigationRow(
                        icon: .symbol(NewsProvider.finnhub.iconName),
                        title: NewsProvider.finnhub.title,
                        value: L10n.text("需要密钥"),
                        valueColor: SettingsTemplate.readOnlyValue
                    ) {
                        LocalServiceDetailView(provider: .finnhub) { _ in
                            hasFinnhubKey = LocalServiceKeys.hasFinnhubKey
                        }
                    }
                }
            }
            SettingsSection(L10n.text("搜索方式")) {
                SettingsToggleRow(
                    icon: .symbol("list.bullet.indent"),
                    title: L10n.text("补充诉讼与财报搜索"),
                    isOn: $usesQueryPlan
                )
                SettingsToggleRow(
                    icon: .symbol("doc.text.magnifyingglass"),
                    title: L10n.text("分析时阅读正文"),
                    isOn: $readsArticles
                )
            }

            SettingsSection(L10n.text("屏蔽网站")) {
                SettingsToggleRow(
                    icon: .symbol("arrow.triangle.2.circlepath"),
                    title: L10n.text("排除转述网站"),
                    isOn: $excludesAggregators
                )
                ForEach(blockedSites, id: \.self) { site in
                    SettingsRowContainer {
                        HStack(spacing: SettingsTemplate.iconSpacing) {
                            SettingsRowIcon(.symbol("nosign"))
                                .foregroundStyle(SettingsTemplate.secondaryText)
                            Text(site)
                                .appText(.subheading)
                                .foregroundStyle(CatfolioTheme.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button {
                                remove(site)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 20))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(CatfolioTheme.danger)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("取消屏蔽 \(site)"))
                        }
                    }
                }
                SettingsRowContainer {
                    HStack(spacing: SettingsTemplate.iconSpacing) {
                        SettingsRowIcon(.symbol("plus"))
                            .foregroundStyle(SettingsTemplate.secondaryText)
                        TextField(L10n.text("网站名称或域名，如 fool.com"), text: $newSite)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.done)
                            .focused($addsSite)
                            .onSubmit(add)
                        if !NewsSettings.normalizedSite(newSite).isEmpty {
                            Button(L10n.text("添加"), action: add)
                                .appText(.subheading, weight: .semibold)
                                .foregroundStyle(CatfolioTheme.accent)
                        }
                    }
                }
            }
            SettingsFootnote(L10n.text("下次刷新分析时生效。"))
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { hasFinnhubKey = LocalServiceKeys.hasFinnhubKey }
    }

    private func toggle(_ provider: NewsProvider, isOn: Binding<Bool>) -> some View {
        SettingsToggleRow(
            icon: .symbol(provider.iconName),
            title: provider.title,
            isOn: isOn
        )
    }

    private func add() {
        let site = NewsSettings.normalizedSite(newSite)
        guard !site.isEmpty else { return }
        if !blockedSites.contains(site) {
            blockedSitesText = (blockedSites + [site]).joined(separator: "\n")
        }
        newSite = ""
        addsSite = false
    }

    private func remove(_ site: String) {
        blockedSitesText = blockedSites.filter { $0 != site }.joined(separator: "\n")
    }
}

/// Previews and lab pages, kept out of the settings a reader uses.
private struct SettingsTestView: View {
    @Environment(AppModel.self) private var model
    @State private var showsFirstLaunchGuide = false
    @State private var showsPaywall = false

    var body: some View {
        SettingsPage(bottomInset: 32, topInset: SettingsTemplate.sectionSpacing) {
            SettingsSection(L10n.text("流程")) {
                SettingsButtonRow(icon: .symbol("play.rectangle"), title: L10n.text("首次进入引导")) {
                    showsFirstLaunchGuide = true
                }
                .accessibilityIdentifier("settings-test-first-launch-guide")
                SettingsButtonRow(icon: .symbol("crown"), title: L10n.text("付费墙")) {
                    showsPaywall = true
                }
                .accessibilityIdentifier("settings-test-paywall")
            }
            SettingsSection(L10n.text("实验页面")) {
                SettingsNavigationRow(icon: .symbol("cube"), title: L10n.text("等距热力图")) {
                    IsometricHeatmapLabView().environment(model)
                }
                SettingsNavigationRow(icon: .symbol("chart.bar.xaxis"), title: L10n.text("OI 布局验证")) {
                    ScrollView { OptionsOIView(symbol: "TEST", currency: "USD", price: 108, costUSD: 104).padding(24) }
                        .softTopScrollEdge()
                        .navigationTitle(L10n.text("OI 布局验证"))
                }
            }
        }
        .navigationTitle(L10n.text("测试"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: $showsPaywall) { PaywallView() }
        .fullScreenCover(isPresented: $showsFirstLaunchGuide) {
            // Reuse the launch flow without resetting its seen flag or any credentials.
            ServiceAPIOnboardingView()
        }
    }
}

/// Experimental features: reachable, but not yet on the pages they belong to.
private struct SettingsLabView: View {
    @Environment(AppModel.self) private var model
    @State private var showsPolicyComposer = LaunchArguments.contains("--show-policy-composer")

    var body: some View {
        SettingsPage(bottomInset: 32, topInset: SettingsTemplate.sectionSpacing) {
            SettingsCard {
                SettingsNavigationRow(icon: .symbol(ReturnsChartDestination.valuation.icon),
                                      title: ReturnsChartDestination.valuation.title) {
                    ReturnsChartPage(chart: .valuation).environment(model)
                }
                .accessibilityIdentifier("lab.valuation")
                SettingsNavigationRow(icon: .symbol("line.3.horizontal.decrease"), title: L10n.text("AI 持仓筛选")) {
                    StockScreenerView().environment(model)
                }
                .accessibilityIdentifier("lab.screener")
                SettingsButtonRow(icon: .symbol("slider.horizontal.3"), title: L10n.text("策略编曲家")) {
                    showsPolicyComposer = true
                }
                .accessibilityIdentifier("lab.policy-composer")
                SettingsValueRow(icon: .symbol("number.square"), title: L10n.text("税务计算"), value: nil)
                    .disabled(true)
                    .accessibilityHint(L10n.text("功能暂未开放"))
            }
        }
        .navigationTitle(L10n.text("Lab 实验室"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .appFullScreenCover(isPresented: $showsPolicyComposer) {
            PolicyComposerEntry().environment(model)
        }
    }
}

/// The provider's current models, read when the sheet opens, searchable;
/// a tap picks one and closes.
private struct AIModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let provider: LocalServiceProvider
    /// The key typed on the page, before it is saved; else the stored one.
    let key: String?
    let defaultModel: String
    @Binding var selection: String
    @State private var models: [AIModelOption] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var error: String?

    private var filtered: [AIModelOption] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(text) || $0.name.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(id: "", title: L10n.text("默认（\(defaultModel)）"), subtitle: nil)
                }
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.text("正在获取模型…")).foregroundStyle(.secondary)
                    }
                } else if let error {
                    Section {
                        Text(L10n.message(error)).foregroundStyle(.secondary)
                        Button(L10n.text("重试")) { Task { await load() } }
                    }
                } else {
                    Section(L10n.text("\(models.count) 个模型")) {
                        ForEach(filtered) { model in
                            row(id: model.id, title: model.name, subtitle: model.name == model.id ? nil : model.id)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: L10n.text("搜索模型"))
            .navigationTitle(L10n.text("选择模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { AppModalDoneButton { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func row(id: String, title: String, subtitle: String?) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(CatfolioTheme.primaryText)
                    if let subtitle {
                        Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if selection.trimmingCharacters(in: .whitespacesAndNewlines) == id {
                    Image(systemName: "checkmark").foregroundStyle(CatfolioTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        error = nil
        let storedKey = KeychainStore.string(for: provider.keychainKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            models = try await AIModelCatalog.fetch(provider, key: key ?? storedKey)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
