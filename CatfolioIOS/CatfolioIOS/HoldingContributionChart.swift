import SwiftUI

/// Where the portfolio's value came from, over time. The principal is the
/// band at the bottom; on top of it sit the gains, the biggest contributors
/// each as their own band and the rest together, so the top of the stack is
/// the day's value. How many holdings get a band is decided from the gains
/// themselves (`HoldingContributionStack.namedCount`).
///
/// Each day is today's share counts at that day's close — for a personal
/// portfolio the home chart's own method, so the stack's top is its value line.
/// The design's dotted field: 3pt dots on a 10pt grid, barely there.
private struct HeroDotField: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 10, dot: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)),
                                 with: .color(color))
                    x += step
                }
                y += step
            }
        }
        .drawingGroup()
    }
}

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
                let visible = visibleBands(stack)
                let top = maximum(window, visible: visible) * 1.06
                // Figma 357:2257 / 362:14796: the figures, the chart and the
                // range strip share one tinted field that runs to all three
                // screen edges; the holdings list sits on the page's own
                // surface below it.
                let chart = plot(stack: stack, window: window, visible: visible, top: top)
                VStack(alignment: .leading, spacing: 0) {
                    header(shown)
                        .padding(.horizontal, Self.heroInset)
                        .padding(.bottom, 20)
                    // Edge to edge, as the home chart is; its value labels sit
                    // inside the plot instead of in a column beside it.
                    ZStack {
                        // The design carries the chart's colour into the field
                        // around it: a blurred copy behind the bands reads as a
                        // coloured glow rather than a grey shadow.
                        // Night only: the violet field takes the colour and
                        // glows. The day field in the design stays clean right
                        // up to the band edges, so nothing is drawn behind it.
                        if colorScheme == .dark {
                            chart
                                .frame(height: Self.chartHeight)
                                .blur(radius: 18)
                                .opacity(0.72)
                                .blendMode(.plusLighter)
                                .allowsHitTesting(false)
                        }
                        chart
                            .frame(height: Self.chartHeight)

                    }
                    .frame(height: Self.chartHeight)
                    .overlay(alignment: .topLeading) { axisLabels(top: top) }
                    rangeStrip(reflecting: chart)
                }
                .background(alignment: .bottom) { heroField }
                // The field is cut with the card radius along the bottom; the
                // mask keeps the upward extension so the bar area stays
                // covered.
                .compositingGroup()
                .mask(alignment: .bottom) {
                    UnevenRoundedRectangle(
                        cornerRadii: .init(bottomLeading: CatfolioStyle.cardRadius,
                                           bottomTrailing: CatfolioStyle.cardRadius),
                        style: .continuous
                    )
                    .fill(Color.black)
                    .padding(.top, -320)
                }
                Group {
                    legend(stack: stack, row: shown)
                    Text(L10n.text("按当前持仓的股数回推每天的市值，所以已卖出的持仓不在图中。收益最多的几只各占一层：按盈利从高到低，直到下一只不到全部盈利的 6%，最多 6 只。其他持仓整体亏损时，亏损从本金层里扣除，本金层会低于本金线。轻点下方任意一行可以隐藏或显示；隐藏的持仓并入其他，由下一只补上。"))
                        .appText(.micro, weight: .regular)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Self.heroInset)
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
                                             message: L10n.text("收益来源"), isLoading: true,
                                             lineWidths: [1.5, 1.5, 1.5], appearanceID: "income-sources")
                    .frame(height: 300)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            }
        }
        // The tinted field runs behind the bar, so the bar brings no surface
        // of its own on this page.
        .toolbarBackground(.hidden, for: .navigationBar)
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
                .foregroundStyle(heroSecondary)
            CatfolioDisplayAmountText(
                text: DisplayFormat.money(row.total, fractionDigits: 0),
                size: 34,
                symbolSize: 22,
                color: heroPrimary
            )
            .contentTransition(.numericText(value: row.total))
            HStack(spacing: 4) {
                // The sign carries the direction here; on the tinted field
                // the line reads as one sentence rather than a green figure.
                Text(DisplayFormat.money(row.total - row.principal, signed: true, fractionDigits: 0))
                    .foregroundStyle(heroPrimary)
                Text("·").foregroundStyle(heroSecondary)
                Text(L10n.text("本金"))
                    .appText(.footnote, weight: .medium)
                    .foregroundStyle(heroSecondary)
                Text(DisplayFormat.money(row.principal, fractionDigits: 0))
                    .foregroundStyle(heroSecondary)
            }
            .appNumber(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    /// Figma 357:2257 (light) and 362:14796 (dark).
    static let heroInset: CGFloat = 24

    private var heroPrimary: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.10, blue: 0.10)
    }

    private var heroSecondary: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.55)
    }

    /// Flat lavender by day, a violet gradient by night, with the design's
    /// dotted field over it. It is drawn from the bottom of the hero upwards
    /// so it fills the page's top padding and the space behind the bar.
    private var heroField: some View {
        ZStack {
            if colorScheme == .dark {
                // The field is drawn taller than the hero so it covers the bar
                // area, so the top colour has to hold through that extension —
                // otherwise the visible top starts already part-way down the
                // gradient and reads too light.
                LinearGradient(stops: [.init(color: Color(red: 0.361, green: 0.196, blue: 0.835), location: 0),
                                       .init(color: Color(red: 0.361, green: 0.196, blue: 0.835), location: 0.46),
                                       .init(color: Color(red: 0.404, green: 0.329, blue: 1.0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Color(red: 0.922, green: 0.894, blue: 1.0)
            }
            // The dots thin out down the field and stop short of the range
            // strip, which carries the chart's reflection instead.
            HeroDotField(color: colorScheme == .dark ? Color.white.opacity(0.06)
                                                     : Color.black.opacity(0.04))
                .mask {
                    LinearGradient(stops: [.init(color: .white, location: 0),
                                           .init(color: .white.opacity(0.85), location: 0.45),
                                           .init(color: .clear, location: 0.78)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .padding(.bottom, Self.stripHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, -320)
        .allowsHitTesting(false)
    }

    static let chartHeight: CGFloat = 280
    static let stripHeight: CGFloat = 62

    /// The range picker on a translucent strip. The design shows the chart
    /// reflected in it — the yellow band's colour pooling under the strip on
    /// the right — so the strip carries a mirrored, blurred copy of the chart
    /// under its tint rather than a flat fill.
    private func rangeStrip<Chart: View>(reflecting chart: Chart) -> some View {
        ChartTimeRangePicker(selection: $range, isOnTintedField: true)
            .frame(maxWidth: .infinity)
            .frame(height: Self.stripHeight)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    // Mirrored, so the chart's bottom edge continues into the
                    // strip; blurred until only the colour is left.
                    chart
                        .frame(height: Self.chartHeight)
                        .scaleEffect(y: -1, anchor: .center)
                        .blur(radius: 16)
                        .opacity(colorScheme == .dark ? 0.55 : 0.5)
                        .allowsHitTesting(false)
                    (colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.42))
                }
                .frame(height: Self.stripHeight, alignment: .top)
                .clipped()
                .allowsHitTesting(false)
            }
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
                // No outline: the design lets the fills meet directly, and a
                // band that is zero across the range would otherwise stroke a
                // line along the bottom of the chart.
                lineWidth: 0,
                areaFill: color,
                // Figma: every gain band is its own colour at the top and
                // pales towards its bottom edge; the striped others band and
                // the principal keep a flat fill.
                areaFillWash: stack.bands[band].kind == .others ? 0 : 0.38,
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
            // The same capsule the home chart shows under the finger.
            selectionIndicatorLabel: selectedDate.map {
                $0.formatted(.dateTime.year().month(.abbreviated).day())
            },
            selectionSeriesIDs: Set([topSeries, showsPrincipal ? "principal" : nil].compactMap { $0 }),
            dimsFutureDuringSelection: true,
            // The header carries the values; the date shows while scrubbing.
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
        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.42) : Color.black.opacity(0.32))
        .padding(.leading, Self.heroInset)
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
            }
        }
    }

    private func legendRow<Trailing: View>(swatch: Color, isOn: Bool, title: String, subtitle: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
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
            // Figma: the principal carries the field's blue in both schemes.
            return Color(red: 0.310, green: 0.694, blue: 0.992)
        case .others:
            return Color(white: 0.34)
        case let .holding(colour):
            let palette = [Color(red: 0.153, green: 0.871, blue: 0.722),   // #27DEB8
                           Color(red: 0.898, green: 0.529, blue: 0.149),   // #E58726
                           Color(red: 0.984, green: 0.886, blue: 0.333),   // #FBE255
                           Color(red: 0.529, green: 0.745, blue: 0.937),   // #87BEEF
                           CatfolioPalette.coral200, CatfolioPalette.green200]
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
