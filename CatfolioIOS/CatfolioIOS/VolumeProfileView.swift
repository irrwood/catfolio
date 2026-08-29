import Charts
import SwiftUI

struct VolumeProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let holding: Holding

    @State private var profile: VolumeProfile?
    @State private var errorMessage: String?
    @State private var selectedPrice: Double?
    @State private var selectionStep = 0

    var body: some View {
        NavigationStack {
            Group {
                if let profile {
                    ScrollView {
                        VStack(spacing: 14) {
                            VolumeSummary(holding: holding)
                            VolumePriceChart(profile: profile, holding: holding, selectedPrice: $selectedPrice)
                            VolumeLevels(profile: profile)
                        }
                        .padding(16)
                    }
                } else if let errorMessage {
                    ContentUnavailableView("暂无成交量分析", systemImage: "chart.bar.xaxis", description: Text(errorMessage))
                } else {
                    ProgressView("正在读取成交量数据")
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("\(holding.ticker) 成交量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                do {
                    profile = try await model.volumeProfile(for: holding.ticker)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .onChange(of: selectedPrice) { _, value in
                guard let value, let profile else { return }
                let markers = [profile.valueAreaLow, profile.pointOfControl, profile.valueAreaHigh, holding.averageCost, holding.quotePrice]
                if let index = markers.enumerated().min(by: { abs($0.element - value) < abs($1.element - value) })?.offset,
                   index != selectionStep {
                    selectionStep = index
                }
            }
            .sensoryFeedback(.selection, trigger: selectionStep)
        }
    }
}

private struct VolumeSummary: View {
    let holding: Holding

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(holding.shortName)
                    .font(.headline)
                Text("当前价")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(DisplayFormat.money(holding.quotePrice, currency: holding.quoteCurrency ?? "USD"))
                    .font(.title2.weight(.bold).monospacedDigit())
                Text(DisplayFormat.percent(holding.todayChangePercent))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(holding.todayChangePercent >= 0 ? CatfolioStyle.green : CatfolioStyle.red)
            }
        }
        .contentCard()
    }
}

private struct VolumePriceChart: View {
    let profile: VolumeProfile
    let holding: Holding
    @Binding var selectedPrice: Double?

    private var domain: ClosedRange<Double> {
        let values = [profile.valueAreaLow, profile.valueAreaHigh, holding.averageCost, holding.quotePrice]
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.16, max(high * 0.03, 1))
        return max(0, low - padding)...(high + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("价值区域")
                .font(.headline)

            Chart {
                RectangleMark(
                    xStart: .value("区域起点", 0.26),
                    xEnd: .value("区域终点", 0.74),
                    yStart: .value("价值区下沿", profile.valueAreaLow),
                    yEnd: .value("价值区上沿", profile.valueAreaHigh)
                )
                .foregroundStyle(CatfolioStyle.blue.opacity(0.16))

                RuleMark(y: .value("VAH", profile.valueAreaHigh))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) { Text("VAH").font(.caption2.bold()) }
                RuleMark(y: .value("POC", profile.pointOfControl))
                    .foregroundStyle(CatfolioStyle.green)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .annotation(position: .top, alignment: .trailing) { Text("POC").font(.caption2.bold()).foregroundStyle(CatfolioStyle.green) }
                RuleMark(y: .value("VAL", profile.valueAreaLow))
                    .foregroundStyle(.secondary)
                    .annotation(position: .bottom, alignment: .leading) { Text("VAL").font(.caption2.bold()) }
                RuleMark(y: .value("成本", holding.averageCost))
                    .foregroundStyle(CatfolioStyle.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .bottom, alignment: .trailing) { Text("成本").font(.caption2.bold()).foregroundStyle(CatfolioStyle.blue) }
                RuleMark(y: .value("当前价", holding.quotePrice))
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top, alignment: .trailing) { Text("现价").font(.caption2.bold()) }

                if let selectedPrice {
                    RuleMark(y: .value("选中价格", selectedPrice))
                        .foregroundStyle(CatfolioStyle.blue.opacity(0.55))
                        .annotation(position: .leading) {
                            Text(DisplayFormat.money(selectedPrice, currency: profile.currency))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.regularMaterial, in: Capsule())
                        }
                }
            }
            .chartXScale(domain: 0...1)
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount, format: .number.precision(.fractionLength(0...2)))
                        }
                    }
                }
            }
            .chartYSelection(value: $selectedPrice)
            .frame(height: 280)
            .accessibilityLabel("成交量价值区域，按住并上下拖动查看价格")

            Text("按住图表并上下拖动查看价格位置。蓝色区域覆盖约 \(profile.valueAreaPercent)% 的成交量。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentCard()
    }
}

private struct VolumeLevels: View {
    let profile: VolumeProfile

    var body: some View {
        VStack(spacing: 12) {
            LevelRow(title: "价值区上沿 VAH", value: profile.valueAreaHigh, currency: profile.currency)
            Divider()
            LevelRow(title: "最大成交量价 POC", value: profile.pointOfControl, currency: profile.currency, color: CatfolioStyle.green)
            Divider()
            LevelRow(title: "价值区下沿 VAL", value: profile.valueAreaLow, currency: profile.currency)
            Divider()
            HStack {
                Text("样本")
                Spacer()
                Text("\(profile.sessions) 个交易日，截至 \(profile.asOf)")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        .contentCard()
    }
}

private struct LevelRow: View {
    let title: String
    let value: Double
    let currency: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(DisplayFormat.money(value, currency: currency))
                .font(.body.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}
