import SwiftUI

/// Where the portfolio's value came from, over time. The principal is the
/// band at the bottom; on top of it sit the gains, the biggest contributors
/// each as their own band and the rest together, so the top of the stack is
/// the day's value. How many holdings get a band is decided from the gains
/// themselves (`HoldingContributionStack.namedCount`).
///
/// Each day is today's share counts at that day's close — for a personal
/// portfolio the home chart's own method, so the stack's top is its value line.
struct HoldingContributionChart: View {
    var refreshRevision = 0
    var fetchHistory: (@MainActor (Bool) async throws -> HoldingValueHistory)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var appLocale
    @State private var loading = HoldingHistoryState()
    @State private var retryRevision = 0
    @State private var range = ChartTimeRange.yearToDate
    @State private var selectedDate: Date?
    /// Holdings the reader turned off; the next ones by gain take their place.
    @State private var hiddenTickers: Set<String> = []
    @State private var showsPrincipal = false
    @State private var showsOthers = true
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    var body: some View {
        let stack = loading.history.map { HoldingContributionStack(history: $0, holdings: model.holdings, hiding: hiddenTickers) }
        let window = stack?.window(for: range)

        VStack(alignment: .leading, spacing: 18) {
            if let stack, let window, window.rows.count > 1 {
                let shown = window.row(nearest: selectedDate) ?? window.rows.last!
                header(shown)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                // Edge to edge, as the home chart is; its value labels sit
                // inside the plot instead of in a column beside it.
                let visible = visibleBands(stack)
                let top = maximum(window, visible: visible) * 1.06
                plot(stack: stack, window: window, visible: visible, top: top)
                    .frame(height: 300)
                    .overlay(alignment: .topLeading) { axisLabels(top: top) }
                ChartTimeRangePicker(selection: $range)
                    .frame(maxWidth: .infinity)
                Group {
                    legend(stack: stack, row: shown)
                    Text(L10n.text("按当前持仓的股数回推每天的市值，所以已卖出的持仓不在图中。收益最多的几只各占一层：按盈利从高到低，直到下一只不到全部盈利的 6%，最多 6 只。其他持仓整体亏损时，亏损从本金层里扣除，本金层会低于本金线。轻点下方任意一行可以隐藏或显示；隐藏的持仓并入其他，由下一只补上。"))
                        .appText(.micro, weight: .regular)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
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
                                             message: L10n.text("收益来源"), isLoading: true,
                                             lineWidths: [1.5, 1.5, 1.5], appearanceID: "income-sources")
                    .frame(height: 300)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            }
        }
        .task(id: "\(model.portfolioChartRevision)|\(model.holdings.count)|\(refreshRevision)|\(retryRevision)") {
            await loading.load { cachedOnly in
                if let fetchHistory { return try await fetchHistory(cachedOnly) }
                #if DEBUG
                if LaunchArguments.contains("--demo-loss-history") {
                    return LossAnalysisChart.demoHistory()
                }
                #endif
                return try await model.holdingValueHistory(cachedOnly: cachedOnly)
            }
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .sensoryFeedback(.selection, trigger: "\(hiddenTickers.sorted())|\(showsPrincipal)|\(showsOthers)") { _, _ in hapticsEnabled }
    }

    /// Band indices to draw, bottom to top. Each keeps its place in the
    /// stack; a hidden one simply is not added in.
    private func visibleBands(_ stack: HoldingContributionStack) -> [Int] {
        stack.bands.indices.filter { index in
            switch stack.bands[index].kind {
            case .principal: showsPrincipal
            case .others: showsOthers
            case .holding: true
            }
        }
    }

    private func maximum(_ window: HoldingContributionStack.Window, visible: [Int]) -> Double {
        window.rows.map { row in
            max(visible.reduce(0) { $0 + row.bands[$1] }, showsPrincipal ? row.principal : 0)
        }.max() ?? 0
    }

    private func header(_ row: HoldingContributionStack.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.date.formatted(.dateTime.year().month(.abbreviated).day()))
                .appText(.caption, weight: .medium)
                .foregroundStyle(.secondary)
            Text(DisplayFormat.money(row.total, fractionDigits: 0))
                .appNumber(.title, weight: .semibold)
                .contentTransition(.numericText(value: row.total))
            HStack(spacing: 4) {
                Text(DisplayFormat.money(row.total - row.principal, signed: true, fractionDigits: 0))
                    .foregroundStyle(CatfolioTheme.heroPerformance(for: row.total - row.principal, scheme: colorScheme))
                Text("·").foregroundStyle(.tertiary)
                Text(L10n.text("本金"))
                    .appText(.footnote, weight: .medium)
                    .foregroundStyle(.secondary)
                Text(DisplayFormat.money(row.principal, fractionDigits: 0))
                    .foregroundStyle(.secondary)
            }
            .appNumber(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private func plot(stack: HoldingContributionStack, window: HoldingContributionStack.Window,
                      visible: [Int], top: Double) -> some View {
        // Painted from the top of the stack down: each band's area reaches
        // the axis and the next one paints over its lower part, leaving the
        // band between them. The principal line goes on last, so where the
        // principal band has been eaten into, the line still shows the sum.
        var series: [StandardLineChartSeries] = []
        for (position, band) in visible.enumerated().reversed() {
            let color = Self.color(for: stack.bands[band].kind, scheme: colorScheme)
            let below = visible[...position]
            let id = Self.seriesID(stack.bands[band])
            series.append(StandardLineChartSeries(
                id: id,
                points: window.rows.map { row in
                    StandardLineChartPoint(id: "\(id)|\(row.dateText)", date: row.date,
                                           value: below.reduce(0) { $0 + row.bands[$1] })
                },
                color: color,
                lineWidth: 1.5,
                areaFill: color,
                areaBaseline: 0,
                areaStripeColor: stack.bands[band].kind == .others ? Color.white.opacity(0.07) : nil,
                areaStripeSpacing: 10,
                latestPointRadius: 0,
                latestPointUsesGlass: false
            ))
        }
        if showsPrincipal {
            series.append(StandardLineChartSeries(
                id: "principal",
                points: window.rows.map { StandardLineChartPoint(id: "principal|\($0.dateText)", date: $0.date, value: $0.principal) },
                color: Self.principalLine,
                lineWidth: 2.5,
                // No endpoint dot: the line ends at the screen edge, where a
                // dot would be cut in half.
                latestPointRadius: 0,
                latestPointUsesGlass: false
            ))
        }
        let topSeries = visible.last.map { Self.seriesID(stack.bands[$0]) }
        return StandardLineChart(
            series: series,
            interactionDates: window.rows.map(\.date),
            domain: 0...max(top, 1),
            yTicks: [top, top / 2, 0],
            axisWidth: 0,
            topInset: 4,
            bottomHeight: 0,
            leadingLineOverflow: 0,
            trailingEndpointInset: 0,
            gridOpacity: 0,
            transitionKey: "\(range.rawValue)-\(colorScheme == .light ? "light" : "dark")",
            appearanceID: "income-sources",
            dataTransition: .viewportZoom,
            selectedDate: selectedDate,
            selectionSeriesIDs: Set([topSeries, showsPrincipal ? "principal" : nil].compactMap { $0 }),
            dimsFutureDuringSelection: true,
            // The overlay carries the values; the date shows while scrubbing.
            yAxisLabel: { _ in "" },
            xAxisLabel: { date in
                [.oneWeek, .oneMonth, .twoMonths].contains(range)
                    ? date.formatted(.dateTime.month(.abbreviated).day())
                    : date.formatted(.dateTime.month(.abbreviated))
            },
            onSelect: { selectedDate = $0 },
            onInteractionEnded: { _ in selectedDate = nil }
        )
        .accessibilityLabel(L10n.text("收益来源堆叠图，长按后拖动查看单日"))
    }

    /// Stable per band, so turning one off morphs the rest into place.
    private static func seriesID(_ band: HoldingContributionStack.Band) -> String {
        switch band.kind {
        case .principal: "band-principal"
        case .others: "band-others"
        case .holding: "band-\(band.title)"
        }
    }

    /// The home chart's axis: three faint values down the left of the plot.
    private func axisLabels(top: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array([top, top / 2, 0].enumerated()), id: \.offset) { index, value in
                AnimatedChartValue(value: value) {
                    Text(DisplayFormat.compact($0, precision: .whole)).appNumber(.footnote)
                }
                if index < 2 { Spacer() }
            }
        }
        .animation(StandardLineChartTransition.zoom, value: top)
        .foregroundStyle(Color.primary.opacity(colorScheme == .light ? 0.35 : 0.4))
        .padding(.leading, CatfolioStyle.pageHorizontalInset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    /// Every row turns its band on and off. A holding turned off joins the
    /// others and the next one by gain takes its band; it waits, dimmed, at
    /// the foot of the list to be turned back on.
    private func legend(stack: HoldingContributionStack, row: HoldingContributionStack.Row) -> some View {
        VStack(spacing: 0) {
            // Top of the stack first, as the eye reads the chart.
            ForEach(Array(stack.bands.indices.reversed()), id: \.self) { band in
                let item = stack.bands[band]
                let isOn = isShown(item.kind)
                Button { toggle(item) } label: {
                    legendRow(swatch: Self.color(for: item.kind, scheme: colorScheme), isOn: isOn,
                              title: item.title, subtitle: item.subtitle) {
                        legendAmount(item.kind, row: row, band: band)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityHint(L10n.text("轻点切换显示或隐藏"))
                Divider()
            }
            ForEach(stack.hidden, id: \.ticker) { holding in
                Button {
                    withAnimation(.snappy) { _ = hiddenTickers.remove(holding.ticker) }
                } label: {
                    legendRow(swatch: .secondary, isOn: false, title: holding.ticker, subtitle: holding.name) {
                        Text(L10n.text("已隐藏")).appText(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.text("轻点重新显示"))
                Divider()
            }
        }
    }

    private func legendRow<Trailing: View>(swatch: Color, isOn: Bool, title: String, subtitle: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isOn ? swatch : .clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(isOn ? .clear : Color.secondary, lineWidth: 1.5)
                }
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appText(.callout, weight: .semibold).lineLimit(1)
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

    private func isShown(_ kind: HoldingContributionStack.Band.Kind) -> Bool {
        switch kind {
        case .principal: showsPrincipal
        case .others: showsOthers
        case .holding: true
        }
    }

    private func toggle(_ band: HoldingContributionStack.Band) {
        withAnimation(.snappy) {
            switch band.kind {
            case .principal: showsPrincipal.toggle()
            case .others: showsOthers.toggle()
            case .holding: hiddenTickers.insert(band.title)
            }
        }
    }

    /// Principal as an amount; gains signed, in the gain and loss colours.
    /// The others row shows the others' real gain, which can be a loss even
    /// though its band never goes below nothing.
    @ViewBuilder
    private func legendAmount(_ kind: HoldingContributionStack.Band.Kind, row: HoldingContributionStack.Row, band: Int) -> some View {
        let amount: Double = {
            switch kind {
            case .principal: row.principal
            case .others: row.othersGain
            case .holding: row.bands[band]
            }
        }()
        if kind == .principal {
            Text(DisplayFormat.money(amount, fractionDigits: 0)).appNumber(.callout)
        } else {
            Text(DisplayFormat.money(amount, signed: true, fractionDigits: 0))
                .appNumber(.callout)
                .foregroundStyle(amount >= 0 ? CatfolioTheme.gain(for: colorScheme) : CatfolioTheme.loss(for: colorScheme))
        }
    }

    /// The home chart's net-deposit blue, for the principal line.
    static let principalLine = Color(red: 0.204, green: 0.459, blue: 1)

    /// The principal is a deep tint of its line's blue; the gains take clear
    /// hues that are neither that blue nor the red and green of loss and gain;
    /// the others sit in an opaque grey so the bands above read against it.
    static func color(for kind: HoldingContributionStack.Band.Kind, scheme: ColorScheme) -> Color {
        switch kind {
        case .principal:
            return scheme == .dark ? Color(red: 0.11, green: 0.20, blue: 0.40) : Color(red: 0.78, green: 0.85, blue: 1)
        case .others:
            return scheme == .dark ? Color(white: 0.26) : Color(white: 0.34)
        case let .holding(colour):
            let palette = [CatfolioPalette.teal500, CatfolioPalette.orange500, CatfolioPalette.yellow500,
                           CatfolioPalette.sky300, CatfolioPalette.coral200, CatfolioPalette.green200]
            return palette[colour % palette.count]
        }
    }
}

/// The history cut into the chart's bands, bottom to top: the principal, the
/// others' gain, then the named holdings' gains from the smallest of them to
/// the largest, so the largest is on top and the stack's top is the day's
/// value.
struct HoldingContributionStack {
    struct Band {
        enum Kind: Equatable {
            case principal
            case others
            /// 0 for the largest gain.
            /// `colour` is the holding's place in the palette, kept when
            /// others are hidden so nothing changes colour under the reader.
            case holding(colour: Int)
        }

        let kind: Kind
        let title: String
        let subtitle: String
    }

    struct Row {
        let dateText: String
        let date: Date
        /// What the holdings open on the day cost.
        let principal: Double
        /// The others' real gain, negative when they are losing.
        let othersGain: Double
        /// One height per band, in `bands` order, never below nothing. The
        /// others' losses come out of the principal band.
        let bands: [Double]
        var total: Double { bands.reduce(0, +) }
    }

    struct Window {
        let rows: [Row]

        func row(nearest date: Date?) -> Row? {
            guard let date else { return nil }
            return rows.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
    }

    /// No more bands than this, however even the gains.
    static let maximumNamed = 6
    /// A holding earns its own band while its gain is at least this share of
    /// all the gains; the first one always does.
    static let minimumShare = 0.06

    let bands: [Band]
    let rows: [Row]
    /// Holdings the reader turned off, with their names: they count in the
    /// others and are listed so they can be turned back on.
    let hidden: [(ticker: String, name: String)]

    /// How many of the gains, largest first, get their own band: while each
    /// is at least `minimumShare` of all the positive gains, up to
    /// `maximumNamed`, and at least one when anything gained at all.
    static func namedCount(_ gains: [Double]) -> Int {
        let positive = gains.filter { $0 > 0 }.sorted(by: >)
        let total = positive.reduce(0, +)
        guard total > 0 else { return 0 }
        var count = 0
        for gain in positive.prefix(maximumNamed) {
            guard count == 0 || gain / total >= minimumShare else { break }
            count += 1
        }
        return count
    }

    /// `holdings` only supplies display names; the ranking and gains come
    /// from the history itself, so they agree with what is drawn. Holdings in
    /// `hiding` never get a band: the next ones by gain take their places.
    init(history: HoldingValueHistory, holdings: [Holding] = [], hiding: Set<String> = []) {
        let latestGains = history.gains
        var names = history.names
        for holding in holdings { names[holding.ticker.uppercased()] = holding.shortName }
        let everyone = latestGains.keys.sorted {
            (latestGains[$0] ?? 0) == (latestGains[$1] ?? 0) ? $0 < $1 : (latestGains[$0] ?? 0) > (latestGains[$1] ?? 0)
        }
        func topGainers(_ tickers: [String]) -> [String] {
            Array(tickers.prefix(Self.namedCount(tickers.map { latestGains[$0] ?? 0 })))
        }
        let named = topGainers(everyone.filter { !hiding.contains($0) })
        // Colours follow the ranking with nothing hidden; one that steps in
        // for a hidden holding takes the colour left free.
        var colours: [String: Int] = [:]
        for (index, ticker) in topGainers(everyone).enumerated() where named.contains(ticker) {
            colours[ticker] = index
        }
        var free = (0..<Self.maximumNamed).filter { !colours.values.contains($0) }.makeIterator()
        for ticker in named where colours[ticker] == nil { colours[ticker] = free.next() ?? 0 }
        let present = Set(history.rows.flatMap(\.values.keys))
        let others = present.subtracting(named)
        hidden = hiding.intersection(present).sorted().map { (ticker: $0, name: names[$0] ?? $0) }

        var bands = [
            Band(kind: .principal, title: L10n.text("本金"), subtitle: L10n.text("当前持仓的买入成本")),
            Band(kind: .others, title: L10n.text("其他收益"), subtitle: L10n.text("\(others.count) 项持仓合计")),
        ]
        for ticker in named.reversed() {
            bands.append(Band(kind: .holding(colour: colours[ticker] ?? 0), title: ticker, subtitle: names[ticker] ?? ticker))
        }
        self.bands = bands

        rows = history.rows.map { row in
            // Named gains are drawn from nothing up; an early stretch below
            // cost counts in with the rest instead of as a negative band.
            let namedGains = named.reversed().map { max(0, row.gain($0)) }
            let remainder = row.total - row.cost - namedGains.reduce(0, +)
            let othersGain = others.reduce(0) { $0 + row.gain($1) }
            return Row(
                dateText: row.dateText,
                date: row.date,
                principal: row.cost,
                othersGain: othersGain,
                bands: [row.cost + min(0, remainder), max(0, remainder)] + namedGains
            )
        }
    }

    func window(for range: ChartTimeRange) -> Window {
        guard let last = rows.last?.date else { return Window(rows: []) }
        let previous = rows.dropLast().last?.date
        return Window(rows: rows.filter { range.includes($0.date, through: last, previousTradingDate: previous) })
    }
}
