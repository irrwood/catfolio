import SwiftUI

enum ReturnsSourceChartStyle {
    // Figma income-sources-screen 496:19294.
    static let incomeBackground = Color(red: 0.235, green: 0.635, blue: 0.988)
    static let incomeBackgroundEnd = Color(red: 0.663, green: 0.839, blue: 0.992)
    static let incomeBase = Color(red: 228 / 255, green: 242 / 255, blue: 1)
    static let incomeFooter = Color(red: 0, green: 128 / 255, blue: 1)
    static let inset: CGFloat = 24
    static let chartHeight: CGFloat = 312
    static let stripHeight: CGFloat = 62
    static let stripeColor = Color(red: 92 / 255, green: 187 / 255, blue: 253 / 255).opacity(0.1)

    // Preserve the loss screen's purple in both appearances.
    static let lossBackground = CatfolioPalette.lossChartBackground
    static let lossFooter = lossBackground
    static let lossBase = CatfolioPalette.lossChartBase
}

enum ReturnsSourceChartTheme {
    case income, losses

    var background: Color {
        self == .income ? ReturnsSourceChartStyle.incomeBackground : ReturnsSourceChartStyle.lossBackground
    }

    var footer: Color {
        self == .income ? ReturnsSourceChartStyle.incomeFooter : ReturnsSourceChartStyle.lossFooter
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
    @Binding var range: ChartTimeRange
    let header: Header
    let plot: Plot
    let axis: Axis
    var theme: ReturnsSourceChartTheme = .losses

    private var plotHeight: CGFloat { ReturnsSourceChartStyle.chartHeight }
    private let bottomRadius: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, ReturnsSourceChartStyle.inset)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .zIndex(1)
            plot
                .frame(height: plotHeight)
                .overlay(alignment: .topLeading) { axis }
            rangeStrip(reflecting: plot)
        }
        .background { theme.background.padding(.top, -320) }
        .compositingGroup()
        .mask(alignment: .bottom) {
            UnevenRoundedRectangle(
                cornerRadii: .init(bottomLeading: bottomRadius,
                                   bottomTrailing: bottomRadius),
                style: .continuous
            )
            .fill(Color.black)
            .padding(.top, -320)
        }
    }

    /// The range picker on a translucent strip. The design shows the chart
    /// reflected in it — the bands' colour pooling under the strip on
    /// the right — so the strip carries a mirrored, blurred copy of the chart
    /// under its tint rather than a flat fill.
    private func rangeStrip<Chart: View>(reflecting chart: Chart) -> some View {
        ChartTimeRangePicker(selection: $range, isOnTintedField: true)
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity)
            .frame(height: ReturnsSourceChartStyle.stripHeight)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    // Mirrored, so the chart's bottom edge continues into the
                    // strip; blurred until only the colour is left.
                    chart
                        .frame(height: plotHeight)
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

/// Where the portfolio's value came from, over time. The principal is the
/// band at the bottom; on top of it sit the gains, the biggest contributors
/// each as their own band and the rest together. With every gain visible,
/// the top is the day's value. How many holdings get a band is decided from the gains
/// themselves (`HoldingContributionStack.namedCount`).
///
/// Each day is today's share counts at that day's close — for a personal
/// portfolio the home chart's own method. Hidden gains leave the plot only.
struct HoldingContributionChart: View {
    var refreshRevision = 0
    var fetchHistory: (@MainActor (Bool) async throws -> HoldingValueHistory)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localCache = ReturnsSourceCache()
    @State private var previousGains: (scope: String, prepared: ReturnsSourcePreparation<HoldingContributionStack>)?
    @State private var handledRefreshRevision = 0
    @State private var retryRevision = 0
    @State private var range = ChartTimeRange.yearToDate
    @State private var selectedDate: Date?
    /// Holdings the reader turned off; the next ones by gain take their place.
    @State private var hiddenTickers: Set<String> = []
    @State private var listScrollRequest: ReturnsSourceScrollRequest?
    @State private var showsPrincipal = false
    @State private var showsOthers = true
    /// The band a right swipe on its row brought forward (its series id).
    @State private var highlightedBand: String?
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    /// On, every day is drawn with that day's own holdings, ones sold since
    /// included until their sale (`ActualHoldingHistory`). Off, it is today's
    /// holdings carried back, as it always was. Set from the bar's corner.
    @AppStorage("returns.sources.includesSold") private var includesSold = false

    private var historyKind: ReturnsSourceCache.Kind { includesSold ? .includingSold : .current }
    private var entry: ReturnsSourceCacheEntry {
        fetchHistory == nil ? model.returnsSourceEntry(kind: historyKind) : localCache.entry(scope: model.comparisonCacheScope, kind: historyKind)
    }
    private var loading: HoldingHistoryState { entry.loading }
    private var preparationConfiguration: String {
        let names = model.holdings.map { "\($0.ticker)|\($0.shortName)" }.joined(separator: ";")
        return "\(hiddenTickers.sorted())|\(names)|\(appLocale.identifier)|\(ContentLanguage.current)"
    }

    private var gains: ReturnsSourcePreparation<HoldingContributionStack> {
        entry.gains.entry(configuration: preparationConfiguration)
    }
    private var displayScope: String { "\(model.comparisonCacheScope)|\(historyKind.rawValue)" }
    private var displayedGains: ReturnsSourcePreparation<HoldingContributionStack> {
        if gains.value != nil { return gains }
        if let previousGains, previousGains.scope == displayScope { return previousGains.prepared }
        return gains
    }
    private var preparationKey: String {
        "\(model.comparisonCacheScope)|\(historyKind.rawValue)|\(loading.revision)|\(preparationConfiguration)"
    }

    var body: some View {
        let prepared = displayedGains.value.flatMap { stack -> HoldingContributionPreparedCache.Prepared? in
            guard let history = loading.history else { return nil }
            return entry.gainPlots.prepared(history: history, historyRevision: displayedGains.revision,
                                     holdings: model.holdings, hiding: hiddenTickers,
                                     locale: appLocale, language: ContentLanguage.current,
                                     range: range, showsPrincipal: showsPrincipal,
                                     showsOthers: showsOthers, highlighted: highlightedBand,
                                     scheme: colorScheme, preparedStack: stack, preparationID: displayedGains.id)
        }
        let shown = prepared.flatMap { $0.window.row(nearest: selectedDate) ?? $0.window.rows.last }

        ReturnsChartPanel(scrollRequest: listScrollRequest) {
            ReturnsSourceChartHero(range: $range, header: Group {
                if let shown { header(shown) }
                else { ReturnsSourceHeaderPlaceholder(theme: .income) }
            }, plot: Group {
                if let prepared, prepared.window.rows.count > 1 { plot(prepared: prepared) }
                else if prepared == nil && loading.errorMessage == nil {
                    ReturnsSourcePlotPlaceholder(appearanceID: "income-sources")
                } else { Color.clear }
            }, axis: Group {
                if let prepared, prepared.window.rows.count > 1 { axisLabels(top: prepared.top) }
                else { Color.clear }
            }, theme: .income)
        } rows: {
            if let prepared, let shown { legend(stack: prepared.stack, row: shown) }
            else {
                ReturnsSourceRowsPlaceholder(errorMessage: loading.errorMessage) { retryRevision &+= 1 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ReturnsSourceChartStyle.incomeBackground.ignoresSafeArea())
        .foregroundStyle(.white)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                IncludesSoldMenu(isOn: $includesSold)
                    .accessibilityIdentifier("returns.sources.includes-sold")
            }
        }
        .task(id: "\(model.comparisonCacheScope)|\(historyKind.rawValue)|\(model.portfolioChartRevision)|\(model.holdings.count)|\(refreshRevision)|\(retryRevision)") {
            let forceRefresh = refreshRevision != handledRefreshRevision
            handledRefreshRevision = refreshRevision
            let fetch = fetchHistory ?? model.returnsSourceFetch(kind: historyKind)
            await entry.load(revision: model.portfolioChartRevision, forceRefresh: forceRefresh) { cachedOnly in
                #if DEBUG
                if LaunchArguments.contains("--demo-loss-history") { return LossAnalysisChart.demoHistory() }
                #endif
                return try await fetch(cachedOnly)
            }
        }
        .task(id: preparationKey) {
            let target = entry
            guard let history = target.loading.history else { return }
            var names = history.names
            for holding in model.holdings { names[holding.ticker.uppercased()] = holding.shortName }
            let input = HoldingValueHistory(rows: history.rows, costs: history.costs, names: names)
            let hidden = hiddenTickers
            await gains.prepare(key: preparationKey) {
                HoldingContributionStack(history: input, hiding: hidden)
            }
        }
        .onChange(of: "\(gains.id)|\(gains.revision)", initial: true) { _, _ in
            if gains.value != nil { previousGains = (displayScope, gains) }
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .sensoryFeedback(.selection, trigger: "\(hiddenTickers.sorted())|\(showsPrincipal)|\(showsOthers)") { _, _ in hapticsEnabled }
    }

    /// The gain is the headline — what the holdings have made — under the
    /// day it is for.
    private func header(_ row: HoldingContributionStack.Row) -> some View {
        let gain = row.total - row.principal
        return VStack(alignment: .leading, spacing: 0) {
            Text(row.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .textCase(.uppercase)
                .appText(.footnote, weight: .medium)
                .tracking(0.7)
                .foregroundStyle(heroSecondary)
            FinancialText(DisplayFormat.money(gain, signed: gain < 0, fractionDigits: 0))
                .font(Typography.number(size: 34, weight: .semibold))
                .foregroundStyle(heroPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            // As on the home page: the digits roll to the new figure as the
            // reader moves along the chart or changes the range.
            .contentTransition(.numericText(value: gain))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: gain)
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
                    FinancialText(DisplayFormat.compact($0, precision: .whole)).appNumber(.caption)
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

    /// Visibility never changes the financial ranking. The list scrolls a
    /// newly hidden source beneath the chart while its row keeps its place.
    private func legend(stack: HoldingContributionStack, row: HoldingContributionStack.Row) -> some View {
        let items = stack.legendItems
        return VStack(spacing: 12) {
            ForEach(items) { entry in
                let item = entry.band
                let id = Self.seriesID(item)
                let isOn = entry.index != nil && isShown(item.kind)
                let color = entry.index.map { band in
                    Self.incomeDisplayColor(for: item.kind, scheme: colorScheme,
                                                    isHighlighted: highlightedBand == id,
                                                    isFaded: highlightedBand != nil && highlightedBand != id,
                                                    rankFromTop: stack.bands.count - 1 - band)
                } ?? Color.secondary
                ReturnsSwipeRow(
                    color: color, isHighlighted: highlightedBand == id, canRemove: isOn,
                    removeTitle: L10n.text("隐藏此项"), removeIcon: "eye.slash", removeSlidesOut: false,
                    onHighlight: {
                        if entry.index == nil { show(item.title, highlighting: true) }
                        else { highlight(item) }
                    }, onRemove: { toggle(item) }
                ) {
                    Button {
                        if entry.index == nil { show(item.title, highlighting: false) }
                        else { toggle(item) }
                    } label: {
                        ReturnsSourceListRow(rank: stack.rank(for: item), color: color,
                                             title: item.title, subtitle: item.subtitle, isOn: isOn,
                                             logo: logoHolding(for: item), isStriped: false, isOnTintedField: true,
                                             isHighlighted: highlightedBand == id) {
                            if let band = entry.index {
                                legendAmount(item.kind, row: row, band: band)
                            } else {
                                Text(L10n.text("已隐藏")).appText(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("income.source.\(id)")
                }
                .returnsSourceScrollRow(id: id)
                .returnsDimmed(entry.index == nil && highlightedBand != nil, ground: .black)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityHint(L10n.text(isOn ? "轻点切换显示或隐藏" : "轻点重新显示"))
                .accessibilityAction(named: highlightedBand == id ? L10n.text("取消高亮") : L10n.text("高亮曲线")) {
                    if entry.index == nil { show(item.title, highlighting: true) }
                    else { highlight(item) }
                }
            }
        }
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
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
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
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            if isShown(band.kind) { listScrollRequest = ReturnsSourceScrollRequest(id: band.id) }
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
            FinancialText(DisplayFormat.money(amount, fractionDigits: 0)).appNumber(.callout)
        } else {
            FinancialText(DisplayFormat.money(amount, signed: true, fractionDigits: 0), isDirectional: true)
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
                           CatfolioPalette.coral200, CatfolioPalette.green200,
                           Color(red: 0.776, green: 0.616, blue: 0.976)]   // #C69DF9
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
        let preparationID: UUID?
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
                  scheme: ColorScheme, preparedStack: HoldingContributionStack? = nil, preparationID: UUID? = nil) -> Prepared {
        // Names can change without a history refresh, for example after an
        // account edit. Compare the source fields rather than resolving the
        // display catalog on every selection tick.
        let names = holdings.map {
            HoldingName(ticker: $0.ticker.uppercased(), displayName: $0.displayName,
                        hasPublicDisclosure: $0.publicDisclosure != nil,
                        underlyingTicker: $0.publicDisclosure?.underlyingTicker)
        }
        let nextStackKey = StackKey(historyRevision: historyRevision, preparationID: preparationID, names: names,
                                    hiding: hiding, localeIdentifier: locale.identifier,
                                    language: language)
        if stackKey != nextStackKey || cachedStack == nil {
            cachedStack = preparedStack ?? HoldingContributionStack(history: history, holdings: holdings, hiding: hiding)
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
struct HoldingContributionStack: Sendable {
    struct LegendItem: Identifiable {
        let band: Band
        /// A hidden holding keeps its row but has no chart layer.
        let index: Int?
        var id: String { band.id }
    }

    struct Band: Identifiable, Sendable {
        enum Kind: Equatable, Sendable {
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

    struct Row: Sendable {
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

    /// The seven largest gains get their own band; the rest are the others.
    static let maximumNamed = 7

    let bands: [Band]
    let rows: [Row]
    /// Rank all holdings by gain before filtering visibility, so a number
    /// stays with its holding when it is hidden, restored, or promoted.
    let holdingRanks: [String: Int]
    /// Holdings the reader turned off, excluded from the gain bands and listed
    /// separately so they can be turned back on.
    let hidden: [(ticker: String, name: String)]

    /// Hidden holdings keep their financial rank and identity in the list.
    var legendItems: [LegendItem] {
        let visible = bands.enumerated().map { LegendItem(band: $0.element, index: $0.offset) }
        let inactive = hidden.map {
            LegendItem(band: Band(kind: .holding(colour: 0), title: $0.ticker, subtitle: $0.name), index: nil)
        }
        func rank(_ item: LegendItem) -> Int {
            switch item.band.kind {
            case .holding: holdingRanks[item.band.title] ?? Int.max - 2
            case .others: Int.max - 1
            case .principal: Int.max
            }
        }
        return (visible + inactive).sorted { rank($0) < rank($1) }
    }

    /// How many of the gains, largest first, get their own band: every
    /// positive one, up to `maximumNamed`.
    static func namedCount(_ gains: [Double]) -> Int {
        min(maximumNamed, gains.filter { $0 > 0 }.count)
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
