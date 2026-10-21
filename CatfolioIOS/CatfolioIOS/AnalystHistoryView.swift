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
    private var chartData: AnalystHistoryChartData {
        AnalystHistoryChartData(points: snapshot?.points ?? [], ratings: ratings, months: months, hidden: hidden)
    }
    private var points: [AnalystHistoryPoint] { chartData.points }
    private var selected: AnalystHistoryPoint? { points.first { $0.date == selection } ?? points.last }

    init(symbol: String, initialRatings: Bool = false) {
        self.symbol = symbol
        _ratings = State(initialValue: initialRatings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(symbol.uppercased() + " · " + L10n.text("历史快照"))
                    .appText(.heading, weight: .semibold)
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
                        if ratings {
                            Text(L10n.text(chartData.hasPrices
                                ? "左轴：评级数量 · 右轴：股价 USD" : "评级数量"))
                                .appText(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if ratings || points.contains(where: { $0.price != nil || $0.validTargets }) { chart } else {
                            Text(L10n.text("来源暂无目标价和股价，可切换查看推荐建议。"))
                                .foregroundStyle(.secondary).frame(height: 160)
                        }
                        legend
                        if ratings {
                            Text(L10n.text(chartData.hasPrices ? "股价（来源月度图表）" : "来源暂无同期股价。"))
                                .appText(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .settingsCardSurface(cornerRadius: CatfolioStyle.cardRadius)
                    if let snapshot {
                        Link("MarketBeat · " + symbol + " ↗", destination: URL(string: snapshot.sourceURL)!)
                            .appText(.caption)
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
        .toolbar { HoldingDetailCloseToolbar { dismiss() } }
        .task(id: symbol) { snapshot = AnalystHistorySnapshot.load(symbol: symbol) }
        .onChange(of: ratings) { _, _ in
            selection = nil
            hidden = []
        }
        .onChange(of: months) { _, _ in selection = nil }
    }

    private func money(_ value: Double?) -> String { AnalystHistoryChartData.money(value) }
    private var readout: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = selected {
                Text(p.date).appText(.caption).foregroundStyle(.secondary)
                FinancialText(L10n.text("股价 ") + money(p.price)).appNumber(.title, weight: .semibold)
                if ratings {
                    Text(zip(labels, p.counts).map { $0.0 + " \($0.1)" }.joined(separator: " · ")).appNumber(.caption)
                } else {
                    FinancialText(L10n.text("共识 ") + money(p.mean)).appNumber(.callout)
                    FinancialText(money(p.low) + " — " + money(p.high)).appText(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(minHeight: 92, alignment: .topLeading)
    }
    private var chart: some View {
        AnalystHistoryPlot(
            data: chartData,
            symbol: symbol,
            transitionKey: "\(ratings)|\(months)|\(hidden.sorted().joined(separator: ","))",
            selectedDate: selection.flatMap { DayDateCodec.date(from: $0) },
            onSelect: { date in
                let text = DayDateCodec.string(from: date)
                selection = points.first { $0.date == text }?.date
            },
            onInteractionEnded: { selection = nil }
        )
    }

    // MARK: Legend

    /// One chip per line with its value at the month being read; a tap shows
    /// or hides the line. The same chips as the cycle comparison.
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(chartData.legendLines) { line in
                chip(line)
            }
        }
    }

    private func chip(_ line: AnalystHistoryChartLine) -> some View {
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
                    .appText(.caption, weight: .medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                FinancialText(valueText)
                    .appNumber(.caption, weight: .semibold)
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
        .accessibilityIdentifier("analyst-history-legend-\(line.id)")
        .accessibilityLabel(line.title)
        .accessibilityValue((isShown ? L10n.text("已显示") : L10n.text("已隐藏")) + " · " + valueText)
    }
}
