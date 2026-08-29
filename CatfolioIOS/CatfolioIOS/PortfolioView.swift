import Charts
import SwiftUI

struct PortfolioView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedHolding: Holding?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let overview = model.overview, let chart = model.portfolioChart {
                        CostMarketCard(overview: overview, response: chart)
                        PortfolioDetailsCard(holdings: model.holdings) { holding in
                            selectedHolding = holding
                        }
                    } else if model.isPortfolioLoading {
                        PortfolioLoadingView()
                    } else if let error = model.portfolioError {
                        ContentUnavailableView("还没有本机持仓", systemImage: "iphone.gen3.slash", description: Text(error))
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
            }
            .sheet(item: $selectedHolding) { holding in
                VolumeProfileView(holding: holding)
                    .environmentObject(model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
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

private struct PortfolioDetailsCard: View {
    @EnvironmentObject private var model: AppModel
    let holdings: [Holding]
    let onSelect: (Holding) -> Void

    @State private var tableMode = ProcessInfo.processInfo.arguments.contains("--show-etf") ? "ETF 穿透" : "持仓"
    @State private var basis: ETFLookThroughBasis = .market
    @State private var etfResponse: ETFLookThroughResponse?
    @State private var etfError: String?
    @State private var isLoadingETF = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("组合明细")
                    .font(.title3.weight(.bold))
                Spacer()
                Text(itemCount)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            HStack {
                Spacer()
                GlassChoiceBar(choices: ["持仓", "ETF 穿透"], selection: $tableMode)
                Spacer()
            }
            .padding(.bottom, 12)

            if tableMode == "持仓" {
                holdingsTable
            } else {
                etfTable
            }
        }
        .contentCard()
        .task(id: "\(tableMode)-\(basis.rawValue)-\(holdings.count)") {
            guard tableMode == "ETF 穿透" else { return }
            await loadETF()
        }
    }

    private var itemCount: String {
        tableMode == "持仓" ? "\(holdings.count) 项" : "\(etfResponse?.rows.count ?? 0) 项"
    }

    private var holdingsTable: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(holdings.enumerated()), id: \.element.id) { index, holding in
                Button {
                    onSelect(holding)
                } label: {
                    HoldingRow(holding: holding)
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开成交量分析")

                if index < holdings.count - 1 {
                    Divider().padding(.leading, 54)
                }
            }
        }
    }

    @ViewBuilder
    private var etfTable: some View {
        HStack {
            Text("计算口径")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            GlassChoiceBar(
                choices: ETFLookThroughBasis.allCases.map(\.title),
                selection: Binding(
                    get: { basis.title },
                    set: { title in
                        basis = ETFLookThroughBasis.allCases.first { $0.title == title } ?? .market
                    }
                )
            )
        }
        .padding(.bottom, 10)

        if isLoadingETF, etfResponse == nil {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在计算 ETF 底层持仓…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.subheadline)
            .frame(minHeight: 90)
        } else if let etfError {
            Label(etfError, systemImage: "square.3.layers.3d.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        } else if let response = etfResponse {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ETF \(basis.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(DisplayFormat.money(response.etfTotalUSD))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("穿透标的")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(response.etfTickers.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
            }
            .padding(.vertical, 8)

            Divider()

            LazyVStack(spacing: 0) {
                ForEach(Array(response.rows.enumerated()), id: \.element.id) { index, row in
                    ETFExposureRow(row: row)
                    if index < response.rows.count - 1 {
                        Divider().padding(.leading, 46)
                    }
                }
            }
        }
    }

    private func loadETF() async {
        isLoadingETF = true
        etfError = nil
        defer { isLoadingETF = false }
        do {
            etfResponse = try await model.loadETFLookThrough(basis: basis)
        } catch {
            etfResponse = nil
            etfError = error.localizedDescription
        }
    }
}

private struct ETFExposureRow: View {
    let row: ETFLookThroughRow

    var body: some View {
        HStack(spacing: 10) {
            AssetLogo(ticker: row.ticker, logoSymbol: row.logoSymbol)
                .scaleEffect(0.86)
                .frame(width: 38, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.ticker)
                    .font(.subheadline.weight(.bold))
                Text(row.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(DisplayFormat.money(row.totalUSD))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(row.fromETFUSD > 0 ? "ETF \(DisplayFormat.percent(row.etfWeightPercent, signed: false))" : "直接持有")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
    }
}

private struct HoldingRow: View {
    let holding: Holding

    var body: some View {
        HStack(spacing: 12) {
            AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol)

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
