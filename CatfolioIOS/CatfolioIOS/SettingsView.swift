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
    @AppStorage(HomeBackgroundStyle.preferenceKey) private var homeBackgroundStyleRawValue = HomeBackgroundStyle.defaultStyle.rawValue
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
                    value: HomeBackgroundStyle(rawValue: homeBackgroundStyleRawValue)?.title ?? HomeBackgroundStyle.defaultStyle.title,
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
                SectorRotationView().hidesTabBarWhenPushed()
            }
            .navigationDestination(isPresented: $showsStockChartsPreview) {
                StockChartsRotationView().hidesTabBarWhenPushed()
            }
            .navigationDestination(isPresented: $showsScreenerPreview) {
                StockScreenerView().hidesTabBarWhenPushed()
            }
            .navigationDestination(isPresented: $showsHistoryPreview) { HistoryView().environment(model) }
            .navigationDestination(isPresented: $showsSentimentPreview) { IndustrySentimentView().environment(model) }
            .navigationDestination(isPresented: $showsResearchPreview) { TodayAttentionView().environment(model) }
            .navigationDestination(isPresented: $showsOIPreview) {
                ScrollView { OptionsOIView(symbol: "TEST", currency: "USD", price: 108, costUSD: 104).padding(24) }
                    .softTopScrollEdge()
                    .navigationTitle(L10n.text("OI 布局验证"))
                    .hidesTabBarWhenPushed()
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
