import SwiftUI

struct HoldingsHeatmapView: View {
    let holdings: [Holding]
    let dailyChanges: [String: Double]
    let isLoading: Bool
    let onSelect: (Holding) -> Void
    let onShowAll: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let maximumHoldingTiles = 14
    private let minimumIndividualFraction = 0.012

    var body: some View {
        let models = makeModels()

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("面积代表持仓市值，颜色代表今日涨跌")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if models.isEmpty {
                ContentUnavailableView(
                    "暂无持仓",
                    systemImage: "square.grid.3x3",
                    description: Text("同步持仓后会在这里显示资产分布。")
                )
                .frame(minHeight: 260)
            } else {
                GeometryReader { geometry in
                    let placements = HoldingsTreemapLayout.layout(
                        items: models.map {
                            HoldingsTreemapLayout.Item(ticker: $0.id, weight: $0.marketValue)
                        },
                        in: CGRect(origin: .zero, size: geometry.size)
                    )

                    ZStack(alignment: .topLeading) {
                        ForEach(placements, id: \.sourceIndex) { placement in
                            let frame = placement.frame.insetBy(dx: 2, dy: 2)
                            let model = models[placement.sourceIndex]

                            HoldingsHeatmapTile(
                                model: model,
                                fraction: placement.fraction,
                                size: frame.size,
                                action: { select(model) }
                            )
                            .frame(width: max(0, frame.width), height: max(0, frame.height))
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(height: 390)
                .transaction { transaction in transaction.animation = nil }

                HStack(spacing: 7) {
                    Circle()
                        .fill(CatfolioPalette.rose500)
                        .frame(width: 7, height: 7)
                    Text("下跌")
                    Spacer()
                    Text("— 暂无行情")
                    Spacer()
                    Text("上涨")
                    Circle()
                        .fill(CatfolioPalette.green500)
                        .frame(width: 7, height: 7)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("查看全部持仓", systemImage: "list.bullet", action: onShowAll)
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        colorScheme == .light ? CatfolioPalette.muted100 : CatfolioPalette.neutral800,
                        in: Capsule()
                    )
                    .buttonStyle(.plain)
            }
        }
    }

    private func makeModels() -> [HoldingsHeatmapTile.Model] {
        let valid = holdings
            .filter { $0.marketValue.isFinite && $0.marketValue > 0 }
            .sorted {
                if $0.marketValue == $1.marketValue {
                    $0.ticker.localizedStandardCompare($1.ticker) == .orderedAscending
                } else {
                    $0.marketValue > $1.marketValue
                }
            }
        let total = valid.reduce(0) { $0 + $1.marketValue }
        guard total.isFinite, total > 0 else { return [] }

        let visible = Array(
            valid.enumerated()
                .filter { index, holding in
                    index < 4 || holding.marketValue / total >= minimumIndividualFraction
                }
                .prefix(maximumHoldingTiles)
                .map(\.element)
        )
        let visibleTickers = Set(visible.map(\.ticker))
        let remainder = valid.filter { !visibleTickers.contains($0.ticker) }

        var models = visible.map { holding in
            HoldingsHeatmapTile.Model(
                id: holding.ticker,
                content: .holding(holding),
                marketValue: holding.marketValue,
                changePercent: holding.todayChangePercent
                    ?? dailyChanges[holding.ticker.uppercased()]
            )
        }
        let remainderValue = remainder.reduce(0) { $0 + $1.marketValue }
        if remainderValue > 0 {
            models.append(
                HoldingsHeatmapTile.Model(
                    id: "__remainder__",
                    content: .remainder(count: remainder.count),
                    marketValue: remainderValue,
                    changePercent: nil
                )
            )
        }
        return models
    }

    private func select(_ model: HoldingsHeatmapTile.Model) {
        if let holding = model.holding {
            onSelect(holding)
        } else {
            onShowAll()
        }
    }
}
