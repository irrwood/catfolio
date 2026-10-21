import SwiftUI

struct AnalystHistoryChartLine: Identifiable {
    let id: String
    let title: String
    let color: Color
    var lineWidth: CGFloat = 2
    var dash: [CGFloat] = []
    var fill: Color? = nil
    let value: (AnalystHistoryPoint) -> Double?
    let text: (AnalystHistoryPoint) -> String
}

/// Price and rating counts retain their own units. Only drawing coordinates
/// are projected onto the count domain; the readout always uses the snapshot.
struct AnalystHistoryChartData {
    let points: [AnalystHistoryPoint]
    let ratings: Bool
    let hidden: Set<String>
    let countCeiling: Double
    let priceCeiling: Double

    init(points: [AnalystHistoryPoint], ratings: Bool, months: Int = 0, hidden: Set<String> = []) {
        let ordered = points.filter { (!ratings || $0.hasRatings) && DayDateCodec.date(from: $0.date) != nil }
            .sorted { $0.date < $1.date }
        self.points = months > 0 ? Array(ordered.suffix(months)) : ordered
        self.ratings = ratings
        self.hidden = hidden
        countCeiling = max(10, ceil(Double(self.points.map { $0.counts.reduce(0, +) }.max() ?? 0) / 10) * 10)
        let prices = self.points.flatMap { point -> [Double] in
            let targets = !ratings && point.validTargets ? [point.low, point.mean, point.high] : []
            return ([point.price] + targets).compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        }
        priceCeiling = max(50, ceil((prices.max() ?? 0) / 50) * 50)
    }

    var hasPrices: Bool { points.contains { Self.validPrice($0.price) != nil } }
    var hasDualAxes: Bool { ratings && hasPrices }
    var ceiling: Double { ratings ? countCeiling : priceCeiling }
    var ticks: [Double] { [0, ceiling / 2, ceiling] }
    var dates: [Date] { points.compactMap { DayDateCodec.date(from: $0.date) } }

    func plottedPrice(_ price: Double) -> Double {
        ratings ? price / priceCeiling * countCeiling : price
    }

    func priceAtTick(_ value: Double) -> Double {
        ratings ? value / countCeiling * priceCeiling : value
    }

    static func money(_ value: Double?) -> String {
        value?.formatted(.currency(code: "USD")) ?? "—"
    }

    private static func validPrice(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var lines: [AnalystHistoryChartLine] {
        let price = AnalystHistoryChartLine(
            id: "price", title: L10n.text("股价"), color: CatfolioStyle.blue, lineWidth: 2.5,
            value: { Self.validPrice($0.price).map(plottedPrice) }, text: { Self.money($0.price) })
        if ratings {
            let labels = [L10n.text("卖出"), L10n.text("持有"), L10n.text("买入"), L10n.text("强烈买入")]
            let colors = [CatfolioPalette.ChartSeries.rose, CatfolioPalette.ChartSeries.orange,
                          CatfolioPalette.ChartSeries.mint, CatfolioPalette.ChartSeries.green]
            // Opaque cumulative fills paint largest first. The price paints
            // last, so no rating area can cover the curve or its crosshair.
            let areas = (0..<4).reversed().map { index in
                AnalystHistoryChartLine(id: "rating-\(index)", title: labels[index], color: colors[index],
                    lineWidth: 0, fill: colors[index],
                    value: { point in
                        guard point.hasRatings else { return nil }
                        return Double((0...index).filter { !hidden.contains("rating-\($0)") }
                            .reduce(0) { $0 + point.counts[$1] })
                    }, text: { $0.hasRatings ? "\($0.counts[index])" : "—" })
            }
            return areas + [price]
        }
        return [
            price,
            .init(id: "mean", title: L10n.text("共识目标价"), color: CatfolioPalette.ChartSeries.orange,
                  value: { $0.validTargets ? $0.mean : nil }, text: { Self.money($0.validTargets ? $0.mean : nil) }),
            .init(id: "high", title: L10n.text("最高目标价"), color: CatfolioTheme.positive,
                  lineWidth: 1.5, dash: [4, 3], value: { $0.validTargets ? $0.high : nil },
                  text: { Self.money($0.validTargets ? $0.high : nil) }),
            .init(id: "low", title: L10n.text("最低目标价"), color: CatfolioTheme.danger,
                  lineWidth: 1.5, dash: [4, 3], value: { $0.validTargets ? $0.low : nil },
                  text: { Self.money($0.validTargets ? $0.low : nil) }),
        ]
    }

    var legendLines: [AnalystHistoryChartLine] {
        ratings ? lines.filter { $0.id == "price" } + lines.filter { $0.fill != nil }.reversed() : lines
    }

    var series: [StandardLineChartSeries] {
        lines.filter { !hidden.contains($0.id) }.flatMap { line in
            var runs: [[StandardLineChartPoint]] = [[]]
            for point in points {
                if let value = line.value(point), value.isFinite, let date = DayDateCodec.date(from: point.date) {
                    runs[runs.count - 1].append(.init(id: "\(line.id)|\(point.date)", date: date, value: value))
                } else if !(runs.last?.isEmpty ?? true) {
                    runs.append([])
                }
            }
            return runs.enumerated().filter { !$0.element.isEmpty }.map { index, run in
                StandardLineChartSeries(id: "\(line.id)|\(index)", points: run, color: line.color,
                    lineWidth: line.fill == nil ? line.lineWidth : 0.01, dash: line.dash,
                    areaFill: line.fill, areaBaseline: line.fill == nil ? nil : 0,
                    selectionRadius: line.fill == nil ? 3.5 : 0,
                    latestPointRadius: line.fill == nil && run.count == 1 ? 3 : nil,
                    latestPointUsesGlass: false)
            }
        }
    }
}

struct AnalystHistoryPlot: View {
    let data: AnalystHistoryChartData
    let symbol: String
    let transitionKey: String
    let selectedDate: Date?
    let onSelect: (Date) -> Void
    let onInteractionEnded: () -> Void

    private let countAxisWidth: CGFloat = 30
    private let topInset: CGFloat = 8
    private let bottomHeight: CGFloat = 24

    var body: some View {
        let drawn = data.series
        StandardLineChart(
            series: drawn, interactionDates: data.dates, domain: 0...data.ceiling,
            yTicks: data.ticks, topInset: topInset, bottomHeight: bottomHeight,
            leadingLineOverflow: 0,
            transitionKey: transitionKey,
            appearanceID: "analyst-history|\(symbol)",
            selectedDate: selectedDate,
            selectionIndicatorLabel: selectedDate.map { String(DayDateCodec.string(from: $0).prefix(7)) },
            selectionSeriesIDs: Set(drawn.filter { $0.areaFill == nil }.map(\.id)),
            yAxisLabel: { value in
                data.ratings && !data.hasPrices
                    ? "\(Int(value.rounded()))"
                    : "$\(Int(data.priceAtTick(value).rounded()))"
            },
            xAxisLabel: { String(DayDateCodec.string(from: $0).prefix(7)) },
            onSelect: onSelect,
            onInteractionEnded: { _ in onInteractionEnded() }
        )
        .padding(.leading, data.hasDualAxes ? countAxisWidth : 0)
        .overlay(alignment: .leading) {
            if data.hasDualAxes {
                GeometryReader { geometry in
                    ForEach(data.ticks, id: \.self) { count in
                        FinancialText("\(Int(count.rounded()))")
                            .font(Typography.number(.nano))
                            .foregroundStyle(.secondary)
                            .frame(width: countAxisWidth - 8, alignment: .trailing)
                            .position(x: (countAxisWidth - 8) / 2,
                                      y: topInset + (geometry.size.height - topInset - bottomHeight)
                                        * (1 - count / data.countCeiling))
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .frame(height: 260)
        .accessibilityLabel(L10n.text(data.ratings ? "推荐建议历史" : "目标价历史"))
        .accessibilityIdentifier("analyst-history-chart")
    }
}
