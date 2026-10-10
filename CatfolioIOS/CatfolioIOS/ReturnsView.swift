import SwiftUI

struct ReturnsView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var selectedHolding: Holding?
    @State private var heatmapExpanded = LaunchArguments.contains("--expand-performance-heatmap")
    @State private var heroScroll = HeroScroll()
    @State private var isScrolling = false
    @State private var sourcePreviews = ReturnsSourcePreviewStore()
    /// Bumped each time the tab comes back into view, so the cards redraw
    /// from prices a chart page may have just refreshed.
    @State private var appearance = 0
    #if DEBUG
    @State private var showsHeatmapPreview = LaunchArguments.contains("--show-heatmap")
    /// `--show-returns-chart=losses` opens that chart page, for screenshots.
    @State private var previewChart: ReturnsChartDestination? = LaunchArguments.all
        .first { $0.hasPrefix("--show-returns-chart=") }
        .flatMap { ReturnsChartDestination(rawValue: String($0.dropFirst("--show-returns-chart=".count))) }
    #endif

    var body: some View {
        SettingsPage(pageBackground: Color(uiColor: .systemBackground)) {
            // The heatmap lives on the tab itself, not behind a row: it reads
            // the same holdings and daily changes the home list already has.
            // It starts lying on an isometric plane; a pull stands it up.
            PortfolioDetailsCard(
                holdings: model.holdings,
                onSelect: { selectedHolding = $0 },
                showsHeatmap: true,
                hero: HeatmapHeroState(
                    isExpanded: heatmapExpanded,
                    pull: heroScroll.pull,
                    topInset: heroScroll.topInset,
                    isOnScreen: heroScroll.isHeroOnScreen,
                    isScrolling: isScrolling,
                    onToggle: toggleHeatmap,
                    collapsedHeight: 100
                )
            )
            .accessibilityIdentifier("performance.heatmap")
            HStack(alignment: .center) {
                Text(L10n.text("Performance"))
                    .font(.system(size: 34, weight: .bold))
                Spacer(minLength: 12)
                Button(action: toggleHeatmap) {
                    Label(L10n.text("热力图"), systemImage: heatmapExpanded ? "chevron.up" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(minWidth: 96, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .buttonBorderShape(.capsule)
                // The hero morph lasts 0.7s; the control must reflect its
                // destination state immediately, without retaining the play
                // symbol in the native button's animated content snapshot.
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .accessibilityIdentifier("performance.heatmap.toggle")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
            ReturnsSourceCards(store: sourcePreviews)
            HStack(spacing: 16) {
                ReturnsNavigationCard(title: L10n.text("收益对比"),
                                      identifier: "comparison", returnPercent: ReturnsEntrySummary.allTimePercent(model.comparison)) {
                    ReturnsChartPage(chart: .comparison)
                }
                ReturnsNavigationCard(title: L10n.text("周期对比"),
                                      identifier: "cycle", returnPercent: comparisonEntryReturnPercent) {
                    CycleComparisonView()
                }
            }
            // 估值 · 成长 · 质量 is in 设置 › Lab 实验室.
            TodayAttentionEntry()
            CorporateEventsCard(holdings: model.holdings)
        }
        // Only what the hero needs, so ordinary scrolling does not redraw
        // the page: the pull past the top, the bar's height, and whether the
        // hero is still in sight.
        .onScrollGeometryChange(for: HeroScroll.self) { geometry in
            let offset = geometry.contentOffset.y + geometry.contentInsets.top
            return HeroScroll(
                pull: max(0, -offset),
                topInset: geometry.contentInsets.top,
                isHeroOnScreen: offset < 480
            )
        } action: { _, scroll in
            heroScroll = scroll
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            // Let native scrolling have the display budget, including inertia.
            let scrolling = newPhase != .idle
            if isScrolling != scrolling { isScrolling = scrolling }
            guard oldPhase == .interacting, newPhase != .interacting,
                  heroScroll.pull >= HeatmapHeroState.threshold else { return }
            toggleHeatmap()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: heroScroll.pull >= HeatmapHeroState.threshold) { wasPast, isPast in
            hapticsEnabled && !wasPast && isPast
        }
        .tracksRootTabBarScroll()
        .onAppear { appearance &+= 1 }
        .task(id: "\(sourcePreviewScope)|\(model.portfolioChartRevision)|\(model.holdings.count)|\(model.selectedAccountKeys.count)|\(appearance)") {
            await sourcePreviews.load(
                scope: sourcePreviewScope,
                revision: "\(model.portfolioChartRevision)",
                holdings: model.holdings,
                isPortfolioLoaded: !model.selectedAccountKeys.isEmpty || !model.holdings.isEmpty,
                fetch: { try await model.holdingValueHistory(cachedOnly: $0) }
            )
        }
        .task(id: "\(sourcePreviewScope)|\(model.portfolioChartRevision)") {
            if !model.isReturnsLoading { await model.refreshReturns() }
        }
        .onDisappear { isScrolling = false }
        .accessibilityIdentifier("returns-root")
        .softTopScrollEdge()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .sheet(item: $selectedHolding) { holding in
            HoldingDetailView(holding: holding, onClose: { selectedHolding = nil })
                .environment(model)
                .securityDetailSheet()
        }
        .securityDetailOpenFeedback(trigger: selectedHolding?.ticker, enabled: hapticsEnabled)
        #if DEBUG
        .navigationDestination(isPresented: $showsHeatmapPreview) {
            ReturnsChartPage(chart: .heatmap)
        }
        .navigationDestination(item: $previewChart) { chart in
            ReturnsChartPage(chart: chart)
        }
        #endif
    }
}

private struct ReturnsNavigationCard<Destination: View>: View {
    let title: String
    let identifier: String
    let returnPercent: Double?
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            ReturnsComparisonEntryArtwork(title: title, isCycle: identifier == "cycle", returnPercent: returnPercent)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("performance.chart.\(identifier)")
    }
}

private extension ReturnsView {
    var comparisonEntryReturnPercent: Double? {
        ReturnsEntrySummary.yearToDatePercent(model.comparison)
    }

    /// The accounts the entry cards describe. Not the holdings: they are not
    /// loaded yet when the app opens, and the saved cards must match then.
    /// A change in holdings moves the chart revision, which redraws them.
    var sourcePreviewScope: String {
        let accounts = model.selectedAccountKeys.sorted().joined(separator: ",")
        return "\(model.isFakeDataMode ? "demo" : "real")|\(accounts)"
    }

    struct HeroScroll: Equatable {
        var pull: CGFloat = 0
        var topInset: CGFloat = 0
        var isHeroOnScreen = true
    }

    func toggleHeatmap() {
        withAnimation(.smooth(duration: 0.7)) { heatmapExpanded.toggle() }
    }
}

enum ReturnsChartDestination: String, CaseIterable, Identifiable {
    case heatmap, contributors, losses, comparison, valuation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heatmap: L10n.text("持仓热力图")
        case .contributors: L10n.text("收益来源")
        case .losses: L10n.text("亏损分析")
        case .comparison: L10n.text("收益对比")
        case .valuation: L10n.text("估值 · 成长 · 质量")
        }
    }

    var icon: String {
        switch self {
        case .heatmap: "square.grid.2x2"
        case .contributors: "square.stack.3d.up"
        case .losses: "chart.line.downtrend.xyaxis"
        case .comparison: "chart.line.uptrend.xyaxis"
        case .valuation: "chart.dots.scatter"
        }
    }
}

struct ReturnsChartPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let chart: ReturnsChartDestination
    @State private var selectedHolding: Holding?
    @State private var holdingHistoryRefreshRevision = 0

    var body: some View {
        // A chart that changes what it shows from further down the page can
        // take the reader back up to it.
        ScrollViewReader { proxy in
            page.environment(\.scrollChartPageToTop, ChartPageScrollToTop {
                withAnimation(.snappy) { proxy.scrollTo("chart-page-top", anchor: .top) }
            })
        }
    }

    private var page: some View {
        Group {
            if chart == .comparison {
                ReturnsComparisonPanel()
            } else {
                ScrollView {
                    Group {
                        switch chart {
                        case .heatmap:
                            PortfolioDetailsCard(
                                holdings: model.holdings,
                                onSelect: { selectedHolding = $0 },
                                showsHeatmap: true
                            )
                        case .contributors:
                            HoldingContributionChart(refreshRevision: holdingHistoryRefreshRevision)
                        case .losses:
                            LossAnalysisChart(refreshRevision: holdingHistoryRefreshRevision)
                        case .comparison:
                            EmptyView()
                        case .valuation:
                            analytics(.valuation)
                        }
                    }
                    .id("chart-page-top")
                    .padding(.top, 20)
                    .padding(.bottom, 72)
                }
            }
        }
        .background(chart == .contributors ? ReturnsSourceChartStyle.incomeFooter : Color(uiColor: .systemBackground))
        .softTopScrollEdge()
        .toolbarColorScheme(chart == .contributors ? .dark : nil, for: .navigationBar)
        .tint(chart == .contributors ? .white : .accentColor)
        .navigationTitle(chart.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(chart == .comparison ? .hidden : .visible, for: .navigationBar)
        .refreshable {
            if chart == .contributors || chart == .losses {
                holdingHistoryRefreshRevision &+= 1
            } else {
                await model.refreshReturnsPage()
            }
        }
        .sheet(item: $selectedHolding) { holding in
            HoldingDetailView(holding: holding, onClose: { selectedHolding = nil })
                .environment(model)
                .securityDetailSheet()
        }
        .securityDetailOpenFeedback(trigger: selectedHolding?.ticker, enabled: hapticsEnabled)
        .task {
            // This page owns its history request; unrelated valuation and
            // comparison fetches compete with it for the same price feed.
            guard chart != .contributors, chart != .losses else { return }
            guard !model.isReturnsLoading, !model.isReturnsAnalyticsLoading else { return }
            // Each part is fetched only when it is missing: analytics that
            // failed must not send the comparison through a full rebuild on
            // every visit.
            if model.comparison == nil {
                await model.refreshReturnsPage()
            } else if model.returnsAnalytics == nil {
                await model.refreshReturnsAnalytics()
            }
        }
    }

    private func analytics(_ chart: ReturnsAnalyticsChart) -> some View {
        Group {
            if let analytics = model.returnsAnalytics {
                ReturnsAnalyticsView(
                    response: analytics,
                    pendingParts: model.returnsAnalyticsPendingParts,
                    chart: chart
                )
                .id(model.returnsAnalyticsRevision)
            } else if model.isReturnsAnalyticsLoading {
                ReturnsAnalyticsLoadingView(chart: chart)
            } else {
                ReturnsAnalyticsUnavailableView()
            }
        }
        .padding(.horizontal, ReturnsChartLayout.contentHorizontalInset)
    }
}
