import Charts
import SwiftUI

struct ReturnsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var benchmark = "SPY"
    @State private var selectedDate: Date?

    private let benchmarkChoices = ["SPY", "QQQ", "VTI", "GLD"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let comparison = model.comparison {
                        ReturnsSummary(comparison: comparison, benchmark: benchmark)
                        ReturnsChart(comparison: comparison, benchmark: benchmark, selectedDate: $selectedDate)
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
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("收益对比")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    GlassIconButton(systemImage: "arrow.clockwise", accessibilityLabel: "刷新收益") {
                        Task { await model.refreshReturns() }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Spacer()
                    GlassChoiceBar(choices: benchmarkChoices, selection: $benchmark)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .refreshable { await model.refreshReturns() }
            .task {
                if model.comparison == nil && !model.isReturnsLoading {
                    await model.refreshReturns()
                }
            }
            .onChange(of: benchmark) { _, _ in selectedDate = nil }
        }
    }
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
                .foregroundStyle((value ?? 0) >= 0 ? CatfolioStyle.green : CatfolioStyle.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReturnsChart: View {
    let comparison: ComparisonResponse
    let benchmark: String
    @Binding var selectedDate: Date?

    private var points: [ComparisonPoint] {
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

    private var selectedPoint: ComparisonPoint? {
        guard let selectedDate else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("累计价值")
                        .font(.title3.weight(.bold))
                    Text("同一现金流基础下的组合与基准")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let point = selectedPoint {
                    Text(DayDateFormatter.shared.string(from: point.date))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let point = selectedPoint {
                HStack(spacing: 20) {
                    SmallValue(title: "组合", value: point.portfolio, color: CatfolioStyle.green)
                    SmallValue(title: benchmark, value: point.benchmark, color: CatfolioStyle.blue)
                }
            }

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
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.year())
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount, format: .number.notation(.compactName))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.12)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .onChanged { value in
                                    guard case let .second(true, drag?) = value,
                                          let plotFrame = proxy.plotFrame else { return }
                                    let frame = geometry[plotFrame]
                                    let x = min(max(drag.location.x - frame.origin.x, 0), frame.width)
                                    selectedDate = proxy.value(atX: x, as: Date.self)
                                }
                        )
                }
            }
            .frame(height: 330)
            .accessibilityLabel("组合与 \(benchmark) 的收益对比图，按住后左右拖动查看")

            Text("组合收益从首次在手机同步开始按日记录。基准行情尚未配置时会显示为暂无。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentCard()
    }
}

private struct SmallValue: View {
    let title: String
    let value: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(color)
            Text(value.map { DisplayFormat.money($0) } ?? "暂无")
                .font(.subheadline.weight(.bold).monospacedDigit())
        }
    }
}
