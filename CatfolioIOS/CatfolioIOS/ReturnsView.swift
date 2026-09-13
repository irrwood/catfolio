import SwiftUI

struct ReturnsView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var showsPolicyComposer = false
    @State private var selectedHolding: Holding?
    @State private var heatmapExpanded = ProcessInfo.processInfo.arguments.contains("--expand-performance-heatmap")
    @State private var heroScroll = HeroScroll()
    #if DEBUG
    @State private var showsHeatmapPreview = ProcessInfo.processInfo.arguments.contains("--show-heatmap")
    #endif

    var body: some View {
        SettingsPage {
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
                    onToggle: toggleHeatmap
                )
            )
            .accessibilityIdentifier("performance.heatmap")
            SettingsSection(L10n.text("Performance")) {
                ForEach(ReturnsChartDestination.allCases.filter { $0 != .heatmap }) { chart in
                    SettingsNavigationRow(icon: .symbol(chart.icon), title: chart.title) {
                        ReturnsChartPage(chart: chart)
                    }
                    .accessibilityIdentifier("performance.chart.\(chart.rawValue)")
                }
            }
            SettingsSection(L10n.text("行情与 AI")) {
                SettingsNavigationRow(icon: .symbol("chart.xyaxis.line"), title: L10n.text("板块轮动")) {
                    SectorRotationView()
                }
                SettingsNavigationRow(icon: .symbol("point.3.connected.trianglepath.dotted"), title: L10n.text("市场轮动 · RRG")) {
                    StockChartsRotationView()
                }
                .accessibilityIdentifier("performance.stockcharts-rrg")
                SettingsNavigationRow(icon: .symbol("gauge.with.dots.needle.50percent"), title: L10n.text("行业情绪")) {
                    IndustrySentimentView()
                }
                SettingsNavigationRow(icon: .symbol("line.3.horizontal.decrease"), title: L10n.text("选股器")) {
                    StockScreenerView()
                }
                SettingsButtonRow(icon: .symbol("slider.horizontal.3"), title: L10n.text("策略编曲家"), action: { showsPolicyComposer = true })
                SettingsButtonRow(icon: .symbol("number.square"), title: L10n.text("税务计算"), action: {})
                    .disabled(true)
                    .accessibilityHint(L10n.text("功能暂未开放"))
            }
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
            guard oldPhase == .interacting, newPhase != .interacting,
                  heroScroll.pull >= HeatmapHeroState.threshold else { return }
            toggleHeatmap()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: heroScroll.pull >= HeatmapHeroState.threshold) { wasPast, isPast in
            hapticsEnabled && !wasPast && isPast
        }
        .tracksRootTabBarScroll()
        .accessibilityIdentifier("returns-root")
        .softTopScrollEdge()
        .navigationTitle(L10n.text("Performance"))
        .navigationBarTitleDisplayMode(.large)
        .toolbarVisibility(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $showsPolicyComposer) {
            PolicyComposerEntry()
        }
        .sheet(item: $selectedHolding) { holding in
            HoldingDetailView(holding: holding)
                .environment(model)
                .securityDetailSheet()
        }
        .securityDetailOpenFeedback(trigger: selectedHolding?.ticker, enabled: hapticsEnabled)
        #if DEBUG
        .navigationDestination(isPresented: $showsHeatmapPreview) {
            ReturnsChartPage(chart: .heatmap)
        }
        .task {
            showsPolicyComposer = ProcessInfo.processInfo.arguments.contains("--show-policy-composer")
        }
        #endif
    }
}

private extension ReturnsView {
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
    case heatmap, contributors, comparison, drawdown, underwater, valuation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heatmap: L10n.text("持仓热力图")
        case .contributors: L10n.text("收益来源")
        case .comparison: L10n.text("收益对比")
        case .drawdown: L10n.text("回撤水下曲线")
        case .underwater: L10n.text("水下分析")
        case .valuation: L10n.text("估值矩阵 (P/E vs 成长)")
        }
    }

    var icon: String {
        switch self {
        case .heatmap: "square.grid.2x2"
        case .contributors: "square.stack.3d.up"
        case .comparison: "chart.line.uptrend.xyaxis"
        case .drawdown: "water.waves"
        case .underwater: "water.waves.and.arrow.down"
        case .valuation: "chart.dots.scatter"
        }
    }
}

private struct ReturnsChartPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let chart: ReturnsChartDestination
    @State private var selectedHolding: Holding?

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
                    HoldingContributionChart()
                case .comparison:
                    ReturnsComparisonPanel()
                case .drawdown:
                    analytics(.drawdown)
                case .underwater:
                    UnderwaterAnalysisChart()
                case .valuation:
                    analytics(.valuation)
                }
            }
            .id("chart-page-top")
            .padding(.top, 20)
            .padding(.bottom, 72)
        }
        .background(Color(uiColor: .systemBackground))
        .softTopScrollEdge()
        .navigationTitle(chart.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .refreshable { await model.refreshReturnsPage() }
        .sheet(item: $selectedHolding) { holding in
            HoldingDetailView(holding: holding)
                .environment(model)
                .securityDetailSheet()
        }
        .securityDetailOpenFeedback(trigger: selectedHolding?.ticker, enabled: hapticsEnabled)
        .task {
            if (model.comparison == nil || model.returnsAnalytics == nil),
               !model.isReturnsLoading,
               !model.isReturnsAnalyticsLoading {
                await model.refreshReturnsPage()
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

struct ReturnsComparisonPanel: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @State private var chartMode: ReturnsChartMode = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-cash-flow") { return .cashFlowMatched }
        if arguments.contains("--show-mwr") { return .mwr }
        return .twr
    }()
    @State private var timeRange: ChartTimeRange = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-returns-1d") { return .oneDay }
        if arguments.contains("--show-returns-1w") { return .oneWeek }
        if arguments.contains("--show-returns-1m") { return .oneMonth }
        if arguments.contains("--show-returns-2m")
            || arguments.contains("--show-returns-3m") { return .twoMonths }
        if arguments.contains("--show-returns-ytd") { return .yearToDate }
        if arguments.contains("--show-returns-6m") { return .sixMonths }
        if arguments.contains("--show-returns-2y") { return .twoYears }
        if arguments.contains("--show-returns-all")
            || arguments.contains("--show-returns-max") { return .maximum }
        return .oneMonth
    }()
    @State private var selectedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let comparison = model.comparison {
                ReturnsChart(
                    comparison: comparison,
                    mode: $chartMode,
                    timeRange: $timeRange,
                    selectedDate: $selectedDate
                )
                .id(model.comparisonRevision)
            } else if model.isReturnsLoading {
                ReturnsComparisonPlaceholder(
                    mode: $chartMode,
                    timeRange: $timeRange,
                    title: L10n.text("正在加载收益数据"),
                    message: L10n.text("正在整理组合与基准的历史记录"),
                    isLoading: true
                )
            } else if let error = model.returnsError {
                ReturnsComparisonPlaceholder(
                    mode: $chartMode,
                    timeRange: $timeRange,
                    title: L10n.text("暂无收益记录"),
                    message: error,
                    isLoading: false
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { selectDrawableModeIfNeeded() }
        .onChange(of: model.comparisonRevision) { _, _ in
            selectDrawableModeIfNeeded()
        }
        .onChange(of: chartMode) { _, _ in selectedDate = nil }
        .onChange(of: timeRange) { _, _ in selectedDate = nil }
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
    static let chipSpacing: CGFloat = 8
    static let chipHeight: CGFloat = 40
    static let chipRowCount = 3
    static let valuesHeight: CGFloat = 136
    static let plotHeight: CGFloat = 426
    static let plotTopSpacing: CGFloat = 10
    static let rangePickerHeight: CGFloat = 44
    static let pickerTopSpacing: CGFloat = 20
    static let modePickerHeight: CGFloat = 50
    static let modePickerHorizontalInset: CGFloat = 20
}

private struct ReturnsTimeRangeControl: View {
    @Environment(\.locale) private var appLocale
    @Binding var selection: ChartTimeRange
    var isDisabled = false

    var body: some View {
        ChartTimeRangePicker(
            selection: $selection,
            isDisabled: isDisabled
        )
        .frame(height: ReturnsChartLayout.rangePickerHeight)
        .padding(.horizontal, ReturnsChartLayout.contentHorizontalInset)
        .accessibilityLabel(L10n.text("收益图表时间范围"))
    }
}

private enum ReturnsSeriesStyle {
    static let portfolio = "组合"
    static let order = [portfolio] + ComparisonBenchmarkCatalog.symbols
    static let displayOrder = order
    // LazyHGrid fills a column before moving horizontally. Keep VOO and VTI in
    // the final column so the broader comparison set appears before them.
    static let selectorOrder = [
        portfolio, "QQQ", "SPY",
        "DIA", "IWM", "VEU",
        "GLD", "VOO", "VTI",
    ]
    /// One colour per series, used by the line and by the chip above it.
    ///
    /// Where a series has an obvious colour, it gets it: gold is gold, and
    /// the reader's own portfolio is the same green the app uses for a gain
    /// everywhere else. The rest are chosen to stay apart from each other and
    /// from those two.
    static let colors: [String: Color] = [
        portfolio: Color(red: 0.004, green: 0.722, blue: 0.004),
        "SPY": Color(red: 1.000, green: 0.584, blue: 0.000),
        "QQQ": Color(red: 0.204, green: 0.459, blue: 1.000),
        "VTI": Color(red: 0.890, green: 0.000, blue: 0.271),
        "VOO": Color(red: 0.780, green: 0.000, blue: 0.910),
        "DIA": Color(red: 0.627, green: 0.804, blue: 1.000),
        "IWM": Color(red: 1.000, green: 0.824, blue: 0.741),
        // Freed by the portfolio moving to green, and far enough from the
        // gold below to stay separable.
        "VEU": Color(red: 0.000, green: 0.882, blue: 0.698),
        "GLD": Color(red: 1.000, green: 0.769, blue: 0.169),
    ]

    static func color(for series: String) -> Color {
        colors[series] ?? .secondary
    }

    static func title(for series: String) -> String {
        series == portfolio ? L10n.text("MY") : series
    }

    /// The chip takes the line's colour. It used to hold its own value for
    /// the portfolio, so the line was teal and the chip above it green — two
    /// colours for one series, which is the one thing a legend must not do.
    static func chipColor(for series: String) -> Color {
        color(for: series)
    }
}

private struct ReturnsComparisonPlaceholder: View {
    @Environment(\.locale) private var appLocale
    @Binding var mode: ReturnsChartMode
    @Binding var timeRange: ChartTimeRange
    let title: String
    let message: String
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReturnsSeriesPlaceholderGrid(mode: mode)
                .frame(height: ReturnsChartLayout.valuesHeight, alignment: .top)

            if isLoading {
                StandardLineChartSkeleton(
                    axisWidth: 33,
                    topInset: 0,
                    leadingLineOverflow: 65,
                    trailingEndpointInset: 9,
                    seriesCount: ReturnsSeriesStyle.displayOrder.count,
                    showsSeries: false
                )
                .frame(height: ReturnsChartLayout.plotHeight)
                .padding(.top, ReturnsChartLayout.plotTopSpacing)
                .padding(.trailing, ReturnsChartLayout.contentHorizontalInset)
            } else {
                ReturnsPlotPlaceholder(
                    title: title,
                    message: message,
                    isLoading: false,
                    maximumLines: 3
                )
                .frame(height: ReturnsChartLayout.plotHeight)
                .padding(.top, ReturnsChartLayout.plotTopSpacing)
                .padding(.trailing, ReturnsChartLayout.contentHorizontalInset)
            }

            if isLoading {
                ChartTimeRangePickerSkeleton()
                    .frame(height: ReturnsChartLayout.rangePickerHeight)
                    .padding(.horizontal, ReturnsChartLayout.contentHorizontalInset)
            } else {
                ReturnsTimeRangeControl(selection: $timeRange, isDisabled: true)
            }

            Group {
                if isLoading {
                    ReturnsModePickerSkeleton()
                } else {
                    Picker(L10n.text("图表口径"), selection: $mode) {
                        ForEach(ReturnsChartMode.displayOrder, id: \.self) { chartMode in
                            Text(chartMode.displayTitle).tag(chartMode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(true)
                }
            }
            .frame(height: ReturnsChartLayout.modePickerHeight)
            .padding(.horizontal, ReturnsChartLayout.modePickerHorizontalInset)
            .padding(.top, ReturnsChartLayout.pickerTopSpacing)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ReturnsModePickerSkeleton: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme

    private var skeletonColor: Color {
        CatfolioTheme.skeletonFill
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index == 0 ? skeletonColor.opacity(1.25) : skeletonColor)
                    .frame(width: index == 2 ? 58 : 42, height: 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(skeletonColor.opacity(0.72), in: Capsule())
        .accessibilityHidden(true)
    }
}

private struct ReturnsSeriesPlaceholderGrid: View {
    @Environment(\.locale) private var appLocale
    let mode: ReturnsChartMode

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = max(
                148,
                (geometry.size.width
                    - ReturnsChartLayout.contentHorizontalInset * 2
                    - ReturnsChartLayout.chipSpacing) / 2
            )

            ScrollView(.horizontal) {
                LazyHGrid(
                    rows: Array(
                        repeating: GridItem(.fixed(ReturnsChartLayout.chipHeight), spacing: ReturnsChartLayout.chipSpacing),
                        count: ReturnsChartLayout.chipRowCount
                    ),
                    alignment: .top,
                    spacing: ReturnsChartLayout.chipSpacing
                ) {
                    ForEach(ReturnsSeriesStyle.selectorOrder, id: \.self) { series in
                        ReturnsSeriesPlaceholderCard(
                            title: ReturnsSeriesStyle.title(for: series),
                            color: ReturnsSeriesStyle.chipColor(for: series),
                            mode: mode
                        )
                        .frame(width: cardWidth)
                    }
                }
                .padding(.horizontal, ReturnsChartLayout.contentHorizontalInset)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

private struct ReturnsSeriesPlaceholderCard: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let color: Color
    let mode: ReturnsChartMode

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .appCaps(.micro, weight: .semibold)
                .lineLimit(1)
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 42, height: 10)
            Capsule()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 46, height: 10)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: ReturnsChartLayout.chipHeight, maxHeight: ReturnsChartLayout.chipHeight)
        .redacted(reason: .placeholder)
        .opacity(0.28)
        .background {
            ReturnsSeriesCardSurface(color: color, isVisible: false)
        }
        .accessibilityHidden(true)
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
            Text(message)
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
        .accessibilityLabel("\(title)，\(message)")
    }
}

private struct ReturnsChart: View {
    @Environment(\.locale) private var appLocale
    let comparison: ComparisonResponse
    @Binding var mode: ReturnsChartMode
    @Binding var timeRange: ChartTimeRange
    @Binding var selectedDate: Date?
    @State private var visibleSeries = Set(ReturnsSeriesStyle.displayOrder)
    @State private var measuredRange: ChartDateRange?
    @State private var prepared: ReturnsPreparedData?
    @State private var displayData = ReturnsDisplayData.empty
    @State private var isPreparing = true

    init(
        comparison: ComparisonResponse,
        mode: Binding<ReturnsChartMode>,
        timeRange: Binding<ChartTimeRange>,
        selectedDate: Binding<Date?>
    ) {
        self.comparison = comparison
        _mode = mode
        _timeRange = timeRange
        _selectedDate = selectedDate
    }

    private var isChartLoading: Bool {
        isPreparing || ProcessInfo.processInfo.arguments.contains("--show-returns-loading-state")
    }

    var body: some View {
        let chartDates = displayData.dates
        let chartDate = nearestDate(in: chartDates)
        let valuesAtDate = values(on: chartDate)
        let hasDrawableLine = displayData.hasDrawableLine
        let measurement = rangeMeasurement()

        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isChartLoading {
                    ReturnsSeriesPlaceholderGrid(mode: mode)
                } else {
                    seriesCards(valuesAtDate)
                }
            }
            .frame(height: ReturnsChartLayout.valuesHeight, alignment: .top)

            if isChartLoading {
                StandardLineChartSkeleton(
                    axisWidth: 33,
                    topInset: 0,
                    leadingLineOverflow: 65,
                    trailingEndpointInset: 9,
                    seriesCount: ReturnsSeriesStyle.displayOrder.count,
                    showsSeries: false
                )
                .frame(height: ReturnsChartLayout.plotHeight)
                .padding(.top, ReturnsChartLayout.plotTopSpacing)
                .padding(.trailing, ReturnsChartLayout.contentHorizontalInset)
            } else if !hasDrawableLine {
                ReturnsPlotPlaceholder(
                    title: L10n.text("暂无可绘制数据"),
                    message: emptyChartDescription,
                    isLoading: false
                )
                .frame(height: ReturnsChartLayout.plotHeight)
                .padding(.top, ReturnsChartLayout.plotTopSpacing)
                .padding(.trailing, ReturnsChartLayout.contentHorizontalInset)
            } else {
                FastReturnsPlot(
                    grouped: displayData.grouped,
                    dates: chartDates,
                    domain: displayData.domain,
                    transitionKey: "\(mode.rawValue)|\(timeRange.rawValue)|\(visibleSeries.sorted().joined(separator: ","))",
                    selectedDate: selectedDate == nil && measuredRange == nil ? nil : chartDate,
                    measuredRange: measuredRange,
                    mode: mode,
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
                .padding(.top, ReturnsChartLayout.plotTopSpacing)
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

            if isChartLoading {
                ChartTimeRangePickerSkeleton()
                    .frame(height: ReturnsChartLayout.rangePickerHeight)
                    .padding(.horizontal, ReturnsChartLayout.contentHorizontalInset)
            } else {
                ReturnsTimeRangeControl(selection: $timeRange)
            }

            if mode == .twr, hasDrawableLine,
               let note = comparison.warnings?.first(where: { $0.hasPrefix("每日 TWR") }) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ReturnsChartLayout.contentHorizontalInset)
                    .padding(.vertical, 8)
            }
            if mode == .mwr, hasDrawableLine,
               let note = comparison.warnings?.first(where: { $0.hasPrefix("MWR：") }) {
                Text(L10n.label(note)).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, ReturnsChartLayout.contentHorizontalInset)
                    .padding(.vertical, 8)
            }
            if mode == .cashFlowMatched, hasDrawableLine,
               let note = comparison.warnings?.first(where: { $0.hasPrefix("现金流镜像：") }) {
                Text(L10n.label(note)).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, ReturnsChartLayout.contentHorizontalInset)
                    .padding(.vertical, 8)
            }

            Group {
                if isChartLoading {
                    ReturnsModePickerSkeleton()
                } else {
                    Picker(L10n.text("图表口径"), selection: $mode) {
                        ForEach(ReturnsChartMode.displayOrder, id: \.self) { chartMode in
                            Text(chartMode.displayTitle).tag(chartMode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel(L10n.text("收益图表口径"))
                }
            }
            .frame(height: ReturnsChartLayout.modePickerHeight)
            .padding(.horizontal, ReturnsChartLayout.modePickerHorizontalInset)
            .padding(.top, ReturnsChartLayout.pickerTopSpacing)
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
        GeometryReader { geometry in
            let cardWidth = max(
                148,
                (geometry.size.width
                    - ReturnsChartLayout.contentHorizontalInset * 2
                    - ReturnsChartLayout.chipSpacing) / 2
            )
            let valuesBySeries = Dictionary(uniqueKeysWithValues: values.map { ($0.series, $0) })

            ScrollView(.horizontal) {
                LazyHGrid(
                    rows: Array(
                        repeating: GridItem(.fixed(ReturnsChartLayout.chipHeight), spacing: ReturnsChartLayout.chipSpacing),
                        count: ReturnsChartLayout.chipRowCount
                    ),
                    alignment: .top,
                    spacing: ReturnsChartLayout.chipSpacing
                ) {
                    ForEach(ReturnsSeriesStyle.selectorOrder.compactMap { valuesBySeries[$0] }) { item in
                        Button {
                            toggleSeries(item.series)
                        } label: {
                            CompactSeriesValue(
                                title: ReturnsSeriesStyle.title(for: item.series),
                                value: item.value,
                                amountValue: item.amountValue,
                                color: ReturnsSeriesStyle.chipColor(for: item.series),
                                mode: mode,
                                returnValue: item.returnValue,
                                isVisible: item.isVisible
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(width: cardWidth)
                        .accessibilityValue(item.isVisible ? L10n.text("已显示") : L10n.text("已隐藏"))
                    }
                }
                .padding(.horizontal, ReturnsChartLayout.contentHorizontalInset)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
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

    private func toggleSeries(_ series: String) {
        if visibleSeries.contains(series) {
            guard visibleSeries.count > 2 else { return }
            visibleSeries.remove(series)
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
        let arguments = ProcessInfo.processInfo.arguments
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
private struct FastReturnsPlot: View {
    @Environment(\.locale) private var appLocale
    let grouped: [String: [ReturnsSeriesPoint]]
    let dates: [Date]
    let domain: ClosedRange<Double>
    let transitionKey: String
    let selectedDate: Date?
    let measuredRange: ChartDateRange?
    let mode: ReturnsChartMode
    let onSelect: (Date) -> Void
    let onMeasure: (ChartDateRange) -> Void
    let onInteractionEnded: (Int) -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private let axisWidth: CGFloat = 33
    private let bottomHeight: CGFloat = 0
    private let endpointConnectorWidth: CGFloat = 9

    var body: some View {
        let standardSeries = ReturnsSeriesStyle.order.compactMap { series -> StandardLineChartSeries? in
            guard let values = grouped[series], !values.isEmpty else { return nil }
            return StandardLineChartSeries(
                id: series,
                points: values.map {
                    StandardLineChartPoint(
                        id: "\(series)|\($0.id)",
                        date: $0.date,
                        value: $0.value
                    )
                },
                color: ReturnsSeriesStyle.color(for: series),
                lineWidth: 2,
                dash: dashPattern(for: series),
                selectionRadius: series == ReturnsSeriesStyle.portfolio ? 3.6 : 2.8,
                latestPointRadius: nil
            )
        }
        StandardLineChart(
            series: standardSeries,
            interactionDates: dates,
            domain: domain,
            yTicks: (0..<6).map { index in
                let fraction = Double(index) / 5
                return domain.upperBound - (domain.upperBound - domain.lowerBound) * fraction
            },
            axisWidth: axisWidth,
            topInset: 0,
            bottomHeight: bottomHeight,
            leadingLineOverflow: 65,
            trailingEndpointInset: endpointConnectorWidth,
            transitionKey: transitionKey,
            dataTransition: .viewportZoom,
            animatesInitialAppearance: true,
            selectedDate: selectedDate,
            measuredRange: measuredRange,
            rangeSeriesIDs: [ReturnsSeriesStyle.portfolio],
            rangePrimarySeriesID: ReturnsSeriesStyle.portfolio,
            yAxisFont: Typography.number(.micro),
            yAxisColor: Color.secondary.opacity(0.48),
            yAxisLabel: axisLabel,
            xAxisLabel: shortDate,
            onSelect: onSelect,
            onMeasure: onMeasure,
            onInteractionEnded: onInteractionEnded
        )
        .overlay {
            GeometryReader { geometry in
                ForEach(endpointLayouts(height: geometry.size.height)) { endpoint in
                    // Continue each curve into its capsule, including labels
                    // shifted vertically to keep neighboring tickers apart.
                    Path { path in
                        let labelLeadingX = geometry.size.width - axisWidth
                        path.move(to: CGPoint(
                            x: labelLeadingX - endpointConnectorWidth,
                            y: endpoint.lineY
                        ))
                        path.addLine(to: CGPoint(
                            x: labelLeadingX + axisWidth / 2,
                            y: endpoint.y
                        ))
                    }
                    .stroke(endpoint.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                    Text(endpoint.text)
                        .font(Typography.text(size: 10, weight: .bold))
                        .foregroundStyle(Color.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(width: axisWidth, height: 18)
                        .background(endpoint.color, in: Capsule())
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
                lineY: rawY,
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

    private func dashPattern(for series: String) -> [CGFloat] {
        guard differentiateWithoutColor,
              series != ReturnsSeriesStyle.portfolio,
              let index = ReturnsSeriesStyle.order.firstIndex(of: series) else { return [] }
        let patterns: [[CGFloat]] = [
            [8, 4], [2, 3], [10, 3, 2, 3], [5, 3],
            [12, 4], [3, 2, 1, 2], [7, 2], [1, 3],
        ]
        return patterns[(index - 1) % patterns.count]
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
        return "\(Int(value.rounded()))%"
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

private struct ReturnsEndpointLabelLayout: Identifiable {
    let id: String
    let text: String
    let color: Color
    let lineY: CGFloat
    var y: CGFloat
}

private struct ReturnsDisplayData {
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
        guard let nearestDate = cashFlowValuesByDate.keys.min(by: {
            abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
        }) else { return nil }
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

private struct CompactSeriesValue: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let value: Double?
    let amountValue: Double?
    let color: Color
    let mode: ReturnsChartMode
    let returnValue: Double?
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(ReturnsTypography.semibold(11, relativeTo: .caption))
                .tracking(2)
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .layoutPriority(2)

            Text(formattedAmount)
                .appNumber(.caption)
                .foregroundStyle(secondaryValueColor)
                .contentTransition(.numericText(value: amountValue ?? 0))
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: amountValue)
                .lineLimit(1)
                .minimumScaleFactor(0.50)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(formattedReturn)
                .appNumber(.micro)
                .monospacedDigit()
                .foregroundStyle(primaryTextColor)
                .contentTransition(.numericText(value: returnValue ?? 0))
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: returnValue)
                .lineLimit(1)
                .minimumScaleFactor(0.56)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: ReturnsChartLayout.chipHeight, maxHeight: ReturnsChartLayout.chipHeight)
        .background {
            ReturnsSeriesCardSurface(color: color, isVisible: isVisible)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(isVisible ? 1 : 0.42)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isVisible)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    private var secondaryValueColor: Color {
        colorScheme == .dark ? .secondary : .primary
    }

    private var formattedAmount: String {
        amountValue.map { DisplayFormat.money($0) } ?? "—"
    }

    private var formattedReturn: String {
        if let returnValue {
            return DisplayFormat.ratioPercent(returnValue)
        }
        guard let value else { return "—" }
        return mode == .cashFlowMatched ? "—" : DisplayFormat.percent(value)
    }
}

private struct ReturnsSeriesCardSurface: View {
    @Environment(\.locale) private var appLocale
    let color: Color
    let isVisible: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let visibility = isVisible ? 1.0 : 0.34

        ZStack {
            // Treat the tint as a light source behind the glass. The blur is
            // deliberately allowed to escape the chip bounds so neighbouring
            // glass surfaces pick up a restrained ambient reflection.
            shape
                .fill(color.opacity((colorScheme == .dark ? 0.026 : 0.008) * visibility))
                .scaleEffect(x: 1.08, y: 1.22)
                .blur(radius: 20)
                .blendMode(colorScheme == .dark ? .plusLighter : .normal)

            shape
                .fill(color.opacity((colorScheme == .dark ? 0.060 : 0.020) * visibility))
                .scaleEffect(x: 1.025, y: 1.09)
                .blur(radius: 8)
                .blendMode(colorScheme == .dark ? .plusLighter : .normal)

            glassShell(shape: shape, visibility: visibility)

            shape
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [
                                color.opacity(0.20 * visibility),
                                color.opacity(0.08 * visibility),
                                Color.black.opacity(0.13),
                            ]
                            : [
                                color.opacity(0.10 * visibility),
                                color.opacity(0.035 * visibility),
                                Color.white.opacity(0.16),
                            ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.20 : 0.46),
                            color.opacity(colorScheme == .dark ? 0.18 : 0.10),
                            Color.white.opacity(colorScheme == .dark ? 0.05 : 0.20),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func glassShell(
        shape: RoundedRectangle,
        visibility: Double
    ) -> some View {
        if #available(iOS 26.0, *) {
            if colorScheme == .dark {
                Color.clear
                    .glassEffect(
                        .regular.tint(color.opacity(0.12 * visibility)),
                        in: shape
                    )
            } else {
                Color.clear
                    .glassEffect(
                        .clear.tint(color.opacity(0.06 * visibility)),
                        in: shape
                    )
            }
        } else {
            shape
                .fill(.ultraThinMaterial)
        }
    }
}
