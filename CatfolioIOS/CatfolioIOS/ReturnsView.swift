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
                ReturnsNavigationCard(title: ReturnsChartDestination.comparison.title,
                                      icon: ReturnsChartDestination.comparison.icon, identifier: "comparison") {
                    ReturnsChartPage(chart: .comparison)
                }
                ReturnsNavigationCard(title: L10n.text("周期对比"),
                                      icon: "clock.arrow.trianglehead.counterclockwise.rotate.90", identifier: "cycle") {
                    CycleComparisonView()
                }
            }
            // 估值 · 成长 · 质量 is in 设置 › Lab 实验室.
            // The analysis and JEV, as two tabs of one section.
            TodayAttentionTabs()
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
    let icon: String
    let identifier: String
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            ReturnsComparisonEntryArtwork(title: title, isCycle: identifier == "cycle")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("performance.chart.\(identifier)")
    }
}

private extension ReturnsView {
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
        .hidesTabBarWhenPushed()
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

private struct ComparisonZeroPositionKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

struct ReturnsComparisonPanel: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var chartMode: ReturnsChartMode = {
        let arguments = LaunchArguments.all
        if arguments.contains("--show-cash-flow") { return .cashFlowMatched }
        if arguments.contains("--show-mwr") { return .mwr }
        return .twr
    }()
    @State private var timeRange: ChartTimeRange = {
        let arguments = LaunchArguments.all
        if arguments.contains("--show-returns-1d") { return .oneDay }
        if arguments.contains("--show-returns-1w") { return .oneWeek }
        if arguments.contains("--show-returns-1m") { return .oneMonth }
        if arguments.contains("--show-returns-2m") { return .twoMonths }
        if arguments.contains("--show-returns-3m") { return .threeMonths }
        if arguments.contains("--show-returns-ytd") { return .yearToDate }
        if arguments.contains("--show-returns-6m") { return .sixMonths }
        if arguments.contains("--show-returns-2y") { return .twoYears }
        if arguments.contains("--show-returns-all")
            || arguments.contains("--show-returns-max") { return .maximum }
        // The home chart's default, and a slot the shared picker has.
        return .yearToDate
    }()
    @State private var selectedDate: Date?
    /// The one line a right swipe on its row brought forward; the rest fade.
    /// Kept here so it outlives the chart being rebuilt when a symbol leaves.
    @State private var highlightedSeries: String?
    @State private var isModeSwitcherExpanded = LaunchArguments.contains("--show-returns-mode-expanded")
    @AppStorage(ComparisonBenchmarkCatalog.preferenceKey) private var storedBenchmarks: String?
    @State private var showsBenchmarkPicker = false
    /// The list the comparison on screen was computed for.
    @State private var computedBenchmarks = ComparisonBenchmarkCatalog.symbols
    @State private var zeroPosition: CGFloat = 230

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let comparison = model.comparison {
                    ReturnsChart(
                        comparison: comparison,
                        mode: $chartMode,
                        timeRange: $timeRange,
                        selectedDate: $selectedDate,
                        highlightedSeries: $highlightedSeries,
                        onAddBenchmark: { showsBenchmarkPicker = true }
                    )
                    // A removed symbol leaves at once; an added one arrives
                    // with the recomputed comparison.
                    .id("\(model.comparisonRevision)|\(storedBenchmarks ?? "")")
                } else {
                    ReturnsComparisonPlaceholder(
                        timeRange: $timeRange,
                        title: model.returnsError == nil
                            ? L10n.text("正在加载收益数据") : L10n.text("暂无收益记录"),
                        message: model.returnsError
                            ?? L10n.text("正在整理组合与基准的历史记录"),
                        isLoading: model.returnsError == nil
                    )
                }
            }
            .padding(.bottom, 34)
        }
        .scrollIndicators(.hidden)
        // The header rides over the chart as the page scrolls, with the
        // same soft blurred edge the other chart pages get from their bar.
        .comparisonTopBar { header }
        .background { ComparisonSwipeBackSupport().frame(width: 0, height: 0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .coordinateSpace(name: "comparison-page")
        .onPreferenceChange(ComparisonZeroPositionKey.self) { value in
            if let value { zeroPosition = value }
        }
        .background {
            GeometryReader { geometry in
                let top = geometry.frame(in: .named("comparison-page")).minY
                let center = min(0.95, max(0.05, (zeroPosition - top) / max(1, geometry.size.height)))
                LinearGradient(stops: [
                    .init(color: Color(red: 91 / 255, green: 49 / 255, blue: 210 / 255), location: 0),
                    .init(color: Color(red: 0.025, green: 0.012, blue: 0.065), location: center),
                    .init(color: Color(red: 92 / 255, green: 50 / 255, blue: 213 / 255), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { selectDrawableModeIfNeeded() }
        .onChange(of: model.comparisonRevision) { _, _ in
            computedBenchmarks = ComparisonBenchmarkCatalog.symbols
            selectDrawableModeIfNeeded()
        }
        .onChange(of: chartMode) { _, _ in selectedDate = nil }
        .onChange(of: timeRange) { _, _ in selectedDate = nil }
        .onChange(of: showsBenchmarkPicker) { _, isShowing in
            // Recompute once for everything added while searching.
            if !isShowing { Task { await recomputeIfAdded() } }
        }
        .appSheet(isPresented: $showsBenchmarkPicker) {
            ReturnsBenchmarkPicker()
                .environment(model)
        }
        .onChange(of: storedBenchmarks) { _, _ in
            Task { await recomputeIfAdded() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            backButton.modifier(ReturnsHeaderCircleGlass())
            // The page draws its own bar, so it sets its own title; it gives
            // way while the mode switcher is open and needs the room.
            if !isModeSwitcherExpanded {
                Text(L10n.text("收益对比"))
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .transition(.opacity)
            }

            Spacer(minLength: 8)
            if !isModeSwitcherExpanded {
                addBenchmarkButton
                    .modifier(ReturnsHeaderCircleGlass())
                    .transition(.opacity)
            }
            modeSwitcher
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 19, weight: .regular))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("返回"))
    }

    private var addBenchmarkButton: some View {
        Button { showsBenchmarkPicker = true } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("添加对比"))
    }

    private var modeSwitcher: some View {
        Group {
            if isModeSwitcherExpanded {
                HStack(spacing: 0) {
                    ForEach(ReturnsChartMode.displayOrder, id: \.self) { mode in
                        let isSelected = chartMode == mode
                        Button {
                            chartMode = mode
                            setSwitcherExpanded(false)
                        } label: {
                            Text(mode == .cashFlowMatched ? "Mirror" : mode.displayTitle)
                                .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 90, height: 48)
                                .background {
                                    if isSelected {
                                        Capsule()
                                            .fill(.white.opacity(0.22))
                                            .overlay {
                                                Capsule().strokeBorder(Color.white.opacity(0.33), lineWidth: 1)
                                            }
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .frame(width: 270, height: 48)
                .modifier(ReturnsSwitcherGlass())
                .accessibilityIdentifier("comparison.mode.expanded")
                .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .trailing)))
            } else {
                Button { setSwitcherExpanded(true) } label: {
                    HStack(spacing: 9) {
                        Text(chartMode == .cashFlowMatched ? "Mirror" : chartMode.displayTitle)
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.7))
                    }
                    .frame(width: 110, height: 48)
                }
                .buttonStyle(.plain)
                .modifier(ReturnsSwitcherGlass())
                .accessibilityLabel(L10n.text("收益图表口径，当前 \(chartMode.displayTitle)，展开选项"))
                .accessibilityIdentifier("comparison.mode.collapsed")
                .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .trailing)))
            }
        }
    }

    private func setSwitcherExpanded(_ expanded: Bool) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.26)) {
            isModeSwitcherExpanded = expanded
        }
    }

    /// Only an added symbol needs its history fetched; a removed one is
    /// already gone from the chart.
    private func recomputeIfAdded() async {
        let current = ComparisonBenchmarkCatalog.symbols
        let added = !Set(current).isSubset(of: Set(computedBenchmarks))
        guard added, !showsBenchmarkPicker else { return }
        computedBenchmarks = current
        await model.refreshReturns()
    }

    private func selectDrawableModeIfNeeded() {
        guard let comparison = model.comparison else { return }
        let hasActiveLine = comparison.dates.count > 1
            && comparison.portfolio.compactMap { $0 }.count > 1
        let hasTWRLine = (comparison.twrDates?.count ?? 0) > 1
            && (comparison.twrPortfolio?.compactMap { $0 }.count ?? 0) > 1
        let hasMWRLine = (comparison.mwrLedger?.dates.count ?? 0) > 1
            && (comparison.mwrPortfolio?.compactMap { $0 }.count ?? 0) > 1

        switch chartMode {
        case .cashFlowMatched where !hasActiveLine:
            break
        case .twr where !hasTWRLine:
            // Keep the requested metric visible with its missing-ledger reason.
            break
        case .mwr where !hasMWRLine:
            break
        default:
            break
        }
    }
}

private extension View {
    /// A custom top bar that the scroll edge effect treats like the system's:
    /// content scrolled under it fades and blurs instead of being cut off.
    @ViewBuilder
    func comparisonTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { bar().background(.bar) }
        }
    }
}

/// On the light page the faint dark-page glass would vanish: there the
/// buttons are fuller glass over a white wash.
private struct ReturnsHeaderCircleGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        if #available(iOS 26.0, *) {
            content.background {
                ZStack {
                    Circle().fill(.white.opacity(isDark ? 0.025 : 0.55))
                    Color.clear.glassEffect(.regular.interactive(), in: Circle()).opacity(isDark ? 0.16 : 1)
                    Circle().strokeBorder(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.05), lineWidth: 1)
                }
            }
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

private struct ReturnsSwitcherGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        if #available(iOS 26.0, *) {
            content
                .background {
                    ZStack {
                        Capsule().fill(.white.opacity(isDark ? 0.03 : 0.45))
                        Color.clear.glassEffect(.regular.interactive(), in: Capsule()).opacity(isDark ? 0.70 : 1)
                        Capsule().strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
                    }
                }
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
        }
    }
}

private enum ReturnsChartMode: String, CaseIterable {
    case cashFlowMatched = "现金流镜像"
    case twr = "TWR"
    case mwr = "MWR"

    var displayTitle: String {
        switch self {
        case .twr: "TWR"
        case .mwr: "MWR"
        case .cashFlowMatched: L10n.text("Flow Mirror")
        }
    }

    static let displayOrder: [ReturnsChartMode] = [.twr, .mwr, .cashFlowMatched]
}

private typealias ReturnsTypography = LegacyType

private enum ReturnsChartLayout {
    static let contentHorizontalInset: CGFloat = 20
    static let plotHeight: CGFloat = 392
    static let rangePickerHeight: CGFloat = 44
}

private struct ReturnsTimeRangeControl: View {
    @Binding var selection: ChartTimeRange
    var isDisabled = false

    var body: some View {
        ChartTimeRangePicker(selection: $selection, isDisabled: isDisabled, isOnComparisonField: true)
        .frame(height: ReturnsChartLayout.rangePickerHeight)
        .accessibilityLabel(L10n.text("收益图表时间范围"))
    }
}

private enum ReturnsSeriesStyle {
    static let portfolio = "组合"
    static var order: [String] { [portfolio] + ComparisonBenchmarkCatalog.symbols }
    static var displayOrder: [String] { order }
    /// One colour per series, used by the line, endpoint and ranking badge.
    ///
    /// Figma 437:11904's line palette stays consistent across the plot,
    /// endpoint labels and ranking badges.
    static let colors: [String: Color] = [
        portfolio: Color(red: 0.204, green: 0.780, blue: 0.349),
        "SPY": Color(red: 1.000, green: 0.584, blue: 0.000),
        "QQQ": Color(red: 0.204, green: 0.459, blue: 1.000),
        "VTI": Color(red: 0.890, green: 0.000, blue: 0.271),
        "VOO": Color(red: 0.780, green: 0.000, blue: 0.910),
        "DIA": Color(red: 0.627, green: 0.804, blue: 1.000),
        "IWM": Color(red: 1.000, green: 0.824, blue: 0.741),
        "VEU": Color(red: 0.000, green: 0.882, blue: 0.698),
        "GLD": Color(red: 0.784, green: 0.804, blue: 0.000),
    ]

    /// For symbols the reader added: light enough to carry the black label
    /// text, and apart from the fixed colours above.
    static let addedColors: [Color] = [
        Color(red: 0.722, green: 0.600, blue: 1.000),
        Color(red: 1.000, green: 0.431, blue: 0.702),
        Color(red: 0.722, green: 0.949, blue: 0.200),
        Color(red: 1.000, green: 0.459, blue: 0.400),
        Color(red: 0.302, green: 0.851, blue: 1.000),
        Color(red: 0.831, green: 0.659, blue: 0.459),
        Color(red: 0.749, green: 0.757, blue: 0.788),
        Color(red: 0.580, green: 0.580, blue: 1.000),
    ]

    static func color(for series: String) -> Color {
        if let fixed = colors[series] { return fixed }
        // Added symbols take the next colour in the order they were added,
        // so two never share one.
        let added = ComparisonBenchmarkCatalog.symbols.filter { colors[$0] == nil }
        guard let index = added.firstIndex(of: series) else { return .secondary }
        return addedColors[index % addedColors.count]
    }

    static func title(for series: String) -> String {
        series == portfolio ? L10n.text("MY") : series
    }
}

private struct ReturnsComparisonPlaceholder: View {
    @Binding var timeRange: ChartTimeRange
    let title: String
    let message: String
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                StandardLineChartSkeleton(
                    axisWidth: 33,
                    topInset: 0,
                    leadingLineOverflow: 0,
                    trailingEndpointInset: 9,
                    seriesCount: ReturnsSeriesStyle.displayOrder.count,
                    lineWidths: [2],
                    appearanceID: "returns-comparison"
                )
                .frame(height: ReturnsChartLayout.plotHeight)
                .padding(.trailing, ReturnsChartLayout.contentHorizontalInset)
            } else {
                ReturnsPlotPlaceholder(
                    title: title,
                    message: message,
                    isLoading: false,
                    maximumLines: 3
                )
                .frame(height: ReturnsChartLayout.plotHeight)
                .padding(.trailing, ReturnsChartLayout.contentHorizontalInset)
            }

            ReturnsTimeRangeControl(selection: $timeRange, isDisabled: true)

            VStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { index in
                    HStack {
                        Circle().fill(ReturnsSeriesStyle.color(for: ReturnsSeriesStyle.order[index]))
                            .frame(width: 24, height: 24)
                        Text(index == 0 ? "MY Portfolio" : ReturnsSeriesStyle.order[index])
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Spacer()
                        Text("—")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 65)
                    .background { ReturnsGlassCardSurface() }
                    .opacity(isLoading ? 0.5 : 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 23)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ReturnsPlotPlaceholder: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let message: String
    let isLoading: Bool
    var maximumLines = 3

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(ReturnsTypography.semibold(15, relativeTo: .subheadline))
            Text(L10n.message(message))
                .font(ReturnsTypography.medium(12, relativeTo: .caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(maximumLines)
                .padding(.horizontal, 24)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("\(title)，\(message)"))
    }
}

private struct ReturnsChart: View {
    @Environment(\.locale) private var appLocale
    let comparison: ComparisonResponse
    @Binding var mode: ReturnsChartMode
    @Binding var timeRange: ChartTimeRange
    @Binding var selectedDate: Date?
    let onAddBenchmark: () -> Void
    @State private var visibleSeries = Set(ReturnsSeriesStyle.displayOrder)
    @Binding var highlightedSeries: String?
    @State private var measuredRange: ChartDateRange?
    @State private var prepared: ReturnsPreparedData?
    @State private var displayData = ReturnsDisplayData.empty
    @State private var isPreparing = true

    init(
        comparison: ComparisonResponse,
        mode: Binding<ReturnsChartMode>,
        timeRange: Binding<ChartTimeRange>,
        selectedDate: Binding<Date?>,
        highlightedSeries: Binding<String?>,
        onAddBenchmark: @escaping () -> Void
    ) {
        self.comparison = comparison
        _mode = mode
        _timeRange = timeRange
        _selectedDate = selectedDate
        _highlightedSeries = highlightedSeries
        self.onAddBenchmark = onAddBenchmark
    }

    private var isChartLoading: Bool {
        isPreparing || LaunchArguments.contains("--show-returns-loading-state")
    }

    var body: some View {
        let chartDates = displayData.dates
        let chartDate = nearestDate(in: chartDates)
        let valuesAtDate = values(on: chartDate)
        let hasDrawableLine = displayData.hasDrawableLine
        let measurement = rangeMeasurement()

        VStack(alignment: .leading, spacing: 0) {
            if isChartLoading {
                StandardLineChartSkeleton(
                    axisWidth: 33,
                    topInset: 0,
                    leadingLineOverflow: 0,
                    trailingEndpointInset: 9,
                    seriesCount: ReturnsSeriesStyle.displayOrder.count,
                    lineWidths: [2],
                    appearanceID: "returns-comparison"
                )
                .frame(height: ReturnsChartLayout.plotHeight)
                .padding(.trailing, ReturnsChartLayout.contentHorizontalInset)
            } else if !hasDrawableLine {
                ReturnsPlotPlaceholder(
                    title: visibleSeries.isEmpty ? L10n.text("已隐藏全部曲线") : L10n.text("暂无可绘制数据"),
                    message: visibleSeries.isEmpty ? L10n.text("轻点下方条目重新显示") : emptyChartDescription,
                    isLoading: false
                )
                .frame(height: ReturnsChartLayout.plotHeight)
                .padding(.trailing, ReturnsChartLayout.contentHorizontalInset)
            } else {
                FastReturnsPlot(
                    data: displayData,
                    transitionKey: displayData.transitionKey,
                    rangeTransitionKey: displayData.rangeTransitionKey,
                    selectedDate: selectedDate == nil && measuredRange == nil ? nil : chartDate,
                    measuredRange: measuredRange,
                    mode: mode,
                    highlightedSeries: highlightedSeries,
                    onSelect: {
                        guard measuredRange != nil || selectedDate != $0 else { return }
                        measuredRange = nil
                        selectedDate = $0
                    },
                    onMeasure: {
                        guard measuredRange != $0 else { return }
                        measuredRange = $0
                        selectedDate = $0.end
                    },
                    onInteractionEnded: { _ in
                        selectedDate = nil
                        measuredRange = nil
                    }
                )
                .frame(height: ReturnsChartLayout.plotHeight)
                .padding(.trailing, ReturnsChartLayout.contentHorizontalInset)
                .accessibilityLabel(L10n.text("组合与基准的 \(timeRange.rawValue) \(mode.displayTitle) 对比图，长按后单指拖动查看单日，保持第一指并加入第二指测量区间"))
                .overlay(alignment: .topLeading) {
                    if let measurement {
                        ChartRangeSummary(
                            dateText: measurement.dateText,
                            primaryValue: measurement.primaryValue,
                            secondaryValue: measurement.secondaryValue,
                            color: measurement.color
                        )
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(8)
                        .allowsHitTesting(false)
                    }
                }
            }

            ReturnsTimeRangeControl(selection: $timeRange)

            seriesCards(valuesAtDate)

        }
        .onChange(of: mode) { _, _ in
            measuredRange = nil
            rebuildDisplayData()
        }
        .onChange(of: timeRange) { _, _ in
            measuredRange = nil
            rebuildDisplayData()
        }
        .task {
            await prepareChartData()
        }
    }

    private func seriesCards(_ values: [ReturnsSelectedValue]) -> some View {
        let ranked = values.sorted { lhs, rhs in
            let left = lhs.returnValue ?? -.infinity
            let right = rhs.returnValue ?? -.infinity
            return left == right
                ? (ReturnsSeriesStyle.order.firstIndex(of: lhs.series) ?? .max)
                    < (ReturnsSeriesStyle.order.firstIndex(of: rhs.series) ?? .max)
                : left > right
        }
        return VStack(spacing: 12) {
            ForEach(Array(ranked.enumerated()), id: \.element.id) { index, item in
                let canRemove = item.series != ReturnsSeriesStyle.portfolio
                let isHighlighted = highlightedSeries == item.series
                ReturnsSwipeRow(
                    color: ReturnsSeriesStyle.color(for: item.series),
                    isHighlighted: isHighlighted,
                    canRemove: canRemove,
                    onHighlight: { toggleHighlight(item.series) },
                    onRemove: { remove(item.series) }
                ) {
                    Button { toggleSeries(item.series) } label: {
                        ReturnsRankingRow(item: item, rank: index + 1)
                    }
                    .buttonStyle(.plain)
                }
                .returnsDimmed(highlightedSeries != nil && !isHighlighted)
                .accessibilityValue(item.isVisible ? L10n.text("已显示") : L10n.text("已隐藏"))
                .accessibilityAction(named: isHighlighted ? L10n.text("取消高亮") : L10n.text("高亮曲线")) {
                    toggleHighlight(item.series)
                }
                .contextMenu {
                    Button { toggleHighlight(item.series) } label: {
                        Label(isHighlighted ? L10n.text("取消高亮") : L10n.text("高亮曲线"),
                              systemImage: "highlighter")
                    }
                    if canRemove {
                        Button(role: .destructive) { remove(item.series) } label: {
                            Label(L10n.text("移除对比"), systemImage: "minus.circle")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 23)
    }

    private func nearestDate(in dates: [Date]) -> Date? {
        guard let selectedDate else { return dates.last }
        guard !dates.isEmpty else { return nil }
        var lower = 0
        var upper = dates.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if dates[middle] < selectedDate {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return dates[0] }
        guard lower < dates.count else { return dates[dates.count - 1] }
        let before = dates[lower - 1]
        let after = dates[lower]
        return abs(before.timeIntervalSince(selectedDate)) <= abs(after.timeIntervalSince(selectedDate)) ? before : after
    }

    private var emptyChartDescription: String {
        if mode == .cashFlowMatched {
            return comparison.warnings?.first(where: { $0.hasPrefix("现金流镜像：") })
                ?? L10n.text("现金流镜像：缺少完整资金账本和账户估值，暂不可用。")
        }
        if mode == .mwr {
            return comparison.warnings?.first(where: { $0.hasPrefix("MWR：") })
                ?? L10n.text("MWR 至少需要两个日期的组合价值与一笔有效现金流。")
        }
        return comparison.warnings?.first(where: { $0.hasPrefix("TWR：") })
            ?? L10n.text("请先同步一次持仓，然后下拉刷新。")
    }

    private func values(on date: Date?) -> [ReturnsSelectedValue] {
        let values = date.flatMap { displayData.valuesByDate[$0] } ?? [:]
        let returns = date.flatMap { displayData.returnsByDate[$0] } ?? [:]
        return ReturnsSeriesStyle.displayOrder.map { series in
            ReturnsSelectedValue(
                series: series,
                value: values[series],
                amountValue: mode == .cashFlowMatched
                    ? values[series]
                    : prepared?.cashFlowValue(for: series, on: date),
                returnValue: returns[series],
                isVisible: visibleSeries.contains(series)
            )
        }
    }

    private func toggleHighlight(_ series: String) {
        withAnimation(.smooth(duration: 0.25)) {
            highlightedSeries = highlightedSeries == series ? nil : series
        }
        // A hidden line cannot stand out; bring it back first.
        if highlightedSeries == series, !visibleSeries.contains(series) {
            visibleSeries.insert(series)
            measuredRange = nil
            rebuildDisplayData()
        }
    }

    private func remove(_ series: String) {
        guard series != ReturnsSeriesStyle.portfolio else { return }
        if highlightedSeries == series { highlightedSeries = nil }
        ComparisonBenchmarkCatalog.remove(series)
    }

    private func toggleSeries(_ series: String) {
        if visibleSeries.contains(series) {
            // Every line may go, the portfolio's included; the rows stay to
            // bring them back.
            visibleSeries.remove(series)
            if highlightedSeries == series { highlightedSeries = nil }
        } else {
            visibleSeries.insert(series)
        }
        measuredRange = nil
        rebuildDisplayData()
    }

    private func rangeMeasurement() -> ReturnsRangeMeasurement? {
        guard let measuredRange else { return nil }
        if mode == .mwr {
            guard let ledger = comparison.mwrLedger,
                  let first = ledger.dates.firstIndex(of: DayDateCodec.string(from: measuredRange.start)),
                  let last = ledger.dates.firstIndex(of: DayDateCodec.string(from: measuredRange.end)),
                  let value = ledger.returns(startIndex: first, endIndex: last).portfolio.last ?? nil else { return nil }
            return ReturnsRangeMeasurement(
                dateText: "\(rangeDate(measuredRange.start)) – \(rangeDate(measuredRange.end))",
                primaryValue: DisplayFormat.ratioPercent(value),
                secondaryValue: "MWR · " + L10n.text("期间收益（非年化）"),
                color: value >= 0 ? CatfolioStyle.green : CatfolioStyle.red)
        }

        if mode == .cashFlowMatched {
            guard let startReturn = displayData.returnsByDate[measuredRange.start]?[ReturnsSeriesStyle.portfolio],
                  let endReturn = displayData.returnsByDate[measuredRange.end]?[ReturnsSeriesStyle.portfolio] else {
                return nil
            }
            let changeInPercentagePoints = (endReturn - startReturn) * 100
            let sign = changeInPercentagePoints >= 0 ? "+" : ""
            return ReturnsRangeMeasurement(
                dateText: "\(rangeDate(measuredRange.start)) – \(rangeDate(measuredRange.end))",
                primaryValue: DisplayFormat.ratioPercent(endReturn),
                secondaryValue: L10n.text("累计收益变化 \(sign)\(changeInPercentagePoints.formatted(.number.precision(.fractionLength(1)))) pp"),
                color: changeInPercentagePoints >= 0 ? CatfolioStyle.green : CatfolioStyle.red
            )
        }

        guard let start = displayData.portfolioByDate[measuredRange.start],
              let end = displayData.portfolioByDate[measuredRange.end] else { return nil }

        let change = end.value - start.value
        let sign = change >= 0 ? "+" : ""
        return ReturnsRangeMeasurement(
            dateText: "\(rangeDate(start.date)) – \(rangeDate(end.date))",
            primaryValue: "\(sign)\(change.formatted(.number.precision(.fractionLength(1)))) pp",
            secondaryValue: L10n.text("至 \(DisplayFormat.percent(end.value))"),
            color: change >= 0 ? CatfolioStyle.green : CatfolioStyle.red
        )
    }

    private func rangeDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private func rebuildDisplayData() {
        guard let prepared else { return }
        displayData = prepared.displayData(
            mode: mode,
            range: timeRange,
            visibleSeries: visibleSeries
        )
    }

    private func prepareChartData() async {
        let comparison = comparison
        let prepared = await Task.detached(priority: .userInitiated) {
            ReturnsPreparedData(comparison: comparison)
        }.value
        guard !Task.isCancelled else { return }
        self.prepared = prepared
        rebuildDisplayData()
        isPreparing = false
        applyLaunchSelectionIfNeeded()
    }

    private func applyLaunchSelectionIfNeeded() {
        let chartDates = displayData.dates
        let arguments = LaunchArguments.all
        guard chartDates.count > 2 else { return }
        if arguments.contains("--show-returns-selection"), selectedDate == nil {
            selectedDate = chartDates[chartDates.count / 3]
        } else if arguments.contains("--show-returns-range"), measuredRange == nil {
            measuredRange = ChartDateRange(
                chartDates[chartDates.count / 3],
                chartDates[chartDates.count - 1]
            )
        }
    }
}

private struct ReturnsRangeMeasurement {
    let dateText: String
    let primaryValue: String
    let secondaryValue: String
    let color: Color
}

/// Nine Swift Charts series create hundreds of main-thread view nodes. Canvas
/// draws the same native chart in one pass and keeps tab switching responsive.
enum ReturnsAxisLabels {
    static func percent(_ value: Double, step: Double, locale: Locale) -> String {
        guard value.isFinite, step.isFinite, step > 0 else { return "—" }
        let digits = min(6, max(0, Int(ceil(-log10(step)))))
        let scale = pow(10.0, Double(digits))
        let rounded = (value * scale).rounded() / scale
        return (rounded == 0 ? 0 : rounded).formatted(
            .number.grouping(.never).precision(.fractionLength(0...digits)).locale(locale)
        ) + "%"
    }
}

private struct FastReturnsPlot: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    let data: ReturnsDisplayData
    let transitionKey: String
    let rangeTransitionKey: String
    let selectedDate: Date?
    let measuredRange: ChartDateRange?
    let mode: ReturnsChartMode
    let highlightedSeries: String?
    let onSelect: (Date) -> Void
    let onMeasure: (ChartDateRange) -> Void
    let onInteractionEnded: (Int) -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var seriesCache = ReturnsPlotSeriesCache()

    private let axisWidth: CGFloat = 33
    private let bottomHeight: CGFloat = 0
    private let endpointInset: CGFloat = 9

    private var grouped: [String: [ReturnsSeriesPoint]] { data.grouped }
    private var domain: ClosedRange<Double> { data.domain }

    var body: some View {
        let prepared = seriesCache.prepared(for: data, differentiateWithoutColor: differentiateWithoutColor,
                                            highlighted: highlightedSeries)
        StandardLineChart(
            series: prepared.series,
            interactionDates: prepared.interactionDates,
            domain: domain,
            yTicks: prepared.yTicks,
            axisWidth: axisWidth,
            topInset: 0,
            bottomHeight: bottomHeight,
            // Keep the range's actual baseline visible and reachable by touch.
            leadingLineOverflow: 0,
            trailingEndpointInset: endpointInset,
            gridOpacity: 0,
            transitionKey: transitionKey,
            rangeTransitionKey: rangeTransitionKey,
            appearanceID: "returns-comparison",
            dataTransition: .viewportZoom,
            animatesInitialAppearance: true,
            selectedDate: selectedDate,
            measuredRange: measuredRange,
            // The day being read, as on the home chart. A measured range
            // names its dates in the summary card instead.
            selectionIndicatorLabel: measuredRange == nil
                ? selectedDate?.formatted(.dateTime.year().month(.abbreviated).day().locale(appLocale))
                : nil,
            rangeSeriesIDs: [ReturnsSeriesStyle.portfolio],
            rangePrimarySeriesID: ReturnsSeriesStyle.portfolio,
            yAxisFont: .system(size: 14, weight: .regular, design: .rounded).italic(),
            yAxisColor: .primary.opacity(0.20),
            yAxisLabel: { _ in "" },
            xAxisLabel: shortDate,
            onSelect: onSelect,
            onMeasure: onMeasure,
            onInteractionEnded: onInteractionEnded
        )
        .overlay {
            // Each line ends in its ring; the labels stand apart in the axis
            // column, shifted vertically to keep neighbouring tickers apart.
            GeometryReader { geometry in
                let span = max(domain.upperBound - domain.lowerBound, 0.000001)
                let zeroY = CGFloat(domain.upperBound / span) * geometry.size.height
                Color.clear.preference(key: ComparisonZeroPositionKey.self,
                    value: geometry.frame(in: .named("comparison-page")).minY + zeroY)
                let zeroIndex = prepared.yTicks.indices.min {
                    abs(prepared.yTicks[$0]) < abs(prepared.yTicks[$1])
                }
                ForEach(prepared.yTicks.indices, id: \.self) { index in
                    let value = domain.contains(0) && index == zeroIndex ? 0 : prepared.yTicks[index]
                    Text(axisLabel(value))
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(Color.white.opacity(0.3))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 50, alignment: .leading)
                        .position(x: 45, y: min(geometry.size.height - 8, max(8,
                            CGFloat((domain.upperBound - value) / span) * geometry.size.height)))
                }
                ForEach(endpointLayouts(height: geometry.size.height)) { endpoint in
                    // Set back behind a highlighted line, a label darkens
                    // but stays solid: see-through, the lines behind it
                    // showed through the capsule.
                    let isDimmed = highlightedSeries != nil && highlightedSeries != endpoint.id
                    Text(endpoint.text)
                        .font(Typography.text(size: 10, weight: .bold))
                        .foregroundStyle(isDimmed ? Color.primary.opacity(0.45) : CatfolioTheme.blackTextOnColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(width: axisWidth, height: 18)
                        .background(isDimmed ? endpoint.color.mix(with: colorScheme == .dark ? .black : .white, by: 0.68)
                                             : endpoint.color,
                                    in: Capsule())
                        .zIndex(highlightedSeries == endpoint.id ? 1 : 0)
                        .position(
                            x: geometry.size.width - axisWidth / 2,
                            y: endpoint.y
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func endpointLayouts(height: CGFloat) -> [ReturnsEndpointLabelLayout] {
        let span = max(domain.upperBound - domain.lowerBound, 0.000_001)
        let halfHeight: CGFloat = 9
        let minimumSpacing: CGFloat = 19
        var result = ReturnsSeriesStyle.displayOrder.compactMap { series -> ReturnsEndpointLabelLayout? in
            guard let point = grouped[series]?.last else { return nil }
            let normalized = (domain.upperBound - point.value) / span
            let rawY = CGFloat(normalized) * height
            return ReturnsEndpointLabelLayout(
                id: series,
                text: ReturnsSeriesStyle.title(for: series),
                color: ReturnsSeriesStyle.color(for: series),
                y: min(max(rawY, halfHeight), max(halfHeight, height - halfHeight))
            )
        }
        .sorted { $0.y < $1.y }

        guard !result.isEmpty else { return [] }
        for index in result.indices.dropFirst() {
            result[index].y = max(result[index].y, result[index - 1].y + minimumSpacing)
        }

        let overflow = max(0, (result.last?.y ?? 0) - (height - halfHeight))
        if overflow > 0 {
            for index in result.indices {
                result[index].y -= overflow
            }
            if result.count > 1 {
                for index in stride(from: result.count - 2, through: 0, by: -1) {
                    result[index].y = min(result[index].y, result[index + 1].y - minimumSpacing)
                }
            }
        }

        let underflow = max(0, halfHeight - (result.first?.y ?? halfHeight))
        if underflow > 0 {
            for index in result.indices {
                result[index].y += underflow
            }
        }
        return result
    }

    private func axisLabel(_ value: Double) -> String {
        if mode == .cashFlowMatched {
            let converted = DisplayCurrency.current.fromUSD(value)
            return (converted / cashFlowAxisDivisor).formatted(
                .number
                    .grouping(.never)
                    .precision(.fractionLength(0))
            )
        }
        return ReturnsAxisLabels.percent(value, step: (domain.upperBound - domain.lowerBound) / 5, locale: appLocale)
    }

    private var cashFlowAxisDivisor: Double {
        let displayCurrency = DisplayCurrency.current
        let maximumMagnitude = max(
            abs(displayCurrency.fromUSD(domain.lowerBound)),
            abs(displayCurrency.fromUSD(domain.upperBound))
        )

        switch maximumMagnitude {
        case 1_000_000_000...: return 1_000_000_000
        case 1_000_000...: return 1_000_000
        case 1_000...: return 1_000
        default: return 1
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A selection changes only the crosshair and readouts. Keep line geometry
/// until the prepared mode/range/visible series or accessibility style changes.
@MainActor
private final class ReturnsPlotSeriesCache {
    struct Prepared {
        let series: [StandardLineChartSeries]
        let interactionDates: [Date]
        let yTicks: [Double]
    }

    /// How far the other lines fade while one is highlighted.
    static let fadedOpacity = 0.18

    private var cachedDataID: UUID?
    private var cachedDifferentiatesWithoutColor = false
    private var cachedHighlight: String?
    private var cachedValue: Prepared?

    func prepared(for data: ReturnsDisplayData, differentiateWithoutColor: Bool, highlighted: String?) -> Prepared {
        if cachedDataID == data.id,
           cachedDifferentiatesWithoutColor == differentiateWithoutColor,
           cachedHighlight == highlighted,
           let cachedValue { return cachedValue }

        let order = ReturnsSeriesStyle.order
        // The highlighted line is drawn last, so nothing crosses over it.
        let drawOrder = order.filter { $0 != highlighted } + order.filter { $0 == highlighted }
        let series = drawOrder.compactMap { name -> StandardLineChartSeries? in
            guard let values = data.grouped[name], !values.isEmpty else { return nil }
            let isFaded = highlighted != nil && highlighted != name
            return StandardLineChartSeries(
                id: name,
                points: values.map {
                    StandardLineChartPoint(id: "\(name)|\($0.id)", date: $0.date, value: $0.value)
                },
                color: ReturnsSeriesStyle.color(for: name).opacity(isFaded ? Self.fadedOpacity : 1),
                lineWidth: 2,
                dash: Self.dashPattern(for: name, in: order, enabled: differentiateWithoutColor),
                selectionRadius: name == ReturnsSeriesStyle.portfolio ? 3.6 : 2.8,
                latestPointRadius: name == ReturnsSeriesStyle.portfolio ? 5 : 4,
                latestPointUsesGlass: false
            )
        }
        let ticks = (0..<6).map { index in
            let fraction = Double(index) / 5
            return data.domain.upperBound - (data.domain.upperBound - data.domain.lowerBound) * fraction
        }
        let value = Prepared(series: series, interactionDates: data.dates, yTicks: ticks)
        cachedDataID = data.id
        cachedDifferentiatesWithoutColor = differentiateWithoutColor
        cachedHighlight = highlighted
        cachedValue = value
        return value
    }

    private static func dashPattern(for series: String, in order: [String], enabled: Bool) -> [CGFloat] {
        guard enabled, series != ReturnsSeriesStyle.portfolio,
              let index = order.firstIndex(of: series) else { return [] }
        let patterns: [[CGFloat]] = [
            [8, 4], [2, 3], [10, 3, 2, 3], [5, 3],
            [12, 4], [3, 2, 1, 2], [7, 2], [1, 3],
        ]
        return patterns[(index - 1) % patterns.count]
    }
}

private struct ReturnsEndpointLabelLayout: Identifiable {
    let id: String
    let text: String
    let color: Color
    var y: CGFloat
}

private struct ReturnsDisplayData {
    let id = UUID()
    // Keep the animation revision with the plotted points. A picker change can
    // render before the new range's points have been prepared.
    let transitionKey: String
    let rangeTransitionKey: String
    let points: [ReturnsSeriesPoint]
    let grouped: [String: [ReturnsSeriesPoint]]
    let dates: [Date]
    let valuesByDate: [Date: [String: Double]]
    let returnsByDate: [Date: [String: Double]]
    let portfolioByDate: [Date: ReturnsSeriesPoint]
    let unavailableBenchmarks: [String]
    let domain: ClosedRange<Double>

    var hasDrawableLine: Bool {
        grouped.values.contains { $0.count > 1 }
    }

    static let empty = ReturnsDisplayData(
        transitionKey: "",
        rangeTransitionKey: "",
        points: [],
        grouped: [:],
        dates: [],
        valuesByDate: [:],
        returnsByDate: [:],
        portfolioByDate: [:],
        unavailableBenchmarks: ComparisonBenchmarkCatalog.symbols,
        domain: 0...1
    )
}

private struct ReturnsPreparedRange {
    let points: [ReturnsSeriesPoint]
    let returnPoints: [ReturnsSeriesPoint]
    let unavailableBenchmarks: [String]

    static let empty = ReturnsPreparedRange(
        points: [],
        returnPoints: [],
        unavailableBenchmarks: ComparisonBenchmarkCatalog.symbols
    )
}

private final class ReturnsPreparedData: @unchecked Sendable {
    private let cashFlowMatchedRanges: [ChartTimeRange: ReturnsPreparedRange]
    private let twrRanges: [ChartTimeRange: ReturnsPreparedRange]
    private let mwrRanges: [ChartTimeRange: ReturnsPreparedRange]
    private let cashFlowValuesByDate: [Date: [String: Double]]
    private let cashFlowDates: [Date]

    init(comparison: ComparisonResponse) {
        let cashFlowMatchedPoints = Self.makePoints(
            dates: comparison.dates,
            portfolio: comparison.portfolio,
            benchmarks: comparison.benchmarks,
            transform: { $0 }
        )
        let cashFlowReturnPoints = Self.makePoints(
            dates: comparison.dates,
            portfolio: comparison.cashFlowPortfolioReturns ?? [],
            benchmarks: comparison.cashFlowBenchmarkReturns ?? [:],
            transform: { $0 }
        )
        let twrPoints = Self.makePoints(
            dates: comparison.twrDates ?? [],
            portfolio: comparison.twrPortfolio ?? [],
            benchmarks: comparison.twrBenchmarks ?? [:],
            transform: { ($0 - 1) * 100 }
        )
        var valuesByDate: [Date: [String: Double]] = [:]
        for point in cashFlowMatchedPoints {
            valuesByDate[point.date, default: [:]][point.series] = point.value
        }
        cashFlowValuesByDate = valuesByDate
        cashFlowDates = valuesByDate.keys.sorted()
        cashFlowMatchedRanges = Self.makeRanges(
            from: cashFlowMatchedPoints,
            suppliedReturns: cashFlowReturnPoints,
            mode: .cashFlowMatched
        )
        twrRanges = Self.makeRanges(from: twrPoints, suppliedReturns: [], mode: .twr)
        mwrRanges = Self.makeMWRRanges(ledger: comparison.mwrLedger)
    }

    func cashFlowValue(for series: String, on date: Date?) -> Double? {
        guard let date else { return nil }
        if let exactValue = cashFlowValuesByDate[date]?[series] {
            return exactValue
        }
        guard !cashFlowDates.isEmpty else { return nil }
        var lower = 0
        var upper = cashFlowDates.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cashFlowDates[middle] < date { lower = middle + 1 } else { upper = middle }
        }
        let nearestDate: Date
        if lower == 0 {
            nearestDate = cashFlowDates[0]
        } else if lower == cashFlowDates.count {
            nearestDate = cashFlowDates[cashFlowDates.count - 1]
        } else {
            let before = cashFlowDates[lower - 1]
            let after = cashFlowDates[lower]
            nearestDate = abs(before.timeIntervalSince(date)) <= abs(after.timeIntervalSince(date))
                ? before : after
        }
        return cashFlowValuesByDate[nearestDate]?[series]
    }

    func displayData(
        mode: ReturnsChartMode,
        range: ChartTimeRange,
        visibleSeries: Set<String>
    ) -> ReturnsDisplayData {
        let ranges: [ChartTimeRange: ReturnsPreparedRange]
        switch mode {
        case .cashFlowMatched: ranges = cashFlowMatchedRanges
        case .twr: ranges = twrRanges
        case .mwr: ranges = mwrRanges
        }
        guard let preparedRange = ranges[range], !preparedRange.points.isEmpty else { return .empty }

        var grouped: [String: [ReturnsSeriesPoint]] = [:]
        var points: [ReturnsSeriesPoint] = []
        let allGrouped = Dictionary(grouping: preparedRange.points, by: \.series)
        for series in ReturnsSeriesStyle.order where visibleSeries.contains(series) {
            guard let values = allGrouped[series], !values.isEmpty else { continue }
            grouped[series] = values
            points.append(contentsOf: values)
        }

        let dates = Array(Set(points.map(\.date))).sorted()
        var valuesByDate: [Date: [String: Double]] = [:]
        for point in preparedRange.points {
            valuesByDate[point.date, default: [:]][point.series] = point.value
        }
        var returnsByDate: [Date: [String: Double]] = [:]
        for point in preparedRange.returnPoints {
            returnsByDate[point.date, default: [:]][point.series] = point.value
        }
        let portfolioByDate = Dictionary(uniqueKeysWithValues:
            (allGrouped[ReturnsSeriesStyle.portfolio] ?? []).map { ($0.date, $0) }
        )
        let values = points.map(\.value)
        let domain: ClosedRange<Double>
        if let minimum = values.min(), let maximum = values.max() {
            let padding = max((maximum - minimum) * 0.12, max(abs(minimum), abs(maximum)) * 0.02, 1)
            domain = mode != .cashFlowMatched
                ? (minimum - padding)...(maximum + padding)
                : max(0, minimum - padding)...(maximum + padding)
        } else {
            domain = 0...1
        }

        return ReturnsDisplayData(
            transitionKey: "\(mode.rawValue)|\(range.rawValue)|\(visibleSeries.sorted().joined(separator: ","))",
            rangeTransitionKey: range.rawValue,
            points: points,
            grouped: grouped,
            dates: dates,
            valuesByDate: valuesByDate,
            returnsByDate: returnsByDate,
            portfolioByDate: portfolioByDate,
            unavailableBenchmarks: preparedRange.unavailableBenchmarks,
            domain: domain
        )
    }

    private static func makePoints(
        dates: [String],
        portfolio: [Double?],
        benchmarks: [String: [Double?]],
        transform: (Double) -> Double
    ) -> [ReturnsSeriesPoint] {
        let count = min(dates.count, portfolio.count)
        guard count > 0 else { return [] }
        let indices = Array(0..<count)
        let parsedDates = Dictionary(uniqueKeysWithValues: indices.compactMap { index in
            DayDateCodec.date(from: dates[index]).map { (index, $0) }
        })

        var result: [ReturnsSeriesPoint] = []
        for series in ReturnsSeriesStyle.order {
            for index in indices {
                guard let date = parsedDates[index] else { continue }
                let value: Double?
                if series == ReturnsSeriesStyle.portfolio {
                    value = portfolio[index]
                } else if let seriesValues = benchmarks[series], index < seriesValues.count {
                    value = seriesValues[index]
                } else {
                    value = nil
                }
                if let value {
                    result.append(ReturnsSeriesPoint(series: series, date: date, value: transform(value)))
                }
            }
        }
        return result
    }

    private static func makeMWRRanges(ledger: AccountMWRLedger?) -> [ChartTimeRange: ReturnsPreparedRange] {
        guard let ledger, let lastText = ledger.dates.last, let last = DayDateCodec.date(from: lastText) else {
            return Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map { ($0, .empty) })
        }
        let dates = ledger.dates.compactMap { DayDateCodec.date(from: $0) }
        guard dates.count == ledger.dates.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map { range in
            guard let first = dates.firstIndex(where: {
                range.includes($0, through: last, previousTradingDate: dates.dropLast().last,
                    calendar: ChartTimeRange.financeCalendar)
            }) else { return (range, .empty) }
            let values = ledger.returns(startIndex: max(0, first - 1))
            let points = makePoints(dates: values.dates, portfolio: values.portfolio,
                benchmarks: values.benchmarks, transform: { $0 * 100 })
                .filter { $0.date >= dates[first] }
            return (range, preparedRange(from: points, suppliedReturns: [], mode: .mwr))
        })
    }

    private static func makeRanges(
        from points: [ReturnsSeriesPoint],
        suppliedReturns: [ReturnsSeriesPoint],
        mode: ReturnsChartMode
    ) -> [ChartTimeRange: ReturnsPreparedRange] {
        guard let lastDate = points.map(\.date).max() else {
            return Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map { ($0, .empty) })
        }
        let calendar = ChartTimeRange.financeCalendar
        let tradingDates = Array(Set(points.map(\.date))).sorted()
        let previousTradingDate = tradingDates.dropLast().last
        return Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map { range in
            let filtered = points.filter {
                range.includes(
                    $0.date,
                    through: lastDate,
                    previousTradingDate: previousTradingDate,
                    calendar: calendar
                )
            }
            let filteredReturns = suppliedReturns.filter {
                range.includes(
                    $0.date,
                    through: lastDate,
                    previousTradingDate: previousTradingDate,
                    calendar: calendar
                )
            }
            return (range, preparedRange(from: filtered, suppliedReturns: filteredReturns, mode: mode))
        })
    }

    private static func preparedRange(
        from points: [ReturnsSeriesPoint],
        suppliedReturns: [ReturnsSeriesPoint],
        mode: ReturnsChartMode
    ) -> ReturnsPreparedRange {
        guard !points.isEmpty else { return .empty }
        let grouped = Dictionary(grouping: points, by: \.series)
        let displayPoints: [ReturnsSeriesPoint]
        let returnPoints: [ReturnsSeriesPoint]
        if mode == .cashFlowMatched {
            displayPoints = points
            returnPoints = suppliedReturns
        } else if mode == .twr {
            returnPoints = ReturnsSeriesStyle.order.flatMap { series -> [ReturnsSeriesPoint] in
                guard let values = grouped[series]?.sorted(by: { $0.date < $1.date }),
                      let first = values.first?.value else { return [] }
                let firstNAV = 1 + first / 100
                guard firstNAV != 0 else { return [] }
                return values.map { point in
                    ReturnsSeriesPoint(
                        series: series,
                        date: point.date,
                        value: (1 + point.value / 100) / firstNAV - 1
                    )
                }
            }
            displayPoints = returnPoints.map { point in
                ReturnsSeriesPoint(
                    series: point.series,
                    date: point.date,
                    value: point.value * 100
                )
            }
        } else {
            displayPoints = points
            returnPoints = points.map { point in
                ReturnsSeriesPoint(
                    series: point.series,
                    date: point.date,
                    value: point.value / 100
                )
            }
        }
        let available = Set(displayPoints.map(\.series))
        return ReturnsPreparedRange(
            points: sampled(displayPoints),
            returnPoints: returnPoints,
            unavailableBenchmarks: ComparisonBenchmarkCatalog.symbols.filter { !available.contains($0) }
        )
    }

    private static func sampled(_ points: [ReturnsSeriesPoint]) -> [ReturnsSeriesPoint] {
        let grouped = Dictionary(grouping: points, by: \.series)
        let portfolioDates = Array(Set(
            (grouped[ReturnsSeriesStyle.portfolio] ?? []).map(\.date)
        )).sorted()
        let sourceDates = portfolioDates.isEmpty
            ? Array(Set(points.map(\.date))).sorted()
            : portfolioDates

        guard sourceDates.count > 100 else {
            return ReturnsSeriesStyle.order.flatMap { series in
                (grouped[series] ?? []).sorted { $0.date < $1.date }
            }
        }

        let step = max(1, Int(ceil(Double(sourceDates.count) / 100)))
        var sampledDates = Set(sourceDates.enumerated().compactMap { index, date in
            index.isMultiple(of: step) ? date : nil
        })
        if let lastDate = sourceDates.last {
            sampledDates.insert(lastDate)
        }

        return ReturnsSeriesStyle.order.flatMap { series -> [ReturnsSeriesPoint] in
            guard let values = grouped[series] else { return [] }
            return values
                .filter { sampledDates.contains($0.date) }
                .sorted { $0.date < $1.date }
        }
    }
}

private struct ReturnsSeriesPoint: Identifiable {
    let series: String
    let date: Date
    let value: Double

    var id: String { "\(series)-\(date.timeIntervalSinceReferenceDate)" }
}

private struct ReturnsSelectedValue: Identifiable {
    let series: String
    let value: Double?
    let amountValue: Double?
    let returnValue: Double?
    let isVisible: Bool

    var id: String { series }
}

private struct ReturnsRankingRow: View {
    let item: ReturnsSelectedValue
    let rank: Int

    private var color: Color { ReturnsSeriesStyle.color(for: item.series) }
    private var isPortfolio: Bool { item.series == ReturnsSeriesStyle.portfolio }

    /// The catalogue's own names are translated; one remembered from a
    /// search is shown as found.
    private var benchmarkName: String? {
        guard let name = ComparisonBenchmarkCatalog.name(for: item.series) else { return nil }
        return ComparisonBenchmarkCatalog.names[item.series] == name ? L10n.label(name) : name
    }

    var body: some View {
        HStack(spacing: 16) {
            ReturnsRankBadge(rank: rank, color: color, isPortfolio: isPortfolio)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(isPortfolio ? "MY Portfolio" : item.series)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .layoutPriority(1)
                    // What the symbol is: "SPY 标普500".
                    if !isPortfolio, let name = benchmarkName {
                        Text(name)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Text(item.amountValue.map { DisplayFormat.money($0) } ?? "—")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let value = item.returnValue {
                HStack(spacing: 0) {
                    Text("\(value >= 0 ? "+" : "")\((value * 100).formatted(.number.precision(.fractionLength(1))))")
                    Text("%")
                        .foregroundStyle(.primary.opacity(0.3))
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
            } else {
                Text("—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 65)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.05), lineWidth: 1)
                }
        }
        .opacity(item.isVisible ? 1 : 0.20)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ReturnsBenchmarkPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var appLocale
    @AppStorage(ComparisonBenchmarkCatalog.preferenceKey) private var storedBenchmarks: String?
    @State private var query = ""
    @State private var results: [MarketSecurityResult] = []
    /// The query `results` answer, so a stale list is not mistaken for an
    /// empty one while the next search runs.
    @State private var searchedQuery = ""

    private var symbols: [String] { ComparisonBenchmarkCatalog.symbols(from: storedBenchmarks) }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isFull: Bool { symbols.count >= ComparisonBenchmarkCatalog.maximumCount }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    chosen
                    recommended
                } else {
                    found
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .appPageBackground(SettingsTemplate.pageBackground)
            .navigationTitle(L10n.text("对比标的"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.text("搜索指数或个股")
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    AppModalDoneButton { dismiss() }
                }
            }
            .task(id: searchText) { await search() }
        }
    }

    private var chosen: some View {
        Section {
            if symbols.isEmpty {
                Text(L10n.text("还没有对比标的，搜索或从推荐里添加。"))
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            ForEach(symbols, id: \.self) { symbol in
                row(symbol: symbol, name: ComparisonBenchmarkCatalog.name(for: symbol)) {
                    Button {
                        ComparisonBenchmarkCatalog.remove(symbol)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("移除 \(symbol)"))
                }
            }
            .onDelete { offsets in
                let current = symbols
                ComparisonBenchmarkCatalog.store(current.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))
            }
        } header: {
            Text(L10n.text("已添加 \(symbols.count)/\(ComparisonBenchmarkCatalog.maximumCount)"))
        } footer: {
            Text(L10n.text("左滑或点 − 移除。收益对比页上长按卡片也可以移除。"))
        }
    }

    @ViewBuilder
    private var recommended: some View {
        let missing = ComparisonBenchmarkCatalog.defaults.filter { !symbols.contains($0) }
        if !missing.isEmpty {
            Section {
                ForEach(missing, id: \.self) { symbol in
                    row(symbol: symbol, name: ComparisonBenchmarkCatalog.name(for: symbol)) {
                        addButton(symbol: symbol, name: nil)
                    }
                }
            } header: {
                Text(L10n.text("推荐指数"))
            }
        }
    }

    @ViewBuilder
    private var found: some View {
        Section {
            if results.isEmpty, searchedQuery == searchText {
                Text(L10n.text("没有找到「\(searchText)」"))
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            ForEach(results) { result in
                let symbol = Self.benchmarkSymbol(for: result)
                row(symbol: symbol, name: CompanyNameCatalog.displayName(ticker: result.ticker, fallback: result.name),
                    venue: result.venue) {
                    if symbols.contains(symbol) {
                        Button {
                            ComparisonBenchmarkCatalog.remove(symbol)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(CatfolioTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("移除 \(symbol)"))
                    } else {
                        addButton(symbol: symbol, name: result.name)
                    }
                }
            }
        } header: {
            Text(L10n.text("证券"))
        } footer: {
            Text(L10n.text("离线证券目录：美股与主要海外市场的股票和 ETF。"))
        }
    }

    private func addButton(symbol: String, name: String?) -> some View {
        Button {
            ComparisonBenchmarkCatalog.add(symbol, name: name)
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(isFull ? Color.secondary : CatfolioTheme.accent)
        }
        .buttonStyle(.plain)
        .disabled(isFull)
        .accessibilityLabel(L10n.text("添加 \(symbol)"))
    }

    private func row(symbol: String, name: String?, venue: String? = nil,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AssetLogo(ticker: symbol, logoSymbol: symbol, size: 36)
                if symbols.contains(symbol) {
                    // The colour the series draws in.
                    Circle()
                        .fill(ReturnsSeriesStyle.color(for: symbol))
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(SettingsTemplate.card, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(symbol)
                    .appText(.body, weight: .semibold)
                    .lineLimit(1)
                if let name {
                    // The built-in names are UI keys; a directory name is not.
                    Text(ComparisonBenchmarkCatalog.names[symbol] == name ? L10n.label(name) : name)
                        .appText(.label)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let venue {
                Text(venue)
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            trailing()
        }
        .frame(minHeight: 48)
    }

    /// The symbol the price history is fetched under: the broker's ticker
    /// with the exchange suffix the quote provider needs.
    private static func benchmarkSymbol(for result: MarketSecurityResult) -> String {
        LocalMarketDataClient.yahooSymbol(ticker: result.ticker, currency: result.currency ?? "USD")
    }

    /// Off the main thread: the directory holds some twenty thousand
    /// securities, and its first use decodes it.
    @MainActor private func search() async {
        let text = searchText
        guard !text.isEmpty else {
            results = []
            searchedQuery = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let found = await Task.detached(priority: .userInitiated) { () -> [MarketSecurityResult] in
            guard let catalog = try? CompanyReferenceCatalog.bundled.get() else { return [] }
            return MarketSecurityResult.search(text, in: catalog)
        }.value
        guard !Task.isCancelled else { return }
        results = found
        searchedQuery = text
    }
}
