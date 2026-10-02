import SwiftUI
import UIKit
import Observation

/// Owns the fast-changing chart selection so dragging never invalidates the
/// volume profile, 52-week range, financials and analyst sections below it.
struct HoldingDetailPriceSection: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model: AppModel?
    let holding: Holding
    let priceHistory: SecurityPriceHistory?
    let priceHistoryError: String?
    let averageCost: Double?
    let selectedAccountKeys: Set<String>
    /// Whose trades the chart marks; the selection plus, under 全部, accounts
    /// that have sold out. Defaults to the selection.
    var tradeAccountKeys: Set<String>? = nil
    var accountOptions: [HoldingDetailAccountOption] = []
    var onSelectAll: () -> Void = {}
    var onToggleAccount: (String) -> Void = { _ in }
    var isRefreshing = false
    var refreshError: String?
    var onRefresh: () -> Void = {}
    var cachedContent: HoldingDetailCachedContent?

    @State private var priceSelection: SecurityPriceSelection?
    @State private var explanation: SecurityPaperRequest?
    @State private var explanationAnchor = SecurityPaperSourceAnchor()
    @State private var tradeReadoutReservations: [SecurityTradeReadout.Measurement] = []
    /// Whether this section first drew the placeholder line — then the line
    /// grows out of it when the history comes, instead of replacing it.
    @State private var startedWithoutHistory: Bool?

    private var movement: SecurityPriceMoveContext? {
        guard let priceHistory else { return nil }
        let isFund = HoldingSecurityKind.classify(holding) == .fund
        return SecurityPriceMoveContext.latestSession(history: priceHistory,
            name: isFund ? holding.displayName : holding.shortName, isFund: isFund)
    }

    var body: some View {
        VStack(spacing: 0) {
            HoldingDetailHeader(
                holding: holding,
                // One source for the day's move, the home list's: known at
                // once, and the page's own fresher quote is written back into
                // it, so the page and the list never show two numbers.
                marketTodayChange: model?.holdingDailyChanges[holding.ticker.uppercased()],
                selectedPrice: priceSelection?.price ?? priceHistory?.latestAvailablePrice,
                selectedReturn: priceSelection?.returnPercent,
                selectedTrades: priceSelection?.trades ?? [],
                tradeReadoutReservations: tradeReadoutReservations,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh
            )

            if let priceHistory {
                SecurityPriceChart(
                    history: priceHistory,
                    averageCost: averageCost,
                    selectedAccountKeys: tradeAccountKeys ?? selectedAccountKeys,
                    cachedContent: cachedContent,
                    followsPlaceholder: startedWithoutHistory ?? false,
                    onSelectionChange: { selection in
                        guard priceSelection != selection else { return }
                        priceSelection = selection
                    }
                )
            } else if let priceHistoryError {
                SecurityPriceChartState(
                    title: L10n.text("暂无价格走势"),
                    message: priceHistoryError,
                    isLoading: false
                )
            } else {
                SecurityPriceChartState(
                    title: L10n.text("正在读取价格走势"),
                    message: L10n.text("正在整理历史行情与买卖记录"),
                    isLoading: true,
                    appearanceID: "security-price|\(holding.ticker)|\(holding.quoteCurrency ?? "USD")"
                )
            }

            // A held security keeps the accounts' place from the first frame:
            // empty shells of the same size until the accounts are read.
            // Swapped in place, not cross-faded: glass drawn through an
            // opacity transition vanished for its duration, and the row went
            // blank between the shells and the cards.
            if !accountOptions.isEmpty {
                HoldingDetailAccountSelector(options: accountOptions, selectedAccountKeys: selectedAccountKeys,
                    onSelectAll: onSelectAll, onToggleAccount: onToggleAccount)
            } else if holding.shares > 0 {
                HoldingDetailAccountSelector.shells
            }

            HStack(spacing: 12) {
                Button {
                    guard let movement,
                          let request = SecurityPaperRequest(context: movement, sourceFrame: explanationAnchor.frame) else { return }
                    // Ask at the tap, before the cover is even inserted, so the
                    // whole entrance and flip run while the note is researched.
                    // The paper's own `start` then joins this request.
                    SecurityDailyMoveStore.shared.start(movement)
                    SecurityDailyMovePresentation.withoutSystemTransition { explanation = request }
                } label: {
                    HoldingHeaderActionLabel(title: movement?.noteTitle ?? L10n.text("今天有什么动静？"),
                        asset: "HoldingWhyMove")
                        // There from the first frame; its dated title fades in.
                        .animation(.easeOut(duration: 0.25), value: movement?.noteTitle)
                }
                .modifier(HoldingHeaderButtonStyle())
                .disabled(movement == nil)
                .background(SecurityPaperSourceReader(anchor: explanationAnchor))
                .accessibilityIdentifier("holding-detail-why-move")
                .accessibilityHint(movement?.intervalText ?? L10n.text("等待带日期的价格走势"))
                // Refreshing is a tap on the price above, not a button here.
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if let refreshError {
                Text(L10n.message(refreshError)).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 20)
            }
        }
        .appFullScreenCover(item: $explanation) { request in
            SecurityDailyMovePaper(context: request.context, logoSymbol: holding.logoSymbol, sourceFrame: request.sourceFrame)
        }
        .onChange(of: selectedAccountKeys) { _, _ in
            priceSelection = nil
            updateTradeReadoutReservations()
        }
        .onAppear {
            if startedWithoutHistory == nil { startedWithoutHistory = priceHistory == nil }
        }
        .onChange(of: priceHistory?.trades, initial: true) { _, _ in
            updateTradeReadoutReservations()
        }
        .onChange(of: appLocale.identifier) { _, _ in
            updateTradeReadoutReservations()
        }
    }

    private func updateTradeReadoutReservations() {
        let trades = (priceHistory?.trades ?? []).compactMap { $0.filtered(accounts: tradeAccountKeys ?? selectedAccountKeys) }
        tradeReadoutReservations = SecurityTradeReadout.reservationCandidates(for: trades)
    }
}

struct SecurityPriceChartState: View {
    @Environment(\.locale) private var appLocale
    /// Figma 455:5530: the chart is 330pt from under the price to the picker.
    static let plotHeight: CGFloat = 330
    static let fixedHeight: CGFloat = plotHeight + 62

    /// The one placeholder line of the price chart — on the opening card, while
    /// the history loads and while it is prepared — drawn in the plot's own
    /// geometry (`SecurityPricePlot`: 49pt axis, 15pt top inset, no leading
    /// overflow, 9pt endpoint inset). The plot's first appearance grows out of
    /// this same shape; three placeholders of three sizes had it jump twice
    /// before the data came.
    static func placeholderLine(appearanceID: String?) -> some View {
        StandardLineChartSkeleton(
            axisWidth: 49,
            topInset: 15,
            leadingLineOverflow: 0,
            trailingEndpointInset: 9,
            lineWidths: [2],
            appearanceID: appearanceID,
            showsAxis: false
        )
    }

    let title: String
    let message: String
    let isLoading: Bool
    var appearanceID: String? = nil

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 0) {
                    // The line alone, in the plot's own frame; the time picker
                    // is the real one from the start. Nothing here is swapped
                    // for something of another size when the data arrives.
                    Self.placeholderLine(appearanceID: appearanceID)
                        .frame(height: Self.plotHeight)

                    ChartTimeRangePicker(selection: .constant(.oneDay))
                        .frame(height: 62)
                        .allowsHitTesting(false)
                }
            } else {
                VStack(spacing: 0) {
                    StandardLineChartPlaceholder(
                        title: title,
                        message: message,
                        isLoading: false,
                        maximumLines: 2
                    )
                    .frame(height: Self.plotHeight)

                    Color.clear
                        .frame(height: 62)
                }
            }
        }
        .frame(height: Self.fixedHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("价格走势，\(title)，\(message)"))
    }
}

struct SecurityPriceSelection: Equatable {
    // Only a historical touch/measurement overrides the independent latest quote.
    let price: Double?
    let returnPercent: Double
    var trades: [SecurityTrade] = []
}

struct SecurityPricePreparationRequest: Equatable {
    let history: SecurityPriceHistory
    let averageCost: Double?
    let accountKeys: Set<String>
}

struct SecurityPriceChart: View {
    @Environment(\.locale) private var appLocale
    let history: SecurityPriceHistory
    let averageCost: Double?
    let selectedAccountKeys: Set<String>
    let cachedContent: HoldingDetailCachedContent?
    let onSelectionChange: (SecurityPriceSelection?) -> Void
    /// The section showed a placeholder line before this history arrived.
    let followsPlaceholder: Bool
    @State private var prepared: SecurityPricePreparedData?
    /// This chart itself showed the placeholder while it prepared.
    @State private var startedWithoutPreparedData: Bool
    @State private var isPreparing = true
    @State private var range: ChartTimeRange
    @State private var selectedDate: Date?
    @State private var measuredRange: ChartDateRange?
    @State private var lastHeaderPublishTime: TimeInterval = 0
    @State private var lastPublishedTrades: [SecurityTrade] = []

    init(
        history: SecurityPriceHistory,
        averageCost: Double?,
        selectedAccountKeys: Set<String>,
        cachedContent: HoldingDetailCachedContent? = nil,
        followsPlaceholder: Bool = false,
        onSelectionChange: @escaping (SecurityPriceSelection?) -> Void = { _ in }
    ) {
        self.history = history
        self.followsPlaceholder = followsPlaceholder
        self.averageCost = averageCost
        self.selectedAccountKeys = selectedAccountKeys
        self.cachedContent = cachedContent
        self.onSelectionChange = onSelectionChange
        let request = SecurityPricePreparationRequest(history: history, averageCost: averageCost, accountKeys: selectedAccountKeys)
        let cached = cachedContent?.preparedChart.flatMap { $0.request == request ? $0.data : nil }
        let arguments = LaunchArguments.all
        // Every new detail/preview opens on the latest session, including
        // cache-backed opens. Range changes stay local to this presentation.
        let openingRange: ChartTimeRange = arguments.contains("--show-security-chart-max") ? .maximum : .oneDay
        _range = State(initialValue: openingRange)
        // With a history in hand the line is drawn in the first frame, as it
        // is, without the placeholder or its entrance: only the opening range
        // is built here, the others off the main actor.
        let opening = cached ?? SecurityPricePreparedData(history: history, averageCost: averageCost,
            selectedAccountKeys: selectedAccountKeys, only: openingRange)
        _prepared = State(initialValue: opening)
        _isPreparing = State(initialValue: !opening.isComplete)
        _startedWithoutPreparedData = State(initialValue: false)
    }

    private var data: SecurityPriceRangeData {
        prepared?.data(for: range) ?? .empty
    }

    private var selectedPoint: SecurityPricePlotPoint? {
        guard let selectedDate else { return data.points.last }
        return data.nearest(to: selectedDate)
    }

    private var selectionIndicatorLabel: String? {
        if let measuredRange {
            return "\(dateLabel(measuredRange.start)) – \(dateLabel(measuredRange.end))"
        }
        guard selectedDate != nil, let selectedPoint else { return nil }
        return dateLabel(selectedPoint.date)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                // Keep prepared data visible during refresh; only an empty
                // chart needs the geometry-matched loading placeholder.
                if isPreparing && prepared == nil {
                    SecurityPriceChartState.placeholderLine(
                        appearanceID: "security-price|\(history.ticker)|\(history.currency)")
                } else if data.points.count > 1 {
                    SecurityPricePlot(
                        data: data,
                        currency: history.currency,
                        appearanceID: "security-price|\(history.ticker)|\(history.currency)",
                        transitionKey: "\(range.rawValue)|\(selectionSignature)",
                        selectedPoint: selectedDate == nil && measuredRange == nil ? nil : selectedPoint,
                        measuredRange: measuredRange,
                        selectionIndicatorLabel: selectionIndicatorLabel,
                        onSelect: { date in
                            guard measuredRange != nil || selectedDate != date else { return }
                            measuredRange = nil
                            selectedDate = date
                            publishInteractiveSelection(selection(at: date))
                        },
                        onMeasure: { measuredRange in
                            guard self.measuredRange != measuredRange else { return }
                            self.measuredRange = measuredRange
                            selectedDate = measuredRange.end
                            publishInteractiveSelection(selection(for: measuredRange))
                        },
                        onInteractionEnded: { _ in clearInteraction() },
                        growsFromPlaceholder: followsPlaceholder || startedWithoutPreparedData
                    )
                } else {
                    StandardLineChartPlaceholder(
                        title: L10n.text("暂无日内行情"),
                        message: L10n.text("Massive 与 Yahoo 暂未返回分钟级数据"),
                        isLoading: false,
                        maximumLines: 2
                    )
                }
            }
            .frame(height: SecurityPriceChartState.plotHeight)
            .accessibilityLabel(L10n.text("\(history.ticker) 价格走势，买入点为绿色圆环，卖出点为黄色圆环，横向玻璃线为持仓成本"))

            ChartTimeRangePicker(selection: $range)
            .frame(height: 62)
            .allowsHitTesting(!isPreparing)
            .accessibilityLabel(L10n.text("价格走势时间范围"))
        }
        .frame(height: SecurityPriceChartState.fixedHeight, alignment: .top)
        .onChange(of: range) { _, _ in clearInteraction() }
        .onChange(of: selectedAccountKeys) { _, _ in clearInteraction() }
        .onDisappear { onSelectionChange(nil) }
        .task(id: preparationRequest) {
            if let cached = cachedContent?.preparedChart, cached.request == preparationRequest {
                prepared = cached.data
                isPreparing = false
                onSelectionChange(rangeSelection)
                return
            }
            isPreparing = !(prepared?.isComplete ?? false)
            let request = preparationRequest
            let history = history
            let averageCost = averageCost
            let selectedAccountKeys = selectedAccountKeys
            let prepared = await Task.detached(priority: .userInitiated) {
                SecurityPricePreparedData(
                    history: history,
                    averageCost: averageCost,
                    selectedAccountKeys: selectedAccountKeys
                )
            }.value
            guard !Task.isCancelled else {
                // Superseded before it finished — by the network's fresher
                // history, typically. With nothing on screen yet it still
                // beats the placeholder: it was thrown away, and the line
                // waited for a second preparation of the newer history.
                if !(self.prepared?.isComplete ?? false) {
                    self.prepared = prepared
                }
                return
            }
            self.prepared = prepared
            cachedContent?.preparedChart = (request, prepared)
            isPreparing = false
            if selectedDate == nil, measuredRange == nil {
                onSelectionChange(rangeSelection)
            }
        }
        .task(id: "\(range.rawValue)|\(selectionSignature)") {
            // Publish the selected time window even when the user is not
            // touching the chart. The header then uses the same start/end
            // basis as the line currently on screen.
            await Task.yield()
            guard !Task.isCancelled, !isPreparing,
                  selectedDate == nil, measuredRange == nil else { return }
            onSelectionChange(rangeSelection)
        }
        .onAppear {
            let arguments = LaunchArguments.all
            if arguments.contains("--show-security-chart-1d") { range = .oneDay }
            if arguments.contains("--show-security-chart-max") { range = .maximum }
        }
    }

    private var selectionSignature: String {
        selectedAccountKeys.sorted().joined(separator: "|")
    }

    private var preparationRequest: SecurityPricePreparationRequest {
        SecurityPricePreparationRequest(history: history, averageCost: averageCost, accountKeys: selectedAccountKeys)
    }

    private func dateLabel(_ date: Date) -> String {
        data.isIntraday
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private func selection(at date: Date) -> SecurityPriceSelection? {
        guard let point = data.nearest(to: date) else { return nil }
        // The prepared point already uses the chart's reference: previous
        // close for 1D, first visible price for the longer time windows.
        return SecurityPriceSelection(price: point.price, returnPercent: point.returnPercent,
                                      trades: data.trades(at: point.date))
    }

    private var rangeSelection: SecurityPriceSelection? {
        // At rest 1D keeps the header's latest market quote and daily change
        // together. Do not replace that change with first-minute-to-last-minute
        // performance when the chart finishes preparing or a touch ends.
        guard range != .oneDay, let latest = data.points.last else { return nil }
        return SecurityPriceSelection(price: nil, returnPercent: latest.returnPercent)
    }

    private func selection(for range: ChartDateRange) -> SecurityPriceSelection? {
        guard let start = data.nearest(to: range.start),
              let end = data.nearest(to: range.end),
              start.price > 0 else { return nil }
        return SecurityPriceSelection(price: end.price, returnPercent: (end.price / start.price - 1) * 100)
    }

    private func clearInteraction() {
        selectedDate = nil
        measuredRange = nil
        lastHeaderPublishTime = 0
        lastPublishedTrades = []
        onSelectionChange(rangeSelection)
    }

    /// The crosshair and bubble stay local and update for every snapped point.
    /// The large price text above the chart does not need 120 writes/second;
    /// bounding that parent-facing update prevents repeated header layout.
    private func publishInteractiveSelection(_ selection: SecurityPriceSelection?) {
        let now = Date.timeIntervalSinceReferenceDate
        // Entering/leaving a trade must never be dropped by price throttling.
        let trades = selection?.trades ?? []
        guard trades != lastPublishedTrades || now - lastHeaderPublishTime >= 1.0 / 30.0 else { return }
        lastPublishedTrades = trades
        lastHeaderPublishTime = now
        onSelectionChange(selection)
    }
}

struct SecurityPricePlot: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    @State private var seriesCache = SecurityPricePlotSeriesCache()

    let data: SecurityPriceRangeData
    let currency: String
    let appearanceID: String
    let transitionKey: String
    let selectedPoint: SecurityPricePlotPoint?
    let measuredRange: ChartDateRange?
    let selectionIndicatorLabel: String?
    let onSelect: (Date) -> Void
    let onMeasure: (ChartDateRange) -> Void
    let onInteractionEnded: (Int) -> Void
    /// Whether the line grows out of the placeholder's shape: only when a
    /// placeholder was on screen, waiting for this data.
    var growsFromPlaceholder = false

    var body: some View {
        let prepared = seriesCache.prepared(for: data, scheme: colorScheme)
        let costReference = data.averageCost.map {
            StandardLineChartReferenceLine(
                id: "cost",
                value: $0,
                color: CatfolioPalette.tradeBuy,
                label: axisPriceLabel($0),
                lineWidth: 2,
                minimumAxisLabelSpacing: 20
            )
        }
        StandardLineChart(
            series: [prepared.priceSeries],
            interactionDates: prepared.interactionDates,
            domain: data.domain,
            yTicks: prepared.yTicks,
            axisWidth: 49,
            topInset: 15,
            bottomHeight: 0,
            // The first price is also the return baseline; keep it visible.
            leadingLineOverflow: 0,
            gridOpacity: 0.08,
            transitionKey: transitionKey,
            appearanceID: appearanceID,
            dataTransition: .viewportZoom,
            // Out of the placeholder's shape only when the placeholder was
            // shown: data already at hand is simply there. Morphed every
            // time, it read as a placeholder replaced on every open.
            animatesInitialAppearance: growsFromPlaceholder,
            markers: prepared.markers,
            markerMagnetRadius: 6,
            referenceLines: [costReference].compactMap { $0 },
            selectedDate: selectedPoint?.date,
            measuredRange: measuredRange,
            selectionIndicatorLabel: selectionIndicatorLabel,
            selectionSeriesIDs: ["price"],
            rangeSeriesIDs: ["price"],
            rangePrimarySeriesID: "price",
            dimsFutureDuringSelection: true,
            yAxisFont: Typography.number(.footnote),
            yAxisColor: Color.primary.opacity(0.20),
            referenceAxisFont: Typography.number(.footnote, weight: .semibold),
            yAxisLabel: axisPriceLabel,
            xAxisLabel: { _ in "" },
            onSelect: onSelect,
            onMeasure: onMeasure,
            onInteractionEnded: onInteractionEnded
        )
        .overlay(alignment: data.offscaleCost?.isAbove == true ? .topTrailing : .bottomTrailing) {
            if let cost = data.offscaleCost {
                // A triangle on the outer side says which way the cost lies:
                // above the top of the scale, or below its bottom. Half
                // strength, as a figure off the chart.
                VStack(spacing: 2) {
                    if cost.isAbove { OffscaleCostTriangle(pointsUp: true) }
                    Text(axisPriceLabel(cost.value))
                        .font(Typography.number(.footnote, weight: .semibold))
                        .lineLimit(1)
                    if !cost.isAbove { OffscaleCostTriangle(pointsUp: false) }
                }
                .foregroundStyle(CatfolioPalette.tradeBuy)
                .opacity(0.5)
                .frame(width: 49)
                .allowsHitTesting(false)
                    .accessibilityLabel(L10n.text("持仓成本 \(axisPriceLabel(cost.value))，不在当前价格范围内"))
            }
        }
    }

    private func axisPriceLabel(_ value: Double) -> String {
        let decimals = seriesCache.prepared(for: data, scheme: colorScheme).yTickDecimals
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }

    private func shortDate(_ date: Date) -> String {
        if data.isIntraday {
            return date.formatted(.dateTime.hour().minute())
        }
        if data.isMaximumRange {
            return date.formatted(.dateTime.year())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A scrubbing selection changes the crosshair and readout, not the price
/// vertices, trade marks, or axis geometry. A new prepared range has a new id.
@MainActor
final class SecurityPricePlotSeriesCache {
    struct Prepared {
        let priceSeries: StandardLineChartSeries
        let interactionDates: [Date]
        let yTicks: [Double]
        /// Decimals the axis labels need so that no two read the same.
        let yTickDecimals: Int
        let markers: [StandardLineChartMarker]
    }

    private struct Key: Equatable {
        let dataID: UUID
        let scheme: ColorScheme
    }

    private var cachedKey: Key?
    private var cachedValue: Prepared?
    private(set) var rebuildCount = 0

    /// Round prices inside the scale — up to four, as few as one — at the
    /// smallest round step that fits: 1, 2, 5, 10, 20, 50… Whole numbers from
    /// $10 up; decimals only below that, or when no whole number falls inside.
    /// Four evenly spaced edges rounded to whole numbers read "23, 23, 23, 22".
    nonisolated static func axisTicks(for domain: ClosedRange<Double>) -> (ticks: [Double], decimals: Int) {
        let low = domain.lowerBound, high = domain.upperBound
        guard high > low, high.isFinite, low.isFinite else { return ([], 0) }
        let allowsDecimals = high < 10
        func ticks(step: Double) -> [Double] {
            let first = (low / step).rounded(.up), last = (high / step).rounded(.down)
            guard last >= first else { return [] }
            return stride(from: last, through: first, by: -1).map { $0 * step }
        }
        func decimals(for step: Double) -> Int { step >= 1 ? 0 : Int((-log10(step)).rounded(.up)) }
        for exponent in -4...8 {
            for mantissa in [1.0, 2.0, 5.0] {
                let step = mantissa * pow(10, Double(exponent))
                if step < 1, !allowsDecimals { continue }
                let found = ticks(step: step)
                if !found.isEmpty, found.count <= 4 { return (found, decimals(for: step)) }
            }
        }
        // A range too narrow for any whole number: finer steps, then one label.
        for exponent in stride(from: -1, through: -4, by: -1) {
            for mantissa in [5.0, 2.0, 1.0] {
                let step = mantissa * pow(10, Double(exponent))
                let found = ticks(step: step)
                if !found.isEmpty, found.count <= 4 { return (found, decimals(for: step)) }
            }
        }
        return ([(low + high) / 2], 2)
    }

    func prepared(for data: SecurityPriceRangeData, scheme: ColorScheme) -> Prepared {
        let key = Key(dataID: data.id, scheme: scheme)
        if cachedKey == key, let cachedValue { return cachedValue }

        let priceSeries = StandardLineChartSeries(
            id: "price",
            points: data.sampledPoints.map {
                StandardLineChartPoint(id: $0.id, date: $0.date, value: $0.price)
            },
            color: CatfolioPalette.securityPriceLine,
            lineWidth: 2,
            selectionRadius: 4,
            latestPointRadius: 5,
            latestPointColor: scheme == .dark ? .white : Color(red: 10 / 255, green: 11 / 255, blue: 12 / 255),
            latestPointUsesGlass: false
        )
        let markers = data.trades.map { trade in
            StandardLineChartMarker(
                id: trade.id,
                point: StandardLineChartPoint(
                    id: trade.id,
                    date: trade.point.date,
                    value: trade.point.price
                ),
                color: trade.trade.isBuy
                    ? CatfolioPalette.tradeBuy
                    : (scheme == .dark ? CatfolioPalette.tradeSellDark : CatfolioPalette.tradeSellLight),
                radius: 4,
                outlineColor: nil,
                outlineWidth: 2,
                style: .ring,
                seriesID: "price"
            )
        }
        var axis = Self.axisTicks(for: data.domain)
        // The cost's green figure owns its edge of the axis: a grey price
        // within a label's height of it would print over it.
        if let cost = data.offscaleCost {
            let low = data.domain.lowerBound, high = data.domain.upperBound
            let plotHeight = SecurityPriceChartState.plotHeight - 15
            let clearance = 30 / plotHeight * (high - low)
            axis.ticks.removeAll { cost.isAbove ? $0 > high - clearance : $0 < low + clearance }
        }
        let value = Prepared(priceSeries: priceSeries, interactionDates: data.points.map(\.date),
                             yTicks: axis.ticks, yTickDecimals: axis.decimals, markers: markers)
        cachedKey = key
        cachedValue = value
        rebuildCount &+= 1
        return value
    }
}

final class SecurityPricePreparedData: @unchecked Sendable {
    private let ranges: [ChartTimeRange: SecurityPriceRangeData]
    /// False while only the opening range is built; the rest follow off the
    /// main actor.
    let isComplete: Bool

    init(
        history: SecurityPriceHistory,
        averageCost: Double?,
        selectedAccountKeys: Set<String>,
        only openingRange: ChartTimeRange? = nil
    ) {
        isComplete = openingRange == nil
        ranges = Dictionary(uniqueKeysWithValues: (openingRange.map { [$0] } ?? ChartTimeRange.allCases).map {
            ($0, SecurityPriceRangeData(
                history: history,
                range: $0,
                averageCost: averageCost,
                selectedAccountKeys: selectedAccountKeys
            ))
        })
    }

    func data(for range: ChartTimeRange) -> SecurityPriceRangeData {
        ranges[range] ?? ranges[.maximum] ?? .empty
    }
}

struct SecurityPriceRangeData: @unchecked Sendable {
    struct TradePoint: Identifiable {
        let trade: SecurityTrade
        let point: SecurityPricePlotPoint
        var id: String { trade.id }
    }

    let id = UUID()
    let points: [SecurityPricePlotPoint]
    let sampledPoints: [SecurityPricePlotPoint]
    let trades: [TradePoint]
    let domain: ClosedRange<Double>
    let averageCost: Double?
    /// The cost when it lies outside the price's scale: no line, only its
    /// figure pinned to the top or bottom of the axis.
    private(set) var offscaleCost: (value: Double, isAbove: Bool)? = nil
    let isIntraday: Bool
    let isMaximumRange: Bool

    static let empty = SecurityPriceRangeData(
        points: [],
        sampledPoints: [],
        trades: [],
        domain: -1...1,
        averageCost: nil,
        isIntraday: false,
        isMaximumRange: false
    )

    private init(
        points: [SecurityPricePlotPoint],
        sampledPoints: [SecurityPricePlotPoint],
        trades: [TradePoint],
        domain: ClosedRange<Double>,
        averageCost: Double?,
        isIntraday: Bool,
        isMaximumRange: Bool
    ) {
        self.points = points
        self.sampledPoints = sampledPoints
        self.trades = trades
        self.domain = domain
        self.averageCost = averageCost
        self.isIntraday = isIntraday
        self.isMaximumRange = isMaximumRange
    }

    init(
        history: SecurityPriceHistory,
        range: ChartTimeRange,
        averageCost: Double?,
        selectedAccountKeys: Set<String>
    ) {
        let usesIntraday = range == .oneDay
        isIntraday = usesIntraday
        isMaximumRange = range == .maximum
        let source = usesIntraday ? history.intradayPoints : history.chartDailyPoints
        let all = source.map {
            SecurityPricePlotPoint(dateText: $0.dateText, date: $0.date, price: $0.close, returnPercent: 0)
        }.sorted { $0.date < $1.date }
        let filtered = Self.filtered(all, range: range)
        let rangeBase: Double? = {
            guard usesIntraday, let sessionStart = filtered.first?.date else {
                return filtered.first?.price
            }
            let sessionDay = DayDateCodec.string(from: sessionStart)
            return history.points
                .filter { $0.dateText < sessionDay }
                .max(by: { $0.dateText < $1.dateText })?
                .close ?? filtered.first?.price
        }()
        guard let base = rangeBase, base > 0 else {
            points = []
            sampledPoints = []
            trades = []
            domain = -1...1
            self.averageCost = nil
            return
        }
        let normalizedPoints = filtered.map {
            SecurityPricePlotPoint(
                dateText: $0.dateText,
                date: $0.date,
                price: $0.price,
                returnPercent: ($0.price / base - 1) * 100
            )
        }
        let step = max(1, Int(ceil(Double(normalizedPoints.count) / 150)))
        var sampled = Array(stride(from: 0, to: normalizedPoints.count, by: step)).map { normalizedPoints[$0] }
        if sampled.last?.id != normalizedPoints.last?.id, let last = normalizedPoints.last { sampled.append(last) }

        let visibleStart = normalizedPoints.first?.date ?? .distantFuture
        let visibleEnd = normalizedPoints.last?.date ?? .distantPast
        let sessionDay = usesIntraday ? normalizedPoints.last.map { DayDateCodec.string(from: $0.date) } : nil
        let visibleTrades: [TradePoint] = history.trades.compactMap { trade -> TradePoint? in
            guard let trade = trade.filtered(accounts: selectedAccountKeys) else { return nil }
            if usesIntraday {
                // Today's fills on today's line, at their execution time
                // where known, otherwise at the latest minute.
                guard trade.dateText == sessionDay,
                      let point = trade.executedAt.flatMap({ Self.nearestPoint(to: $0, in: normalizedPoints) })
                        ?? normalizedPoints.last else { return nil }
                return TradePoint(trade: trade, point: point)
            }
            // A fill newer than the last daily close (a feed a session or a
            // weekend behind) still belongs on the line's latest point.
            let latestAccepted = visibleEnd.addingTimeInterval(7 * 86_400)
            guard trade.date >= visibleStart, trade.date <= latestAccepted,
                  let point = Self.nearestPoint(to: trade.date, in: normalizedPoints) else { return nil }
            return TradePoint(trade: trade, point: point)
        }

        // The price alone sets the scale, so the line fills the chart the
        // same way on every security. Folding in a cost far from the price
        // pressed the line flat against the top or bottom by an amount that
        // differed from stock to stock. The cost line shows only when it
        // falls inside that scale.
        let values = normalizedPoints.map(\.price)
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        // No floor of a share of the price: a quiet day on VUSA (0.9 on 110)
        // was stretched to 2%, and its line filled half the height another
        // stock's filled. Only a price that did not move at all needs a span.
        let span = max(maximum - minimum, max(abs(maximum) * 0.0005, 0.01))
        let padding = span * 0.12
        let validCost = averageCost.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let visibleCost = validCost.flatMap { cost -> Double? in
            cost >= minimum - padding && cost <= maximum + padding ? cost : nil
        }
        if let cost = validCost, visibleCost == nil {
            offscaleCost = (cost, cost > maximum)
        }
        points = normalizedPoints
        // Keep every annotated vertex in the rendered polyline. Otherwise an
        // exact trade-day quote can float off a downsampled line even at rest.
        sampledPoints = Dictionary(grouping: sampled + visibleTrades.map(\.point), by: \.date)
            .values.compactMap(\.first).sorted { $0.date < $1.date }
        trades = visibleTrades
        domain = (minimum - padding)...(maximum + padding)
        self.averageCost = visibleCost
    }

    func nearest(to date: Date) -> SecurityPricePlotPoint? {
        Self.nearestPoint(to: date, in: points)
    }

    func trades(at date: Date) -> [SecurityTrade] {
        // Match the same snapped vertex that draws the ring, including dates
        // without a quote. Adjacent ordinary price points clear the readout.
        guard let point = nearest(to: date) else { return [] }
        return trades.filter { $0.point.date == point.date }.map(\.trade)
    }

    private static func filtered(
        _ points: [SecurityPricePlotPoint],
        range: ChartTimeRange
    ) -> [SecurityPricePlotPoint] {
        guard let last = points.last?.date else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start: Date?
        switch range {
        case .oneDay: start = nil
        case .oneWeek: start = calendar.date(byAdding: .day, value: -7, to: last)
        case .oneMonth: start = calendar.date(byAdding: .month, value: -1, to: last)
        case .twoMonths: start = calendar.date(byAdding: .month, value: -2, to: last)
        case .threeMonths: start = calendar.date(byAdding: .month, value: -3, to: last)
        case .yearToDate:
            start = calendar.date(from: DateComponents(
                year: calendar.component(.year, from: last), month: 1, day: 1
            ))
        case .sixMonths: start = calendar.date(byAdding: .month, value: -6, to: last)
        case .oneYear: start = calendar.date(byAdding: .year, value: -1, to: last)
        case .twoYears: start = calendar.date(byAdding: .year, value: -2, to: last)
        case .fiveYears: start = calendar.date(byAdding: .year, value: -5, to: last)
        case .maximum: start = nil
        }
        guard let start else { return points }
        if range == .oneWeek {
            // Measure from the last available close on or before one week ago.
            // A holiday must not move the baseline forward and omit the next
            // session's change. Retain the close's actual date on the chart.
            let first = points.lastIndex(where: { $0.date <= start }) ?? points.startIndex
            return Array(points[first...])
        }
        let result = points.filter { $0.date >= start }
        return result.count > 1 ? result : Array(points.suffix(2))
    }

    private static func nearestPoint(
        to date: Date,
        in points: [SecurityPricePlotPoint]
    ) -> SecurityPricePlotPoint? {
        guard !points.isEmpty else { return nil }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return points[0] }
        guard lower < points.count else { return points[points.count - 1] }
        let before = points[lower - 1]
        let after = points[lower]
        return abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
    }
}

struct SecurityPricePlotPoint: Identifiable {
    let dateText: String
    let date: Date
    let price: Double
    let returnPercent: Double

    var id: String { dateText }
}

/// The small triangle beside a cost that lies off the price chart's scale.
private struct OffscaleCostTriangle: View {
    let pointsUp: Bool

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: pointsUp ? 5 : 0))
            path.addLine(to: CGPoint(x: 8, y: pointsUp ? 5 : 0))
            path.addLine(to: CGPoint(x: 4, y: pointsUp ? 0 : 5))
            path.closeSubpath()
        }
        .frame(width: 8, height: 5)
        .accessibilityHidden(true)
    }
}
