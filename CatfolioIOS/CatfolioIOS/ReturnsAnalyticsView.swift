import SwiftUI

private typealias ReturnsAnalyticsTypography = LegacyType

enum ReturnsAnalyticsChart {
    case drawdown, valuation
}

struct ReturnsAnalyticsView: View {
    @Environment(\.locale) private var appLocale
    let response: ReturnsAnalyticsResponse
    let pendingParts: Set<ReturnsAnalyticsPart>
    let chart: ReturnsAnalyticsChart

    var body: some View {
        switch chart {
        case .drawdown:
            if pendingParts.contains(.drawdown) {
                ReturnsAnalyticsLoadingView(chart: chart)
            } else {
                DrawdownCard(series: response.drawdown)
            }
        case .valuation:
            if pendingParts.contains(.valuation) {
                ReturnsAnalyticsLoadingView(chart: chart)
            } else {
                ValuationMatrixCard(matrix: response.valuation)
                    .onAppear { ChartAppearanceHistory.record("returns-valuation") }
            }
        }
    }
}

struct ReturnsAnalyticsLoadingView: View {
    @Environment(\.locale) private var appLocale
    let chart: ReturnsAnalyticsChart

    var body: some View {
        switch chart {
        case .drawdown:
            AnalyticsLoadingCard(title: L10n.text("回撤水下曲线"), height: 210, chart: chart)
        case .valuation:
            AnalyticsLoadingCard(title: L10n.text("估值矩阵 (P/E vs 成长)"), height: 240, chart: chart)
        }
    }
}

private struct AnalyticsLoadingCard: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let height: CGFloat
    let chart: ReturnsAnalyticsChart

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(ReturnsAnalyticsTypography.medium(19, relativeTo: .headline))

            Group {
                switch chart {
                case .drawdown:
                    StandardLineChartSkeleton(topInset: 8, lineWidths: [2], appearanceID: "returns-drawdown")
                case .valuation:
                    ChartShapeSkeleton(layout: .bubbles, appearanceID: "returns-valuation")
                }
            }
            .frame(height: height)
        }
    }
}

struct ReturnsAnalyticsUnavailableView: View {
    @Environment(\.locale) private var appLocale
    var body: some View {
        ContentUnavailableView(
            L10n.text("暂无分析图表"),
            systemImage: "chart.xyaxis.line",
            description: Text(L10n.text("下拉刷新后重试。"))
        )
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

private struct DrawdownCard: View {
    @Environment(\.locale) private var appLocale
    let series: DrawdownSeries
    @State private var range = ChartTimeRange.maximum
    @State private var rows: [DrawdownPoint]
    @State private var selectedDate: Date?

    init(series: DrawdownSeries) {
        self.series = series
        _rows = State(initialValue: Self.filteredRows(series.rows, for: .maximum))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.text("回撤水下曲线"))
                    .font(ReturnsAnalyticsTypography.medium(19, relativeTo: .headline))

                Spacer(minLength: 8)

                Text(L10n.text("最大回撤 \(DisplayFormat.ratioPercent(series.maxDrawdown))"))
                    .appNumber(.label, weight: .semibold)
                    .foregroundStyle(CatfolioStyle.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if rows.count > 1 {
                if let point = selectedPoint {
                    HStack(alignment: .firstTextBaseline) {
                        Text(point.date.formatted(.dateTime.year().month(.abbreviated).day()))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(DisplayFormat.ratioPercent(point.drawdown))
                            .foregroundStyle(point.drawdown < 0 ? CatfolioStyle.blue : .secondary)
                    }
                    .appNumber(.caption)
                }

                DrawdownPlot(
                    rows: rows,
                    transitionKey: range.rawValue,
                    selectedDate: selectedDate,
                    onSelect: select,
                    onInteractionEnded: { selectedDate = nil }
                )
                .frame(height: 230)
                .accessibilityLabel(L10n.text("回撤水下曲线。\(range.rawValue)。最大回撤 \(DisplayFormat.ratioPercent(series.maxDrawdown))"))

                drawdownRangePicker
            } else {
                ContentUnavailableView(
                    L10n.text("暂无回撤数据"),
                    systemImage: "water.waves",
                    description: Text(L10n.text("至少需要两个持仓共同交易日。"))
                )
                .frame(maxWidth: .infinity, minHeight: 130)
            }
        }
        .onChange(of: range) { _, newRange in
            rows = Self.filteredRows(series.rows, for: newRange)
            selectedDate = nil
        }
    }

    private var selectedPoint: DrawdownPoint? {
        guard let selectedDate else { return rows.last }
        return Self.nearestPoint(to: selectedDate, in: rows)
    }

    private var drawdownRangePicker: some View {
        ChartTimeRangePicker(
            selection: $range
        )
        .frame(height: 44)
        .accessibilityLabel(L10n.text("回撤图表时间范围"))
    }

    private func select(_ date: Date) {
        guard selectedDate != date else { return }
        selectedDate = date
    }

    private static func filteredRows(
        _ source: [DrawdownPoint],
        for range: ChartTimeRange
    ) -> [DrawdownPoint] {
        let allRows = source.sorted { $0.date < $1.date }
        guard let endDate = allRows.last?.date else { return [] }

        let previousTradingDate = allRows.dropLast().last?.date
        let filtered = allRows.filter {
            range.includes(
                $0.date,
                through: endDate,
                previousTradingDate: previousTradingDate,
                calendar: financeCalendar
            )
        }

        return filtered.count >= 2 ? filtered : Array(allRows.suffix(2))
    }

    private static func nearestPoint(to target: Date, in rows: [DrawdownPoint]) -> DrawdownPoint? {
        guard !rows.isEmpty else { return nil }
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].date < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return rows[0] }
        guard lower < rows.count else { return rows[rows.count - 1] }
        let before = rows[lower - 1]
        let after = rows[lower]
        return abs(before.date.timeIntervalSince(target)) <= abs(after.date.timeIntervalSince(target))
            ? before
            : after
    }

    private static var financeCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

private struct DrawdownPlot: View {
    @Environment(\.locale) private var appLocale
    let rows: [DrawdownPoint]
    let transitionKey: String
    let selectedDate: Date?
    let onSelect: (Date) -> Void
    let onInteractionEnded: () -> Void

    private let axisWidth: CGFloat = 33

    var body: some View {
        let axisMinimum = minimumAxisValue
        StandardLineChart(
            series: [StandardLineChartSeries(
                id: "drawdown",
                points: rows.map {
                    StandardLineChartPoint(id: $0.id, date: $0.date, value: $0.drawdown * 100)
                },
                color: CatfolioStyle.blue,
                lineWidth: 2,
                areaFill: CatfolioStyle.blue.opacity(0.065),
                areaBaseline: 0,
                areaStripeColor: nil,
                selectionRadius: 3.5
            )],
            interactionDates: rows.map(\.date),
            domain: axisMinimum...0,
            yTicks: yTicks(for: axisMinimum),
            yAxisSide: .trailing,
            axisWidth: axisWidth,
            bottomHeight: 0,
            leadingLineOverflow: 20,
            transitionKey: transitionKey,
            appearanceID: "returns-drawdown",
            dataTransition: .viewportZoom,
            animatesInitialAppearance: true,
            selectedDate: selectedDate,
            selectionSeriesIDs: ["drawdown"],
            yAxisFont: Typography.number(.micro),
            yAxisColor: Color.secondary.opacity(0.48),
            yAxisLabel: { "\(Int($0))%" },
            xAxisLabel: { _ in "" },
            onSelect: onSelect,
            onInteractionEnded: { _ in onInteractionEnded() }
        )
    }

    private var minimumAxisValue: Double {
        let minimum = rows.map { $0.drawdown * 100 }.min() ?? 0
        let padding = max(0.6, abs(minimum) * 0.08)
        return min(-1, minimum - padding)
    }

    private func yTicks(for minimum: Double) -> [Double] {
        var ticks = [0.0]
        var tick = -10.0
        while tick > minimum {
            ticks.append(tick)
            tick -= 10
        }
        if ticks.count == 1 {
            ticks.append(minimum)
        }
        return ticks
    }

}

private struct ValuationMatrixCard: View {
    @Environment(\.locale) private var appLocale
    let matrix: ValuationMatrix
    @State private var selectedTicker: String?

    init(matrix: ValuationMatrix) {
        self.matrix = matrix
        _selectedTicker = State(
            initialValue: matrix.rows.max(by: { $0.weight < $1.weight })?.ticker
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("估值矩阵 (P/E vs 成长)"))
                    .font(ReturnsAnalyticsTypography.medium(19, relativeTo: .headline))
                Text(L10n.text("气泡大小 = 仓位权重"))
                    .font(ReturnsAnalyticsTypography.medium(12, relativeTo: .subheadline))
                    .foregroundStyle(.secondary)

                if let selectedBubble {
                    Text(selectedSummary(selectedBubble))
                        .appNumber(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.top, 3)
                        .accessibilityLabel(selectedAccessibilitySummary(selectedBubble))
                }
            }

            if matrix.rows.isEmpty {
                ContentUnavailableView(
                    L10n.text("暂无估值数据"),
                    systemImage: "chart.dots.scatter",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ValuationBubblePlot(
                    rows: matrix.rows,
                    selectedTicker: selectedTicker,
                    onSelect: { selectedTicker = $0 },
                    onInteractionEnded: { selectedTicker = defaultTicker }
                )
                .frame(height: 300)
            }
        }
    }

    private var selectedBubble: ValuationBubble? {
        guard let selectedTicker else { return nil }
        return matrix.rows.first { $0.ticker == selectedTicker }
    }

    private var defaultTicker: String? {
        matrix.rows.max(by: { $0.weight < $1.weight })?.ticker
    }

    private var emptyDescription: String {
        matrix.warnings.contains(where: { $0.contains("FMP API Key") })
            ? L10n.text("请在设置中配置 FMP API Key 后下拉刷新。")
            : L10n.text("暂无同时具备 P/E 与成长数据的持仓。")
    }

    private func selectedSummary(_ row: ValuationBubble) -> String {
        let pe = row.pe.formatted(.number.precision(.fractionLength(1)))
        let growth = DisplayFormat.percent(row.growthPercent)
        let weight = DisplayFormat.percent(row.weight * 100, signed: false)
        return L10n.text("\(row.ticker) · P/E \(pe)× · \(growthLabel(row.growthSource)) \(growth) · 仓位 \(weight)")
    }

    private func selectedAccessibilitySummary(_ row: ValuationBubble) -> String {
        let pe = row.pe.formatted(.number.precision(.fractionLength(1)))
        let growth = DisplayFormat.percent(row.growthPercent)
        let weight = DisplayFormat.percent(row.weight * 100, signed: false)
        return L10n.text("\(row.ticker)，市盈率 \(pe) 倍，\(growthLabel(row.growthSource)) \(growth)，仓位 \(weight)")
    }

    private func growthLabel(_ source: String) -> String {
        source.localizedCaseInsensitiveContains("EPS") ? L10n.text("EPS同比") : L10n.text("营收同比")
    }
}

private struct ValuationBubblePlot: View {
    @Environment(\.locale) private var appLocale
    let rows: [ValuationBubble]
    let selectedTicker: String?
    let onSelect: (String) -> Void
    let onInteractionEnded: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let domain = ValuationDomain(rows: rows)
            let plot = CGRect(
                x: 46,
                y: 44,
                width: max(1, geometry.size.width - 108),
                height: max(1, geometry.size.height - 106)
            )
            let colors = sectorColors

            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: true) { context, _ in
                    drawGrid(context: &context, plot: plot, domain: domain)
                    drawBubbles(context: &context, plot: plot, domain: domain, colors: colors)
                }

                Canvas { context, _ in
                    guard let selectedTicker,
                          let selected = rows.first(where: { $0.ticker == selectedTicker }) else { return }
                    drawSelection(selected, context: &context, plot: plot, domain: domain)
                }
                .allowsHitTesting(false)

                ChartPointInteractionOverlay(
                    onLocationChanged: { location in
                        guard plot.insetBy(dx: -22, dy: -22).contains(location),
                              let nearest = nearestBubble(to: location, plot: plot, domain: domain) else { return }
                        onSelect(nearest.ticker)
                    },
                    onInteractionEnded: onInteractionEnded
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("估值矩阵，气泡大小表示仓位权重"))
            .accessibilityValue(L10n.text("\(rows.count) 个持仓有可用估值与成长数据"))
        }
    }

    private var maximumWeight: Double {
        max(rows.map(\.weight).max() ?? 0, 0.0001)
    }

    private var sectorColors: [String: Color] {
        var result: [String: Color] = [:]
        for row in rows {
            let sector = normalizedSector(row.sector)
            if result[sector] == nil {
                result[sector] = Self.palette[result.count % Self.palette.count]
            }
        }
        return result
    }

    private func drawGrid(
        context: inout GraphicsContext,
        plot: CGRect,
        domain: ValuationDomain
    ) {
        for value in tickValues(from: domain.xMinimum, through: domain.xMaximum, by: domain.xInterval) {
            let x = x(for: value, plot: plot, domain: domain)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(Color.secondary.opacity(0.10)), lineWidth: 0.7)
            let suffix = abs(value - domain.xMaximum) < 0.001 ? "× P/E" : "×"
            context.draw(
                Text("\(Int(value))\(suffix)")
                    .font(Typography.number(.micro))
                    .foregroundStyle(Color.secondary.opacity(0.62)),
                at: CGPoint(x: x, y: plot.maxY + 10),
                anchor: .top
            )
        }

        for value in tickValues(from: domain.yMinimum, through: domain.yMaximum, by: domain.yInterval) {
            let y = y(for: value, plot: plot, domain: domain)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(Color.secondary.opacity(0.10)), lineWidth: 0.7)
            context.draw(
                Text("\(Int(value))%")
                    .font(Typography.number(.micro))
                    .foregroundStyle(Color.secondary.opacity(0.62)),
                at: CGPoint(x: plot.minX - 8, y: y),
                anchor: .trailing
            )
        }
    }

    private func drawBubbles(
        context: inout GraphicsContext,
        plot: CGRect,
        domain: ValuationDomain,
        colors: [String: Color]
    ) {
        for row in rows.sorted(by: { $0.weight > $1.weight }) {
            let diameter = bubbleDiameter(for: row)
            let center = bubbleCenter(for: row, plot: plot, domain: domain)
            let color = colors[normalizedSector(row.sector)] ?? .secondary
            let bubble = CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(
                Path(ellipseIn: bubble),
                with: .color(color.opacity(colorScheme == .dark ? 0.22 : 0.14))
            )
            context.stroke(Path(ellipseIn: bubble), with: .color(color.opacity(0.92)), lineWidth: 2)
            context.draw(
                Text(row.ticker)
                    .font(ReturnsAnalyticsTypography.semibold(11, relativeTo: .caption))
                    .foregroundStyle(color),
                at: CGPoint(x: center.x, y: center.y - diameter / 2 - 4),
                anchor: .bottom
            )
        }
    }

    private func drawSelection(
        _ row: ValuationBubble,
        context: inout GraphicsContext,
        plot: CGRect,
        domain: ValuationDomain
    ) {
        let diameter = bubbleDiameter(for: row)
        let center = bubbleCenter(for: row, plot: plot, domain: domain)
        let selectionDiameter = diameter + 7
        let selection = CGRect(
            x: center.x - selectionDiameter / 2,
            y: center.y - selectionDiameter / 2,
            width: selectionDiameter,
            height: selectionDiameter
        )
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: CatfolioStyle.blue.opacity(0.46), radius: 6))
            layer.stroke(
                Path(ellipseIn: selection),
                with: .color(CatfolioStyle.blue),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func nearestBubble(
        to location: CGPoint,
        plot: CGRect,
        domain: ValuationDomain
    ) -> ValuationBubble? {
        rows
            .filter { row in
                let tolerance = bubbleDiameter(for: row) / 2 + 14
                return squaredDistance(
                    from: location,
                    to: bubbleCenter(for: row, plot: plot, domain: domain)
                ) <= tolerance * tolerance
            }
            .min { left, right in
                squaredDistance(
                    from: location,
                    to: bubbleCenter(for: left, plot: plot, domain: domain)
                ) < squaredDistance(
                    from: location,
                    to: bubbleCenter(for: right, plot: plot, domain: domain)
                )
            }
    }

    private func squaredDistance(from first: CGPoint, to second: CGPoint) -> CGFloat {
        let x = first.x - second.x
        let y = first.y - second.y
        return x * x + y * y
    }

    private func bubbleCenter(
        for row: ValuationBubble,
        plot: CGRect,
        domain: ValuationDomain
    ) -> CGPoint {
        CGPoint(
            x: x(for: row.pe, plot: plot, domain: domain),
            y: y(for: row.growthPercent, plot: plot, domain: domain)
        )
    }

    private func bubbleDiameter(for row: ValuationBubble) -> CGFloat {
        max(20, min(118, sqrt(max(0, row.weight) / maximumWeight) * 118))
    }

    private func x(for value: Double, plot: CGRect, domain: ValuationDomain) -> CGFloat {
        let span = max(domain.xMaximum - domain.xMinimum, 0.000_001)
        return plot.minX + plot.width * CGFloat((value - domain.xMinimum) / span)
    }

    private func y(for value: Double, plot: CGRect, domain: ValuationDomain) -> CGFloat {
        let span = max(domain.yMaximum - domain.yMinimum, 0.000_001)
        return plot.maxY - plot.height * CGFloat((value - domain.yMinimum) / span)
    }

    private func tickValues(from minimum: Double, through maximum: Double, by interval: Double) -> [Double] {
        guard interval > 0 else { return [] }
        var result: [Double] = []
        var value = minimum
        while value <= maximum + 0.001, result.count < 20 {
            result.append(value)
            value += interval
        }
        if let last = result.last, abs(last - maximum) > 0.001 {
            result.append(maximum)
        }
        return result
    }

    private func normalizedSector(_ sector: String) -> String {
        let normalized = sector.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Other" : normalized
    }

    private static let palette: [Color] = [
        Color(red: 137 / 255, green: 214 / 255, blue: 99 / 255),
        Color(red: 243 / 255, green: 109 / 255, blue: 13 / 255),
        Color(red: 112 / 255, green: 140 / 255, blue: 255 / 255),
        Color(red: 47 / 255, green: 138 / 255, blue: 62 / 255),
        Color(red: 212 / 255, green: 155 / 255, blue: 39 / 255),
        Color(red: 125 / 255, green: 104 / 255, blue: 216 / 255),
        Color(red: 26 / 255, green: 154 / 255, blue: 168 / 255),
    ]
}

private struct ValuationDomain {
    let xMinimum: Double
    let xMaximum: Double
    let yMinimum: Double
    let yMaximum: Double
    let xInterval: Double
    let yInterval: Double

    init(rows: [ValuationBubble]) {
        let peValues = rows.map(\.pe)
        let growthValues = rows.map(\.growthPercent)
        let minimumPE = peValues.min() ?? 0
        let maximumPE = peValues.max() ?? 50
        let minimumGrowth = growthValues.min() ?? 0
        let maximumGrowth = growthValues.max() ?? 0

        xMinimum = min(-10, floor(minimumPE / 10) * 10)
        xMaximum = max(50, ceil(maximumPE / 10) * 10)

        let growthSpan = max(20, maximumGrowth - minimumGrowth)
        let growthPadding = max(10, growthSpan * 0.25)
        yMinimum = min(-60, floor((minimumGrowth - growthPadding) / 10) * 10)
        yMaximum = max(0, ceil((maximumGrowth + growthPadding) / 10) * 10)

        xInterval = max(10, ceil(((xMaximum - xMinimum) / 6) / 10) * 10)
        yInterval = max(10, ceil(((yMaximum - yMinimum) / 6) / 10) * 10)
    }
}
