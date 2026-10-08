import SwiftUI
import UIKit

/// Which feeds news leads come from, which sites never count, and how each
/// holding is searched. Read by the attention scan, a security's
/// developments and today's move alike, from the next refresh on.
struct NewsSettingsView: View {
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
struct SettingsTestView: View {
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
        .hidesTabBarWhenPushed()
        .fullScreenCover(isPresented: $showsPaywall) { PaywallView() }
        .fullScreenCover(isPresented: $showsFirstLaunchGuide) {
            // Reuse the launch flow without resetting its seen flag or any credentials.
            ServiceAPIOnboardingView()
        }
    }
}

/// Experimental features: reachable, but not yet on the pages they belong to.
struct SettingsLabView: View {
    @Environment(AppModel.self) private var model

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
                SettingsValueRow(icon: .symbol("number.square"), title: L10n.text("税务计算"), value: nil)
                    .disabled(true)
                    .accessibilityHint(L10n.text("功能暂未开放"))
            }
        }
        .navigationTitle(L10n.text("Lab 实验室"))
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBarWhenPushed()
    }
}
