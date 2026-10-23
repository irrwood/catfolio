import SwiftUI
import UIKit

/// App-wide preferences and maintenance, opened from the Account page.
struct AppSettingsView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.openURL) private var openURL
    @Environment(AppModel.self) private var model
    private let dataSourceHealth = DataSourceHealth.shared
    @AppStorage(AppLanguage.preferenceKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage("catfolio.haptics") private var hapticsEnabled = true
    @AppStorage(AppAppearance.preferenceKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(DisplayCurrency.preferenceKey) private var displayCurrencyRawValue = DisplayCurrency.usd.rawValue
    @AppStorage(CompanyNameDisplay.preferenceKey) private var companyNameDisplayRawValue = CompanyNameDisplay.original.rawValue
    @AppStorage(AssetLogoStyle.preferenceKey) private var assetLogoStyleRawValue = AssetLogoStyle.automatic.rawValue
    @AppStorage(HomeBackgroundStyle.preferenceKey) private var homeBackgroundStyleRawValue = HomeBackgroundStyle.defaultStyle.rawValue
    @State private var showsPortfolioResetConfirmation = false
    @State private var isResettingPortfolio = false
    @State private var portfolioResetError: String?
    @State private var reconciliation: LedgerReconciliation.Report?

    var body: some View {
        SettingsPage(title: L10n.text("设置"), topInset: SettingsTemplate.sectionSpacing,
                     titleDisplayMode: .inline) {
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
                // A Mac has no haptics to turn off.
                if !MacPlatform.isMac {
                    SettingsToggleRow(
                        icon: .symbol("hand.tap"),
                        title: L10n.text("触控反馈"),
                        isOn: $hapticsEnabled
                    )
                }

                SettingsMenuRow(
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
            CloudDataSettingsSection()

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
                    title: L10n.text("重置组合数据"),
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
                SettingsButtonRow(icon: .symbol("questionmark.circle"), title: L10n.text("支持与帮助")) {
                    openInformationPage("support")
                }
                .accessibilityIdentifier("settings.support")
                SettingsButtonRow(icon: .symbol("hand.raised"), title: L10n.text("隐私政策")) {
                    openInformationPage("privacy")
                }
                .accessibilityIdentifier("settings.privacy")
                #if DEBUG
                SettingsNavigationRow(icon: .symbol("testtube.2"), title: L10n.text("测试")) {
                    SettingsTestView()
                }
                .accessibilityIdentifier("settings-test")
                #endif
            }
        }
        .accessibilityIdentifier("app-settings")
        .task {
            if model.overview == nil { await model.refreshPortfolio() }
            await loadReconciliation()
        }
        .confirmationDialog(L10n.text("重置组合数据？"), isPresented: $showsPortfolioResetConfirmation, titleVisibility: .visible) {
            Button(L10n.text("备份并重置"), role: .destructive) {
                isResettingPortfolio = true
                Task {
                    defer { isResettingPortfolio = false }
                    do { try await model.resetLocalPortfolio() }
                    catch { portfolioResetError = error.localizedDescription }
                }
            }
        } message: {
            Text(L10n.text("将清空当前持仓、交易和历史快照，并保留一份本机备份。券商授权、API 密钥及 AI 对话会保留。开启或重新开启账户与持仓同步后，重置也会同步到其他设备。"))
        }
        .alert(L10n.text("无法重置组合"), isPresented: Binding(
            get: { portfolioResetError != nil },
            set: { if !$0 { portfolioResetError = nil } }
        )) {
            Button(L10n.text("好"), role: .cancel) { portfolioResetError = nil }
        } message: {
            Text(L10n.message(portfolioResetError ?? ""))
        }
        .tint(CatfolioTheme.accent)
    }

    private func openInformationPage(_ page: String) {
        let suffix = AppLanguage.currentIdentifier == "zh-Hans" ? "-zh" : ""
        guard let url = URL(string: "https://catfolio-app.vercel.app/\(page)\(suffix)") else { return }
        openURL(url)
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

}
