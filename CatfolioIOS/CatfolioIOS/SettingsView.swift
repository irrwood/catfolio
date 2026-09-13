import SwiftUI
import UIKit

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
    @AppStorage(AppLanguage.preferenceKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage("catfolio.haptics") private var hapticsEnabled = true
    @AppStorage(AppAppearance.preferenceKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrencyRawValue = DisplayCurrency.usd.rawValue
    @AppStorage(CompanyNameDisplay.preferenceKey) private var companyNameDisplayRawValue = CompanyNameDisplay.original.rawValue
    @State private var showsCSVImport = false
    @State private var showsTrading212 = false
    @State private var showsIBKRFlex = false
    @State private var showsMoomooOAuth = false
    @State private var showsLocalServices = false
    @State private var showsPortfolioResetConfirmation = false
    @State private var isResettingPortfolio = false
    @State private var portfolioResetError: String?
    @State private var reconciliation: LedgerReconciliation.Report?
    #if DEBUG
    @State private var showsRotationPreview = ProcessInfo.processInfo.arguments.contains("--show-sector-rotation")
    @State private var showsStockChartsPreview = ProcessInfo.processInfo.arguments.contains("--show-stockcharts-rrg")
    @State private var showsScreenerPreview = ProcessInfo.processInfo.arguments.contains("--show-screener")
    @State private var showsHistoryPreview = ProcessInfo.processInfo.arguments.contains("--show-history-preview")
    @State private var showsResearchPreview = ProcessInfo.processInfo.arguments.contains("--preview-research-analysis")
    @State private var showsOIPreview = ProcessInfo.processInfo.arguments.contains("--preview-options-oi")
    @State private var showsIsometricHeatmap = ProcessInfo.processInfo.arguments.contains("--show-isometric-heatmap")
    #endif

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        SettingsPage {
            PublicInvestorSettingsSection()

            if !model.accounts.isEmpty {
                SettingsSection(L10n.text("账户范围")) {
                    allAccountsRow
                    ForEach(model.accounts) { account in
                        accountScopeRow(account)
                    }
                }

                SettingsSection(L10n.text("账户活动")) {
                    SettingsNavigationRow(
                        // The drawing's 账单 row, down to the 2pt between its
                        // two lines: an icon, what the page is, and what it
                        // tracks.
                        icon: .asset("SettingsInvoice"),
                        title: L10n.text("History"),
                        subtitle: L10n.text("跨账户资产活动流水"),
                        subtitleSpacing: 2
                    ) {
                        HistoryView().environment(model)
                    }
                }
                SettingsHistoryOverview()
            }

            SettingsSection(L10n.text("新建账户")) {
                connector("Trading 212", detail: L10n.text("使用只读 API 创建账户"), icon: "chart.line.uptrend.xyaxis") {
                    showsTrading212 = true
                }
                connector("Moomoo", detail: L10n.text("通过 OAuth 授权创建账户"), icon: "person.badge.key") {
                    showsMoomooOAuth = true
                }
                connector("Interactive Brokers", detail: L10n.text("使用 Flex Web Service 创建账户"), icon: "doc.text") {
                    showsIBKRFlex = true
                }
                connector(L10n.text("CSV 导入"), detail: L10n.text("从交易记录创建账户"), icon: "doc.badge.plus") {
                    showsCSVImport = true
                }
                // An entry only for now: shown so the direction is visible,
                // disabled like the photo row below until it is built.
                SettingsButtonRow(
                    icon: .symbol("link"),
                    title: L10n.text("连接交易所账户"),
                    subtitle: L10n.text("支持 1000+ 家交易所，即将开放"),
                    subtitleSpacing: 2,
                    action: {}
                )
                .disabled(true)
                .accessibilityHint(L10n.text("功能暂未开放"))
                SettingsButtonRow(
                    icon: .symbol("camera"),
                    title: L10n.text("拍照 AI 添加持仓"),
                    subtitle: L10n.text("本地模型识别添加，需 iOS 27 支持"),
                    subtitleSpacing: 2,
                    action: {}
                )
                .disabled(true)
                .accessibilityHint(L10n.text("功能暂未开放"))
            }

            SettingsSection(L10n.text("行情与 AI")) {
                SettingsNavigationRow(icon: .symbol("sparkles"), title: L10n.text("今天值得关注")) {
                    TodayAttentionView().environment(model)
                }
                .accessibilityIdentifier("settings.today-attention")
                connector(L10n.text("服务商"), detail: L10n.text("行情、估值与 AI 密钥"), icon: "key") {
                    showsLocalServices = true
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

            SettingsSection(L10n.text("实验")) {
                SettingsNavigationRow(
                    icon: .symbol("square.3.layers.3d"),
                    title: L10n.text("等距热力图"),
                    subtitle: L10n.text("渐进模糊与缓慢平移"),
                    subtitleSpacing: 2
                ) {
                    IsometricHeatmapLabView().environment(model)
                }
                .accessibilityIdentifier("settings.isometric-heatmap")
            }

            SettingsSection(L10n.text("关于")) {
                SettingsValueRow(
                    icon: .symbol("info.circle"),
                    title: L10n.text("版本"),
                    value: appVersion,
                    valueIsNumeric: true
                )
            }
        }
        .tracksRootTabBarScroll()
            .accessibilityIdentifier("settings-root")
            #if DEBUG
            .navigationDestination(isPresented: $showsRotationPreview) { SectorRotationView() }
            .navigationDestination(isPresented: $showsStockChartsPreview) { StockChartsRotationView() }
            .navigationDestination(isPresented: $showsScreenerPreview) { StockScreenerView() }
            .navigationDestination(isPresented: $showsHistoryPreview) { HistoryView().environment(model) }
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
            }
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                showsCSVImport = arguments.contains("--show-csv")
                showsTrading212 = arguments.contains("--show-trading212")
                showsIBKRFlex = arguments.contains("--show-flex")
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
                Text(portfolioResetError ?? "")
            }
            .sheet(isPresented: $showsCSVImport) {
                CSVImportView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsTrading212) {
                Trading212View(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsIBKRFlex) {
                IBKRFlexView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsMoomooOAuth) {
                MoomooOAuthView(context: .create).environment(model)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
        .sheet(isPresented: $showsLocalServices) {
            LocalServicesSettingsView()
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
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

    private func accountScopeRow(_ account: PortfolioAccount) -> some View {
        let isSelected = model.selectedAccountKeys.contains(account.id)
        return SettingsSelectionRow(
            isSelected: isSelected,
            title: account.localizedDisplayName,
            subtitle: account.awaitsFirstSync
                ? (model.isPublicInvestorMode ? L10n.text("暂无数据") : L10n.text("等待首次同步"))
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

    /// A row that opens a broker flow in a sheet. The subtitle stacks at 2
    /// rather than 4 — the drawing sets a one-line explanation that tight, and
    /// reserves 4 for the two-line account rows where the second line is a
    /// figure.
    private func connector(
        _ title: String,
        detail: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        SettingsButtonRow(
            icon: .symbol(icon),
            title: title,
            subtitle: detail,
            subtitleSpacing: 2,
            action: action
        )
    }
}

private enum AccountManagementSheet: String, Identifiable {
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

                SettingsValueRow(title: L10n.text("账户类型"), value: L10n.label(account.accountType), valueIsNumeric: false)
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
            Text(notice.message)
        }
        .sheet(item: $activeSheet) { sheet in
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
        case "IBKR Flex": .ibkr
        default: .csv
        }
    }

    private var primarySourceTitle: String {
        switch account.source {
        case "Trading 212": L10n.text("Trading 212 同步")
        case "Moomoo": L10n.text("Moomoo 同步")
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

/// Uses the same prepared ledger and fund charges as History, across all
/// accounts and years. Display currency remains a presentation preference.
private struct SettingsHistoryOverview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrency = DisplayCurrency.usd.rawValue
    @State private var prepared: HistoryPreparedLedger?
    @State private var annualFees: Double?
    /// This calendar year's dividends: received so far, plus what today's
    /// holdings paid over the rest of the year last year.
    @State private var dividendForecast: Double?
    @State private var failed = false

    private struct LoadKey: Hashable {
        let updatedAt: Date?
        let accountIDs: Set<String>
        let investorSelection: String
        let locale: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                     count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                overviewCard(.orders, title: L10n.text("已实现盈亏"), icon: "arrow.up.arrow.down",
                             caption: realisedCaption, amount: realisedAmount, signed: true)
                overviewCard(.dividends, title: L10n.text("Total dividends"), icon: "banknote",
                             caption: dividendForecastCaption, amount: total(for: .dividends))
                overviewCard(.interest, title: L10n.text("Total interest"), icon: "percent",
                             caption: "", amount: total(for: .interest))
                overviewCard(.fees, title: L10n.text("年费用合计"), icon: "creditcard",
                             caption: "", amount: annualFees)
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
        .task(id: LoadKey(updatedAt: model.localUpdatedAt,
                          accountIDs: Set(model.accounts.map(\.id)),
                          investorSelection: model.publicInvestorSelection, locale: locale.identifier)) {
            await load()
        }
    }

    private var realisedAmount: Double? {
        guard let calculation = prepared?.realisedTotal,
              calculation.brokerCount + calculation.estimatedCount > 0 else { return nil }
        return calculation.combinedUSD
    }

    private var dividendForecastCaption: String {
        guard let dividendForecast, dividendForecast.isFinite, dividendForecast > 0 else { return "" }
        let currency = DisplayCurrency(rawValue: displayCurrency) ?? .usd
        let amount = DisplayFormat.money(currency.fromUSD(dividendForecast), currency: currency.rawValue, fractionDigits: 0)
        return L10n.text("今年预计 \(amount)")
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
            SectorGlassCard(title: title, icon: icon, caption: caption, value: value,
                            tint: .clear, valueColor: color, usesGlass: false)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(caption.isEmpty ? value : "\(caption) · \(value)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("settings.history-overview.\(category.rawValue.lowercased())")
    }

    @MainActor
    private func load() async {
        prepared = nil
        annualFees = nil
        dividendForecast = nil
        failed = false
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
            if let positions {
                // After the cards are up: the schedules are a request per
                // holding, the first time each day.
                let year = String(DayDateCodec.string(from: Date()).prefix(4))
                let received = result.page(category: .dividends, basis: .calendar, year: year).totalUSD
                let remaining = await LocalMarketDataClient().remainingDividends(for: positions)
                try Task.checkCancellation()
                if remaining.covered > 0 || received > 0 { dividendForecast = received + remaining.usd }
            }
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

private struct AccountTransactionsView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    let account: PortfolioAccount
    @State private var transactions: [LocalTransactionRecord] = []
    @State private var errorMessage: String?
    @State private var isSyncingHistory = false
    @State private var syncMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView(
                    L10n.text("无法读取交易"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if transactions.isEmpty {
                ContentUnavailableView(
                    L10n.text("暂无交易记录"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(L10n.text("可以通过同步、CSV 导入或手动补充添加历史交易。"))
                )
            } else {
                List(transactions) { transaction in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(transaction.ticker)
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text(actionTitle(transaction.action))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(
                                    transaction.action.uppercased() == "SELL"
                                        ? CatfolioTheme.danger
                                        : CatfolioTheme.positive
                                )
                        }
                        HStack {
                            Text(transaction.date)
                            Spacer()
                            Text(transactionDetail(transaction))
                                .appNumber(.caption)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(CatfolioTheme.settingsBackground)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isSyncingHistory, let syncMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(syncMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .background(CatfolioTheme.settingsBackground)
        .tint(CatfolioTheme.accent)
        .softTopScrollEdge()
        .navigationTitle(L10n.text("交易记录"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: account.id) {
            await loadLocalTransactions()
            await synchronizeTrading212History()
        }
        .refreshable { await synchronizeTrading212History() }
    }

    private func actionTitle(_ action: String) -> String {
        switch action.uppercased() {
        case "BUY": L10n.text("买入")
        case "SELL": L10n.text("卖出")
        case "DIVIDEND": L10n.text("股息")
        case "INTEREST": L10n.text("利息")
        default: action
        }
    }

    private func transactionDetail(_ transaction: LocalTransactionRecord) -> String {
        if transaction.action.uppercased() == "DIVIDEND"
            || transaction.action.uppercased() == "INTEREST" {
            return "+\(DisplayFormat.money(transaction.quantity * transaction.price, currency: transaction.currency))"
        }
        return "\(DisplayFormat.shares(transaction.quantity)) × \(DisplayFormat.money(transaction.price, currency: transaction.currency))"
    }

    private func loadLocalTransactions() async {
        do {
            transactions = try await model.transactions(for: account.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func synchronizeTrading212History() async {
        guard account.source == "Trading 212",
              !isSyncingHistory,
              let accountID = account.accountID,
              let slot = Int(accountID.replacingOccurrences(of: "account-", with: "")),
              let apiKey = KeychainStore.string(for: "trading212.account-\(slot).api-key"),
              let apiSecret = KeychainStore.string(for: "trading212.account-\(slot).api-secret"),
              !apiKey.isEmpty,
              !apiSecret.isEmpty else { return }

        isSyncingHistory = true
        syncMessage = L10n.text("正在补齐 Trading 212 成交、分红与利息…")
        defer { isSyncingHistory = false }

        do {
            let credentials = try Trading212Credentials(apiKey: apiKey, apiSecret: apiSecret)
            let environment = UserDefaults.standard.string(forKey: "trading212.environment")
                .flatMap(Trading212Environment.init(rawValue:)) ?? .live
            while !Task.isCancelled {
                let snapshot = try await Trading212Client().fetchSnapshot(
                    accounts: [Trading212AccountCredentials(slot: slot, credentials: credentials)],
                    environment: environment
                )
                _ = try await model.importTrading212(
                    snapshot,
                    accountNames: [accountID: account.name],
                    replacingAccountsOnly: true
                )
                await loadLocalTransactions()
                if snapshot.hasCompleteTransactionHistory {
                    syncMessage = nil
                    return
                }
                syncMessage = snapshot.transactionHistoryStatus
                    ?? L10n.text("历史记录较多，正在等待下一批…")
                try await Task.sleep(for: .seconds(62))
            }
        } catch is CancellationError {
            return
        } catch {
            syncMessage = L10n.text("同步失败：\(error.localizedDescription)")
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

private enum LocalServiceProvider: String, CaseIterable, Identifiable, Hashable {
    case massive
    case fmp
    case deepSeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .massive: "Massive"
        case .fmp: "Financial Modeling Prep"
        case .deepSeek: "DeepSeek"
        }
    }

    var shortTitle: String {
        switch self {
        case .fmp: "FMP"
        default: title
        }
    }

    var purpose: String {
        switch self {
        case .massive: L10n.text("美股成交量与历史行情")
        case .fmp: L10n.text("估值矩阵与行情备用")
        case .deepSeek: L10n.text("云端问答与自动回退")
        }
    }

    var detail: String {
        switch self {
        case .massive:
            L10n.text("读取美股日线价格与成交量，用于计算成交量分布、VAH、POC 和 VAL。")
        case .fmp:
            L10n.text("读取估值矩阵需要的 P/E、EPS 与营收成长数据，并作为历史行情备用。")
        case .deepSeek:
            L10n.text("选择 DeepSeek 或自动模式需要回退时，组合摘要和问题会直接发送给 DeepSeek，不经过 Mac 或 Catfolio 服务端。")
        }
    }

    var keychainKey: String {
        switch self {
        case .massive: LocalServiceKeys.massive
        case .fmp: LocalServiceKeys.fmp
        case .deepSeek: LocalServiceKeys.deepSeek
        }
    }

    var iconName: String {
        switch self {
        case .massive: "chart.bar.xaxis"
        case .fmp: "chart.xyaxis.line"
        case .deepSeek: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .massive: CatfolioTheme.accent
        case .fmp: CatfolioTheme.warning
        case .deepSeek: CatfolioTheme.services
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
        }
    }
}

private enum LocalServiceStatus: Equatable {
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

private struct LocalServicesSettingsView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AIProviderPreference.storageKey) private var aiProviderRaw = AIProviderPreference.automatic.rawValue
    @AppStorage(CodexOAuthClient.connectedStorageKey) private var codexConnected = false
    @State private var path: [LocalServiceProvider] = []
    @State private var statuses: [LocalServiceProvider: LocalServiceStatus] = [:]
    @State private var hasAppliedLaunchRoute = false

    var body: some View {
        NavigationStack(path: $path) {
            SettingsPage(
                title: L10n.text("服务商"),
                subtitle: L10n.text("行情、估值与 AI 密钥"),
                bottomInset: 32
            ) {
                SettingsFootnote(L10n.text("行情密钥和 ChatGPT 登录都只保存在此 iPhone。"))

                SettingsSection(L10n.text("行情与估值")) {
                    providerLink(.massive)
                    providerLink(.fmp)
                }
                SettingsFootnote(L10n.text("Yahoo Finance 无需密钥；自动用于回撤与历史价格，也会在 Massive 不可用时补充成交量行情。"))

                SettingsSectionHeader("AI")
                SettingsCard {
                    // The one row on these pages that is not a row: choosing a
                    // model is a choice between three, and a segmented control
                    // shows all three at once. It sits on the card's own 20/16
                    // padding so it lines up with every row under it.
                    SettingsRowContainer(minHeight: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.text("默认模型"))
                                .appText(.label, weight: .medium)
                                .foregroundStyle(SettingsTemplate.sectionHeader)

                            Picker(L10n.text("默认模型"), selection: $aiProviderRaw) {
                                ForEach(AIProviderPreference.allCases) { provider in
                                    Text(L10n.label(provider.title)).tag(provider.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

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
                    providerLink(.deepSeek)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("完成")) { dismiss() }
                }
            }
            .navigationDestination(for: LocalServiceProvider.self) { provider in
                LocalServiceDetailView(provider: provider) { status in
                    statuses[provider] = status
                }
            }
            .onAppear {
                refreshStatuses()
                applyLaunchRouteIfNeeded()
            }
        }
        .tint(CatfolioTheme.accent)
    }

    private var selectedAIProvider: AIProviderPreference {
        AIProviderPreference(rawValue: aiProviderRaw) ?? .automatic
    }

    private var codexLink: some View {
        SettingsNavigationRow(
            icon: .symbol("bubble.left.and.text.bubble.right"),
            title: "ChatGPT Codex",
            subtitle: L10n.text("使用 ChatGPT 订阅进行组合问答"),
            subtitleSpacing: 2,
            value: codexConnected ? L10n.text("已连接") : L10n.text("未连接"),
            valueColor: codexConnected ? CatfolioTheme.positive : SettingsTemplate.readOnlyValue
        ) {
            CodexOAuthSettingsView()
        }
        .accessibilityLabel(L10n.text("ChatGPT Codex，使用 ChatGPT 订阅进行组合问答"))
        .accessibilityValue(codexConnected ? L10n.text("已连接") : L10n.text("未连接"))
    }

    private func providerLink(_ provider: LocalServiceProvider) -> some View {
        let status = statuses[provider] ?? .unconfigured
        // Pushed by value, so a launch argument can route straight to one
        // provider. The row is otherwise the template's navigation row.
        return NavigationLink(value: provider) {
            SettingsRowContainer {
                HStack(spacing: SettingsTemplate.iconSpacing) {
                    SettingsRowLabel(
                        icon: .symbol(provider.iconName),
                        title: provider.shortTitle,
                        subtitle: provider.purpose,
                        subtitleSpacing: 2,
                        value: status.title,
                        valueColor: status == .unconfigured ? SettingsTemplate.readOnlyValue : status.color,
                        valueIsNumeric: false
                    )
                    SettingsChevron()
                }
            }
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.title)，\(provider.purpose)")
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
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-local-service-massive") {
            path = [.massive]
        } else if arguments.contains("--show-local-service-fmp") {
            path = [.fmp]
        } else if arguments.contains("--show-local-service-deepseek") {
            path = [.deepSeek]
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
            subtitle: connected ? L10n.text("已连接 ChatGPT") : L10n.text("尚未连接"),
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
                                .foregroundStyle(.primary)
                            Text(connected
                                ? [accountEmail, planLabel].filter { !$0.isEmpty }.joined(separator: " · ")
                                : L10n.text("授权令牌保存在此 iPhone 的 Keychain 中。"))
                                .appText(.label, weight: .regular)
                                .foregroundStyle(SettingsTemplate.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
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

private struct LocalServiceDetailView: View {
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

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsPage(title: provider.shortTitle, subtitle: provider.purpose, bottomInset: 32) {
            SettingsSectionHeader(L10n.text("服务用途"))
            SettingsCard {
                SettingsRowContainer {
                    HStack(alignment: .top, spacing: SettingsTemplate.iconSpacing) {
                        SettingsRowIcon(.symbol(provider.iconName))
                        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                            Text(provider.title)
                                .appText(.subheading)
                                .foregroundStyle(.primary)
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
                                TextField(L10n.text("输入 \(provider.shortTitle) API Key"), text: $apiKey)
                            } else {
                                SecureField(L10n.text("输入 \(provider.shortTitle) API Key"), text: $apiKey)
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
                .disabled(trimmedKey.isEmpty || isTesting)
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
        } catch is CancellationError {
            return
        } catch {
            let suffix = originalKey.isEmpty ? L10n.text("未保存这次输入。") : L10n.text("原密钥未更改。")
            let message = "\(error.localizedDescription) \(suffix)"
            feedback = LocalServiceFeedback(text: message, kind: .error)
            announce(L10n.text("验证失败。\(message)"))
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
            announce(L10n.text("密钥已保存"))
        } catch {
            feedback = LocalServiceFeedback(text: error.localizedDescription, kind: .error)
            announce(L10n.text("保存失败。\(error.localizedDescription)"))
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
            announce(L10n.text("密钥已移除"))
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
    let issues: [String]

    var body: some View {
        SettingsPage {
            SettingsSection(L10n.text("不影响出图")) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { index, issue in
                        if index > 0 { Divider() }
                        Text(L10n.label(issue))
                            .appText(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
                            .padding(.vertical, SettingsTemplate.rowVerticalPadding)
                            .textSelection(.enabled)
                    }
                }
            }
            SettingsFootnote(L10n.text("首页和收益页照常绘制，上面每一条是重建账户历史时做的推算或跳过的数据。导入券商的完整活动记录（带现金金额）后，这些推算会换成真实数据。"))
        }
        .navigationTitle(L10n.text("数据问题"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
