import SwiftUI

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
    /// Lines the reader turned off. Every line starts on.
    @State private var hidden: Set<String> = []
    private var labels: [String] { [L10n.text("卖出"), L10n.text("持有"), L10n.text("买入"), L10n.text("强烈买入")] }
    /// Opaque, because the ratings stack by painting over one another.
    private let colors: [Color] = [
        Color(red: 0.937, green: 0.384, blue: 0.384), Color(red: 1.000, green: 0.800, blue: 0.290),
        Color(red: 0.561, green: 0.835, blue: 0.561), Color(red: 0.204, green: 0.659, blue: 0.325),
    ]
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
                        if ratings || points.contains(where: { $0.price != nil || $0.validTargets }) { chart } else {
                            Text(L10n.text("来源暂无目标价和股价，可切换查看推荐建议。"))
                                .foregroundStyle(.secondary).frame(height: 160)
                        }
                        legend
                    }
                    .padding(20)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.06)) }
                    if let snapshot {
                        Link("MarketBeat · " + symbol + " ↗", destination: URL(string: snapshot.sourceURL)!)
                            .font(.caption)
                    }
                } else {
                    ContentUnavailableView(L10n.text("暂无历史快照"), systemImage: "chart.xyaxis.line", description: Text(AnalystHistorySnapshot.unavailableReason(symbol: symbol)))
                }
            }.padding(20)
        }
        .appPageBackground(Color(uiColor: .systemGroupedBackground))
        .softTopScrollEdge()
        .appPageBackground().navigationTitle(L10n.text("分析师历史回顾"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { dismiss() } } }
        .task(id: symbol) { snapshot = AnalystHistorySnapshot.load(symbol: symbol) }
        .onChange(of: ratings) { _, _ in
            selection = nil
            hidden = []
        }
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
    // MARK: Chart

    /// One drawn line and its legend chip.
    private struct Line: Identifiable {
        let id: String
        let title: String
        let color: Color
        var lineWidth: CGFloat = 2
        var dash: [CGFloat] = []
        /// Filled down to zero, drawn largest first, so the ratings stack.
        var fill: Color? = nil
        let value: (AnalystHistoryPoint) -> Double?
        let text: (AnalystHistoryPoint) -> String
    }

    private var lines: [Line] {
        if ratings {
            // Cumulative from the bottom: sell, then hold above it, and so on.
            // Each is filled to zero and drawn over the taller ones.
            return (0..<4).reversed().map { index in
                Line(id: "rating-\(index)", title: labels[index], color: colors[index], lineWidth: 0,
                     fill: colors[index],
                     value: { $0.hasRatings ? Double($0.counts.prefix(index + 1).reduce(0, +)) : nil },
                     text: { $0.hasRatings ? "\($0.counts[index])" : "—" })
            }
        }
        return [
            Line(id: "price", title: L10n.text("股价"), color: CatfolioStyle.blue, lineWidth: 2.5,
                 value: \.price, text: { money($0.price) }),
            Line(id: "mean", title: L10n.text("共识目标价"), color: Self.consensusColor, lineWidth: 2,
                 value: { $0.validTargets ? $0.mean : nil }, text: { money($0.validTargets ? $0.mean : nil) }),
            Line(id: "high", title: L10n.text("最高目标价"), color: CatfolioTheme.positive, lineWidth: 1.5, dash: [4, 3],
                 value: { $0.validTargets ? $0.high : nil }, text: { money($0.validTargets ? $0.high : nil) }),
            Line(id: "low", title: L10n.text("最低目标价"), color: CatfolioTheme.danger, lineWidth: 1.5, dash: [4, 3],
                 value: { $0.validTargets ? $0.low : nil }, text: { money($0.validTargets ? $0.low : nil) }),
        ]
    }

    private static let consensusColor = Color(red: 1.000, green: 0.584, blue: 0.000)

    private func date(_ point: AnalystHistoryPoint) -> Date {
        DayDateCodec.date(from: point.date) ?? .distantPast
    }

    /// A line breaks where the source left a month empty rather than joining
    /// across it.
    private func series(_ line: Line) -> [StandardLineChartSeries] {
        var runs: [[StandardLineChartPoint]] = [[]]
        for point in points {
            if let value = line.value(point), value.isFinite {
                runs[runs.count - 1].append(StandardLineChartPoint(id: "\(line.id)|\(point.date)", date: date(point), value: value))
            } else if !(runs.last?.isEmpty ?? true) {
                runs.append([])
            }
        }
        return runs.enumerated().filter { !$0.element.isEmpty }.map { index, run in
            StandardLineChartSeries(
                id: "\(line.id)|\(index)", points: run, color: line.color,
                lineWidth: line.fill == nil ? line.lineWidth : 0.01, dash: line.dash,
                areaFill: line.fill, areaBaseline: line.fill == nil ? nil : 0,
                selectionRadius: line.fill == nil ? 3 : 0, latestPointRadius: nil,
                latestPointUsesGlass: false)
        }
    }

    private var chart: some View {
        let visible = lines.filter { !hidden.contains($0.id) }
        let ceiling = ratings ? countCeiling : priceCeiling
        let drawn = visible.flatMap(series)
        return StandardLineChart(
            series: drawn,
            interactionDates: points.map(date),
            domain: 0...ceiling,
            yTicks: [0, ceiling / 2, ceiling],
            transitionKey: "\(ratings)|\(months)|\(hidden.sorted().joined(separator: ","))",
            appearanceID: "analyst-history|\(symbol)",
            selectedDate: selection.flatMap { DayDateCodec.date(from: $0) },
            selectionIndicatorLabel: selected.map { String($0.date.prefix(7)) },
            selectionSeriesIDs: ratings ? [] : Set(drawn.map(\.id)),
            yAxisLabel: { ratings ? "\(Int($0.rounded()))" : "$\(Int($0.rounded()))" },
            xAxisLabel: { DayDateCodec.string(from: $0).prefix(7).description },
            onSelect: { date in
                let text = DayDateCodec.string(from: date)
                selection = points.first { $0.date == text }?.date
            },
            onInteractionEnded: { _ in selection = nil }
        )
        .frame(height: 250)
        .accessibilityLabel(L10n.text(ratings ? "推荐建议历史" : "目标价历史"))
    }

    // MARK: Legend

    /// One chip per line with its value at the month being read; a tap shows
    /// or hides the line. The same chips as the cycle comparison.
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(ratings ? Array(lines.reversed()) : lines) { line in
                chip(line)
            }
        }
    }

    private func chip(_ line: Line) -> some View {
        let isShown = !hidden.contains(line.id)
        let valueText = selected.map(line.text) ?? "—"
        return Button {
            if isShown { hidden.insert(line.id) } else { hidden.remove(line.id) }
            selection = nil
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(line.color, lineWidth: 2)
                    .background(Circle().fill(isShown ? line.color : .clear))
                    .frame(width: 10, height: 10)
                Text(line.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text(valueText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(isShown ? CatfolioTheme.primaryText : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(isShown ? 0.07 : 0.03)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.title)
        .accessibilityValue((isShown ? L10n.text("已显示") : L10n.text("已隐藏")) + " · " + valueText)
    }
}
