import SwiftUI

struct HoldingsHeatmapTile: View {
    struct Model: Identifiable {
        enum Content {
            case holding(Holding)
            case remainder(count: Int)
        }

        let id: String
        let content: Content
        let marketValue: Double
        let changePercent: Double?

        var holding: Holding? {
            guard case let .holding(holding) = content else { return nil }
            return holding
        }
    }

    let model: Model
    let fraction: Double
    let size: CGSize
    let action: () -> Void

    private var showsTicker: Bool {
        size.width >= 46 && size.height >= 40
    }

    private var showsChange: Bool {
        size.width >= 62 && size.height >= 58
    }

    private var showsLogo: Bool {
        size.width >= 88 && size.height >= 92
    }

    private var showsWeight: Bool {
        size.width >= 108 && size.height >= 124
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: tileRadius)
                    .fill(backgroundColor)

                tileContent
                    .padding(tilePadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect(cornerRadius: tileRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var tileContent: some View {
        switch model.content {
        case let .holding(holding):
            VStack(spacing: showsLogo ? 6 : 3) {
                if showsLogo {
                    AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol)
                }

                if showsTicker {
                    Text(holding.ticker)
                        .font(showsLogo ? .headline : .caption.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }

                if showsChange {
                    Text(changeText)
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(changeColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                if showsWeight {
                    Text("仓位 \(DisplayFormat.percent(fraction * 100, signed: false))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

        case let .remainder(count):
            VStack(spacing: 3) {
                Image(systemName: "ellipsis")
                    .font(.headline)
                if showsTicker {
                    Text("其他")
                        .font(.caption.bold())
                    Text("\(count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tileRadius: CGFloat {
        min(size.width, size.height) < 60 ? 8 : 11
    }

    private var tilePadding: CGFloat {
        min(size.width, size.height) < 72 ? 5 : 9
    }

    private var changeText: String {
        model.changePercent.map { DisplayFormat.percent($0) } ?? "—"
    }

    private var changeColor: Color {
        guard let change = model.changePercent, abs(change) >= 0.005 else { return .secondary }
        return change > 0 ? CatfolioPalette.green500 : CatfolioPalette.rose500
    }

    private var backgroundColor: Color {
        guard let change = model.changePercent, abs(change) >= 0.005 else {
            return CatfolioPalette.neutral100
        }
        let intensity = min(abs(change) / 3, 1)
        let opacity = 0.12 + intensity * 0.22
        return (change > 0 ? CatfolioPalette.green500 : CatfolioPalette.rose500).opacity(opacity)
    }

    private var accessibilityText: String {
        switch model.content {
        case let .holding(holding):
            return "\(holding.shortName)，仓位 \(DisplayFormat.percent(fraction * 100, signed: false))，今日 \(changeText)"
        case let .remainder(count):
            return "其他 \(count) 项持仓，打开持仓明细"
        }
    }
}
