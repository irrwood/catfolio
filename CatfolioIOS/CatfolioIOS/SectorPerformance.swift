import SwiftUI
import Charts

struct SectorPerformanceDefinition: Identifiable {
    let symbol: String
    let titleKey: L10n.Message
    let icon: String
    var id: String { symbol }
    var title: String { L10n.text(titleKey) }
    var ink: Color { symbol == "XLV" ? .black : .white }
    var color: Color { Color(uiColor: SectorRotationChartView.color(symbol)) }

    // Preserve the Research page's eleven proxies and their order.
    static let all: [Self] = [
        .init(symbol: "XLK", titleKey: "科技", icon: "cpu"),
        .init(symbol: "XLV", titleKey: "医疗", icon: "cross.case.circle.fill"),
        .init(symbol: "XLF", titleKey: "金融", icon: "dollarsign.circle.fill"),
        .init(symbol: "XLE", titleKey: "能源", icon: "fuelpump.circle.fill"),
        .init(symbol: "XLI", titleKey: "工业", icon: "gearshape.circle.fill"),
        .init(symbol: "XLY", titleKey: "可选消费", icon: "cart.circle.fill"),
        .init(symbol: "XLP", titleKey: "必需消费", icon: "basket.fill"),
        .init(symbol: "XLU", titleKey: "公用事业", icon: "bolt.circle.fill"),
        .init(symbol: "XLRE", titleKey: "房地产", icon: "house.circle.fill"),
        .init(symbol: "XLB", titleKey: "材料", icon: "shippingbox.circle.fill"),
        .init(symbol: "XLC", titleKey: "通信", icon: "antenna.radiowaves.left.and.right.circle.fill")
    ]
}

@MainActor @Observable
final class SectorPerformanceStore {
    private(set) var markets: [String: ResearchMarketSnapshot] = [:]
    private(set) var isLoading = false

    var dateRange: String? {
        let dates = Set(markets.values.compactMap { $0.latest?.id }).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        return first == last ? first : "\(first)–\(last)"
    }

    func merge(_ histories: [String: [String: Double]]) {
        for definition in SectorPerformanceDefinition.all {
            guard let history = histories[definition.symbol] else { continue }
            let snapshot = ResearchMarketSnapshot(id: definition.symbol, title: definition.title, history: history)
            // Partial/failed responses keep the previous usable close pair.
            guard snapshot.changePercent != nil else { continue }
            if let previous = markets[definition.symbol]?.latest?.id,
               let next = snapshot.latest?.id, next < previous { continue }
            markets[definition.symbol] = snapshot
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -14, to: end) ?? end
        let symbols = SectorPerformanceDefinition.all.map(\.symbol)
        let client = LocalMarketDataClient()
        let from = DayDateCodec.string(from: start), to = DayDateCodec.string(from: end)
        let cached = await client.historicalCloses(symbols: symbols, from: from, to: to, cachedOnly: true)
        guard !Task.isCancelled else { return }
        merge(cached)
        let latest = await client.historicalCloses(symbols: symbols, from: from, to: to)
        guard !Task.isCancelled else { return }
        merge(latest)
    }
}

struct SectorPerformancePanel: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let store: SectorPerformanceStore
    let rotation: SectorRotationSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                     count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(SectorPerformanceDefinition.all) { definition in
                    NavigationLink {
                        SectorPerformanceDetailView(definition: definition, store: store, rotation: rotation)
                    } label: {
                        SectorPerformanceCard(definition: definition, market: store.markets[definition.symbol])
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(definition.title) · \(definition.symbol)")
                    .accessibilityValue(store.markets[definition.symbol]?.changePercent.map { String(format: "%+.1f%%", $0) } ?? L10n.text("暂无数据"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("sector-performance.\(definition.symbol)")
                }
            }
            if let dateRange = store.dateRange {
                Text(L10n.text("板块表现")) + Text(" · ") + Text(L10n.text("数据日期 \(dateRange)"))
            } else if store.isLoading {
                ChartSkeletonShape(width: 140, height: 11).chartLoadingShimmer()
            }
            Text(L10n.text("行业 ETF 作为美国板块代理；数值为最近两个可用收盘价的变化，非盘中实时行情。来源：现有 Yahoo 行情服务及本机缓存。"))
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(Color.primary.opacity(0.45))
    }
}

struct SectorPerformanceCard: View {
    let definition: SectorPerformanceDefinition
    let market: ResearchMarketSnapshot?

    var body: some View {
        SectorGlassCard(
            title: definition.title, icon: definition.icon, caption: definition.symbol,
            value: market?.changePercent.map { String(format: "%+.1f%%", abs($0) < 0.05 ? 0 : $0) } ?? "—",
            tint: definition.color
        )
    }
}

/// Shared industry tile for market performance and portfolio attribution.
struct SectorGlassCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let title: String
    let icon: String
    let caption: String
    let value: String
    let tint: Color
    var valueColor: Color = .primary
    var usesGlass = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
    }

    var body: some View {
        surface
            .contentShape(shape)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                // One line: an English caption ("This year ~£14") wrapped
                // and pushed this card's title and value out of line with
                // its neighbour's.
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                // Two lines reserved either way, so a card whose title wraps
                // in English keeps its value level with the one beside it.
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(typeSize.isAccessibilitySize ? 8 : 2,
                               reservesSpace: !typeSize.isAccessibilitySize)
                Text(value)
                    .font(.body.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(CatfolioTheme.primaryText)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
    }

    @ViewBuilder private var surface: some View {
        if !usesGlass {
            content.background(SettingsTemplate.card, in: shape)
        } else if reduceTransparency {
            content.background(SettingsTemplate.card, in: shape)
                .overlay(shape.strokeBorder(tint, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint.opacity(0.35)).interactive(), in: shape)
        } else {
            content.background(tint.opacity(0.18), in: shape)
                .background(.thinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.55), lineWidth: 1))
        }
    }
}

extension SectorPerformanceDefinition {
}

private struct SectorPerformanceDetailView: View {
    let definition: SectorPerformanceDefinition
    let store: SectorPerformanceStore
    let rotation: SectorRotationSnapshot?
    private var market: ResearchMarketSnapshot? { store.markets[definition.symbol] }

    var body: some View {
        List {
            Section {
                LabeledContent(definition.title, value: definition.symbol)
                if let market, let latest = market.latest {
                    LabeledContent(L10n.text("收盘")) {
                        Text(latest.value, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }
                    if let change = market.changePercent {
                        LabeledContent(L10n.text("板块表现"), value: String(format: "%+.1f%%", change))
                    }
                    Text(L10n.text("数据日期 \(latest.id)")).foregroundStyle(.secondary)
                } else { Text(L10n.text("暂无数据")).foregroundStyle(.secondary) }
            }
            if let market, market.points.count > 1 {
                Section {
                    let domain = StandardLineChartEntrancePhase.domain(market.points.map(\.value))
                    StandardLineChartEntrance(appearanceID: "sector-performance|\(definition.symbol)") { phase in
                    Chart(Array(market.points.enumerated()), id: \.element.id) { item in
                        LineMark(x: .value(L10n.text("日期"), DayDateCodec.date(from: item.element.id) ?? .distantPast),
                                 y: .value(L10n.text("收盘"), phase.value(item.element.value,
                                    fraction: Double(item.offset) / Double(market.points.count - 1), domain: domain)))
                            .foregroundStyle(definition.color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    .chartYScale(domain: domain)
                    .frame(height: 180)
                    }
                } footer: {
                    Text(L10n.text("行业 ETF 作为美国板块代理；数值为最近两个可用收盘价的变化，非盘中实时行情。来源：现有 Yahoo 行情服务及本机缓存。"))
                }
            }
            if let rotation, let sector = rotation.sectors.first(where: { $0.symbol == definition.symbol }) {
                Section(L10n.text("行业轮动")) {
                    LabeledContent(L10n.text("中期相对强弱"), value: String(format: "%+.1f%%", sector.relativeTrend*100))
                    LabeledContent(L10n.text("近 1 月相对动量"), value: String(format: "%+.1f%%", sector.relativeMomentum*100))
                    Text(sector.displayQuadrant)
                    Text(sector.explanation).foregroundStyle(.secondary)
                    Text(L10n.text("数据截至 \(rotation.asOf)（纽约）")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .softTopScrollEdge()
        .navigationTitle(definition.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sector-performance-detail.\(definition.symbol)")
    }
}
