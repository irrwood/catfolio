import SwiftUI

/// Immediate list feedback stays independent of the asynchronous chart rebuild.
@MainActor @Observable
final class LossSourceListState {
    private(set) var hiddenTickers: Set<String> = []
    private(set) var showsOthers = true
    private(set) var highlightedBand: String?
    private(set) var scrollRequest: ReturnsSourceScrollRequest?

    func isShown(_ band: HoldingLossStack.Band) -> Bool {
        band.kind == .others ? showsOthers : !hiddenTickers.contains(band.title)
    }

    func toggle(_ band: HoldingLossStack.Band) {
        let hiding = isShown(band)
        scrollRequest = hiding ? ReturnsSourceScrollRequest(id: band.id) : nil
        if hiding, highlightedBand == band.id { highlightedBand = nil }
        switch band.kind {
        case .others: showsOthers.toggle()
        case .holding:
            if hiding { hiddenTickers.insert(band.title) }
            else { hiddenTickers.remove(band.title) }
        }
    }

    func highlight(_ band: HoldingLossStack.Band) {
        if highlightedBand == band.id {
            highlightedBand = nil
            return
        }
        if !isShown(band) {
            if band.kind == .others { showsOthers = true }
            else { hiddenTickers.remove(band.title) }
            scrollRequest = nil
        }
        highlightedBand = band.id
    }

    func reconcileHighlight(with stack: HoldingLossStack) {
        if let highlightedBand, !stack.bands.contains(where: { $0.id == highlightedBand }) {
            self.highlightedBand = nil
        }
    }
}

/// Where the portfolio's losses came from, over time — the gain-sources
/// chart turned over. Each losing holding is a band hanging below zero, the
/// deepest of them furthest down and the rest together nearest the axis, so
/// the bottom edge is everything lost on that day. Following a band left to
/// right is that holding's loss: when it opened, how far it went, whether it
/// has come back.
///
/// Rank by each holding's latest loss or its deepest loss in the range shown.
/// The latter keeps a band for a holding that fell hard and then recovered.
/// Like the gain sources, it is today's share counts at each day's close, so
/// holdings already sold are not in it — unless 包含已卖出 is on: then every
/// day has that day's own holdings, and one cut at a loss drops straight out
/// of the chart on the day it was sold.
struct LossAnalysisChart: View {
    var refreshRevision = 0
    var fetchHistory: (@MainActor (Bool) async throws -> HoldingValueHistory)? = nil
    @Environment(AppModel.self) private var model
    private let colorScheme: ColorScheme = .dark
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var appLocale
    @State private var localCache = ReturnsSourceCache()
    @State private var previousLosses: (scope: String, prepared: ReturnsSourcePreparation<HoldingLossRanges>)?
    @State private var handledRefreshRevision = 0
    @State private var handledDrawdownRefreshRevision = 0
    @State private var retryRevision = 0
    @State private var range = ChartTimeRange.oneYear
    @State private var selectedDate: Date?
    @State private var listState: LossSourceListState
    @State private var listDisclosure: ReturnsListDisclosure
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    /// Each day with that day's own holdings (`ActualHoldingHistory`), or
    /// today's carried back. Set from the bar's corner.
    @AppStorage("returns.losses.includesSold") private var includesSold = false
    @AppStorage(HoldingLossSortOrder.preferenceKey) private var sortOrder = HoldingLossSortOrder.maximumLoss

    init(refreshRevision: Int = 0,
         fetchHistory: (@MainActor (Bool) async throws -> HoldingValueHistory)? = nil,
         listState: LossSourceListState? = nil,
         listDisclosure: ReturnsListDisclosure? = nil) {
        self.refreshRevision = refreshRevision
        self.fetchHistory = fetchHistory
        _listState = State(initialValue: listState ?? LossSourceListState())
        _listDisclosure = State(initialValue: listDisclosure ?? ReturnsListDisclosure())
    }

    private var historyKind: ReturnsSourceCache.Kind { includesSold ? .includingSold : .current }
    private var entry: ReturnsSourceCacheEntry {
        fetchHistory == nil ? model.returnsSourceEntry(kind: historyKind) : localCache.entry(scope: model.comparisonCacheScope, kind: historyKind)
    }
    private var drawdownEntry: ReturnsSourceCacheEntry {
        fetchHistory == nil ? model.returnsSourceEntry(kind: .drawdown) : localCache.entry(scope: model.comparisonCacheScope, kind: .drawdown)
    }
    private var loading: HoldingHistoryState { entry.loading }
    private var losses: ReturnsSourcePreparation<HoldingLossRanges> {
        entry.losses.entry(configuration: preparationConfiguration)
    }
    private var displayScope: String { "\(model.comparisonCacheScope)|\(historyKind.rawValue)" }
    private var preparedRanges: HoldingLossRanges? {
        if let value = losses.value { return value }
        return previousLosses?.scope == displayScope ? previousLosses?.prepared.value : nil
    }
    private var drawdownLoading: HoldingHistoryState { drawdownEntry.loading }
    private var drawdown: UnderwaterSeries? {
        guard let series = drawdownEntry.drawdowns.value?[range], series.points.count > 1 else { return nil }
        return series
    }

    var body: some View {
        let stack = preparedRanges?[range, sortOrder]
        let shown = stack.flatMap { $0.row(nearest: selectedDate) ?? $0.rows.last }
        let visible = stack.map(visibleBands) ?? []
        let bottom = stack.map { floor($0, visible: visible) } ?? -1

        ReturnsChartPanel(scrollRequest: listState.scrollRequest, listDisclosure: listDisclosure, surface: .losses) {
            ReturnsSourceChartHero(range: $range, header: Group {
                if let shown { header(shown) }
                else { ReturnsSourceHeaderPlaceholder(theme: .losses) }
            }, plot: Group {
                if let stack, stack.rows.count > 1 { plot(stack: stack, visible: visible, bottom: bottom) }
                else if stack == nil && loading.errorMessage == nil {
                    ReturnsSourcePlotPlaceholder(appearanceID: "loss-sources")
                } else { Color.clear }
            }, axis: Group {
                if let stack, stack.rows.count > 1 { axisLabels(bottom: bottom) }
                else { Color.clear }
            }, theme: .losses)
        } rows: {
            VStack(alignment: .leading, spacing: 0) {
                ReturnsListDrawer(disclosure: listDisclosure) {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker(L10n.text("亏损排序"), selection: $sortOrder) {
                            ForEach(HoldingLossSortOrder.allCases, id: \.self) { order in
                                Text(order.title).tag(order)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("returns.losses.sort-order")
                        DrawdownStatistics(series: drawdown)
                    }
                }
                if let stack, let shown {
                    if stack.bands.count > 1 || !stack.hidden.isEmpty || stack.rows.contains(where: { $0.totalLoss > 0 }) {
                        legend(stack: stack, row: shown)
                    } else {
                        Text(L10n.text(stack.rows.count > 1 ? "这段时间里没有持仓低于成本。" : "当前没有持仓低于成本。"))
                            .appText(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                } else {
                    ReturnsSourceRowsPlaceholder(errorMessage: loading.errorMessage) { retryRevision &+= 1 }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ReturnsSourceChartStyle.lossBackground.ignoresSafeArea())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .tint(.white)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                IncludesSoldMenu(isOn: $includesSold)
                    .accessibilityIdentifier("returns.losses.includes-sold")
            }
        }
        .task(id: "\(model.comparisonCacheScope)|\(historyKind.rawValue)|\(model.portfolioChartRevision)|\(model.holdings.count)|\(refreshRevision)|\(retryRevision)") {
            let forceRefresh = refreshRevision != handledRefreshRevision
            handledRefreshRevision = refreshRevision
            let fetch = fetchHistory ?? model.returnsSourceFetch(kind: historyKind)
            await entry.load(revision: model.portfolioChartRevision, forceRefresh: forceRefresh) { cachedOnly in
                #if DEBUG
                if LaunchArguments.contains("--demo-loss-history") { return Self.demoHistory() }
                #endif
                return try await fetch(cachedOnly)
            }
        }
        .task(id: "\(model.comparisonCacheScope)|\(model.portfolioChartRevision)|\(model.holdings.count)|\(refreshRevision)|\(retryRevision)") {
            let forceRefresh = refreshRevision != handledDrawdownRefreshRevision
            handledDrawdownRefreshRevision = refreshRevision
            let fetch = fetchHistory ?? model.returnsSourceFetch(kind: .drawdown)
            await drawdownEntry.load(revision: model.portfolioChartRevision, forceRefresh: forceRefresh) { cachedOnly in
                #if DEBUG
                if LaunchArguments.contains("--demo-loss-history") { return Self.demoHistory() }
                #endif
                return try await fetch(cachedOnly)
            }
        }
        .task(id: "\(model.comparisonCacheScope)|\(drawdownLoading.revision)") {
            let target = drawdownEntry
            guard let history = target.loading.history else { return }
            await target.drawdowns.prepare(key: "\(target.loading.revision)") {
                Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map {
                    ($0, UnderwaterSeries.portfolio(history, range: $0))
                })
            }
        }
        .onChange(of: "\(losses.id)|\(losses.revision)", initial: true) { _, _ in
            if losses.value != nil { previousLosses = (displayScope, losses) }
        }
        .onChange(of: range) { _, _ in
            selectedDate = nil
            if let stack = preparedRanges?[range, sortOrder] { listState.reconcileHighlight(with: stack) }
        }
        .onChange(of: sortOrder) { _, _ in
            selectedDate = nil
            if let stack = preparedRanges?[range, sortOrder] { listState.reconcileHighlight(with: stack) }
        }
        // Range taps and chart selection only read prepared values. They must
        // not reparse every date and rerank all holdings on the main thread.
        .task(id: preparationKey) {
            let target = entry
            guard let history = target.loading.history else { return }
            var names = history.names
            for holding in model.holdings { names[holding.ticker.uppercased()] = holding.shortName }
            let input = HoldingValueHistory(rows: history.rows, costs: history.costs, names: names)
            let hidden = listState.hiddenTickers
            await losses.prepare(key: preparationKey) {
                try HoldingLossRanges(history: input, hiding: hidden)
            }
        }
        .sensoryFeedback(.selection, trigger: "\(listState.hiddenTickers.sorted())|\(listState.showsOthers)|\(sortOrder.rawValue)") { _, _ in hapticsEnabled }
    }

    private var preparationConfiguration: String {
        let names = model.holdings.map { "\($0.ticker)|\($0.shortName)" }.joined(separator: ";")
        return "\(listState.hiddenTickers.sorted())|\(names)|\(appLocale.identifier)|\(ContentLanguage.current)"
    }

    private var preparationKey: String {
        "\(model.comparisonCacheScope)|\(historyKind.rawValue)|\(loading.revision)|\(preparationConfiguration)"
    }

    private func visibleBands(_ stack: HoldingLossStack) -> [Int] {
        stack.bands.indices.filter { stack.bands[$0].kind != .others || listState.showsOthers }
    }

    /// The chart's floor: the deepest stack of visible bands, with room.
    private func floor(_ stack: HoldingLossStack, visible: [Int]) -> Double {
        let deepest = stack.rows.map { row in visible.reduce(0) { $0 + row.bands[$1] } }.max() ?? 0
        return -max(deepest, 1) * 1.08
    }

    private func header(_ row: HoldingLossStack.Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .textCase(.uppercase)
                .appText(.footnote, weight: .medium)
                .tracking(0.7)
                .foregroundStyle(.white)
            FinancialText(row.totalLoss > 0 ? DisplayFormat.money(-row.totalLoss, signed: true, fractionDigits: 0)
                                           : DisplayFormat.money(0, fractionDigits: 0))
                .font(Typography.number(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .contentTransition(.numericText(value: row.totalLoss))
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: row.totalLoss)
            HStack(spacing: 4) {
                Text(L10n.text("\(row.losingCount) 只持仓低于成本"))
                Text("·")
                Text(L10n.text("组合盈亏"))
                FinancialText(DisplayFormat.money(row.netGain, signed: true, fractionDigits: 0), isDirectional: true)
                    .appNumber(.footnote)
            }
            .appText(.footnote, weight: .medium)
            .foregroundStyle(Color.white.opacity(0.72))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private func plot(stack: HoldingLossStack, visible: [Int], bottom: Double) -> some View {
        let series = Self.chartSeries(stack: stack, visible: visible, scheme: colorScheme,
                                      highlighted: listState.highlightedBand)
        let outer = series.first?.id
        return StandardLineChart(
            series: series,
            interactionDates: stack.rows.map(\.date),
            domain: bottom...0,
            yTicks: [0, bottom / 2, bottom],
            axisWidth: 0,
            topInset: 4,
            bottomHeight: 0,
            leadingLineOverflow: 0,
            // Both edges run to the screen: the stack is a shape, and a gap
            // on one side only reads as a mistake.
            trailingEndpointInset: 0,
            gridOpacity: 0,
            transitionKey: "\(range.rawValue)-\(sortOrder.rawValue)-\(colorScheme == .light ? "light" : "dark")",
            appearanceID: "loss-sources",
            dataTransition: .viewportZoom,
            selectedDate: selectedDate,
            selectionIndicatorLabel: selectedDate.map {
                $0.formatted(.dateTime.year().month(.abbreviated).day())
            },
            selectionSeriesIDs: Set([outer].compactMap { $0 }),
            dimsFutureDuringSelection: true,
            yAxisLabel: { _ in "" },
            xAxisLabel: { date in
                [.oneWeek, .oneMonth, .twoMonths].contains(range)
                    ? date.formatted(.dateTime.month(.abbreviated).day())
                    : date.formatted(.dateTime.month(.abbreviated))
            },
            onSelect: { selectedDate = $0 },
            onInteractionEnded: { _ in selectedDate = nil }
        )
        .accessibilityLabel(L10n.text("亏损来源堆叠图，长按后拖动查看单日"))
    }

    /// A band's name for highlighting: its ticker, or one key for the others.
    static func key(for band: HoldingLossStack.Band) -> String {
        band.id
    }

    static func chartSeries(stack: HoldingLossStack, visible: [Int], scheme: ColorScheme,
                            highlighted: String? = nil) -> [StandardLineChartSeries] {
        // These paths are cumulative boundaries, not individual holdings.
        // Match them by depth when range rankings change, or a ticker moving
        // between ranks will pull its old boundary across neighbouring bands.
        let named = Array(visible.filter { stack.bands[$0].kind != .others }.reversed())
        let others = visible.filter { stack.bands[$0].kind == .others }
        let maximumNamed = HoldingContributionStack.maximumNamed
        return (0...maximumNamed).map { depth in
            let isOthers = depth == maximumNamed
            let kind: HoldingLossStack.Band.Kind = isOthers ? .others
                : depth < named.count ? stack.bands[named[depth]].kind : .holding(colour: depth)
            let band: Int? = isOthers ? others.first : depth < named.count ? named[depth] : nil
            let key = band.map { Self.key(for: stack.bands[$0]) }
            let color = displayColor(for: kind, rankFromBottom: depth,
                                     isHighlighted: highlighted != nil && highlighted == key,
                                     isFaded: highlighted != nil && highlighted != key)
            // Keep unused layers at zero thickness against the others layer.
            // A range with fewer losers can then shrink bands continuously,
            // instead of fading old cumulative areas over the new viewport.
            let above = Array(named.dropFirst(depth)) + others
            let id = isOthers ? "loss-others" : "loss-depth-\(depth)"
            return StandardLineChartSeries(
                id: id,
                points: stack.rows.map { row in
                    StandardLineChartPoint(id: "\(id)|\(row.dateText)", date: row.date,
                                           value: -above.reduce(0) { $0 + row.bands[$1] })
                },
                color: color,
                lineWidth: 0,
                areaFill: color,
                cornerRadius: 6,
                areaFillEndColor: nil,
                areaBaseline: 0,
                areaStripeColor: nil,
                areaStripeSpacing: 35.5,
                areaStripeWidth: 13,
                latestPointRadius: 0,
                latestPointUsesGlass: false
            )
        }
    }

    /// The middle and the floor, faint, down the left of the plot. The top
    /// edge is always zero.
    private func axisLabels(bottom: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            AnimatedChartValue(value: bottom / 2) {
                FinancialText(DisplayFormat.compact($0, precision: .whole)).appNumber(.footnote)
            }
            Spacer()
            AnimatedChartValue(value: bottom) {
                FinancialText(DisplayFormat.compact($0, precision: .whole)).appNumber(.footnote)
            }
        }
        .animation(reduceMotion ? nil : StandardLineChartTransition.zoom, value: bottom)
        .foregroundStyle(Color.white.opacity(0.5))
        .padding(.leading, ReturnsSourceChartStyle.inset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    /// The comparison page's list, as on the gain sources: tap to turn a
    /// band on and off, swipe right to highlight it, left to hide it. The
    /// selected loss ranking is listed first, including hidden rows.
    private func legend(stack: HoldingLossStack, row: HoldingLossStack.Row) -> some View {
        VStack(spacing: 12) {
            ForEach(stack.legendItems) { entry in
                let item = entry.band
                let key = entry.id
                let isOn = listState.isShown(item)
                let isHighlighted = listState.highlightedBand == key
                let color = entry.index.map { band in
                    Self.displayColor(for: item.kind, rankFromBottom: stack.bands.count - 1 - band,
                                      isHighlighted: isHighlighted,
                                      isFaded: listState.highlightedBand != nil && !isHighlighted)
                } ?? Color.secondary
                ReturnsSwipeRow(
                    color: color, isHighlighted: isHighlighted, canRemove: isOn,
                    removeTitle: L10n.text("隐藏此项"), removeIcon: "eye.slash", removeSlidesOut: false,
                    onHighlight: { highlight(item) }, onRemove: { toggle(item) }
                ) {
                    Button { toggle(item) } label: {
                        ReturnsSourceListRow(rank: stack.rank(for: item), color: color,
                                             title: item.title, subtitle: item.subtitle, isOn: isOn,
                                             logo: logoHolding(for: item), isStriped: false, isOnTintedField: true,
                                             isHighlighted: isHighlighted) {
                            if isOn, let band = entry.index {
                                VStack(alignment: .trailing, spacing: 2) {
                                    lossText(row.bands[band])
                                    if let deepest = stack.deepest[item.title], item.kind != .others {
                                        FinancialText(L10n.text("最深 \(DisplayFormat.money(-deepest, signed: true, fractionDigits: 0))"), isDirectional: true)
                                            .appNumber(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text(isOn ? "—" : L10n.text("已隐藏"))
                                    .appText(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("loss.source.\(key)")
                }
                .returnsSourceScrollRow(id: key)
                .returnsDimmed(entry.index == nil && listState.highlightedBand != nil, ground: .black)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityValue(L10n.text(isOn ? "已显示" : "已隐藏"))
                .accessibilityHint(L10n.text(isOn ? "轻点切换显示或隐藏" : "轻点重新显示"))
                .accessibilityAction(named: isHighlighted ? L10n.text("取消高亮") : L10n.text("高亮曲线")) {
                    highlight(item)
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: sortOrder)
    }

    /// A band's company logo, from its holding's logo symbol where there is
    /// one; nil for the others and the principal, which are not one company.
    private func logoHolding(for band: HoldingLossStack.Band) -> (ticker: String, symbol: String)? {
        guard case .holding = band.kind else { return nil }
        return logoHolding(ticker: band.title)
    }

    private func logoHolding(ticker: String) -> (ticker: String, symbol: String) {
        let key = ticker.uppercased()
        let holding = model.holdings.first { $0.ticker.uppercased() == key }
        return (ticker, holding?.logoSymbol ?? ticker)
    }

    /// Highlighting a hidden holding restores it without moving the list.
    private func highlight(_ band: HoldingLossStack.Band) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            listState.highlight(band)
        }
    }

    private func lossText(_ loss: Double) -> some View {
        FinancialText(loss > 0.5 ? DisplayFormat.money(-loss, signed: true, fractionDigits: 0) : L10n.text("未亏损"), isDirectional: true)
            .appNumber(.callout)
            .foregroundStyle(Color.white.opacity(loss > 0.5 ? 1 : 0.5))
    }

    private func toggle(_ band: HoldingLossStack.Band) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            listState.toggle(band)
        }
    }

    /// Flat purple layers, deepest loss darkest, matching the income chart's tonal bands.
    static func color(for kind: HoldingLossStack.Band.Kind, scheme: ColorScheme,
                      rankFromBottom: Int? = nil) -> Color {
        switch kind {
        case .others: return ReturnsSourceChartStyle.lossBase
        case let .holding(index):
            let palette = CatfolioPalette.lossChartLayers
            return palette[min(max(0, rankFromBottom ?? index), palette.count - 1)]
        }
    }

    static func displayColor(for kind: HoldingLossStack.Band.Kind, rankFromBottom: Int,
                             isHighlighted: Bool, isFaded: Bool) -> Color {
        let base = color(for: kind, scheme: .dark, rankFromBottom: rankFromBottom)
        if isHighlighted { return ReturnsSourceChartStyle.lossBase }
        if isFaded { return base.mix(with: ReturnsSourceChartStyle.lossBackground, by: 0.75) }
        return base
    }

}

/// The history in the range cut into loss bands, from the axis outward: the
/// others' losses, then the named holdings' losses from the smallest of them
/// to the largest by the selected ranking. Heights are losses as positive amounts.
struct HoldingLossStack: Sendable {
    struct LegendItem: Identifiable, Sendable {
        let band: Band
        /// A hidden holding remains in the list without a named chart layer.
        let index: Int?
        var id: String { band.id }
    }

    struct Band: Identifiable, Sendable {
        enum Kind: Equatable, Sendable {
            case others
            /// 0 for the deepest loss; kept when others are hidden.
            case holding(colour: Int)
        }

        let kind: Kind
        let title: String
        let subtitle: String
        var id: String { kind == .others ? "loss-others" : title }
    }

    struct Row: Sendable {
        let dateText: String
        let date: Date
        /// One loss per band, in `bands` order, never below nothing.
        let bands: [Double]
        /// All the holdings' losses together, the named and the others.
        var totalLoss: Double { bands.reduce(0, +) }
        /// How many holdings were below their cost that day.
        let losingCount: Int
        /// The whole portfolio's gain that day, gains and losses together.
        let netGain: Double
    }

    let bands: [Band]
    let rows: [Row]
    /// Each named holding's deepest loss in the range, as a positive amount.
    let deepest: [String: Double]
    /// Rank by the selected loss measure, computed before hiding.
    let holdingRanks: [String: Int]
    let hidden: [(ticker: String, name: String)]

    /// One stable list in the selected loss order, independent of visibility.
    var legendItems: [LegendItem] {
        let visible = bands.enumerated().map { LegendItem(band: $0.element, index: $0.offset) }
        let inactive = hidden.map {
            LegendItem(band: Band(kind: .holding(colour: 0), title: $0.ticker, subtitle: $0.name), index: nil)
        }
        func rank(_ entry: LegendItem) -> Int {
            entry.band.kind == .others ? Int.max : (holdingRanks[entry.band.title] ?? Int.max - 1)
        }
        return (visible + inactive).sorted {
            rank($0) == rank($1) ? $0.id < $1.id : rank($0) < rank($1)
        }
    }

    init(history: HoldingValueHistory, holdings: [Holding] = [], range: ChartTimeRange,
         hiding: Set<String> = [], sortOrder: HoldingLossSortOrder = .maximumLoss) {
        let window: [HoldingValueHistory.Row] = {
            guard let last = history.rows.last?.date else { return [] }
            let previous = history.rows.dropLast().last?.date
            return history.rows.filter { range.includes($0.date, through: last, previousTradingDate: previous) }
        }()
        var names = history.names
        for holding in holdings { names[holding.ticker.uppercased()] = holding.shortName }
        let present = Set(window.flatMap(\.values.keys))

        // Keep the same daily loss amounts; only ranking and named bands change.
        var deepestLoss: [String: Double] = [:]
        for row in window {
            for ticker in present {
                let loss = max(0, -row.gain(ticker))
                if loss > (deepestLoss[ticker] ?? 0) { deepestLoss[ticker] = loss }
            }
        }
        let rankingLoss: [String: Double]
        switch sortOrder {
        case .maximumLoss: rankingLoss = deepestLoss
        case .currentLoss:
            rankingLoss = Dictionary(uniqueKeysWithValues: deepestLoss.keys.map {
                ($0, max(0, -(window.last?.gain($0) ?? 0)))
            })
        }
        let everyone = rankingLoss.keys.sorted {
            (rankingLoss[$0] ?? 0) == (rankingLoss[$1] ?? 0) ? $0 < $1 : (rankingLoss[$0] ?? 0) > (rankingLoss[$1] ?? 0)
        }
        let ranks = Dictionary(uniqueKeysWithValues: everyone.enumerated().map { ($0.element, $0.offset + 1) })
        holdingRanks = ranks
        func topLosers(_ tickers: [String]) -> [String] {
            Array(tickers.prefix(HoldingContributionStack.namedCount(tickers.map { rankingLoss[$0] ?? 0 })))
        }
        let named = topLosers(everyone.filter { !hiding.contains($0) })
        var colours: [String: Int] = [:]
        for (index, ticker) in topLosers(everyone).enumerated() where named.contains(ticker) {
            colours[ticker] = index
        }
        var free = (0..<HoldingContributionStack.maximumNamed).filter { !colours.values.contains($0) }.makeIterator()
        for ticker in named where colours[ticker] == nil { colours[ticker] = free.next() ?? 0 }
        let others = present.subtracting(named)
        hidden = hiding.intersection(present).sorted {
            let left = ranks[$0] ?? Int.max, right = ranks[$1] ?? Int.max
            return left == right ? $0 < $1 : left < right
        }.map { (ticker: $0, name: names[$0] ?? $0) }

        var bands = [Band(kind: .others, title: L10n.text("其他亏损"), subtitle: L10n.text("\(others.count) 项持仓合计"))]
        for ticker in named.reversed() {
            bands.append(Band(kind: .holding(colour: colours[ticker] ?? 0), title: ticker, subtitle: names[ticker] ?? ticker))
        }
        self.bands = bands
        deepest = deepestLoss.filter { named.contains($0.key) }

        rows = window.map { row in
            let othersLoss = others.reduce(0) { $0 + max(0, -row.gain($1)) }
            let namedLosses = named.reversed().map { max(0, -row.gain($0)) }
            let losing = present.filter { row.gain($0) < 0 }.count
            let net = present.reduce(0) { $0 + row.gain($1) }
            return Row(dateText: row.dateText, date: row.date, bands: [othersLoss] + namedLosses,
                       losingCount: losing, netGain: net)
        }
    }

    func rank(for band: Band) -> Int? {
        guard case .holding = band.kind else { return nil }
        return holdingRanks[band.title]
    }

    func row(nearest date: Date?) -> Row? {
        guard let date else { return nil }
        return rows.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

/// Built once per history/visibility revision, away from the UI thread.
/// Both sort orders and every picker range are ready before interaction.
struct HoldingLossRanges: Sendable {
    private let stacks: [HoldingLossSortOrder: [ChartTimeRange: HoldingLossStack]]

    init(history: HoldingValueHistory, hiding: Set<String> = []) throws {
        var stacks: [HoldingLossSortOrder: [ChartTimeRange: HoldingLossStack]] = [:]
        for order in HoldingLossSortOrder.allCases {
            var ranges: [ChartTimeRange: HoldingLossStack] = [:]
            for range in ChartTimeRange.allCases {
                try Task.checkCancellation()
                ranges[range] = HoldingLossStack(history: history, range: range, hiding: hiding, sortOrder: order)
            }
            stacks[order] = ranges
        }
        self.stacks = stacks
    }

    subscript(range: ChartTimeRange, order: HoldingLossSortOrder = .maximumLoss) -> HoldingLossStack? {
        stacks[order]?[range]
    }
}

#if DEBUG
extension LossAnalysisChart {
    /// A year of made-up holdings that go under and back over their cost,
    /// for looking at the page where there is no ledger.
    static func demoHistory() -> HoldingValueHistory {
        let holdings: [(String, Double, Double, Double)] = [
            // ticker, cost, depth of the dip, phase
            ("NVDA", 12000, 0.28, 0.2), ("META", 9000, 0.18, 1.3), ("UBER", 6000, 0.32, 2.1),
            ("ASML", 7000, 0.22, 3.0), ("SAP", 5000, 0.10, 0.7), ("KO", 4000, 0.06, 4.2),
            ("XOM", 3500, 0.12, 5.0), ("AMD", 4500, 0.26, 2.6),
        ]
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: .now)
        var rows: [HoldingValueHistory.Row] = []
        for day in stride(from: 365, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -day, to: today),
                  !calendar.isDateInWeekend(date) else { continue }
            let t = Double(365 - day) / 365
            var values: [String: Double] = [:]
            var costs: [String: Double] = [:]
            for (ticker, cost, depth, phase) in holdings {
                let wave = sin(t * .pi * 2.2 + phase) * depth - depth * 0.25 + t * 0.12
                values[ticker] = cost * (1 + wave)
                costs[ticker] = cost
            }
            rows.append(HoldingValueHistory.Row(dateText: DayDateCodec.string(from: date),
                                                cost: costs.values.reduce(0, +), values: values, costs: costs))
        }
        return HoldingValueHistory(rows: rows, costs: Dictionary(uniqueKeysWithValues: holdings.map { ($0.0, $0.1) }),
                                   names: Dictionary(uniqueKeysWithValues: holdings.map { ($0.0, $0.0) }))
    }
}
#endif
