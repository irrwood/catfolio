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
        forcesChartLoadingState || (prepared == nil && isPreparing)
            || ((isAwaitingEnrichedHistory || response.positionHistory.rows.count > 1)
                && (prepared?.data(for: .maximum).rows.count ?? 0) <= 1)
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

    private var depositIsSettled: Bool {
        prepared != nil || DisplayCurrency.current == .usd || model.displayCurrencyHistory(for: response) != nil
    }

    /// Changes when the reader's currency, or the rates its history is read
    /// at, do.
    private var displayRatesKey: String {
        let currency = DisplayCurrency.current.rawValue
        let history = model.currencyHistories[currency]
        return "\(currency)-\(history?.from ?? "")-\(history?.closes.count ?? 0)-\(history?.closes.keys.max() ?? "")"
    }

    private var displayedMarketValue: Double {
        if response.accountNAV != nil { return selectedPoint?.marketValue ?? response.currentPoint.marketValue }
        return selectedPoint?.marketValue ?? overview.summary.marketValue
    }

    private var displayedCost: Double {
        // Before the ranges are prepared, the deposits still read in the
        // reader's currency: a pound paid in counts at its own day's rate.
        if response.accountNAV != nil { return selectedPoint?.cost ?? model.displayedPortfolioChart(response).currentPoint.cost }
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
        HomeStatusLine.shared.show(note)
    }

    /// The status speaks over the title, but never over a day the reader is
    /// inspecting on the chart.
    private var headerStatus: HomeHeaderLine? {
        guard selectedDate == nil, measuredRange == nil else { return nil }
        let status = HomeStatusLine.shared
        if let message = status.message { return .status(message.text, isError: message.kind == .error) }
        if status.isRefreshing || isRefreshingBehindCache { return .refreshing }
        return nil
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
        // Read here, not inside the timeline: what a timeline's content reads
        // does not redraw the card when it changes.
        let status = headerStatus
        ZStack(alignment: .topLeading) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let isClosed = !model.holdings.isEmpty && !DataDayLabel.isLive(model.holdings, at: context.date)
                // Public portfolios keep their owner's name.
                let title = HomeHeaderLine.title(portfolioOwnerName ?? headerLabel(at: context.date),
                    holdingsValueOnly: response.isCurrentHoldingsOnly, closed: portfolioOwnerName == nil && isClosed)
                SweepReplace(value: status ?? title, sweeps: HomeHeaderLine.sweeps) { line in
                    line.view
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
                color: .primary,
                // Optically under the label: the "$" carries its own blank.
                alignsInkToLeadingEdge: true
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
                            FinancialText(DisplayFormat.money(profit.amount, signed: true),
                                          isDirectional: response.accountNAV == nil && addedRealisedProfit == nil)
                                .contentTransition(.numericText(value: profit.amount))
                                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: profit.amount)

                            Text("·")
                                .foregroundStyle(.tertiary)

                            FinancialText((response.accountNAV != nil ? "TWR " : "") + (profit.percentage.isFinite ? DisplayFormat.percent(profit.percentage, signed: false) : "—"))
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
                        FinancialText(DisplayFormat.money(displayedCost))
                            .numericTransition(displayedCost)
                            // Settling swaps the figure as it fades in, not
                            // rolls or fades the dollar sum's digits into it.
                            .id(depositIsSettled)
                            .transition(.identity)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showsNetDeposit ? 1 : 0.45)
                // In pounds, deposits wait for the rates of the days they
                // arrived rather than show the dollar sum for a moment.
                .opacity(depositIsSettled ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: depositIsSettled)
                .accessibilityLabel(L10n.text("净入金线"))
                .accessibilityValue(showsNetDeposit ? L10n.text("显示") : L10n.text("隐藏"))
                .accessibilityHint(L10n.text("轻点切换显示或隐藏"))
                .foregroundStyle(Color.primary.opacity(colorScheme == .light ? 0.30 : 0.50))
            }
            .appNumber(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            // The leading triangle starts at the edge, under the label and
            // the total, rather than in the middle of its own slot.
            .environment(\.financialSignStyle, FinancialSignStyle(hugsLeadingEdge: true))
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
        .task(id: "\(model.portfolioChartRevision)-\(isAwaitingEnrichedHistory)-\(displayRatesKey)") {
            // Prepare locally available data even while history is refreshing.
            // Keep a complete mounted curve over interim snapshot-only responses.
            // Each day reads at its own rate in the reader's currency. Take
            // the saved rates first rather than draw the dollar figures and
            // then redraw; fresher ones follow from the page.
            if DisplayCurrency.current != .usd, model.displayCurrencyHistory(for: response) == nil {
                await model.loadCurrencyHistories(cachedOnly: true)
                guard !Task.isCancelled else { return }
            }
            let response = model.displayedPortfolioChart(response)
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

        } else if data.rows.count > 1 {
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
            // A refresh keeps the lines already drawn and runs the amount's
            // light along them, instead of swapping them for a skeleton.
            // Not while the reader is holding the chart to read a day.
            .refreshGlow(isActive: isRefreshingBehindCache && selectedDate == nil && measuredRange == nil)
        } else {
            // The header still shows the available account figures. No
            // historical curve is implied when no real observations exist,
            // and a single day is not a curve: drawn, it was the market and
            // cost end dots side by side at the left edge.
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
                FinancialText(compactAxisValue(value))
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

struct PortfolioChartLoadingPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true
    /// No account yet: a small button in the middle of the empty chart.
    var onAddAccount: (() -> Void)?

    var body: some View {
        let color = HomeSkeletonStyle.heroColor(for: colorScheme)
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

            if let onAddAccount {
                Button(action: onAddAccount) {
                    Label(L10n.text("添加账户"), systemImage: "plus")
                        .appText(.footnote, weight: .semibold)
                        .foregroundStyle(CatfolioTheme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(color, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.add-account")
                .frame(maxWidth: .infinity)
                .frame(height: PortfolioHeroChartLayout.plotHeight)
                .offset(y: PortfolioHeroChartLayout.plotTop)
            }

            // No slot drawn as chosen: the chart opens on YTD, or on MAX for
            // a short history, and a fixed highlight showed a different one.
            ChartTimeRangePickerSkeleton(selectedIndex: nil, fill: color)
                .frame(height: PortfolioHeroChartLayout.pickerHeight)
                .offset(y: PortfolioHeroChartLayout.pickerTop)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: PortfolioHeroChartLayout.sectionHeight, alignment: .topLeading)
    }
}
