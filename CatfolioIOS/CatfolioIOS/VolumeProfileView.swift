import Charts
import SwiftUI

struct HoldingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let holding: Holding

    @State private var profile: VolumeProfile?
    @State private var errorMessage: String?
    @State private var selectedPrice: Double?
    @State private var selectionStep = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    HoldingDetailHeader(holding: holding, marketTodayChange: profile?.todayChangePercent)
                    HoldingPositionDetails(holding: holding, marketTodayChange: profile?.todayChangePercent)

                    if let profile {
                        if let high = profile.fiftyTwoWeekHigh,
                           let low = profile.fiftyTwoWeekLow,
                           high > low {
                            FiftyTwoWeekRange(
                                low: low,
                                high: high,
                                current: holding.quotePrice,
                                currency: profile.currency
                            )
                        }
                        VolumePriceChart(profile: profile, holding: holding, selectedPrice: $selectedPrice)
                        VolumeLevels(profile: profile)
                    } else if let errorMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("成交量分析")
                                .font(.headline)
                            StatusNotice(text: errorMessage, kind: .info)
                        }
                        .contentCard()
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取成交量与 52 周数据…")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("持仓详情")
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

private struct HoldingDetailHeader: View {
    let holding: Holding
    let marketTodayChange: Double?

    private var todayChange: Double? {
        holding.todayChangePercent ?? marketTodayChange
    }

    var body: some View {
        HStack(spacing: 12) {
            AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol)

            VStack(alignment: .leading, spacing: 4) {
                Text(holding.shortName)
                    .font(.headline)
                    .lineLimit(2)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(DisplayFormat.money(holding.quotePrice, currency: holding.quoteCurrency ?? "USD"))
                    .font(.title2.weight(.bold).monospacedDigit())
                if let todayChangePercent = todayChange {
                    Text(DisplayFormat.percent(todayChangePercent))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(todayChangePercent >= 0 ? CatfolioStyle.green : CatfolioStyle.red)
                } else {
                    Text("今日 —")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentCard()
    }

    private var metadata: String {
        ([holding.ticker] + [holding.sector, holding.source].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }).joined(separator: " · ")
    }
}

private struct HoldingPositionDetails: View {
    let holding: Holding
    let marketTodayChange: Double?

    private let columns = [
        GridItem(.flexible(), alignment: .leading),
        GridItem(.flexible(), alignment: .leading),
    ]

    private var costBasis: Double {
        holding.marketValue - holding.unrealized
    }

    private var profitColor: Color {
        holding.unrealized >= 0 ? CatfolioStyle.green : CatfolioStyle.red
    }

    private var todayChange: Double? {
        holding.todayChangePercent ?? marketTodayChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("持仓数据")
                .font(.headline)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                HoldingMetric(
                    title: "股数",
                    value: holding.shares.formatted(.number.precision(.fractionLength(0...4)))
                )
                HoldingMetric(
                    title: "组合占比",
                    value: DisplayFormat.percent(holding.weight * 100, signed: false)
                )
                HoldingMetric(
                    title: "平均成本",
                    value: DisplayFormat.money(holding.averageCost, currency: holding.costCurrency ?? "USD")
                )
                HoldingMetric(
                    title: "当前价格",
                    value: DisplayFormat.money(holding.quotePrice, currency: holding.quoteCurrency ?? "USD")
                )
                HoldingMetric(title: "持仓成本", value: DisplayFormat.money(costBasis))
                HoldingMetric(title: "当前市值", value: DisplayFormat.money(holding.marketValue))
                HoldingMetric(
                    title: "未实现盈亏",
                    value: DisplayFormat.money(holding.unrealized, signed: true),
                    detail: DisplayFormat.percent(holding.unrealizedPercent),
                    color: profitColor
                )
                HoldingMetric(
                    title: "今日变化",
                    value: todayChange.map { DisplayFormat.percent($0) } ?? "暂无",
                    color: todayChange.map { $0 >= 0 ? CatfolioStyle.green : CatfolioStyle.red } ?? .secondary
                )
            }
        }
        .contentCard()
    }
}

private struct HoldingMetric: View {
    let title: String
    let value: String
    var detail: String? = nil
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if let detail {
                Text(detail)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FiftyTwoWeekRange: View {
    let low: Double
    let high: Double
    let current: Double
    let currency: String

    private var position: Double {
        min(1, max(0, (current - low) / (high - low)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("52 周区间")
                    .font(.headline)
                Spacer()
                Text("当前位于 \(Int((position * 100).rounded()))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(CatfolioStyle.blue.opacity(0.34))
                        .frame(width: max(8, geometry.size.width * position))
                    Circle()
                        .fill(CatfolioStyle.blue)
                        .frame(width: 14, height: 14)
                        .offset(x: max(0, min(geometry.size.width - 14, geometry.size.width * position - 7)))
                }
            }
            .frame(height: 14)

            HStack {
                Text(DisplayFormat.money(low, currency: currency))
                Spacer()
                Text(DisplayFormat.money(high, currency: currency))
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .contentCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("52 周最低 \(DisplayFormat.money(low, currency: currency))，最高 \(DisplayFormat.money(high, currency: currency))，当前位于百分之 \(Int((position * 100).rounded()))")
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
