import SwiftUI

/// Where the portfolio's value came from, over time. The principal is the
/// band at the bottom; on top of it sit the gains, the biggest contributors
/// each as their own band and the rest together. With every gain visible,
/// the top is the day's value. How many holdings get a band is decided from the gains
/// themselves (`HoldingContributionStack.namedCount`).
///
/// Each day is today's share counts at that day's close — for a personal
/// portfolio the home chart's own method. Hidden gains leave the plot only.
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

enum ReturnsSourceChartStyle {
    static let inset: CGFloat = 24
    static let chartHeight: CGFloat = 280
    static let stripHeight: CGFloat = 62
    static let stripeColor = Color(red: 92 / 255, green: 187 / 255, blue: 253 / 255).opacity(0.1)

    static func primary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(red: 0.10, green: 0.10, blue: 0.10)
    }

    static func secondary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.55)
    }
}

/// Every legend row reserves the same digit width, including hidden holdings
/// and unranked aggregates. The column also follows the reader's text size.
struct ReturnsSourceRankLabel: View {
    let rank: Int?
    let maximumRank: Int

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(String(repeating: "8", count: max(2, String(maximumRank).count)))
                .hidden()
            Text(rank.map(String.init) ?? "")
        }
        .appNumber(.callout, weight: .semibold)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rank.map(String.init) ?? "")
        .accessibilityHidden(rank == nil)
    }
}

/// The aggregate key uses the same white ground and diagonal paint as its area.
struct ReturnsSourceLegendSwatch: View {
    let color: Color
    let isOn: Bool
    var isOtherGains = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isOn ? (isOtherGains ? .white : color) : .clear)
            .overlay {
                if isOn && isOtherGains {
                    Canvas { context, size in
                        var stripes = Path()
                        for x in stride(from: -size.height, through: size.width, by: 7) {
                            // Keep stroke caps outside the key; only the mask
                            // should define where a stripe meets its edge.
                            stripes.move(to: CGPoint(x: x - 4, y: size.height + 4))
                            stripes.addLine(to: CGPoint(x: x + size.height + 4, y: -4))
                        }
                        context.stroke(stripes, with: .color(ReturnsSourceChartStyle.stripeColor), lineWidth: 2.6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous).inset(by: 0.75))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isOn ? (isOtherGains ? Color.secondary.opacity(0.2) : .clear) : .secondary,
                                  lineWidth: isOn ? 0.5 : 1.5)
            }
            .frame(width: 20, height: 20)
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Shared Figma surface for gains and losses; each page supplies its own
/// data-driven plot and axes, including the losses' downward direction.
struct ReturnsSourceChartHero<Header: View, Plot: View, Axis: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var range: ChartTimeRange
    let header: Header
    let plot: Plot
    let axis: Axis

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, ReturnsSourceChartStyle.inset)
                .padding(.bottom, 20)
                // Downward loss areas have colour at the top of the plot;
                // their expanded glow must stay behind the header's text.
                .zIndex(1)
            ZStack {
                // 454pt of colour behind a 280pt plot, blurred at 35pt.
                plot
                    .frame(height: ReturnsSourceChartStyle.chartHeight)
                    .scaleEffect(y: 454 / 280, anchor: .bottom)
                    .blur(radius: 35)
                    .opacity(colorScheme == .dark ? 0.2 : 0.5)
                    .blendMode(colorScheme == .dark ? .plusLighter : .lighten)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                plot.frame(height: ReturnsSourceChartStyle.chartHeight)
            }
            .frame(height: ReturnsSourceChartStyle.chartHeight)
            .overlay(alignment: .topLeading) { axis }
            rangeStrip(reflecting: plot)
        }
        .background(alignment: .bottom) { heroField }
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
    }

    /// Exact Figma field paints. The apparent dark gradient comes from
    /// the chart glow, not a second gradient baked into the background.
    private var heroField: some View {
        ZStack(alignment: .bottom) {
            (colorScheme == .dark
                ? Color(red: 0.360386, green: 0.194594, blue: 0.834078)
                : Color(red: 238 / 255, green: 248 / 255, blue: 254 / 255))
                .padding(.top, -320)
            HeroDotField(color: .black)
                .mask {
                    LinearGradient(stops: [.init(color: .white, location: 0),
                                           .init(color: .clear, location: 0.7684)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .opacity(colorScheme == .dark ? 0.34 : 0.1)
                .blendMode(colorScheme == .dark ? .overlay : .normal)
                // Anchor the 533pt field to the plot baseline, so extending
                // the background behind navigation does not dilute the dots.
                .frame(height: 533)
                .padding(.bottom, ReturnsSourceChartStyle.stripHeight - 23)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The range picker on a translucent strip. The design shows the chart
    /// reflected in it — the yellow band's colour pooling under the strip on
    /// the right — so the strip carries a mirrored, blurred copy of the chart
    /// under its tint rather than a flat fill.
    private func rangeStrip<Chart: View>(reflecting chart: Chart) -> some View {
        ChartTimeRangePicker(selection: $range, isOnTintedField: true)
            .frame(maxWidth: .infinity)
            .frame(height: ReturnsSourceChartStyle.stripHeight)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    // Mirrored, so the chart's bottom edge continues into the
                    // strip; blurred until only the colour is left.
                    chart
                        .frame(height: ReturnsSourceChartStyle.chartHeight)
                        .scaleEffect(y: -1, anchor: .center)
                        .offset(y: -24)
                        .blur(radius: 20)
                        .opacity(0.5)
                        .allowsHitTesting(false)
                }
                .frame(height: ReturnsSourceChartStyle.stripHeight, alignment: .top)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

}

struct HoldingContributionChart: View {
    var refreshRevision = 0
    var fetchHistory: (@MainActor (Bool) async throws -> HoldingValueHistory)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                ReturnsSourceChartHero(range: $range, header: header(shown), plot: chart,
                                       axis: axisLabels(top: top))
                Group {
                    legend(stack: stack, row: shown)
                    Text(L10n.text("按当前持仓的股数回推每天的市值，所以已卖出的持仓不在图中。收益最多的几只各占一层：按盈利从高到低，直到下一只不到全部盈利的 6%，最多 6 只。其他持仓整体亏损时，亏损从本金层里扣除，本金层会低于本金线。其他收益只包含未单独列出且未隐藏的持仓。轻点下方任意一行可以隐藏或显示；隐藏的收益从图中移除，由下一只补上。顶部组合总额与本金不受隐藏影响。"))
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
            // As on the home page: the digits roll to the new figure as the
            // reader moves along the chart or changes the range.
            .contentTransition(.numericText(value: row.total))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: row.total)
            HStack(spacing: 4) {
                // The sign carries the direction here; on the tinted field
                // the line reads as one sentence rather than a green figure.
                Text(DisplayFormat.money(row.total - row.principal, signed: true, fractionDigits: 0))
                    .foregroundStyle(heroPrimary)
                    .contentTransition(.numericText(value: row.total - row.principal))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: row.total - row.principal)
                Text("·").foregroundStyle(heroSecondary)
                Text(L10n.text("本金"))
                    .appText(.footnote, weight: .medium)
                    .foregroundStyle(heroSecondary)
                Text(DisplayFormat.money(row.principal, fractionDigits: 0))
                    .foregroundStyle(heroSecondary)
                    .contentTransition(.numericText(value: row.principal))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: row.principal)
            }
            .appNumber(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private var heroPrimary: Color {
        ReturnsSourceChartStyle.primary(for: colorScheme)
    }

    private var heroSecondary: Color {
        ReturnsSourceChartStyle.secondary(for: colorScheme)
    }

    private func plot(stack: HoldingContributionStack, window: HoldingContributionStack.Window,
                      visible: [Int], top: Double) -> some View {
        // Painted from the top of the stack down: each band's area reaches
        // the axis and the next one paints over its lower part, leaving the
        // band between them. The principal line goes on last, so where the
        // principal band has been eaten into, the line still shows the sum.
        var series: [StandardLineChartSeries] = []
        for (position, band) in visible.enumerated().reversed() {
            let color = Self.fillColor(for: stack.bands[band].kind, scheme: colorScheme)
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
                areaFill: stack.bands[band].kind == .others ? .white : color,
                areaFillEndColor: Self.fillEndColor(for: stack.bands[band].kind),
                areaBaseline: 0,
                areaStripeColor: stack.bands[band].kind == .others
                    ? ReturnsSourceChartStyle.stripeColor : nil,
                areaStripeSpacing: 35.5,
                areaStripeWidth: 13,
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
        .padding(.leading, ReturnsSourceChartStyle.inset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    /// Every row turns its band on and off. A holding turned off leaves the
    /// plot and the next one by gain takes its band; it waits, dimmed, at
    /// the foot of the list to be turned back on.
    private func legend(stack: HoldingContributionStack, row: HoldingContributionStack.Row) -> some View {
        VStack(spacing: 0) {
            // Top of the stack first, as the eye reads the chart.
            ForEach(Array(stack.bands.indices.reversed()), id: \.self) { band in
                let item = stack.bands[band]
                let isOn = isShown(item.kind)
                Button { toggle(item) } label: {
                    legendRow(rank: stack.rank(for: item), maximumRank: stack.holdingRanks.count,
                              swatch: Self.color(for: item.kind, scheme: colorScheme), isOn: isOn,
                              isOtherGains: item.kind == .others,
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
                    legendRow(rank: stack.holdingRanks[holding.ticker], maximumRank: stack.holdingRanks.count,
                              swatch: .secondary, isOn: false,
                              title: holding.ticker, subtitle: holding.name) {
                        Text(L10n.text("已隐藏")).appText(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.text("轻点重新显示"))
            }
        }
    }

    private func legendRow<Trailing: View>(rank: Int?, maximumRank: Int,
                                           swatch: Color, isOn: Bool, isOtherGains: Bool = false,
                                           title: String, subtitle: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ReturnsSourceRankLabel(rank: rank, maximumRank: maximumRank)
            ReturnsSourceLegendSwatch(color: swatch, isOn: isOn, isOtherGains: isOtherGains)
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

    /// Figma uses saturated plot paints and softer legend swatches.
    static func fillColor(for kind: HoldingContributionStack.Band.Kind, scheme: ColorScheme) -> Color {
        if case let .holding(index) = kind {
            switch index % 6 {
            case 0: return Color(red: 0, green: 202 / 255, blue: 160 / 255)
            case 2: return Color(red: 253 / 255, green: 214 / 255, blue: 0)
            case 3: return Color(red: 0.130390, green: 0.556810, blue: 0.983229)
            default: break
            }
        }
        return color(for: kind, scheme: scheme)
    }

    /// Chart gradients are separate from the neutral "other gains" legend key.
    static func fillEndColor(for kind: HoldingContributionStack.Band.Kind) -> Color? {
        switch kind {
        case .others: nil
        case .principal: Color(red: 124 / 255, green: 212 / 255, blue: 1)
        case let .holding(index):
            switch index % 6 {
            case 0: Color(red: 0.344214, green: 0.970314, blue: 0.840135)
            case 2: Color(red: 0.979969, green: 0.933497, blue: 0.678497)
            case 3: Color(red: 124 / 255, green: 212 / 255, blue: 1)
            default: color(for: kind, scheme: .light).mix(with: .white, by: 0.38)
            }
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
/// the largest, so the largest is on top. Hidden gains are excluded; portfolio
/// totals remain available separately for the header.
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
        /// Full portfolio value for the header; hiding a chart layer does not
        /// alter the holdings or their principal.
        let total: Double
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
    /// Rank all holdings by gain before filtering visibility, so a number
    /// stays with its holding when it is hidden, restored, or promoted.
    let holdingRanks: [String: Int]
    /// Holdings the reader turned off, excluded from the gain bands and listed
    /// separately so they can be turned back on.
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
        let ranks = Dictionary(uniqueKeysWithValues: everyone.enumerated().map { ($0.element, $0.offset + 1) })
        holdingRanks = ranks
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
        let others = present.subtracting(named).subtracting(hiding)
        hidden = hiding.intersection(present).sorted {
            let left = ranks[$0] ?? Int.max, right = ranks[$1] ?? Int.max
            return left == right ? $0 < $1 : left < right
        }.map { (ticker: $0, name: names[$0] ?? $0) }

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
            let othersGain = others.reduce(0) { $0 + row.gain($1) }
            let namedLosses = named.reduce(0) { $0 + min(0, row.gain($1)) }
            let remainder = othersGain + namedLosses
            return Row(
                dateText: row.dateText,
                date: row.date,
                principal: row.cost,
                othersGain: othersGain,
                bands: [row.cost + min(0, remainder), max(0, remainder)] + namedGains,
                total: row.total
            )
        }
    }

    func rank(for band: Band) -> Int? {
        guard case .holding = band.kind else { return nil }
        return holdingRanks[band.title]
    }

    func window(for range: ChartTimeRange) -> Window {
        guard let last = rows.last?.date else { return Window(rows: []) }
        let previous = rows.dropLast().last?.date
        return Window(rows: rows.filter { range.includes($0.date, through: last, previousTradingDate: previous) })
    }
}
