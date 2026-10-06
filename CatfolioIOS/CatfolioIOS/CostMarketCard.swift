import SwiftUI
import UIKit

enum PortfolioHeroChartLayout {
    static let sectionHeight: CGFloat = 461
    static let plotTop: CGFloat = 118
    // Keep the UIKit-backed chart's frame entirely above the range picker.
    // A visual overlap can still intercept taps even when the chart's own
    // gesture overlay is inset, particularly with iOS 26 dark rendering.
    static let plotHeight: CGFloat = 280
    // Keep UIKit's long-press capture view away from the range buttons. The
    // chart still draws at full height; only its interactive surface is inset.
    static let chartInteractionBottomInset: CGFloat = 24
    static let pickerTop: CGFloat = 398
    static let pickerHeight: CGFloat = 62
}

struct CostMarketCard: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model

    let overview: PortfolioOverview
    let warning: String?
    let response: PortfolioChartResponse
    let isAwaitingEnrichedHistory: Bool
    /// Cached figures are up and fresh quotes are still coming in.
    private var isRefreshingBehindCache: Bool { model.isHomeRefreshingBehindCache }
    @State private var prepared: CostMarketPreparedData?
    @State private var isPreparing = true
    @State private var hasPreparedAllRanges = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var range = ChartTimeRange.yearToDate
    @State private var selectedDate: Date?
    @State private var measuredRange: ChartDateRange?
    @State private var showsNetDeposit = true
    /// Whether the all-time figure counts profit already taken. The reader's
    /// choice, kept between launches.
    @AppStorage("home.profitIncludesRealised") private var includesRealisedProfit = false
    /// The last profit pair that could be computed. While a refresh rebuilds
    /// the history the period's ends can briefly be missing, and the row
    /// would otherwise drop to "— · TWR —" until the new figures land.
    @State private var lastValidProfit: ProfitFigures?
    /// What the last tap did, shown for a moment and then gone.
    @Environment(\.colorScheme) private var colorScheme

    private var forcesChartLoadingState: Bool {
        LaunchArguments.contains("--show-chart-loading-state")
    }

    private var isChartLoading: Bool {
        forcesChartLoadingState || (prepared == nil && (isPreparing || isAwaitingEnrichedHistory))
    }

    init(
        overview: PortfolioOverview,
        response: PortfolioChartResponse,
        isAwaitingEnrichedHistory: Bool
    ) {
        self.overview = overview
        self.warning = response.warning
        self.response = response
        self.isAwaitingEnrichedHistory = isAwaitingEnrichedHistory
    }

    private var rangeData: CostMarketRangeData {
        guard let prepared else { return .empty }
        let chosen = prepared.data(for: range)
        guard chosen.rows.count <= 1 else { return chosen }
        // Too little for this window — a closed market, or history still on
        // its way. The nearest window the saved history does fill stands in,
        // rather than an empty chart over data the app already has.
        let fallbacks: [ChartTimeRange] = [.threeDays, .oneWeek, .oneMonth, .threeMonths, .yearToDate, .maximum]
        return fallbacks.lazy.filter { $0 != range }.map { prepared.data(for: $0) }
            .first { $0.rows.count > 1 } ?? chosen
    }

    /// The latest figures keep the app's name even after the market closes.
    /// A historical selection labels the day being inspected instead.
    private func headerLabel(at date: Date) -> String {
        let latest = DataDayLabel.latestSession(in: response.marketDates ?? [])
            ?? rangeData.rows.last?.dateText
        let displayed = selectedDate != nil || measuredRange != nil ? selectedPoint?.dateText : nil
        return DataDayLabel.homeTitle(displayedDay: displayed, latestDay: latest,
            locale: appLocale, now: date)
    }

    private var selectedPoint: CostMarketPlotPoint? {
        if let measuredRange {
            return rangeData.nearest(to: measuredRange.end)
        }
        guard let selectedDate else { return rangeData.rows.last }
        return rangeData.nearest(to: selectedDate)
    }

    private var measuredPoints: (start: CostMarketPlotPoint, end: CostMarketPlotPoint)? {
        guard let measuredRange,
              let start = rangeData.nearest(to: measuredRange.start),
              let end = rangeData.nearest(to: measuredRange.end) else { return nil }
        return (start, end)
    }

    private var displayedMarketValue: Double {
        if response.accountNAV != nil { return selectedPoint?.marketValue ?? response.currentPoint.marketValue }
        return selectedPoint?.marketValue ?? overview.summary.marketValue
    }

    private var displayedCost: Double {
        if response.accountNAV != nil { return selectedPoint?.cost ?? response.currentPoint.cost }
        return selectedPoint?.cost ?? overview.summary.totalCost
    }

    private var displayedProfit: Double {
        displayedMarketValue - displayedCost
    }

    private var rangePerformance: (amount: Double, percentage: Double) {
        if response.accountNAV != nil {
            if let measurement = measuredPoints {
                return accountPerformance(from: measurement.start.dateText, to: measurement.end.dateText)
            }
            guard let first = rangeData.rows.first, let end = selectedPoint else { return (.nan, .nan) }
            return accountPerformance(from: first.dateText, to: end.dateText)
        }
        if let measurement = measuredPoints {
            return costMarketChange(from: measurement.start, to: measurement.end)
        }
        guard range != .maximum,
              let start = rangeData.rows.first,
              let end = selectedPoint,
              start.id != end.id else {
            let percentage = displayedCost == 0 ? 0 : displayedProfit / displayedCost * 100
            return (displayedProfit, percentage)
        }

        // The market-value line can jump when cash is added or removed. Offset
        // that movement with the matching change in the cost/deposit line so
        // the header describes investment performance for the visible window,
        // rather than mistaking a contribution for a gain.
        return costMarketChange(from: start, to: end)
    }

    private func accountPerformance(from startDate: String, to endDate: String) -> (amount: Double, percentage: Double) {
        // The prepared source indexes the first occurrence of each date, just
        // as PortfolioChartResponse.accountPerformance does. Scrubbing must
        // not linearly scan the entire account history on every selected day.
        prepared?.accountPerformance(from: startDate, to: endDate)
            ?? response.accountPerformance(from: startDate, to: endDate)
    }

    private var displayedPrimaryAmount: Double {
        displayedMarketValue
    }

    /// True while the header reads the whole history rather than a window or a
    /// single day. Profit already taken belongs only to that figure: adding a
    /// lifetime total to one week's movement would say nothing.
    private var showsLifetimeProfit: Bool {
        response.accountNAV == nil && measuredRange == nil && selectedDate == nil && range == .maximum
    }

    /// Profit taken on sales, once the reader has asked for it and the header
    /// is showing the whole history.
    private var addedRealisedProfit: Double? {
        guard showsLifetimeProfit, includesRealisedProfit,
              model.realisedProfit.isFinite else { return nil }
        return model.realisedProfit
    }

    private var headerProfit: (amount: Double, percentage: Double) {
        let base = rangePerformance
        guard let realised = addedRealisedProfit else { return base }
        let amount = base.amount + realised
        return (amount, displayedCost == 0 ? 0 : amount / displayedCost * 100)
    }

    /// A tap turns profit already taken on and off, and says what it did.
    private func toggleProfitBasis() {
        guard showsLifetimeProfit else {
            range = .maximum
            selectedDate = nil
            measuredRange = nil
            includesRealisedProfit = model.realisedProfit.isFinite
            return
        }
        guard model.realisedProfit.isFinite else {
            show(note: L10n.text("暂无已实现利润"))
            return
        }
        includesRealisedProfit.toggle()
        if includesRealisedProfit {
            let gaps = model.realisedProfitGaps
            show(note: gaps > 0
                 ? L10n.text("已计入已实现利润 · \(gaps) 笔未计")
                 : L10n.text("已计入已实现利润"))
        } else {
            show(note: L10n.text("仅未实现利润"))
        }
    }

    private func show(note: String) {
        ToastCenter.shared.show(note, kind: .info)
    }

    private struct ProfitFigures: Equatable {
        let amount: Double
        let percentage: Double
        var isValid: Bool { amount.isFinite && percentage.isFinite }
    }

    /// The header's profit, or while it cannot be computed, the last one
    /// that could — never a pair of dashes in the middle of a refresh.
    private var shownProfit: (amount: Double, percentage: Double) {
        let current = ProfitFigures(amount: headerProfit.amount, percentage: headerProfit.percentage)
        if current.isValid { return headerProfit }
        if let lastValidProfit { return (lastValidProfit.amount, lastValidProfit.percentage) }
        return headerProfit
    }

    private var financialAccent: Color {
        let amount = shownProfit.amount
        if !amount.isFinite { return .secondary }
        return CatfolioTheme.heroPerformance(for: amount, scheme: colorScheme)
    }

    /// Nil while the reader is looking at their own portfolio.
    private var portfolioOwnerName: String? {
        PublicInvestorNaming.title(
            selection: model.publicInvestorSelection,
            isDemo: model.isFakeDataMode,
            isInvestorMode: model.isPublicInvestorMode
        )
    }

    var body: some View {
        let data = rangeData
        ZStack(alignment: .topLeading) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let isClosed = !model.holdings.isEmpty && !DataDayLabel.isLive(model.holdings, at: context.date)
                HStack(spacing: 4) {
                    // Public portfolios keep their owner's name.
                    Text(portfolioOwnerName ?? headerLabel(at: context.date))
                        .appCaps(.caption, weight: .semibold)
                    if response.isCurrentHoldingsOnly {
                        Text(L10n.text("持仓市值"))
                            .appCaps(.caption, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                    if portfolioOwnerName == nil, isClosed {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.text("休市"))
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .lineLimit(1)
            .foregroundStyle(CatfolioTheme.primaryText)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 15)

            CatfolioDisplayAmountText(
                text: model.publicDisclosureSummary?.amountLabel ?? DisplayFormat.money(
                    displayedPrimaryAmount,
                    signed: false,
                    fractionDigits: 2
                ),
                size: 40,
                symbolSize: 25.8,
                color: .primary
            )
            .contentTransition(.numericText(value: displayedPrimaryAmount))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: displayedPrimaryAmount)
            .refreshGlow(isActive: isRefreshingBehindCache)
            .frame(height: 44, alignment: .leading)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 32)

            HStack(spacing: 4) {
                let summaryAccent = financialAccent
                let profit = shownProfit
                Group {
                    Button(action: toggleProfitBasis) {
                        HStack(spacing: 4) {
                            Text(DisplayFormat.money(profit.amount, signed: true))
                                .contentTransition(.numericText(value: profit.amount))
                                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: profit.amount)

                            Text("·")
                                .foregroundStyle(.tertiary)

                            Text((response.accountNAV != nil ? "TWR " : "") + (profit.percentage.isFinite ? DisplayFormat.percent(profit.percentage, signed: false) : "—"))
                                .contentTransition(.numericText(value: profit.percentage))
                                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: profit.percentage)
                        }
                        .foregroundStyle(summaryAccent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(addedRealisedProfit == nil
                                        ? L10n.text("未实现利润") : L10n.text("已实现加未实现利润"))
                    .accessibilityHint(L10n.text("轻点切换是否计入已实现利润"))

                    Text("·")
                        .foregroundStyle(.tertiary)
                }
                // Known holdings figures can render before history preparation.
                .opacity(shownProfit.amount.isFinite && shownProfit.percentage.isFinite ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: prepared == nil)

                Button {
                    showsNetDeposit.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.text(response.accountNAV != nil ? "NET DEPOSIT" : "成本"))
                            .appCaps(.footnote)
                        Text(DisplayFormat.money(displayedCost))
                            .numericTransition(displayedCost)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showsNetDeposit ? 1 : 0.45)
                .accessibilityLabel(L10n.text("净入金线"))
                .accessibilityValue(showsNetDeposit ? L10n.text("显示") : L10n.text("隐藏"))
                .accessibilityHint(L10n.text("轻点切换显示或隐藏"))
                .foregroundStyle(Color.primary.opacity(colorScheme == .light ? 0.30 : 0.50))
            }
            .appNumber(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 82)

            chartContent(data: data)
                .frame(height: PortfolioHeroChartLayout.plotHeight)
                .clipped()
                .offset(y: PortfolioHeroChartLayout.plotTop)
                .zIndex(0)

            if !isChartLoading, data.rows.count > 1 {
                chartAxisLabels(data: data)
                    .frame(height: PortfolioHeroChartLayout.plotHeight)
                    .offset(y: PortfolioHeroChartLayout.plotTop)
            }

            ChartTimeRangePicker(
                selection: $range,
                isDisabled: isChartLoading || !hasPreparedAllRanges,
                usesBrightSelectedBackground: true
            )
            .frame(height: PortfolioHeroChartLayout.pickerHeight)
            .contentShape(Rectangle())
            .offset(y: PortfolioHeroChartLayout.pickerTop)
            .zIndex(2)
            .accessibilityLabel(response.accountNAV != nil ? L10n.text("账户资产与净入金时间范围") : L10n.text("成本与市值时间范围"))
        }
        .frame(height: PortfolioHeroChartLayout.sectionHeight, alignment: .topLeading)
        .preference(key: PortfolioHeroReadyPreference.self, value: !isChartLoading && hasPreparedAllRanges)
        .onChange(of: ProfitFigures(amount: headerProfit.amount, percentage: headerProfit.percentage),
                  initial: true) { _, figures in
            if figures.isValid { lastValidProfit = figures }
        }
        .task(id: "\(model.portfolioChartRevision)-\(isAwaitingEnrichedHistory)") {
            // Prepare locally available data even while history is refreshing.
            // Keep a complete mounted curve over interim snapshot-only responses.
            let response = response
            let initialRange = range
            let initialRanges: [ChartTimeRange] = initialRange == .maximum
                ? [.maximum]
                : [initialRange, .maximum]
            let source = await Task.detached(priority: .userInitiated) {
                CostMarketPreparedSource(response: response)
            }.value
            guard !Task.isCancelled else { return }
            if !hasPreparedAllRanges {
                let initial = await Task.detached(priority: .userInitiated) {
                    CostMarketPreparedData(source: source, requestedRanges: initialRanges)
                }.value
                guard !Task.isCancelled else { return }
                self.prepared = initial
                if initial.data(for: range).rows.count <= 1,
                   initial.data(for: .maximum).rows.count > 1 {
                    range = .maximum
                }
                isPreparing = false
                applyLaunchSelectionIfNeeded()
            }

            // The first visible plot should not wait for every alternate
            // range. Fill those caches at lower priority after the default
            // range is already on screen; the picker stays disabled until the
            // complete set is ready, so it can never select an empty cache.
            // On refresh, keep the existing complete cache interactive until
            // its replacement is ready; never dim the picker for background work.
            let complete = await Task.detached(priority: .utility) {
                CostMarketPreparedData(source: source)
            }.value
            guard !Task.isCancelled else { return }
            // A snapshot-only refresh must not discard the already mounted
            // cached curve. Account changes give this card a new identity.
            if !CostMarketPreparedData.shouldReplace(prepared, with: complete) { return }
            self.prepared = complete
            hasPreparedAllRanges = true
            if complete.data(for: range).rows.count <= 1,
               let availableRange = ChartTimeRange.allCases.first(where: {
                   complete.data(for: $0).rows.count > 1
               }) {
                range = availableRange
            }
        }
        .onChange(of: range) { _, _ in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedDate = nil
                measuredRange = nil
            }
        }
    }

    @ViewBuilder
    private func chartContent(data: CostMarketRangeData) -> some View {
        if forcesChartLoadingState || isChartLoading {
            StandardLineChartSkeleton(
                axisWidth: 0,
                topInset: 0,
                trailingEndpointInset: 21,
                seriesCount: 2,
                lineWidths: [2],
                appearanceID: "portfolio-assets"
            )
                .accessibilityElement()
                .accessibilityLabel(L10n.text("正在准备历史数据"))

        } else if !data.rows.isEmpty {
            FastCostMarketPlot(
                data: data,
                showsNetDeposit: showsNetDeposit,
                transitionKey: range.rawValue,
                showsLatestPoint: range != .oneDay || data.rows.count == 1,
                selectedPoint: selectedDate == nil && measuredRange == nil ? nil : selectedPoint,
                measuredRange: measuredRange,
                selectionIndicatorLabel: selectionIndicatorLabel,
                compactDates: [.oneDay, .oneWeek, .oneMonth, .twoMonths].contains(range),
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
            .accessibilityLabel(response.accountNAV != nil ? L10n.text("账户资产与净入金对比图，长按查看单日，双指测量区间") : L10n.text("成本与市值对比图，长按后单指拖动查看单日，保持第一指并加入第二指测量区间"))
        } else {
            // The header still shows the available account figures. No
            // historical curve is implied when no real observations exist.
            Color.clear
        }
    }

    private func chartAxisLabels(data: CostMarketRangeData) -> some View {
        let values = [
            data.domain.upperBound,
            (data.domain.lowerBound + data.domain.upperBound) / 2,
            data.domain.lowerBound,
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text(compactAxisValue(value))
                    .appNumber(.footnote)
                if index < values.count - 1 { Spacer() }
            }
        }
        .foregroundStyle(Color.white.opacity(colorScheme == .light ? 0.16 : 0.08))
        .padding(.leading, CatfolioStyle.pageHorizontalInset)
        .padding(.vertical, 13)
        .allowsHitTesting(false)
    }

    /// An axis label. This stopped at M, so a portfolio past a billion drew
    /// `1234M` where the ladder now gives `1B`.
    private func compactAxisValue(_ value: Double) -> String {
        DisplayFormat.compact(value, precision: .whole)
    }

    private func rangeDateText(from start: Date, to end: Date) -> String {
        "\(start.formatted(.dateTime.year().month(.abbreviated).day())) – \(end.formatted(.dateTime.year().month(.abbreviated).day()))"
    }

    private var selectionIndicatorLabel: String? {
        if let measurement = measuredPoints {
            return rangeDateText(from: measurement.start.date, to: measurement.end.date)
        }
        guard selectedDate != nil, let selectedPoint else { return nil }
        return selectedPoint.date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private func applyLaunchSelectionIfNeeded() {
        let data = rangeData
        let arguments = LaunchArguments.all
        guard data.rows.count > 1 else { return }
        if arguments.contains("--show-chart-selection"), selectedDate == nil {
            selectedDate = data.rows[data.rows.count / 3].date
        } else if arguments.contains("--show-chart-range"), measuredRange == nil {
            measuredRange = ChartDateRange(
                data.rows[data.rows.count / 3].date,
                data.rows[(data.rows.count * 2) / 3].date
            )
        }
    }
}

/// Canvas keeps a range switch to one draw pass instead of rebuilding hundreds
/// of Swift Charts marks. Filtering and domains are cached once; every range
/// keeps the original daily vertices so viewport zooms preserve the same curve.
struct FastCostMarketPlot: View {
    @Environment(\.locale) private var appLocale
    let data: CostMarketRangeData
    let showsNetDeposit: Bool
    let transitionKey: String
    let showsLatestPoint: Bool
    let selectedPoint: CostMarketPlotPoint?
    let measuredRange: ChartDateRange?
    let selectionIndicatorLabel: String?
    let compactDates: Bool
    let onSelect: (Date) -> Void
    let onMeasure: (ChartDateRange) -> Void
    let onInteractionEnded: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var seriesCache = CostMarketPlotSeriesCache()
    private let bottomHeight: CGFloat = 0

    var body: some View {
        // A selection changes this view every time the finger crosses a day.
        // Rebuilding both point arrays and sorting them in Series.init on
        // every move makes a long portfolio history compete with scrolling.
        let prepared = seriesCache.prepared(for: data, scheme: colorScheme,
                                            showsLatestPoint: showsLatestPoint)
        StandardLineChart(
            // Canvas paints later series above earlier ones. Keep the blue
            // net-deposit line underneath the adaptive white/green market
            // line so their crossings preserve the portfolio-value signal.
            series: showsNetDeposit ? [prepared.cost, prepared.market] : [prepared.market],
            interactionDates: prepared.interactionDates,
            domain: data.domain,
            yTicks: prepared.yTicks,
            axisWidth: 0,
            topInset: 0,
            bottomHeight: bottomHeight,
            interactionBottomInset: PortfolioHeroChartLayout.chartInteractionBottomInset,
            leadingLineOverflow: 0,
            trailingEndpointInset: 21,
            gridOpacity: 0,
            transitionKey: "\(transitionKey)-\(colorScheme == .light ? "light" : "dark")-\(showsNetDeposit)",
            rangeTransitionKey: transitionKey,
            appearanceID: "portfolio-assets",
            dataTransition: .viewportZoom,
            seriesChangeBounce: 12,
            // No morph out of the loading lines at launch: the blue line
            // slid from the placeholder's slope to its real level.
            animatesInitialAppearance: false,
            selectedDate: selectedPoint?.date,
            measuredRange: measuredRange,
            selectionIndicatorLabel: selectionIndicatorLabel,
            selectionSeriesIDs: showsNetDeposit ? ["market", "cost"] : ["market"],
            rangeSeriesIDs: showsNetDeposit ? ["market", "cost"] : ["market"],
            rangePrimarySeriesID: "market",
            dimsFutureDuringSelection: true,
            yAxisLabel: { _ in "" },
            xAxisLabel: shortDate,
            onSelect: onSelect,
            onMeasure: onMeasure,
            onInteractionEnded: onInteractionEnded
        )
    }

    private func shortDate(_ date: Date) -> String {
        compactDates
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated))
    }
}

/// Keeps the immutable chart geometry across selection-only body updates.
/// Every prepared range has a new identity, including a refreshed account or
/// currency response, so stale points cannot leak into a new portfolio.
@MainActor
final class CostMarketPlotSeriesCache {
    struct Prepared {
        let market: StandardLineChartSeries
        let cost: StandardLineChartSeries
        let interactionDates: [Date]
        let yTicks: [Double]
    }

    private struct Key: Equatable {
        let dataID: UUID
        let scheme: ColorScheme
        let showsLatestPoint: Bool
    }

    private var cachedKey: Key?
    private var cachedValue: Prepared?
    private(set) var rebuildCount = 0

    func prepared(for data: CostMarketRangeData, scheme: ColorScheme,
                  showsLatestPoint: Bool) -> Prepared {
        let key = Key(dataID: data.id, scheme: scheme, showsLatestPoint: showsLatestPoint)
        if key == cachedKey, let cachedValue { return cachedValue }

        let market = StandardLineChartSeries(
            id: "market",
            points: data.plottedRows.map {
                StandardLineChartPoint(id: $0.id, date: $0.date, value: $0.marketValue)
            },
            color: scheme == .light ? .white : CatfolioTheme.gain(for: .dark),
            lineWidth: 2,
            latestPointRadius: showsLatestPoint ? 5 : 0,
            latestPointColor: scheme == .light ? .black : nil,
            latestPointUsesGlass: false
        )
        let cost = StandardLineChartSeries(
            id: "cost",
            points: data.plottedRows.map {
                StandardLineChartPoint(id: "cost|\($0.id)", date: $0.date, value: $0.cost)
            },
            color: Color(red: 0.204, green: 0.459, blue: 1),
            lineWidth: 2,
            latestPointRadius: showsLatestPoint ? 5 : 0,
            latestPointUsesGlass: false
        )
        let ticks = (0..<5).map { index in
            let fraction = Double(index) / 4
            return data.domain.upperBound
                - (data.domain.upperBound - data.domain.lowerBound) * fraction
        }
        let value = Prepared(market: market, cost: cost,
                             interactionDates: data.rows.map(\.date), yTicks: ticks)
        cachedKey = key
        cachedValue = value
        rebuildCount &+= 1
        return value
    }
}

final class CostMarketPreparedSource: @unchecked Sendable {
    let points: [CostMarketPlotPoint]
    let lastDate: Date?
    let previousTradingDate: Date?
    let accountRowsByDate: [String: ChartPoint]
    let accountNAV: [String: Double]?

    init(response: PortfolioChartResponse) {
        accountNAV = response.accountNAV
        accountRowsByDate = response.accountNAV == nil ? [:] : Dictionary(
            response.positionHistory.rows.map { ($0.dateText, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // The latest observation may replace a same-day historical point or
        // extend it. Never let a nonempty history hide the current endpoint.
        var source = response.positionHistory.rows
        if response.currentPoint.marketValue.isFinite, response.currentPoint.cost.isFinite {
            source.removeAll { $0.dateText == response.currentPoint.dateText }
            source.append(response.currentPoint)
        }
        points = source.compactMap { row -> CostMarketPlotPoint? in
            guard row.marketValue.isFinite, row.cost.isFinite,
                  let date = DayDateCodec.date(from: row.dateText) else { return nil }
            return CostMarketPlotPoint(
                dateText: row.dateText,
                date: date,
                marketValue: row.marketValue,
                cost: row.cost
            )
        }.sorted { $0.date < $1.date }
        lastDate = points.last?.date
        if let sessions = response.marketDates?.sorted(), sessions.count >= 2 {
            let baseline = sessions[sessions.count - 2]
            previousTradingDate = points.last(where: { $0.dateText <= baseline })?.date
                ?? points.first?.date
        } else {
            previousTradingDate = points.dropLast().last?.date
        }
    }
}

final class CostMarketPreparedData: @unchecked Sendable {
    private let ranges: [ChartTimeRange: CostMarketRangeData]
    private let accountRowsByDate: [String: ChartPoint]
    private let accountNAV: [String: Double]?

    init(
        source: CostMarketPreparedSource,
        requestedRanges: [ChartTimeRange] = ChartTimeRange.allCases
    ) {
        let points = source.points
        accountRowsByDate = source.accountRowsByDate
        accountNAV = source.accountNAV

        guard let last = source.lastDate else {
            ranges = [:]
            return
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        ranges = Dictionary(uniqueKeysWithValues: requestedRanges.map { range in
            // Portfolio history is daily rather than intraday. Use the latest
            // two trading snapshots so 1D still shows the day-over-day move
            // instead of collapsing to an unhelpful single point.
            var filtered = points.filter {
                range.includes(
                    $0.date,
                    through: last,
                    previousTradingDate: source.previousTradingDate,
                    calendar: calendar
                )
            }
            // YTD starts at the prior year-end closing valuation.
            if range == .yearToDate, let first = filtered.first,
               let prior = points.last(where: { $0.date < first.date }) {
                filtered.insert(prior, at: 0)
            }
            return (range, Self.prepare(filtered))
        })
    }

    func data(for range: ChartTimeRange) -> CostMarketRangeData {
        ranges[range] ?? ranges[.maximum] ?? .empty
    }

    static func shouldReplace(_ cached: CostMarketPreparedData?, with fresh: CostMarketPreparedData) -> Bool {
        !(fresh.data(for: .maximum).rows.count <= 1 && (cached?.data(for: .maximum).rows.count ?? 0) > 1)
    }

    func accountPerformance(from startDate: String, to endDate: String) -> (amount: Double, percentage: Double) {
        guard let accountNAV, let start = accountRowsByDate[startDate],
              let end = accountRowsByDate[endDate], startDate <= endDate,
              let base = accountNAV[startDate], base > 0,
              let last = accountNAV[endDate] else { return (.nan, .nan) }
        return ((end.marketValue - start.marketValue) - (end.cost - start.cost), (last / base - 1) * 100)
    }

    private static func prepare(_ points: [CostMarketPlotPoint]) -> CostMarketRangeData {
        guard !points.isEmpty else { return .empty }
        // Range-dependent decimation changes the curve at shared dates. Keep
        // every daily vertex so the transition's union and the resting path
        // have identical geometry inside the final viewport.

        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        for point in points {
            minimum = min(minimum, point.marketValue, point.cost)
            maximum = max(maximum, point.marketValue, point.cost)
        }
        let span = max(maximum - minimum, max(abs(minimum), abs(maximum)) * 0.02, 1)
        let padding = span * 0.12
        return CostMarketRangeData(
            rows: points,
            plottedRows: points,
            domain: (minimum < 0 ? minimum - padding : max(0, minimum - padding))...(maximum + padding)
        )
    }
}

struct CostMarketRangeData {
    /// A freshly prepared range gets a fresh identity, while copies of that
    /// range keep it so chart-only state changes reuse its geometry.
    let id = UUID()
    let rows: [CostMarketPlotPoint]
    let plottedRows: [CostMarketPlotPoint]
    let domain: ClosedRange<Double>

    static let empty = CostMarketRangeData(rows: [], plottedRows: [], domain: 0...1)

    func nearest(to date: Date) -> CostMarketPlotPoint? {
        guard !rows.isEmpty else { return nil }
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].date < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return rows[0] }
        guard lower < rows.count else { return rows[rows.count - 1] }
        let before = rows[lower - 1]
        let after = rows[lower]
        return abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
    }
}

struct CostMarketPlotPoint: Identifiable {
    let dateText: String
    let date: Date
    let marketValue: Double
    let cost: Double

    var id: String { dateText }
}

struct PortfolioChartLoadingPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true

    var body: some View {
        let color = Color.primary.opacity(colorScheme == .light ? 0.08 : 0.14)
        ZStack(alignment: .topLeading) {
            HomeSkeletonBlock(width: 88, height: 10, color: color)
                .offset(x: CatfolioStyle.pageHorizontalInset, y: 15)
            HomeSkeletonBlock(width: 240, height: 44, color: color)
                .offset(x: CatfolioStyle.pageHorizontalInset, y: 32)
            HStack(spacing: 8) {
                HomeSkeletonBlock(width: 72, height: 13, color: color)
                HomeSkeletonBlock(width: 42, height: 13, color: color)
                HomeSkeletonBlock(width: 124, height: 13, color: color)
            }
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 82)

            // Match the current quiet chart-loading state, not the old mock
            // asset curves, which briefly looked like a different portfolio.
            Color.clear
                .frame(height: PortfolioHeroChartLayout.plotHeight)
                .offset(y: PortfolioHeroChartLayout.plotTop)

            ChartTimeRangePickerSkeleton()
                .frame(height: PortfolioHeroChartLayout.pickerHeight)
                .offset(y: PortfolioHeroChartLayout.pickerTop)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: PortfolioHeroChartLayout.sectionHeight, alignment: .topLeading)
    }
}

/// Change in the chart's cost-adjusted value, not a ledger-backed TWR/IRR.
/// Inputs share the chart's reporting currency; do not convert either endpoint twice.
func costMarketChange(
    from start: CostMarketPlotPoint, to end: CostMarketPlotPoint
) -> (amount: Double, percentage: Double) {
    let amount = (end.marketValue - start.marketValue) - (end.cost - start.cost)
    return (amount, start.marketValue == 0 ? 0 : amount / start.marketValue * 100)
}

/// Names the day a set of figures belongs to, the way a person would:
/// 今天, 昨天, the weekday within the past week, the date before that.
enum DataDayLabel {
    /// `now` is read on the reader's own calendar: just past midnight is
    /// already the next day for them, whatever the date is in UTC.
    static func text(for dayKey: String, locale: Locale, now: Date = Date(),
                     timeZone: TimeZone = .current) -> String {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard let date = DayDateCodec.date(from: dayKey),
              let current = DayDateCodec.date(from: today) else { return dayKey }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var style = Date.FormatStyle(date: .omitted, time: .omitted).locale(locale)
        style.timeZone = calendar.timeZone
        switch calendar.dateComponents([.day], from: date, to: current).day ?? 0 {
        case ...0: return L10n.text("今天")
        case 1: return L10n.text("昨天")
        case 2...6: return date.formatted(style.weekday(.abbreviated))
        default: return date.formatted(style.month(.abbreviated).day())
        }
    }

    /// No selection, or the newest available session, keeps the home title.
    /// Market opening hours do not determine whether data is the latest.
    static func homeTitle(displayedDay: String?, latestDay: String?, locale: Locale,
                          now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let displayedDay, let latestDay, displayedDay < latestDay else { return "CATFOLIO" }
        return text(for: displayedDay, locale: locale, now: now, timeZone: timeZone)
    }

    /// The latest trading day among these dates. A snapshot taken on a
    /// Saturday is dated Saturday, but its prices are Friday's.
    static func latestSession(in dates: [String]) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return dates.filter { key in
            guard let date = DayDateCodec.date(from: key) else { return false }
            return !calendar.isDateInWeekend(date)
        }.max()
    }

    /// True while any held listing's market is in session, so its prices are
    /// moving now.
    static func isLive(_ holdings: [Holding], at date: Date = Date()) -> Bool {
        holdings.contains { MarketHours.isOpen(ticker: $0.ticker, at: date) }
    }
}

