import SwiftUI

/// Where the portfolio's losses came from, over time — the gain-sources
/// chart turned over. Each losing holding is a band hanging below zero, the
/// deepest of them furthest down and the rest together nearest the axis, so
/// the bottom edge is everything lost on that day. Following a band left to
/// right is that holding's loss: when it opened, how far it went, whether it
/// has come back.
///
/// The ranking is taken over the range shown, by each holding's deepest
/// loss in it, so a holding that fell hard and then recovered keeps its band.
/// Like the gain sources, it is today's share counts at each day's close, so
/// holdings already sold are not in it.
struct LossAnalysisChart: View {
    var refreshRevision = 0
    var fetchHistory: (@MainActor (Bool) async throws -> HoldingValueHistory)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var appLocale
    @State private var loading = HoldingHistoryState()
    @State private var handledRefreshRevision = 0
    @State private var handledDrawdownRefreshRevision = 0
    @State private var retryRevision = 0
    @State private var range = ChartTimeRange.oneYear
    @State private var selectedDate: Date?
    @State private var preparedRanges: HoldingLossRanges?
    /// Holdings the reader turned off; the next ones by loss take their place.
    @State private var hiddenTickers: Set<String> = []
    @State private var showsOthers = true
    /// The band a right swipe on its row brought forward (`key(for:)`).
    @State private var highlightedBand: String?
    /// Today's share counts held through the whole window (a buy never reads
    /// as a rise), for the drawdown tiles moved here from the underwater page.
    @State private var drawdownLoading = HoldingHistoryState()
    @State private var drawdown: UnderwaterSeries?
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    var body: some View {
        let stack = preparedRanges?[range]

        VStack(alignment: .leading, spacing: 18) {
            if let stack, !stack.rows.isEmpty {
                let shown = stack.row(nearest: selectedDate) ?? stack.rows.last!
                let visible = visibleBands(stack)
                let bottom = floor(stack, visible: visible)
                ReturnsSourceChartHero(range: $range, header: header(shown),
                                       plot: Group {
                                           if stack.rows.count > 1 { plot(stack: stack, visible: visible, bottom: bottom) }
                                           else { Color.clear }
                                       },
                                       axis: Group {
                                           if stack.rows.count > 1 { axisLabels(bottom: bottom) }
                                           else { Color.clear }
                                       })
                if let drawdown, drawdown.points.count > 1 {
                    DrawdownStatistics(series: drawdown)
                        .padding(.horizontal, ReturnsSourceChartStyle.inset)
                        .padding(.top, 6)
                }
                Group {
                    if stack.bands.count > 1 || !stack.hidden.isEmpty {
                        legend(stack: stack, row: shown)
                    } else {
                        Text(L10n.text(stack.rows.count > 1 ? "这段时间里没有持仓低于成本。" : "当前没有持仓低于成本。"))
                            .appText(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, ReturnsSourceChartStyle.inset)
                .padding(.top, 6)
            } else if let errorMessage = loading.errorMessage {
                StandardLineChartPlaceholder(title: L10n.text("暂时无法绘制"), message: errorMessage, isLoading: false)
                    .frame(height: 300)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                Button(L10n.text("重试")) { retryRevision &+= 1 }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            } else if preparedRanges != nil {
                Color.clear
                    .frame(height: 300)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            } else {
                StandardLineChartPlaceholder(title: L10n.text("正在准备历史数据"),
                                             message: L10n.text("亏损分析"), isLoading: true,
                                             lineWidths: [1.5, 1.5, 1.5], appearanceID: "loss-sources")
                    .frame(height: 300)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: "\(model.portfolioChartRevision)|\(model.holdings.count)|\(refreshRevision)|\(retryRevision)") {
            let forceRefresh = refreshRevision != handledRefreshRevision
            handledRefreshRevision = refreshRevision
            await loading.load(forceRefresh: forceRefresh) { cachedOnly in
                if let fetchHistory { return try await fetchHistory(cachedOnly) }
                #if DEBUG
                if LaunchArguments.contains("--demo-loss-history") { return Self.demoHistory() }
                #endif
                return try await model.holdingValueHistory(cachedOnly: cachedOnly)
            }
        }
        .task(id: "\(model.portfolioChartRevision)|\(model.holdings.count)|\(refreshRevision)|\(retryRevision)") {
            let forceRefresh = refreshRevision != handledDrawdownRefreshRevision
            handledDrawdownRefreshRevision = refreshRevision
            await drawdownLoading.load(forceRefresh: forceRefresh) { cachedOnly in
                #if DEBUG
                if LaunchArguments.contains("--demo-loss-history") { return Self.demoHistory() }
                #endif
                return try await model.fixedShareHistory(cachedOnly: cachedOnly)
            }
        }
        // Windowing five years of rows stays off the main thread too.
        .task(id: "\(drawdownLoading.revision)|\(range)") {
            guard let history = drawdownLoading.history else { drawdown = nil; return }
            let shown = range
            let series = await Task.detached(priority: .userInitiated) {
                UnderwaterSeries.portfolio(history, range: shown)
            }.value
            guard !Task.isCancelled else { return }
            drawdown = series
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
        // Range taps and chart selection only read prepared values. They must
        // not reparse every date and rerank all holdings on the main thread.
        .task(id: preparationKey) {
            guard let history = loading.history else { preparedRanges = nil; return }
            var names = history.names
            for holding in model.holdings { names[holding.ticker.uppercased()] = holding.shortName }
            let input = HoldingValueHistory(rows: history.rows, costs: history.costs, names: names)
            let hidden = hiddenTickers
            let work = Task.detached(priority: .userInitiated) {
                try HoldingLossRanges(history: input, hiding: hidden)
            }
            let result = try? await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            preparedRanges = result
        }
        .sensoryFeedback(.selection, trigger: "\(hiddenTickers.sorted())|\(showsOthers)") { _, _ in hapticsEnabled }
    }

    private var preparationKey: String {
        let names = model.holdings.map { "\($0.ticker)|\($0.shortName)" }.joined(separator: ";")
        return "\(loading.revision)|\(hiddenTickers.sorted())|\(names)|\(appLocale.identifier)"
    }

    private func visibleBands(_ stack: HoldingLossStack) -> [Int] {
        stack.bands.indices.filter { stack.bands[$0].kind != .others || showsOthers }
    }

    /// The chart's floor: the deepest stack of visible bands, with room.
    private func floor(_ stack: HoldingLossStack, visible: [Int]) -> Double {
        let deepest = stack.rows.map { row in visible.reduce(0) { $0 + row.bands[$1] } }.max() ?? 0
        return -max(deepest, 1) * 1.08
    }

    private func header(_ row: HoldingLossStack.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.date.formatted(.dateTime.year().month(.abbreviated).day()))
                .appText(.caption, weight: .medium)
                .foregroundStyle(ReturnsSourceChartStyle.secondary(for: colorScheme))
            CatfolioDisplayAmountText(
                text: row.totalLoss > 0 ? DisplayFormat.money(-row.totalLoss, signed: true, fractionDigits: 0)
                                       : DisplayFormat.money(0, fractionDigits: 0),
                size: 34, symbolSize: 22,
                color: ReturnsSourceChartStyle.primary(for: colorScheme)
            )
                .contentTransition(.numericText(value: row.totalLoss))
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: row.totalLoss)
            HStack(spacing: 4) {
                Text(L10n.text("\(row.losingCount) 只持仓低于成本"))
                    .appText(.footnote, weight: .medium)
                    .foregroundStyle(ReturnsSourceChartStyle.secondary(for: colorScheme))
                Text("·").foregroundStyle(ReturnsSourceChartStyle.secondary(for: colorScheme))
                Text(L10n.text("组合盈亏"))
                    .appText(.footnote, weight: .medium)
                    .foregroundStyle(ReturnsSourceChartStyle.secondary(for: colorScheme))
                Text(DisplayFormat.money(row.netGain, signed: true, fractionDigits: 0))
                    .appNumber(.footnote)
                    .foregroundStyle(ReturnsSourceChartStyle.primary(for: colorScheme))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private func plot(stack: HoldingLossStack, visible: [Int], bottom: Double) -> some View {
        let series = Self.chartSeries(stack: stack, visible: visible, scheme: colorScheme,
                                      highlighted: highlightedBand)
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
            transitionKey: "\(range.rawValue)-\(colorScheme == .light ? "light" : "dark")",
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
        band.kind == .others ? "loss-others" : band.title
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
            let gainKind: HoldingContributionStack.Band.Kind = switch kind {
            case .others: .others
            case let .holding(colour): .holding(colour: colour)
            }
            let band: Int? = isOthers ? others.first : depth < named.count ? named[depth] : nil
            let isFaded = highlighted != nil && highlighted != band.map { key(for: stack.bands[$0]) }
            func paint(_ color: Color) -> Color {
                isFaded ? ReturnsSourceChartStyle.faded(color, scheme: scheme) : color
            }
            let color = paint(HoldingContributionChart.fillColor(for: gainKind, scheme: scheme))
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
                areaFill: kind == .others ? paint(.white) : color,
                areaFillEndColor: HoldingContributionChart.fillEndColor(for: gainKind).map(paint),
                areaBaseline: 0,
                areaStripeColor: kind == .others && !isFaded ? ReturnsSourceChartStyle.stripeColor : nil,
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
                Text(DisplayFormat.compact($0, precision: .whole)).appNumber(.footnote)
            }
            Spacer()
            AnimatedChartValue(value: bottom) {
                Text(DisplayFormat.compact($0, precision: .whole)).appNumber(.footnote)
            }
        }
        .animation(reduceMotion ? nil : StandardLineChartTransition.zoom, value: bottom)
        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.42) : Color.black.opacity(0.32))
        .padding(.leading, ReturnsSourceChartStyle.inset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    /// The comparison page's list, as on the gain sources: tap to turn a
    /// band on and off, swipe right to highlight it, left to hide it. The
    /// deepest loss is listed first.
    private func legend(stack: HoldingLossStack, row: HoldingLossStack.Row) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(stack.bands.indices.reversed()), id: \.self) { band in
                let item = stack.bands[band]
                let key = Self.key(for: item)
                let isOn = item.kind != .others || showsOthers
                let color = Self.color(for: item.kind, scheme: colorScheme)
                ReturnsSwipeRow(
                    color: color, isHighlighted: highlightedBand == key, canRemove: isOn,
                    removeTitle: L10n.text("隐藏此项"), removeIcon: "eye.slash", removeSlidesOut: false,
                    onHighlight: { highlight(item) }, onRemove: { toggle(item) }
                ) {
                    Button { toggle(item) } label: {
                        ReturnsSourceListRow(rank: stack.rank(for: item), color: color,
                                             title: item.title, subtitle: item.subtitle, isOn: isOn,
                                             logo: logoHolding(for: item), isStriped: item.kind == .others) {
                            VStack(alignment: .trailing, spacing: 2) {
                                lossText(row.bands[band])
                                if let deepest = stack.deepest[item.title], item.kind != .others {
                                    Text(L10n.text("最深 \(DisplayFormat.money(-deepest, signed: true, fractionDigits: 0))"))
                                        .appNumber(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .returnsDimmed(highlightedBand != nil && highlightedBand != key)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityHint(L10n.text("轻点切换显示或隐藏"))
                .accessibilityAction(named: highlightedBand == key ? L10n.text("取消高亮") : L10n.text("高亮曲线")) {
                    highlight(item)
                }
            }
            ForEach(stack.hidden, id: \.ticker) { holding in
                ReturnsSwipeRow(
                    color: .secondary, isHighlighted: false, canRemove: false,
                    onHighlight: { show(holding.ticker, highlighting: true) }, onRemove: {}
                ) {
                    Button { show(holding.ticker, highlighting: false) } label: {
                        ReturnsSourceListRow(rank: stack.holdingRanks[holding.ticker], color: .secondary,
                                             title: holding.ticker, subtitle: holding.name, isOn: false,
                                             logo: logoHolding(ticker: holding.ticker)) {
                            Text(L10n.text("已隐藏")).appText(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .returnsDimmed(highlightedBand != nil)
                .accessibilityHint(L10n.text("轻点重新显示"))
            }
        }
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

    private func show(_ ticker: String, highlighting: Bool) {
        withAnimation(.snappy) {
            _ = hiddenTickers.remove(ticker)
            if highlighting { highlightedBand = ticker }
        }
    }

    /// Again on the highlighted band clears it; the others, if off, come
    /// back on first.
    private func highlight(_ band: HoldingLossStack.Band) {
        let key = Self.key(for: band)
        withAnimation(.smooth(duration: 0.25)) {
            if highlightedBand == key {
                highlightedBand = nil
                return
            }
            if band.kind == .others { showsOthers = true }
            highlightedBand = key
        }
    }

    private func lossText(_ loss: Double) -> some View {
        Text(loss > 0.5 ? DisplayFormat.money(-loss, signed: true, fractionDigits: 0) : L10n.text("未亏损"))
            .appNumber(.callout)
            .foregroundStyle(loss > 0.5 ? CatfolioTheme.loss(for: colorScheme) : .secondary)
    }

    private func toggle(_ band: HoldingLossStack.Band) {
        withAnimation(.snappy) {
            if highlightedBand == Self.key(for: band), band.kind != .others || showsOthers { highlightedBand = nil }
            switch band.kind {
            case .others: showsOthers.toggle()
            case .holding: hiddenTickers.insert(band.title)
            }
        }
    }

    /// The gain sources' palette, so a holding reads the same colour on both
    /// pages' bands; the others in a light grey.
    static func color(for kind: HoldingLossStack.Band.Kind, scheme: ColorScheme) -> Color {
        switch kind {
        case .others:
            return scheme == .dark ? Color(white: 0.30) : Color(white: 0.78)
        case let .holding(colour):
            return HoldingContributionChart.color(for: .holding(colour: colour), scheme: scheme)
        }
    }
}

/// The history in the range cut into loss bands, from the axis outward: the
/// others' losses, then the named holdings' losses from the smallest of them
/// to the deepest. Heights are losses as positive amounts.
struct HoldingLossStack: Sendable {
    struct Band: Sendable {
        enum Kind: Equatable, Sendable {
            case others
            /// 0 for the deepest loss; kept when others are hidden.
            case holding(colour: Int)
        }

        let kind: Kind
        let title: String
        let subtitle: String
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
    /// Deepest-loss rank in the selected range, computed before hiding.
    let holdingRanks: [String: Int]
    let hidden: [(ticker: String, name: String)]

    init(history: HoldingValueHistory, holdings: [Holding] = [], range: ChartTimeRange, hiding: Set<String> = []) {
        let window: [HoldingValueHistory.Row] = {
            guard let last = history.rows.last?.date else { return [] }
            let previous = history.rows.dropLast().last?.date
            return history.rows.filter { range.includes($0.date, through: last, previousTradingDate: previous) }
        }()
        var names = history.names
        for holding in holdings { names[holding.ticker.uppercased()] = holding.shortName }
        let present = Set(window.flatMap(\.values.keys))

        // Each holding's deepest loss in the range decides its place.
        var deepestLoss: [String: Double] = [:]
        for row in window {
            for ticker in present {
                let loss = max(0, -row.gain(ticker))
                if loss > (deepestLoss[ticker] ?? 0) { deepestLoss[ticker] = loss }
            }
        }
        let everyone = deepestLoss.keys.sorted {
            (deepestLoss[$0] ?? 0) == (deepestLoss[$1] ?? 0) ? $0 < $1 : (deepestLoss[$0] ?? 0) > (deepestLoss[$1] ?? 0)
        }
        let ranks = Dictionary(uniqueKeysWithValues: everyone.enumerated().map { ($0.element, $0.offset + 1) })
        holdingRanks = ranks
        func topLosers(_ tickers: [String]) -> [String] {
            Array(tickers.prefix(HoldingContributionStack.namedCount(tickers.map { deepestLoss[$0] ?? 0 })))
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
/// Every picker range is ready before the chart becomes interactive.
struct HoldingLossRanges: Sendable {
    private let stacks: [ChartTimeRange: HoldingLossStack]

    init(history: HoldingValueHistory, hiding: Set<String> = []) throws {
        var stacks: [ChartTimeRange: HoldingLossStack] = [:]
        for range in ChartTimeRange.allCases {
            try Task.checkCancellation()
            stacks[range] = HoldingLossStack(history: history, range: range, hiding: hiding)
        }
        self.stacks = stacks
    }

    subscript(range: ChartTimeRange) -> HoldingLossStack? { stacks[range] }
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
