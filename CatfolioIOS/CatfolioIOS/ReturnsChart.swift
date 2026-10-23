import SwiftUI

enum ReturnsChartMode: String, CaseIterable {
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

enum ReturnsChartLayout {
    static let contentHorizontalInset: CGFloat = 20
    static let plotHeight: CGFloat = 392
    static let rangePickerHeight: CGFloat = 44
}

struct ReturnsTimeRangeControl: View {
    @Binding var selection: ChartTimeRange
    var isDisabled = false

    var body: some View {
        ChartTimeRangePicker(selection: $selection, isDisabled: isDisabled, isOnComparisonField: true)
        .frame(height: ReturnsChartLayout.rangePickerHeight)
        .accessibilityLabel(L10n.text("收益图表时间范围"))
    }
}

enum ReturnsSeriesStyle {
    static let portfolio = "组合"
    static var order: [String] { [portfolio] + ComparisonBenchmarkCatalog.symbols }
    static var displayOrder: [String] { order }
    /// One colour per series, used by the line, endpoint and ranking badge.
    ///
    /// Figma 437:11904's line palette stays consistent across the plot,
    /// endpoint labels and ranking badges.
    static let colors: [String: Color] = [
        portfolio: CatfolioPalette.ChartSeries.green,
        "SPY": CatfolioPalette.ChartSeries.orange,
        "QQQ": CatfolioPalette.ChartSeries.blue,
        "VTI": CatfolioPalette.ChartSeries.rose,
        "VOO": CatfolioPalette.ChartSeries.magenta,
        "DIA": CatfolioPalette.ChartSeries.sky,
        "IWM": CatfolioPalette.ChartSeries.peach,
        "VEU": CatfolioPalette.ChartSeries.mint,
        "GLD": Color(red: 0.784, green: 0.804, blue: 0.000),
    ]

    /// For symbols the reader added: light enough to carry the black label
    /// text, and apart from the fixed colours above.
    static let addedColors: [Color] = [
        CatfolioPalette.ChartSeries.lavender,
        CatfolioPalette.ChartSeries.pink,
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

struct ReturnsComparisonPlaceholder: View {
    @Binding var timeRange: ChartTimeRange
    let title: String
    let message: String
    let isLoading: Bool
    var disclosure: ReturnsChartDisclosure? = nil

    var body: some View {
        ReturnsChartPanel(disclosure: disclosure, surface: .page) {
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
            }
        } rows: {
            VStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { index in
                    HStack {
                        Circle().fill(ReturnsSeriesStyle.color(for: ReturnsSeriesStyle.order[index]))
                            .frame(width: 24, height: 24)
                        Text(index == 0 ? "MY Portfolio" : ReturnsSeriesStyle.order[index])
                            .font(Typography.rounded(size: 16, weight: .semibold))
                        Spacer()
                        Text("—")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 65)
                    .background { ReturnsGlassCardSurface() }
                    .opacity(isLoading ? 0.5 : 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct ReturnsPlotPlaceholder: View {
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

struct ReturnsChart: View {
    @Environment(\.locale) private var appLocale
    let comparison: ComparisonResponse
    @Binding var mode: ReturnsChartMode
    @Binding var timeRange: ChartTimeRange
    @Binding var selectedDate: Date?
    let onAddBenchmark: () -> Void
    let disclosure: ReturnsChartDisclosure?
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
        disclosure: ReturnsChartDisclosure? = nil,
        onAddBenchmark: @escaping () -> Void
    ) {
        self.comparison = comparison
        _mode = mode
        _timeRange = timeRange
        _selectedDate = selectedDate
        _highlightedSeries = highlightedSeries
        self.disclosure = disclosure
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

        ReturnsChartPanel(disclosure: disclosure, surface: .page) {
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
            }
        } rows: {
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

    /// The stored warnings are in Chinese, the language they were recorded
    /// in; they are translated here, where they are shown.
    private var emptyChartDescription: String {
        if mode == .cashFlowMatched {
            return comparison.warnings?.first(where: { $0.hasPrefix("现金流镜像：") }).map { L10n.message($0) }
                ?? L10n.text("现金流镜像：缺少完整资金账本和账户估值，暂不可用。")
        }
        if mode == .mwr {
            return comparison.warnings?.first(where: { $0.hasPrefix("MWR：") }).map { L10n.message($0) }
                ?? L10n.text("MWR 至少需要两个日期的组合价值与一笔有效现金流。")
        }
        return comparison.warnings?.first(where: { $0.hasPrefix("TWR：") }).map { L10n.message($0) }
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

struct ReturnsRangeMeasurement {
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
            .number.grouping(.never).precision(.fractionLength(0...digits))
                .sign(strategy: .always(includingZero: false)).locale(locale)
        ) + "%"
    }
}

struct ReturnsSelectedValue: Identifiable {
    let series: String
    let value: Double?
    let amountValue: Double?
    let returnValue: Double?
    let isVisible: Bool

    var id: String { series }
}

struct ReturnsRankingRow: View {
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
                        .font(Typography.rounded(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    // What the symbol is: "SPY 标普500".
                    if !isPortfolio, let name = benchmarkName {
                        Text(name)
                            .font(Typography.rounded(size: 14, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                FinancialText(item.amountValue.map { DisplayFormat.money($0) } ?? "—")
                    .font(Typography.rounded(size: 15, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let value = item.returnValue {
                HStack(spacing: 0) {
                    Text(verbatim: (value * 100).formatted(.number.precision(.fractionLength(1))
                        .sign(strategy: .always(includingZero: false))))
                    Text("%")
                        .foregroundStyle(.primary.opacity(0.3))
                }
                .font(Typography.rounded(size: 15, weight: .semibold))
                .monospacedDigit()
            } else {
                Text("—")
                    .font(Typography.rounded(size: 15, weight: .semibold))
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
