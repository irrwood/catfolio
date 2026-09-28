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
    // Figma income-sources-screen 496:19294.
    static let incomeBackground = Color(red: 0.235, green: 0.635, blue: 0.988)
    static let incomeBackgroundEnd = Color(red: 0.663, green: 0.839, blue: 0.992)
    static let incomeBase = Color(red: 228 / 255, green: 242 / 255, blue: 1)
    static let incomeFooter = Color(red: 0, green: 128 / 255, blue: 1)
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

    /// The hero's field paint (Figma), behind the plot.
    static func field(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.360386, green: 0.194594, blue: 0.834078)
            : Color(red: 238 / 255, green: 248 / 255, blue: 254 / 255)
    }

    /// A band set back while another is highlighted. The bands are stacked
    /// as overlapping cumulative areas, so a see-through band would show
    /// the ones beneath it; each is instead mixed most of the way into the
    /// field and stays opaque.
    static func faded(_ color: Color, scheme: ColorScheme) -> Color {
        color.mix(with: field(for: scheme), by: 0.75)
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
    var isIncome = false

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
                if !isIncome {
                    plot
                    .frame(height: ReturnsSourceChartStyle.chartHeight)
                    .scaleEffect(y: 454 / 280, anchor: .bottom)
                    .blur(radius: 35)
                    .opacity(colorScheme == .dark ? 0.2 : 0.5)
                    .blendMode(colorScheme == .dark ? .plusLighter : .lighten)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
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
            (isIncome ? ReturnsSourceChartStyle.incomeBackground : ReturnsSourceChartStyle.field(for: colorScheme))
                .padding(.top, -320)
            if isIncome {
                // The supplied rotated gradient runs vertically over 506pt,
                // ending at the plot baseline; the range strip keeps its tint.
                LinearGradient(colors: [ReturnsSourceChartStyle.incomeBackground,
                                        ReturnsSourceChartStyle.incomeBackgroundEnd],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 506)
                    .padding(.bottom, ReturnsSourceChartStyle.stripHeight)
            }
            if !isIncome {
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
            .environment(\.colorScheme, isIncome ? .dark : colorScheme)
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
    @State private var handledRefreshRevision = 0
    @State private var retryRevision = 0
    @State private var range = ChartTimeRange.yearToDate
    @State private var incomeHeroHeight: CGFloat = 0
    @State private var selectedDate: Date?
    /// Holdings the reader turned off; the next ones by gain take their place.
    @State private var hiddenTickers: Set<String> = []
    @State private var showsPrincipal = false
    @State private var showsOthers = true
    /// The band a right swipe on its row brought forward (its series id).
    @State private var highlightedBand: String?
    @State private var preparedCache = HoldingContributionPreparedCache()
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    var body: some View {
        let prepared = loading.history.map {
            preparedCache.prepared(history: $0, historyRevision: loading.revision,
                                   holdings: model.holdings, hiding: hiddenTickers,
                                   locale: appLocale, language: ContentLanguage.current,
                                   range: range, showsPrincipal: showsPrincipal,
                                   showsOthers: showsOthers, highlighted: highlightedBand,
                                   scheme: colorScheme)
        }

        VStack(alignment: .leading, spacing: 18) {
            if let prepared, prepared.window.rows.count > 1 {
                let shown = prepared.window.row(nearest: selectedDate) ?? prepared.window.rows.last!
                // Figma 357:2257 / 362:14796: the figures, the chart and the
                // range strip share one tinted field that runs to all three
                // screen edges; the holdings list sits on the page's own
                // surface below it.
                let chart = plot(prepared: prepared)
                ReturnsSourceChartHero(range: $range, header: header(shown), plot: chart,
                                       axis: axisLabels(top: prepared.top), isIncome: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { incomeHeroHeight = $0 }
                legend(stack: prepared.stack, row: shown)
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
        .background {
            GeometryReader { geometry in
                let start = max(0, incomeHeroHeight - ReturnsSourceChartStyle.stripHeight)
                VStack(spacing: 0) {
                    Color.clear.frame(height: start)
                    LinearGradient(colors: [.black, ReturnsSourceChartStyle.incomeFooter],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 402)
                    ReturnsSourceChartStyle.incomeFooter
                        .frame(height: max(0, geometry.size.height - start - 402))
                }
            }
        }
        .foregroundStyle(.white)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: "\(model.portfolioChartRevision)|\(model.holdings.count)|\(refreshRevision)|\(retryRevision)") {
            let forceRefresh = refreshRevision != handledRefreshRevision
            handledRefreshRevision = refreshRevision
            await loading.load(forceRefresh: forceRefresh) { cachedOnly in
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
        .white
    }

    private var heroSecondary: Color {
        .white
    }

    private func plot(prepared: HoldingContributionPreparedCache.Prepared) -> some View {
        return StandardLineChart(
            series: prepared.series,
            interactionDates: prepared.interactionDates,
            domain: 0...max(prepared.top, 1),
            yTicks: prepared.yTicks,
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
            selectionSeriesIDs: prepared.selectionSeriesIDs,
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
    static func seriesID(_ band: HoldingContributionStack.Band) -> String { band.id }

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
        .foregroundStyle(Color.white.opacity(0.5))
        .padding(.leading, ReturnsSourceChartStyle.inset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    /// The comparison page's list: tap a row to turn its band on and off,
    /// swipe right to highlight it, swipe left to hide it. A holding turned
    /// off leaves the plot and the next one by gain takes its band; it
    /// waits, dimmed, at the foot of the list to be turned back on.
    private func legend(stack: HoldingContributionStack, row: HoldingContributionStack.Row) -> some View {
        VStack(spacing: 12) {
            // Top of the stack first, as the eye reads the chart.
            ForEach(Array(stack.bands.enumerated().reversed()), id: \.element.id) { band, item in
                let id = Self.seriesID(item)
                let isOn = isShown(item.kind)
                let color = Self.incomeDisplayColor(for: item.kind, scheme: colorScheme,
                                                    isHighlighted: highlightedBand == id,
                                                    isFaded: highlightedBand != nil && highlightedBand != id,
                                                    rankFromTop: stack.bands.count - 1 - band)
                ReturnsSwipeRow(
                    color: color, isHighlighted: highlightedBand == id, canRemove: isOn,
                    removeTitle: L10n.text("隐藏此项"), removeIcon: "eye.slash", removeSlidesOut: false,
                    onHighlight: { highlight(item) }, onRemove: { toggle(item) }
                ) {
                    Button { toggle(item) } label: {
                        ReturnsSourceListRow(rank: stack.rank(for: item), color: color,
                                             title: item.title, subtitle: item.subtitle, isOn: isOn,
                                             logo: logoHolding(for: item), isStriped: false, isOnBlueField: true,
                                             isHighlighted: highlightedBand == id) {
                            legendAmount(item.kind, row: row, band: band)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityHint(L10n.text("轻点切换显示或隐藏"))
                .accessibilityAction(named: highlightedBand == id ? L10n.text("取消高亮") : L10n.text("高亮曲线")) {
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
                                             logo: logoHolding(ticker: holding.ticker), isOnBlueField: true) {
                            Text(L10n.text("已隐藏")).appText(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .returnsDimmed(highlightedBand != nil, ground: .black)
                .accessibilityHint(L10n.text("轻点重新显示"))
            }
        }
        // Rapid hide/restore must not interpolate text and row positions from
        // an interrupted reorder. The chart owns its separate data animation.
        .animation(nil, value: hiddenTickers)
    }

    /// A band's company logo, from its holding's logo symbol where there is
    /// one; nil for the others and the principal, which are not one company.
    private func logoHolding(for band: HoldingContributionStack.Band) -> (ticker: String, symbol: String)? {
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
            if highlighting { highlightedBand = "band-\(ticker)" }
        }
    }

    /// Again on the highlighted band clears it; a band that is off comes
    /// back on first, since a hidden band has nothing to show.
    private func highlight(_ band: HoldingContributionStack.Band) {
        let id = Self.seriesID(band)
        withAnimation(.smooth(duration: 0.25)) {
            if highlightedBand == id {
                highlightedBand = nil
                return
            }
            switch band.kind {
            case .principal: showsPrincipal = true
            case .others: showsOthers = true
            case .holding: break
            }
            highlightedBand = id
        }
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
            if isShown(band.kind), highlightedBand == Self.seriesID(band) { highlightedBand = nil }
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
                .foregroundStyle(.white)
        }
    }

    /// Flat blue layers from Figma 439:15498, ordered by contribution rank.
    static func incomeFillColor(for kind: HoldingContributionStack.Band.Kind, scheme: ColorScheme, rankFromTop: Int? = nil) -> Color {
        switch kind {
        case .principal, .others: return ReturnsSourceChartStyle.incomeBase
        case let .holding(index):
            // Six distinct shades, darkest at the top; never cycle back to dark.
            let palette = [Color(red: 0, green: 46 / 255, blue: 88 / 255),
                           Color(red: 0, green: 107 / 255, blue: 203 / 255),
                           Color(red: 66 / 255, green: 163 / 255, blue: 251 / 255),
                           Color(red: 141 / 255, green: 201 / 255, blue: 1),
                           Color(red: 172 / 255, green: 217 / 255, blue: 1),
                           Color(red: 200 / 255, green: 230 / 255, blue: 1)]
            return palette[min(max(0, rankFromTop ?? index), palette.count - 1)]
        }
    }

    /// Chart bands and legend swatches share the same paint in every state.
    static func incomeDisplayColor(for kind: HoldingContributionStack.Band.Kind,
                                   scheme: ColorScheme, isHighlighted: Bool, isFaded: Bool,
                                   rankFromTop: Int? = nil) -> Color {
        let base = incomeFillColor(for: kind, scheme: scheme, rankFromTop: rankFromTop)
        if isHighlighted { return ReturnsSourceChartStyle.incomeBase }
        if isFaded { return base.mix(with: ReturnsSourceChartStyle.incomeBackground, by: 0.75) }
        return base
    }

    // Loss analysis retains its existing multicolour palette.
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

/// Scrubbing changes only the selection. Keep the ranked stack, filtered
/// window, and sorted chart points until an input that affects them changes.
@MainActor
final class HoldingContributionPreparedCache {
    struct Prepared {
        let stack: HoldingContributionStack
        let window: HoldingContributionStack.Window
        let series: [StandardLineChartSeries]
        let interactionDates: [Date]
        let top: Double
        let yTicks: [Double]
        let selectionSeriesIDs: Set<String>
    }

    private struct HoldingName: Equatable {
        let ticker: String
        let displayName: String
        let hasPublicDisclosure: Bool
        let underlyingTicker: String?
    }

    private struct StackKey: Equatable {
        let historyRevision: Int
        let names: [HoldingName]
        let hiding: Set<String>
        let localeIdentifier: String
        let language: String
    }

    private struct PlotKey: Equatable {
        let stackGeneration: Int
        let range: ChartTimeRange
        let showsPrincipal: Bool
        let showsOthers: Bool
        let highlighted: String?
        let scheme: ColorScheme
    }

    private var stackKey: StackKey?
    private var cachedStack: HoldingContributionStack?
    private var plotKey: PlotKey?
    private var cachedPlot: Prepared?
    private var stackGeneration = 0
    private(set) var stackRebuildCount = 0
    private(set) var plotRebuildCount = 0

    func prepared(history: HoldingValueHistory, historyRevision: Int,
                  holdings: [Holding], hiding: Set<String>, locale: Locale,
                  language: String, range: ChartTimeRange,
                  showsPrincipal: Bool, showsOthers: Bool, highlighted: String? = nil,
                  scheme: ColorScheme) -> Prepared {
        // Names can change without a history refresh, for example after an
        // account edit. Compare the source fields rather than resolving the
        // display catalog on every selection tick.
        let names = holdings.map {
            HoldingName(ticker: $0.ticker.uppercased(), displayName: $0.displayName,
                        hasPublicDisclosure: $0.publicDisclosure != nil,
                        underlyingTicker: $0.publicDisclosure?.underlyingTicker)
        }
        let nextStackKey = StackKey(historyRevision: historyRevision, names: names,
                                    hiding: hiding, localeIdentifier: locale.identifier,
                                    language: language)
        if stackKey != nextStackKey || cachedStack == nil {
            cachedStack = HoldingContributionStack(history: history, holdings: holdings, hiding: hiding)
            stackKey = nextStackKey
            stackGeneration &+= 1
            stackRebuildCount &+= 1
            cachedPlot = nil
        }
        let stack = cachedStack!
        let nextPlotKey = PlotKey(stackGeneration: stackGeneration, range: range,
                                  showsPrincipal: showsPrincipal, showsOthers: showsOthers,
                                  highlighted: highlighted, scheme: scheme)
        if plotKey == nextPlotKey, let cachedPlot { return cachedPlot }

        let window = stack.window(for: range)
        // Band indices are bottom to top. Only visible gains take part in a
        // boundary, exactly as before a band was hidden.
        let visible = stack.bands.indices.filter { index in
            switch stack.bands[index].kind {
            case .principal: showsPrincipal
            case .others: showsOthers
            case .holding: true
            }
        }
        let boundaries = window.rows.map { row in
            var cumulative = 0.0
            return visible.map { band in
                cumulative += row.bands[band]
                return cumulative
            }
        }
        let maximum = window.rows.indices.map { index in
            max(boundaries[index].last ?? 0,
                showsPrincipal ? window.rows[index].principal : 0)
        }.max() ?? 0
        let top = maximum * 1.06

        // Paint the outermost cumulative area first, then successively cover
        // its lower part. The principal outline remains the final series.
        var series: [StandardLineChartSeries] = []
        for (position, band) in visible.enumerated().reversed() {
            let kind = stack.bands[band].kind
            let id = HoldingContributionChart.seriesID(stack.bands[band])
            let color = HoldingContributionChart.incomeDisplayColor(
                for: kind, scheme: scheme,
                isHighlighted: highlighted == id,
                isFaded: highlighted != nil && highlighted != id,
                rankFromTop: stack.bands.count - 1 - band)
            series.append(StandardLineChartSeries(
                id: id,
                points: window.rows.indices.map { index in
                    let row = window.rows[index]
                    return StandardLineChartPoint(id: "\(id)|\(row.dateText)", date: row.date,
                                                  value: boundaries[index][position])
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
            ))
        }
        if showsPrincipal {
            series.append(StandardLineChartSeries(
                id: "principal",
                points: window.rows.map {
                    StandardLineChartPoint(id: "principal|\($0.dateText)", date: $0.date, value: $0.principal)
                },
                color: HoldingContributionChart.principalLine
                    .opacity(highlighted == nil || highlighted == "band-principal" ? 1 : 0.3),
                lineWidth: 1.25,
                latestPointRadius: 0,
                latestPointUsesGlass: false
            ))
        }
        let topSeries = visible.last.map { HoldingContributionChart.seriesID(stack.bands[$0]) }
        let value = Prepared(stack: stack, window: window, series: series,
                             interactionDates: window.rows.map(\.date), top: top,
                             yTicks: [top, top / 2, 0],
                             selectionSeriesIDs: Set([topSeries, showsPrincipal ? "principal" : nil].compactMap { $0 }))
        plotKey = nextPlotKey
        cachedPlot = value
        plotRebuildCount &+= 1
        return value
    }
}

/// The history cut into the chart's bands, bottom to top: the principal, the
/// others' gain, then the named holdings' gains from the smallest of them to
/// the largest, so the largest is on top. Hidden gains are excluded; portfolio
/// totals remain available separately for the header.
struct HoldingContributionStack {
    struct Band: Identifiable {
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

        /// Identity follows the holding, never its current position or colour.
        var id: String {
            switch kind {
            case .principal: "band-principal"
            case .others: "band-others"
            case .holding: "band-\(title)"
            }
        }
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
        private let firstRowByDate: [Date: Int]

        init(rows: [Row]) {
            self.rows = rows
            var first: [Date: Int] = [:]
            for (index, row) in rows.enumerated() where first[row.date] == nil {
                first[row.date] = index
            }
            firstRowByDate = first
        }

        func row(nearest date: Date?) -> Row? {
            guard let date else { return nil }
            // Chart selection comes from interactionDates, so this is the
            // usual path while the reader drags. Keep the prior nearest-row
            // behavior for an arbitrary date between samples.
            if let index = firstRowByDate[date] { return rows[index] }
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
