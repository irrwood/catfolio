import SwiftUI

/// The underwater analysis, drawn the way the gain-sources chart is: edge to
/// edge, one band per holding that matters, the rest together.
///
/// For the whole portfolio the line is how far it sits below its high, and
/// the bands under it are who pulled it there. For one holding the area is
/// its own fall from its high, with the portfolio's line beside it.
struct UnderwaterAnalysisChart: View {
    enum Mode: Hashable { case portfolio, holding }
    var refreshRevision = 0

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var appLocale
    @Environment(\.scrollChartPageToTop) private var scrollToTop
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var loading = HoldingHistoryState()
    @State private var retryRevision = 0
    @State private var stack: UnderwaterStack?
    @State private var range = ChartTimeRange.oneYear
    @State private var mode = Mode.portfolio
    @State private var focus: String?
    @State private var selectedDate: Date?
    @State private var showsAllHoldings = false
    @State private var detailHolding: Holding?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(L10n.text("分析对象"), selection: $mode) {
                Text(L10n.text("整体")).tag(Mode.portfolio)
                Text(L10n.text("个股")).tag(Mode.holding)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)

            if let stack, stack.rows.count > 1 {
                switch mode {
                case .portfolio: portfolio(stack)
                case .holding: holding(stack)
                }
            } else if let errorMessage = loading.errorMessage {
                StandardLineChartPlaceholder(title: L10n.text("暂时无法绘制"), message: errorMessage, isLoading: false)
                    .frame(height: 280)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                Button(L10n.text("重试")) { retryRevision &+= 1 }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            } else if loading.history != nil {
                StandardLineChartPlaceholder(title: L10n.text("历史数据不足"),
                                             message: L10n.text("该时间范围内没有足够的市值记录。"), isLoading: false)
                    .frame(height: 280)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            } else {
                StandardLineChartPlaceholder(title: L10n.text("正在准备历史数据"),
                                             message: L10n.text("水下分析"), isLoading: true,
                                             lineWidths: mode == .portfolio ? [1, 1, 2.5] : [2, 1.5],
                                             appearanceID: "underwater-\(mode)")
                    .frame(height: 280)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            }
        }
        // The holdings count as well: opened before the portfolio has
        // loaded, the page tries again once it has.
        .task(id: "\(model.portfolioChartRevision)|\(model.holdings.count)|\(refreshRevision)|\(retryRevision)") {
            await loading.load { cachedOnly in try await model.fixedShareHistory(cachedOnly: cachedOnly) }
        }
        .onChange(of: loading.revision) { _, _ in rebuild() }
        .onChange(of: range) { _, _ in
            selectedDate = nil
            rebuild()
        }
        .onChange(of: mode) { _, _ in selectedDate = nil }
        .onChange(of: focus) { _, _ in selectedDate = nil }
        .sensoryFeedback(.selection, trigger: "\(mode)|\(focus ?? "")") { _, _ in hapticsEnabled }
        .sheet(item: $detailHolding) { holding in
            HoldingDetailView(holding: holding, onClose: { detailHolding = nil })
                .environment(model)
                .securityDetailSheet()
        }
    }

    // MARK: Portfolio

    @ViewBuilder
    private func portfolio(_ stack: UnderwaterStack) -> some View {
        let shown = stack.row(nearest: selectedDate) ?? stack.rows.last!
        let bottom = Self.bottom(stack.rows.map { min($0.gross, $0.drawdown) })
        portfolioHeader(stack, row: shown)
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
        portfolioPlot(stack, bottom: bottom)
            .frame(height: 280)
            .overlay(alignment: .topLeading) { axisLabels(bottom: bottom) }
        ChartTimeRangePicker(selection: $range)
            .frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 0) {
            statistics(stack.total)
                .padding(.bottom, 20)
            sectionTitle(L10n.text("拖累来源"), detail: shown.date.formatted(.dateTime.month(.abbreviated).day()))
            portfolioLegend(stack, row: shown)
            allHoldings(stack, row: shown)
                .padding(.top, 24)
            Text(L10n.text("按当前持仓的股数回推每天的市值，从这段时间里的最高点算回落。组合回落多少，正好等于每只持仓从那天高点以来的涨跌之和，所以每一层就是这只持仓拖了多少。拖累最大的几只各占一层（直到下一只不到全部拖累的 6%，最多 6 只）；有持仓上涨时会抵消一部分，组合的线会高于色块。轻点任意持仓，看它自己的水下曲线。"))
                .appText(.micro, weight: .regular)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
        .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
    }

    private func portfolioHeader(_ stack: UnderwaterStack, row: UnderwaterStack.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dateLine(date: row.date, peakText: row.peakDateText, underwater: row.drawdown < 0))
                .appText(.caption, weight: .medium)
                .foregroundStyle(.secondary)
            Text(Self.percent(row.drawdown))
                .appNumber(.title, weight: .semibold)
                .foregroundStyle(row.drawdown < 0 ? CatfolioTheme.loss(for: colorScheme) : .primary)
                .contentTransition(.numericText(value: row.drawdown))
            Text(row.drawdown < 0
                 ? L10n.text("比高点少 \(DisplayFormat.money(row.peak - row.value, fractionDigits: 0))")
                 : L10n.text("在这段时间的最高点"))
                .appNumber(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func portfolioPlot(_ stack: UnderwaterStack, bottom: Double) -> some View {
        // Deepest level first: each band's area reaches the axis and the
        // next paints over it, leaving the band between. The portfolio's
        // own line goes on last.
        var series: [StandardLineChartSeries] = []
        for index in stack.bands.indices.reversed() {
            let band = stack.bands[index]
            let color = Self.color(for: band, scheme: colorScheme)
            let id = band.ticker.map { "band-\($0)" } ?? "band-others"
            series.append(StandardLineChartSeries(
                id: id,
                points: stack.rows.map { row in
                    StandardLineChartPoint(id: "\(id)|\(row.dateText)", date: row.date,
                                           value: row.bands[...index].reduce(0, +) * 100)
                },
                color: color,
                lineWidth: 1,
                areaFill: color,
                areaBaseline: 0,
                areaStripeColor: band.ticker == nil ? Color.white.opacity(0.07) : nil,
                areaStripeSpacing: 10,
                latestPointRadius: 0,
                latestPointUsesGlass: false
            ))
        }
        series.append(StandardLineChartSeries(
            id: "portfolio",
            points: stack.rows.map { StandardLineChartPoint(id: "portfolio|\($0.dateText)", date: $0.date, value: $0.drawdown * 100) },
            color: .primary,
            lineWidth: 2.5,
            latestPointRadius: 4,
            latestPointUsesGlass: false
        ))
        return chart(series: series, dates: stack.rows.map(\.date), bottom: bottom, selectionIDs: ["portfolio"])
            .accessibilityLabel(L10n.text("组合水下曲线与拖累来源，长按后拖动查看单日"))
    }

    /// Bands deepest first, the others after them, then whatever rising
    /// holdings took back.
    private func portfolioLegend(_ stack: UnderwaterStack, row: UnderwaterStack.Row) -> some View {
        VStack(spacing: 0) {
            legendRow(swatch: .primary, isLine: true, title: L10n.text("组合回撤"), subtitle: L10n.text("从高点回落了多少")) {
                amount(row.drawdown, peak: row.peak)
            }
            Divider()
            ForEach(Array(stack.bands.indices.reversed()), id: \.self) { index in
                let band = stack.bands[index]
                if let ticker = band.ticker {
                    Button { analyze(ticker) } label: {
                        legendRow(swatch: Self.color(for: band, scheme: colorScheme), title: band.title, subtitle: band.subtitle, disclosure: true) {
                            amount(row.parts[ticker] ?? 0, peak: row.peak)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.text("轻点查看这只持仓的水下曲线"))
                } else {
                    legendRow(swatch: Self.color(for: band, scheme: colorScheme), title: band.title, subtitle: band.subtitle) {
                        amount(stack.othersPart(row), peak: row.peak)
                    }
                }
                Divider()
            }
            let offset = row.drawdown - row.gross
            if offset > 0.00005 {
                legendRow(swatch: CatfolioTheme.gain(for: colorScheme), title: L10n.text("上涨持仓抵消"),
                          subtitle: L10n.text("线高出色块的部分")) {
                    amount(offset, peak: row.peak)
                }
                Divider()
            }
        }
    }

    /// Every holding, deepest pull first on the day shown: the way into
    /// any one of them.
    private func allHoldings(_ stack: UnderwaterStack, row: UnderwaterStack.Row) -> some View {
        let ranked = row.parts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
        let visible = showsAllHoldings ? ranked : Array(ranked.prefix(8))
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle(L10n.text("每只持仓"), detail: L10n.text("拖累 · 自身最大回撤"))
            ForEach(visible, id: \.key) { ticker, part in
                Button { analyze(ticker) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ticker).appText(.callout, weight: .semibold).lineLimit(1)
                            Text(stack.names[ticker] ?? ticker).appText(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Self.points(part))
                                .appNumber(.callout)
                                .foregroundStyle(part < 0 ? CatfolioTheme.loss(for: colorScheme) : part > 0 ? CatfolioTheme.gain(for: colorScheme) : .secondary)
                            Text(Self.percent(stack.holdings[ticker]?.maxDrawdown ?? 0))
                                .appNumber(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            if ranked.count > 8 {
                Button(showsAllHoldings ? L10n.text("收起") : L10n.text("显示全部 \(ranked.count) 只")) {
                    withAnimation(.snappy) { showsAllHoldings.toggle() }
                }
                .appText(.footnote, weight: .semibold)
                .padding(.top, 12)
            }
        }
    }

    // MARK: One holding

    @ViewBuilder
    private func holding(_ stack: UnderwaterStack) -> some View {
        let tickers = holdingOrder(stack)
        let ticker = focus.flatMap { stack.holdings[$0] != nil ? $0 : nil } ?? tickers.first
        holdingChips(tickers, selected: ticker)
        if let ticker, let series = stack.holdings[ticker], series.points.count > 1 {
            let point = series.points.first { $0.dateText == stack.row(nearest: selectedDate)?.dateText } ?? series.points.last!
            let bottom = Self.bottom(series.points.map(\.drawdown) + stack.rows.map(\.drawdown))
            holdingHeader(ticker: ticker, name: stack.names[ticker] ?? ticker, point: point)
                .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            holdingPlot(series: series, stack: stack, bottom: bottom)
                .frame(height: 280)
                .overlay(alignment: .topLeading) { axisLabels(bottom: bottom) }
            ChartTimeRangePicker(selection: $range)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                statistics(series, recoverGain: true)
                    .padding(.bottom, 20)
                VStack(spacing: 0) {
                    legendRow(swatch: CatfolioTheme.loss(for: colorScheme), title: ticker, subtitle: L10n.text("自己从高点回落了多少")) {
                        Text(Self.percent(point.drawdown)).appNumber(.callout)
                    }
                    Divider()
                    let portfolio = stack.rows.first { $0.dateText == point.dateText }
                    legendRow(swatch: .secondary, isLine: true, title: L10n.text("组合回撤"), subtitle: L10n.text("同一天，整个组合")) {
                        Text(Self.percent(portfolio?.drawdown ?? 0)).appNumber(.callout)
                    }
                    Divider()
                    if let deepest = stack.total.trough, deepest.drawdown < 0,
                       let row = stack.rows.first(where: { $0.dateText == deepest.dateText }) {
                        legendRow(swatch: .clear, title: L10n.text("组合最深时的拖累"),
                                  subtitle: deepest.date.formatted(.dateTime.year().month(.abbreviated).day())) {
                            amount(row.parts[ticker] ?? 0, peak: row.peak)
                        }
                        Divider()
                    }
                }
                if let held = model.holdings.first(where: { $0.ticker.uppercased() == ticker }) {
                    Button { detailHolding = held } label: {
                        Label(L10n.text("打开个股页"), systemImage: "arrow.up.right.square")
                            .appText(.callout, weight: .semibold)
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 16)
                }
                Text(L10n.text("按当前股数回推，所以个股的水下曲线就是它自己的价格离这段时间高点有多远；灰线是同一天整个组合的回撤。"))
                    .appText(.micro, weight: .regular)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
        }
    }

    /// Largest holdings first, as the home list orders them.
    private func holdingOrder(_ stack: UnderwaterStack) -> [String] {
        stack.holdings.keys.sorted {
            let a = stack.holdings[$0]?.points.last?.value ?? 0, b = stack.holdings[$1]?.points.last?.value ?? 0
            return a == b ? $0 < $1 : a > b
        }
    }

    private func holdingChips(_ tickers: [String], selected: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(tickers, id: \.self) { ticker in
                        Button { withAnimation(.snappy) { focus = ticker } } label: {
                            Text(ticker)
                                .appText(.footnote, weight: .semibold)
                                .foregroundStyle(ticker == selected ? Color(uiColor: .systemBackground) : .primary)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Capsule().fill(ticker == selected ? Color.primary : Color(uiColor: .tertiarySystemFill)))
                        }
                        .buttonStyle(.plain)
                        .id(ticker)
                        .accessibilityAddTraits(ticker == selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            }
            .scrollIndicators(.hidden)
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            .onChange(of: selected) { _, ticker in
                if let ticker { withAnimation(.snappy) { proxy.scrollTo(ticker, anchor: .center) } }
            }
        }
    }

    private func holdingHeader(ticker: String, name: String, point: UnderwaterSeries.Point) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dateLine(date: point.date, peakText: point.peakDateText, underwater: point.drawdown < 0))
                .appText(.caption, weight: .medium)
                .foregroundStyle(.secondary)
            Text(Self.percent(point.drawdown))
                .appNumber(.title, weight: .semibold)
                .foregroundStyle(point.drawdown < 0 ? CatfolioTheme.loss(for: colorScheme) : .primary)
                .contentTransition(.numericText(value: point.drawdown))
            Text(point.drawdown < 0
                 ? L10n.text("\(name) · 回到高点还要涨 \(DisplayFormat.percent(UnderwaterSeries.gainToRecover(point.drawdown) * 100))")
                 : L10n.text("\(name) · 在这段时间的最高点"))
                .appNumber(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func holdingPlot(series: UnderwaterSeries, stack: UnderwaterStack, bottom: Double) -> some View {
        let loss = CatfolioTheme.loss(for: colorScheme)
        return chart(
            series: [
                StandardLineChartSeries(
                    id: "holding",
                    points: series.points.map { StandardLineChartPoint(id: "holding|\($0.dateText)", date: $0.date, value: $0.drawdown * 100) },
                    color: loss,
                    lineWidth: 2,
                    areaFill: loss.opacity(0.26),
                    areaBaseline: 0,
                    latestPointRadius: 4,
                    latestPointUsesGlass: false
                ),
                StandardLineChartSeries(
                    id: "portfolio",
                    points: stack.rows.map { StandardLineChartPoint(id: "portfolio|\($0.dateText)", date: $0.date, value: $0.drawdown * 100) },
                    color: Color.secondary,
                    lineWidth: 1.5,
                    dash: [4, 3],
                    latestPointRadius: 0,
                    latestPointUsesGlass: false
                ),
            ],
            dates: series.points.map(\.date),
            bottom: bottom,
            selectionIDs: ["holding"]
        )
        .accessibilityLabel(L10n.text("个股水下曲线，长按后拖动查看单日"))
    }

    // MARK: Shared

    private func chart(series: [StandardLineChartSeries], dates: [Date], bottom: Double, selectionIDs: Set<String>) -> some View {
        StandardLineChart(
            series: series,
            interactionDates: dates,
            domain: (bottom * 100)...0,
            yTicks: [0, bottom * 50, bottom * 100],
            axisWidth: 0,
            topInset: 4,
            bottomHeight: 0,
            leadingLineOverflow: 0,
            trailingEndpointInset: 21,
            gridOpacity: 0,
            transitionKey: "\(range.rawValue)-\(mode)-\(focus ?? "")-\(colorScheme == .light ? "light" : "dark")",
            appearanceID: "underwater-\(mode)",
            dataTransition: .viewportZoom,
            selectedDate: selectedDate,
            selectionSeriesIDs: selectionIDs,
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
    }

    /// Three figures, the way a report card reads: how deep, how long to
    /// climb out, how long under.
    private func statistics(_ series: UnderwaterSeries, recoverGain: Bool = false) -> some View {
        let trough = series.trough
        let recovery = series.recovery
        let recoveryText: String = {
            guard let trough, trough.drawdown < 0 else { return L10n.text("没有回撤") }
            guard let recovery else { return L10n.text("还没收复") }
            let days = Calendar(identifier: .gregorian).dateComponents([.day], from: trough.date, to: recovery.date).day ?? 0
            return L10n.text("\(days) 天收复")
        }()
        return HStack(alignment: .top, spacing: 10) {
            statistic(L10n.text("最大回撤"), Self.percent(series.maxDrawdown),
                      trough.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "",
                      color: series.maxDrawdown < 0 ? CatfolioTheme.loss(for: colorScheme) : .primary)
            if recoverGain, let last = series.points.last, last.drawdown < 0 {
                statistic(L10n.text("回到高点"), DisplayFormat.percent(UnderwaterSeries.gainToRecover(last.drawdown) * 100),
                          L10n.text("还要涨"), color: .primary)
            } else {
                statistic(L10n.text("从最深处"), recoveryText,
                          recovery.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "", color: .primary)
            }
            statistic(L10n.text("最长水下"), L10n.text("\(series.longestUnderwaterDays) 天"),
                      series.daysUnderwater > 0 ? L10n.text("现在已 \(series.daysUnderwater) 天") : L10n.text("现在在高点"),
                      color: .primary)
        }
    }

    private func statistic(_ title: String, _ value: String, _ detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).appText(.caption, weight: .medium).foregroundStyle(.secondary)
            Text(value).appNumber(.callout, weight: .semibold).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).appText(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).appText(.subheading, weight: .semibold)
            Spacer()
            Text(detail).appText(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func legendRow<Trailing: View>(swatch: Color, isLine: Bool = false, title: String, subtitle: String, disclosure: Bool = false,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if isLine {
                    Capsule().fill(swatch).frame(width: 14, height: 3)
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(swatch).frame(width: 12, height: 12)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appText(.callout, weight: .semibold).lineLimit(1)
                Text(subtitle).appText(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
            if disclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// A part of the drawdown, in points of the high and in money.
    private func amount(_ part: Double, peak: Double) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(Self.points(part))
                .appNumber(.callout)
                .foregroundStyle(part < 0 ? CatfolioTheme.loss(for: colorScheme) : part > 0 ? CatfolioTheme.gain(for: colorScheme) : .secondary)
            Text(DisplayFormat.money(part * peak, signed: true, fractionDigits: 0))
                .appNumber(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The middle and the floor. The top edge is always the high, and a
    /// "0%" there sat on the start of every line.
    private func axisLabels(bottom: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text(Self.percent(bottom / 2)).appNumber(.footnote)
            Spacer()
            Text(Self.percent(bottom)).appNumber(.footnote)
        }
        .foregroundStyle(Color.primary.opacity(colorScheme == .light ? 0.35 : 0.4))
        .padding(.leading, CatfolioStyle.pageHorizontalInset)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    private func dateLine(date: Date, peakText: String, underwater: Bool) -> String {
        let day = date.formatted(.dateTime.year().month(.abbreviated).day())
        guard underwater, let peak = DayDateCodec.date(from: peakText) else { return day }
        return L10n.text("\(day) · 高点在 \(peak.formatted(.dateTime.month(.abbreviated).day()))")
    }

    private func analyze(_ ticker: String) {
        withAnimation(.snappy) {
            focus = ticker
            mode = .holding
        }
        scrollToTop()
    }

    private func rebuild() {
        guard let history = loading.history else { stack = nil; return }
        let names = Dictionary(model.holdings.map { ($0.ticker.uppercased(), $0.shortName) }, uniquingKeysWith: { first, _ in first })
        stack = UnderwaterStack(history: history, range: range, names: names)
    }

    // MARK: Formatting

    /// The chart's floor: the deepest value with a little room, never flat.
    static func bottom(_ values: [Double]) -> Double {
        min(values.min() ?? 0, -0.01) * 1.08
    }

    static func percent(_ fraction: Double) -> String {
        abs(fraction) < 0.00005 ? "0%" : DisplayFormat.percent(fraction * 100)
    }

    /// Percentage points of the high, signed.
    static func points(_ fraction: Double) -> String {
        abs(fraction) < 0.00005 ? "0" : DisplayFormat.percent(fraction * 100)
    }

    static func color(for band: UnderwaterStack.Band, scheme: ColorScheme) -> Color {
        guard band.ticker != nil else { return scheme == .dark ? Color(white: 0.26) : Color(white: 0.62) }
        return HoldingContributionChart.color(for: .holding(colour: band.colour), scheme: scheme)
    }
}

/// Scrolls the chart page back to its top, where the picker and chart are.
struct ChartPageScrollToTop {
    let action: () -> Void
    init(_ action: @escaping () -> Void = {}) { self.action = action }
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var scrollChartPageToTop = ChartPageScrollToTop()
}
