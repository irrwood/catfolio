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
            AnalyticsLoadingCard(title: L10n.text("估值 · 成长 · 质量"), height: 240, chart: chart)
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
    let matrix: ValuationMatrix
    var body: some View { ValuationStockMap(matrix: matrix) }
}
