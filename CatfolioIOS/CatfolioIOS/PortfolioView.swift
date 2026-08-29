import Charts
import SwiftUI

struct PortfolioView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedHolding: Holding?
    @State private var showsETFLookThrough = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let overview = model.overview, let chart = model.portfolioChart {
                        CostMarketCard(overview: overview, response: chart)
                        ETFLookThroughEntryCard {
                            showsETFLookThrough = true
                        }
                        HoldingsCard(holdings: model.holdings, serverURL: model.serverURL) { holding in
                            selectedHolding = holding
                        }
                    } else if model.isPortfolioLoading {
                        PortfolioLoadingView()
                    } else if let error = model.portfolioError {
                        ContentUnavailableView("无法读取持仓", systemImage: "wifi.exclamationmark", description: Text(error))
                            .frame(minHeight: 420)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("投资组合")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    GlassIconButton(systemImage: "arrow.clockwise", accessibilityLabel: "刷新投资组合") {
                        Task { await model.refreshPortfolio() }
                    }
                }
            }
            .refreshable { await model.refreshPortfolio() }
            .task {
                if model.overview == nil && !model.isPortfolioLoading {
                    await model.refreshPortfolio()
                }
                if ProcessInfo.processInfo.arguments.contains("--show-volume"),
                   selectedHolding == nil {
                    selectedHolding = model.holdings.first
                }
                if ProcessInfo.processInfo.arguments.contains("--show-etf") {
                    showsETFLookThrough = true
                }
            }
            .sheet(item: $selectedHolding) { holding in
                VolumeProfileView(holding: holding)
                    .environmentObject(model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsETFLookThrough) {
                ETFLookThroughView()
                    .environmentObject(model)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct ETFLookThroughEntryCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "square.3.layers.3d")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(CatfolioStyle.blue)
                    .frame(width: 42, height: 42)
                    .background(CatfolioStyle.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("ETF 穿透")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("展开基金底层持仓，合并直接与间接暴露")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentCard()
        .accessibilityHint("打开 ETF 底层股票暴露")
    }
}

private struct CostMarketCard: View {
    let overview: PortfolioOverview
    let response: PortfolioChartResponse

    @State private var range = "3M"
    @State private var selectedDate: Date?

    private let choices = ["1M", "3M", "YTD", "1Y", "全部"]

    private var rows: [ChartPoint] {
        let source = response.positionHistory.rows
        guard let last = source.last?.date else { return [] }
        switch range {
        case "1M":
            return source.filter { $0.date >= Calendar.current.date(byAdding: .month, value: -1, to: last) ?? .distantPast }
        case "3M":
            return source.filter { $0.date >= Calendar.current.date(byAdding: .month, value: -3, to: last) ?? .distantPast }
        case "YTD":
            let year = Calendar.current.component(.year, from: last)
            return source.filter { Calendar.current.component(.year, from: $0.date) == year }
        case "1Y":
            return source.filter { $0.date >= Calendar.current.date(byAdding: .year, value: -1, to: last) ?? .distantPast }
        default:
            return source
        }
    }

    private var selectedPoint: ChartPoint? {
        guard let selectedDate else { return rows.last }
        return rows.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("成本与市值")
                        .font(.title3.weight(.bold))
                    Text(overview.summary.asOf ?? "最新数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let point = selectedPoint {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(DisplayFormat.money(point.marketValue))
                            .font(.headline.monospacedDigit())
                        Text(DayDateFormatter.shared.string(from: point.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 20) {
                ChartLegend(color: CatfolioStyle.green, title: "市值", value: DisplayFormat.money(selectedPoint?.marketValue ?? overview.summary.marketValue))
                ChartLegend(color: CatfolioStyle.blue, title: "成本", value: DisplayFormat.money(selectedPoint?.cost ?? overview.summary.totalCost))
            }

            Chart(rows) { row in
                LineMark(x: .value("日期", row.date), y: .value("市值", row.marketValue))
                    .foregroundStyle(by: .value("系列", "市值"))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("日期", row.date), y: .value("成本", row.cost))
                    .foregroundStyle(by: .value("系列", "成本"))
                    .interpolationMethod(.catmullRom)

                if let selectedPoint, selectedPoint.id == row.id {
                    RuleMark(x: .value("选择日期", row.date))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("日期", row.date), y: .value("市值", row.marketValue))
                        .foregroundStyle(CatfolioStyle.green)
                        .symbolSize(48)
                    PointMark(x: .value("日期", row.date), y: .value("成本", row.cost))
                        .foregroundStyle(CatfolioStyle.blue)
                        .symbolSize(48)
                }
            }
            .chartForegroundStyleScale(["市值": CatfolioStyle.green, "成本": CatfolioStyle.blue])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
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
            .frame(height: 245)
            .accessibilityLabel("成本与市值对比图，按住后左右拖动查看历史数据")

            HStack {
                Spacer()
                GlassChoiceBar(choices: choices, selection: $range)
                Spacer()
            }

            Text("按住图表并左右拖动，可查看任意日期。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentCard()
        .onChange(of: range) { _, _ in selectedDate = nil }
    }
}

private struct ChartLegend: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
        }
    }
}

private struct HoldingsCard: View {
    let holdings: [Holding]
    let serverURL: String
    let onSelect: (Holding) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("持仓明细")
                    .font(.title3.weight(.bold))
                Spacer()
                Text("\(holdings.count) 项")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)

            ForEach(Array(holdings.enumerated()), id: \.element.id) { index, holding in
                Button {
                    onSelect(holding)
                } label: {
                    HoldingRow(holding: holding, serverURL: serverURL)
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开成交量分析")

                if index < holdings.count - 1 {
                    Divider().padding(.leading, 54)
                }
            }
        }
        .contentCard()
    }
}

private struct HoldingRow: View {
    let holding: Holding
    let serverURL: String

    var body: some View {
        HStack(spacing: 12) {
            AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, serverURL: serverURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(holding.ticker)
                    .font(.body.weight(.bold))
                Text(holding.shortName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(DisplayFormat.money(holding.marketValue))
                    .font(.body.weight(.semibold).monospacedDigit())
                Text(DisplayFormat.percent(holding.unrealizedPercent))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(holding.unrealized >= 0 ? CatfolioStyle.green : CatfolioStyle.red)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 62)
        .contentShape(Rectangle())
    }
}

private struct PortfolioLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 20).fill(Color.secondary.opacity(0.12)).frame(height: 430)
            RoundedRectangle(cornerRadius: 20).fill(Color.secondary.opacity(0.12)).frame(height: 360)
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("正在读取投资组合")
    }
}
