import SwiftUI
import Charts

struct AnalystHistorySnapshot: Decodable {
    let symbol: String
    let currency: String
    let retrievedOn: String
    let sourceURL: String
    let points: [AnalystHistoryPoint]
    let status: String?
    let warnings: [String]?

    private struct Catalog: Decodable { let entries: [String: AnalystHistorySnapshot] }
    private static let catalog: [String: AnalystHistorySnapshot] = {
        guard let url = Bundle.main.url(forResource: "analyst_history_catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Catalog.self, from: data) else { return [:] }
        return decoded.entries
    }()
    static func load(symbol: String, bundle: Bundle = .main) -> Self? {
        guard let value = catalog[symbol.uppercased()], value.symbol == symbol.uppercased(),
              value.currency == "USD", !value.points.isEmpty,
              value.points.allSatisfy(\.isValid),
              Set(value.points.map(\.date)).count == value.points.count else { return nil }
        return value
    }
    static func unavailableReason(symbol: String) -> String {
        guard let value = catalog[symbol.uppercased()] else { return L10n.text("该证券尚未采集历史数据。") }
        switch value.status {
        case "UNSUPPORTED_LISTING": return L10n.text("该上市市场暂不支持，未使用其他市场同名股票数据。")
        case "FETCH_FAILED": return L10n.text("来源抓取失败，暂未取得历史数据。")
        default: return L10n.text("来源暂无有效历史覆盖。")
        }
    }

}

struct AnalystHistoryPoint: Decodable, Identifiable {
    let date: String
    let price: Double?
    let low: Double?
    let mean: Double?
    let high: Double?
    let sell: Int?
    let hold: Int?
    let buy: Int?
    let strongBuy: Int?
    var id: String { date }
    var hasRatings: Bool { sell != nil && hold != nil && buy != nil && strongBuy != nil }
    var counts: [Int] { [sell ?? 0, hold ?? 0, buy ?? 0, strongBuy ?? 0] }
    var validTargets: Bool {
        guard let low, let mean, let high else { return false }
        return [low, mean, high].allSatisfy { $0.isFinite && $0 > 0 } && low <= mean && mean <= high
    }
    var isValid: Bool {
        (price.map { $0.isFinite && $0 > 0 } ?? hasRatings) && (validTargets || (low == nil && mean == nil && high == nil))
        && [sell, hold, buy, strongBuy].compactMap { $0 }.allSatisfy { $0 >= 0 }
        && ([sell, hold, buy, strongBuy].compactMap { $0 }.isEmpty || hasRatings)
    }
}

struct AnalystHistoryView: View {
    let symbol: String
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: AnalystHistorySnapshot?
    @State private var ratings = false
    @State private var months = 0
    @State private var selection: String?
    private var labels: [String] { [L10n.text("卖出"), L10n.text("持有"), L10n.text("买入"), L10n.text("强烈买入")] }
    private let colors: [Color] = [CatfolioStyle.red.opacity(0.65), Color.yellow.opacity(0.35), CatfolioStyle.green.opacity(0.5), CatfolioStyle.green]
    private var points: [AnalystHistoryPoint] {
        let all = (snapshot?.points ?? []).filter { !ratings || $0.hasRatings }.sorted { $0.date < $1.date }
        return months == 0 ? all : Array(all.suffix(months))
    }
    private var selected: AnalystHistoryPoint? { points.first { $0.date == selection } ?? points.last }
    private var countCeiling: Double {
        max(10, ceil(Double(points.map { $0.counts.reduce(0, +) }.max() ?? 0) / 10) * 10)
    }
    private var priceCeiling: Double {
        max(50, ceil((points.compactMap { ratings ? $0.price : $0.high ?? $0.price }.max() ?? 0) / 50) * 50)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(symbol.uppercased() + " · " + L10n.text("历史快照"))
                    .font(.headline)
                Picker(L10n.text("图表"), selection: $ratings) {
                    Text(L10n.text("目标价历史")).tag(false)
                    Text(L10n.text("推荐建议历史")).tag(true)
                }.pickerStyle(.segmented)
                Picker(L10n.text("时间范围"), selection: $months) {
                    Text(L10n.text("1 年")).tag(12)
                    Text(L10n.text("2 年")).tag(24)
                    Text(L10n.text("全部")).tag(0)
                }.pickerStyle(.segmented)
                if snapshot != nil, !points.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        readout
                        if ratings { ratingsChart } else if points.contains(where: { $0.price != nil || $0.validTargets }) { targetsChart } else {
                            Text(L10n.text("来源暂无目标价和股价，可切换查看推荐建议。"))
                                .foregroundStyle(.secondary).frame(height: 160)
                        }
                        legend
                        Text(L10n.text(ratings ? "左轴：评级数量 · 右轴：股价 USD" : "单位 USD · 阴影为最低至最高目标价"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.06)) }
                    Text(L10n.text("每月推荐建议为该月份对应的过去一年评级分布，并非当月新增评级。股价来自同一来源的月度图表，不是当日收盘价。月份统计窗口与拆股调整口径尚未确认，不用于预测准确率计算。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if snapshot?.warnings?.isEmpty == false {
                        Text(L10n.text("部分月份目标价异常，已留空；未补值或连接缺失区间。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let snapshot {
                        Text(L10n.text("本地快照 · 采集于 ") + snapshot.retrievedOn)
                            .font(.caption).foregroundStyle(.secondary)
                        Link("MarketBeat · " + symbol + " ↗", destination: URL(string: snapshot.sourceURL)!)
                            .font(.caption)
                    }
                } else {
                    ContentUnavailableView(L10n.text("暂无历史快照"), systemImage: "chart.xyaxis.line", description: Text(AnalystHistorySnapshot.unavailableReason(symbol: symbol)))
                }
            }.padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .softTopScrollEdge()
        .navigationTitle(L10n.text("分析师历史回顾"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { dismiss() } } }
        .task(id: symbol) { snapshot = AnalystHistorySnapshot.load(symbol: symbol) }
        .onChange(of: ratings) { _, _ in selection = nil }
        .onChange(of: months) { _, _ in selection = nil }
    }

    private func money(_ value: Double?) -> String { value?.formatted(.currency(code: "USD")) ?? "—" }
    private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = selected {
                Text(p.date).font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("股价 ") + money(p.price)).font(.title3.bold()).monospacedDigit()
                if ratings {
                    Text(zip(labels, p.counts).map { $0.0 + " \($0.1)" }.joined(separator: " · ")).font(.caption).monospacedDigit()
                } else {
                    Text(L10n.text("共识 ") + money(p.mean)).font(.subheadline).monospacedDigit()
                    Text(money(p.low) + " — " + money(p.high)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(minHeight: 92, alignment: .topLeading)
    }
    private func priceSegment(for point: AnalystHistoryPoint) -> String {
        String(points.prefix { $0.date <= point.date }.filter { $0.price == nil }.count)
    }
    private func segment(for point: AnalystHistoryPoint) -> String {
        String(points.prefix { $0.date <= point.date }.filter { !$0.validTargets }.count)
    }
    private var targetsChart: some View {
        StandardLineChartEntrance { phase in
        Chart(Array(points.enumerated()), id: \.element.id) { item in
            let p = item.element
            let fraction = Double(item.offset) / Double(max(1, points.count - 1))
            if let low = p.low, let high = p.high, let mean = p.mean {
                AreaMark(x: .value("Month", p.date),
                    yStart: .value("Low", phase.value(low, fraction: fraction, domain: 0...priceCeiling)),
                    yEnd: .value("High", phase.value(high, fraction: fraction, domain: 0...priceCeiling)), series: .value("Segment", segment(for: p)))
                    .foregroundStyle(CatfolioStyle.blue.opacity(0.12))
                LineMark(x: .value("Month", p.date), y: .value("USD", phase.value(mean, fraction: fraction, domain: 0...priceCeiling)), series: .value("Series", "Consensus-" + segment(for: p)))
                    .foregroundStyle(CatfolioStyle.blue.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let price = p.price {
                LineMark(x: .value("Month", p.date), y: .value("USD", phase.value(price, fraction: fraction, domain: 0...priceCeiling, seriesIndex: 1, seriesCount: 2)), series: .value("Series", "Price-" + priceSegment(for: p)))
                    .foregroundStyle(CatfolioStyle.blue).lineStyle(StrokeStyle(lineWidth: 3))
            }
        }
        .chartYScale(domain: 0...priceCeiling)
        .chartXAxis { AxisMarks(values: axisDates) { value in AxisValueLabel { if let d = value.as(String.self) { Text(String(d.prefix(7))).font(.system(size: 9)) } } } }
        .chartXSelection(value: $selection)
        .frame(height: 250)
        }
    }
    private var ratingsChart: some View {
        StandardLineChartEntrance { phase in
        Chart {
            ForEach(Array(points.enumerated()), id: \.element.id) { item in
                let p = item.element
                ForEach(0..<4, id: \.self) { i in
                    BarMark(x: .value("Month", p.date), yStart: .value("Count", Double(p.counts.prefix(i).reduce(0, +)) / countCeiling), yEnd: .value("Count", Double(p.counts.prefix(i + 1).reduce(0, +)) / countCeiling))
                        .foregroundStyle(colors[i])
                }
                if let price = p.price {
                    LineMark(x: .value("Month", p.date), y: .value("Price", phase.value(price / priceCeiling,
                        fraction: Double(item.offset) / Double(max(1, points.count - 1)), domain: 0...1)), series: .value("Segment", priceSegment(for: p)))
                        .foregroundStyle(CatfolioStyle.blue).lineStyle(StrokeStyle(lineWidth: 3))
                }
            }
        }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                AxisGridLine()
                AxisValueLabel { if let n = value.as(Double.self) { Text("\(Int((n * countCeiling).rounded()))") } }
            }
            AxisMarks(position: .trailing, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                AxisValueLabel { if let n = value.as(Double.self) { Text("$\(Int((n * priceCeiling).rounded()))") } }
            }
        }
        .chartXAxis { AxisMarks(values: axisDates) { value in AxisValueLabel { if let d = value.as(String.self) { Text(String(d.prefix(7))).font(.system(size: 9)) } } } }
        .chartXSelection(value: $selection)
        .frame(height: 250)
        }
    }
    private var axisDates: [String] {
        let step = max(1, points.count / 4)
        return points.enumerated().filter { $0.offset % step == 0 }.map { $0.element.date }
    }
    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ratings {
                HStack { ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 3) { Circle().fill(colors[i]).frame(width: 7, height: 7); Text(labels[i]) }
                } }.font(.caption2)
            } else { Text(L10n.text("浅蓝：共识目标价 · 阴影：目标价范围")).font(.caption2).foregroundStyle(.secondary) }
            HStack { Capsule().fill(CatfolioStyle.blue).frame(width: 16, height: 3); Text(L10n.text("股价（来源月度图表）")).font(.caption2) }
        }
    }
}
