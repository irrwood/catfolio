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
    @State private var retryRevision = 0
    @State private var range = ChartTimeRange.oneYear
    @State private var selectedDate: Date?
    /// Holdings the reader turned off; the next ones by loss take their place.
    @State private var hiddenTickers: Set<String> = []
    @State private var showsOthers = true
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    var body: some View {
        let stack = loading.history.map {
            HoldingLossStack(history: $0, holdings: model.holdings, range: range, hiding: hiddenTickers)
        }

        VStack(alignment: .leading, spacing: 18) {
            if let stack, stack.rows.count > 1 {
                let shown = stack.row(nearest: selectedDate) ?? stack.rows.last!
                let visible = visibleBands(stack)
                let bottom = floor(stack, visible: visible)
                ReturnsSourceChartHero(range: $range, header: header(shown),
                                       plot: plot(stack: stack, visible: visible, bottom: bottom),
                                       axis: axisLabels(bottom: bottom))
                Group {
                    if stack.bands.count > 1 || !stack.hidden.isEmpty {
                        legend(stack: stack, row: shown)
                    } else {
                        Text(L10n.text("这段时间里没有持仓低于成本。"))
                            .appText(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                    Text(L10n.text("按当前持仓的股数回推每天的市值，所以已卖出的持仓不在图中。每只持仓低于成本的部分是它的亏损，高于成本时为零。在所选时间里亏得最深的几只各占一层：按最深亏损从大到小，直到下一只不到全部的 6%，最多 6 只；其余合为一层，贴着零线。轻点下方任意一行可以隐藏或显示；隐藏的持仓并入其他，由下一只补上。"))
                        .appText(.micro, weight: .regular)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
            } else if loading.history != nil {
                StandardLineChartPlaceholder(title: L10n.text("历史数据不足"),
                                             message: L10n.text("该时间范围内没有足够的市值记录。"), isLoading: false,
                                             hint: L10n.text("下拉刷新会重新计算这段历史。"))
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
            await loading.load { cachedOnly in
                if let fetchHistory { return try await fetchHistory(cachedOnly) }
                #if DEBUG
                if LaunchArguments.contains("--demo-loss-history") { return Self.demoHistory() }
                #endif
                return try await model.holdingValueHistory(cachedOnly: cachedOnly)
            }
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .sensoryFeedback(.selection, trigger: "\(hiddenTickers.sorted())|\(showsOthers)") { _, _ in hapticsEnabled }
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
        // Deepest level first: each band's area reaches the axis and the
        // next one paints over its upper part, leaving the band between.
        // No portfolio line on top — the bottom edge already is the total.
        var series: [StandardLineChartSeries] = []
        for (position, band) in visible.enumerated().reversed() {
            let kind = stack.bands[band].kind
            let gainKind: HoldingContributionStack.Band.Kind = switch kind {
            case .others: .others
            case let .holding(colour): .holding(colour: colour)
            }
            let color = HoldingContributionChart.fillColor(for: gainKind, scheme: colorScheme)
            let above = visible[...position]
            let id = Self.seriesID(stack.bands[band])
            series.append(StandardLineChartSeries(
                id: id,
                points: stack.rows.map { row in
                    StandardLineChartPoint(id: "\(id)|\(row.dateText)", date: row.date,
                                           value: -above.reduce(0) { $0 + row.bands[$1] })
                },
                color: color,
                lineWidth: 0,
                areaFill: kind == .others ? .white : color,
                areaFillEndColor: HoldingContributionChart.fillEndColor(for: gainKind),
                areaBaseline: 0,
                areaStripeColor: kind == .others ? ReturnsSourceChartStyle.stripeColor : nil,
                areaStripeSpacing: 35.5,
                areaStripeWidth: 13,
                latestPointRadius: 0,
                latestPointUsesGlass: false
            ))
        }
        let outer = visible.last.map { Self.seriesID(stack.bands[$0]) }
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

    private static func seriesID(_ band: HoldingLossStack.Band) -> String {
        switch band.kind {
        case .others: "loss-others"
        case .holding: "loss-\(band.title)"
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
        .animation(StandardLineChartTransition.zoom, value: bottom)
        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.42) : Color.black.opacity(0.32))
        .padding(.leading, ReturnsSourceChartStyle.inset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    /// Every row turns its band on and off, as on the gain sources. The
    /// deepest loss is listed first.
    private func legend(stack: HoldingLossStack, row: HoldingLossStack.Row) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(stack.bands.indices.reversed()), id: \.self) { band in
                let item = stack.bands[band]
                let isOn = item.kind != .others || showsOthers
                Button { toggle(item) } label: {
                    legendRow(rank: stack.rank(for: item), swatch: Self.color(for: item.kind, scheme: colorScheme), isOn: isOn,
                              title: item.title, subtitle: item.subtitle) {
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
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityHint(L10n.text("轻点切换显示或隐藏"))
            }
            ForEach(stack.hidden, id: \.ticker) { holding in
                Button {
                    withAnimation(.snappy) { _ = hiddenTickers.remove(holding.ticker) }
                } label: {
                    legendRow(rank: stack.holdingRanks[holding.ticker], swatch: .secondary, isOn: false, title: holding.ticker, subtitle: holding.name) {
                        Text(L10n.text("已隐藏")).appText(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.text("轻点重新显示"))
            }
        }
    }

    private func lossText(_ loss: Double) -> some View {
        Text(loss > 0.5 ? DisplayFormat.money(-loss, signed: true, fractionDigits: 0) : L10n.text("未亏损"))
            .appNumber(.callout)
            .foregroundStyle(loss > 0.5 ? CatfolioTheme.loss(for: colorScheme) : .secondary)
    }

    private func legendRow<Trailing: View>(rank: Int?, swatch: Color, isOn: Bool, title: String, subtitle: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(rank.map(String.init) ?? "")
                .appNumber(.callout, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isOn ? swatch : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isOn ? .clear : Color.secondary, lineWidth: 1.5)
                }
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appText(.subheading, weight: .semibold).lineLimit(1)
                Text(subtitle).appText(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .opacity(isOn ? 1 : 0.45)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func toggle(_ band: HoldingLossStack.Band) {
        withAnimation(.snappy) {
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
struct HoldingLossStack {
    struct Band {
        enum Kind: Equatable {
            case others
            /// 0 for the deepest loss; kept when others are hidden.
            case holding(colour: Int)
        }

        let kind: Kind
        let title: String
        let subtitle: String
    }

    struct Row {
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
