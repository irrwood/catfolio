import SwiftUI

struct HoldingsHeatmapTile: View {
    struct Model: Identifiable {
        enum Content {
            case holding(Holding)
            case exposure(ETFLookThroughRow, directHolding: Holding?)
            case remainder(count: Int)
        }

        let id: String
        let content: Content
        let marketValue: Double
        let portfolioFraction: Double
        let changePercent: Double?
        let performanceTitle: String

        var holding: Holding? {
            switch content {
            case let .holding(holding): holding
            case let .exposure(_, directHolding): directHolding
            case .remainder: nil
            }
        }

        var isRemainder: Bool {
            if case .remainder = content { return true }
            return false
        }
    }

    let model: Model
    let fraction: Double
    let size: CGSize
    let action: (() -> Void)?

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
        Group {
            if let action {
                Button(action: action) {
                    tileBody
                }
                .buttonStyle(.plain)
            } else {
                tileBody
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var tileBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tileRadius)
                .fill(backgroundColor)

            if usesMicroSeparator {
                RoundedRectangle(cornerRadius: tileRadius)
                    .strokeBorder(Color(uiColor: .systemBackground), lineWidth: 0.75)
            }

            tileContent
                .padding(tilePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect(cornerRadius: tileRadius))
    }

    @ViewBuilder
    private var tileContent: some View {
        switch model.content {
        case let .holding(holding):
            securityContent(ticker: holding.ticker, logoSymbol: holding.logoSymbol)

        case let .exposure(row, _):
            securityContent(ticker: row.ticker, logoSymbol: row.logoSymbol)

        case .remainder:
            Color.clear
        }
    }

    private func securityContent(ticker: String, logoSymbol: String?) -> some View {
        VStack(spacing: showsLogo ? 6 : 3) {
            if showsLogo {
                AssetLogo(ticker: ticker, logoSymbol: logoSymbol)
            }

            if showsTicker {
                Text(ticker)
                    .font(showsLogo ? .headline : .caption.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }

            if showsChange, let change = model.changePercent {
                Text(DisplayFormat.percent(change))
                    .appNumber(.callout, weight: .bold)
                    .foregroundStyle(changeColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if showsWeight {
                Text("仓位 \(DisplayFormat.percent(fraction * 100, signed: false))")
                    .appNumber(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var tileRadius: CGFloat {
        let shortestSide = max(0, min(size.width, size.height))
        if shortestSide < 16 { return shortestSide * 0.06 }
        if shortestSide < 60 { return min(8, shortestSide * 0.2) }
        return 11
    }

    private var usesMicroSeparator: Bool {
        min(size.width, size.height) < 24
    }

    private var tilePadding: CGFloat {
        min(size.width, size.height) < 72 ? 5 : 9
    }

    private var changeText: String {
        model.changePercent.map { DisplayFormat.percent($0) } ?? "暂无行情"
    }

    private var changeColor: Color {
        guard let change = model.changePercent, abs(change) >= 0.005 else { return .secondary }
        return change > 0 ? CatfolioPalette.green500 : CatfolioPalette.rose500
    }

    private var backgroundColor: Color {
        if model.isRemainder {
            return Color(uiColor: .secondarySystemFill)
        }
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
            return "\(holding.shortName)，仓位 \(DisplayFormat.percent(fraction * 100, signed: false))，\(model.performanceTitle) \(changeText)"
        case let .exposure(row, directHolding):
            let name = CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name)
            let source = directHolding == nil ? "ETF 穿透持仓" : "直接与 ETF 合并持仓"
            return "\(name)，\(source)，仓位 \(DisplayFormat.percent(fraction * 100, signed: false))，\(model.performanceTitle) \(changeText)"
        case let .remainder(count):
            return "其他 \(count) 项持仓，打开明细"
        }
    }
}
