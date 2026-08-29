import Charts
import SwiftUI

struct ReturnsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var benchmark = "SPY"
    @State private var chartMode = ReturnsChartMode.cumulativeValue
    @State private var selectedDate: Date?

    private let benchmarkChoices = ["SPY", "QQQ", "VTI", "GLD"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        GlassChoiceBar(choices: benchmarkChoices, selection: $benchmark)
                        Spacer()
                    }
                    .padding(.bottom, 2)

                    if let comparison = model.comparison {
                        ReturnsSummary(comparison: comparison, benchmark: benchmark)
                        ReturnsChart(
                            comparison: comparison,
                            benchmark: benchmark,
                            mode: $chartMode,
                            selectedDate: $selectedDate
                        )
                    } else if model.isReturnsLoading {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 520)
                            .redacted(reason: .placeholder)
                    } else if let error = model.returnsError {
                        ContentUnavailableView("暂无收益记录", systemImage: "calendar.badge.clock", description: Text(error))
                            .frame(minHeight: 420)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 88)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("收益对比")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isReturnsLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 36, height: 36)
                            .accessibilityLabel("正在刷新收益")
                    } else {
                        ToolbarIconButton(systemImage: "arrow.clockwise", accessibilityLabel: "刷新收益") {
                            Task { await model.refreshReturns() }
                        }
                    }
                }
            }
            .refreshable { await model.refreshReturns() }
            .task {
                if model.comparison == nil && !model.isReturnsLoading {
                    await model.refreshReturns()
                }
            }
            .onChange(of: benchmark) { _, _ in selectedDate = nil }
            .onChange(of: chartMode) { _, _ in selectedDate = nil }
        }
    }
}

private enum ReturnsChartMode: String, CaseIterable {
    case cumulativeValue = "累计价值"
    case twr = "TWR"
}

private struct ReturnsSummary: View {
    let comparison: ComparisonResponse
    let benchmark: String

    private var benchmarkReturn: Double? {
        comparison.summary.benchmarkReturns[benchmark] ?? nil
    }

    var body: some View {
        HStack(spacing: 0) {
            ReturnMetric(title: "组合", value: comparison.summary.portfolioReturn, color: CatfolioStyle.green)
            Divider().frame(height: 56)
            ReturnMetric(title: benchmark, value: benchmarkReturn, color: CatfolioStyle.blue)
        }
        .contentCard()
    }
}

private struct ReturnMetric: View {
    let title: String
    let value: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            Text(DisplayFormat.ratioPercent(value))
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(value.map { $0 >= 0 ? CatfolioStyle.green : CatfolioStyle.red } ?? Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReturnsChart: View {
    let comparison: ComparisonResponse
    let benchmark: String
    @Binding var mode: ReturnsChartMode
    @Binding var selectedDate: Date?

    private var rawPoints: [ComparisonPoint] {
        guard let benchmarkValues = comparison.benchmarks[benchmark] else { return [] }
        let count = min(comparison.dates.count, comparison.portfolio.count, benchmarkValues.count)
        guard count > 0 else { return [] }
        let step = max(1, Int(ceil(Double(count) / 140)))
        var sampledIndices = Array(stride(from: 0, to: count, by: step))
        if sampledIndices.last != count - 1 {
            sampledIndices.append(count - 1)
        }
        return sampledIndices.compactMap { index -> ComparisonPoint? in
            guard let portfolio = comparison.portfolio[index],
                  let date = DayDateFormatter.shared.date(from: comparison.dates[index]) else { return nil }
            return ComparisonPoint(date: date, portfolio: portfolio, benchmark: benchmarkValues[index])
        }
    }

    private var points: [ComparisonPoint] {
        guard mode == .twr,
              let initialPortfolio = rawPoints.first?.portfolio,
              initialPortfolio != 0 else { return rawPoints }
        let initialBenchmark = rawPoints.compactMap(\.benchmark).first
        return rawPoints.map { point in
            ComparisonPoint(
                date: point.date,
                portfolio: (point.portfolio / initialPortfolio - 1) * 100,
                benchmark: initialBenchmark.flatMap { initial in
                    guard initial != 0, let value = point.benchmark else { return nil }
                    return (value / initial - 1) * 100
                }
            )
        }
    }

    private var selectedPoint: ComparisonPoint? {
        guard let selectedDate else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.flatMap { point in
            [Optional(point.portfolio), point.benchmark].compactMap { $0 }
        }
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        let padding = max((maximum - minimum) * 0.12, max(abs(minimum), abs(maximum)) * 0.02, 1)
        if mode == .twr {
            return (minimum - padding)...(maximum + padding)
        }
        return max(0, minimum - padding)...(maximum + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.rawValue)
                        .font(.title3.weight(.bold))
                    Text(mode == .twr ? "以首日为 0% 的组合与基准链式收益" : "同一现金流基础下的组合与基准")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    GlassChoiceBar(
                        choices: ReturnsChartMode.allCases.map(\.rawValue),
                        selection: Binding(
                            get: { mode.rawValue },
                            set: { mode = ReturnsChartMode(rawValue: $0) ?? .cumulativeValue }
                        )
                    )
                    if let point = selectedPoint {
                        Text(DayDateFormatter.shared.string(from: point.date))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let point = selectedPoint {
                HStack(spacing: 20) {
                    SmallValue(title: "组合", value: point.portfolio, color: CatfolioStyle.green, mode: mode)
                    SmallValue(title: benchmark, value: point.benchmark, color: CatfolioStyle.blue, mode: mode)
                }
            }

            if !points.isEmpty, points.allSatisfy({ $0.benchmark == nil }) {
                StatusNotice(text: "暂时没有读取到 \(benchmark) 行情，组合曲线仍可正常查看。", kind: .info)
            }

            if points.isEmpty {
                ContentUnavailableView(
                    "暂无可绘制数据",
                    systemImage: "chart.xyaxis.line",
                    description: Text("请先同步一次持仓，然后点右上角刷新。")
                )
                .frame(height: 280)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("日期", point.date), y: .value("组合", point.portfolio))
                        .foregroundStyle(by: .value("系列", "组合"))
                        .interpolationMethod(.linear)
                    if let benchmarkValue = point.benchmark {
                        LineMark(x: .value("日期", point.date), y: .value(benchmark, benchmarkValue))
                            .foregroundStyle(by: .value("系列", benchmark))
                            .interpolationMethod(.linear)
                    }

                    if selectedPoint?.id == point.id {
                        RuleMark(x: .value("选择日期", point.date))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        PointMark(x: .value("日期", point.date), y: .value("组合", point.portfolio))
                            .foregroundStyle(CatfolioStyle.green)
                            .symbolSize(48)
                        if let benchmarkValue = point.benchmark {
                            PointMark(x: .value("日期", point.date), y: .value(benchmark, benchmarkValue))
                                .foregroundStyle(CatfolioStyle.blue)
                                .symbolSize(48)
                        }
                    }
                }
                .chartForegroundStyleScale(["组合": CatfolioStyle.green, benchmark: CatfolioStyle.blue])
                .chartYScale(domain: yDomain)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                if mode == .twr {
                                    Text(DisplayFormat.percent(amount, signed: false))
                                } else {
                                    Text(amount, format: .number.notation(.compactName))
                                }
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 8)
                                    .onChanged { drag in
                                        guard abs(drag.translation.width) > abs(drag.translation.height),
                                              let plotFrame = proxy.plotFrame else { return }
                                        let frame = geometry[plotFrame]
                                        let x = min(max(drag.location.x - frame.origin.x, 0), frame.width)
                                        selectedDate = proxy.value(atX: x, as: Date.self)
                                    }
                            )
                    }
                }
                .frame(height: 290)
                .accessibilityLabel("组合与 \(benchmark) 的 \(mode.rawValue) 对比图，横向拖动查看")
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentCard()
    }

    private var footnote: String {
        if mode == .twr {
            return "TWR 按已保存的净值序列链式计算；如果期间有入金或出金但没有对应现金流记录，结果无法自动剔除其影响。"
        }
        return "只有一个同步快照时，会按当前持仓回溯近一年行情；后续同步将优先使用手机保存的真实快照。"
    }
}

private struct SmallValue: View {
    let title: String
    let value: Double?
    let color: Color
    let mode: ReturnsChartMode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(color)
            Text(formattedValue)
                .font(.subheadline.weight(.bold).monospacedDigit())
        }
    }

    private var formattedValue: String {
        guard let value else { return "暂无" }
        return mode == .twr ? DisplayFormat.percent(value) : DisplayFormat.money(value)
    }
}
