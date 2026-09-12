import SwiftUI

struct HoldingsHeatmapTile: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.reportsHeatmapTileFrames) private var reportsFrame
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
        var performancePeriod: HoldingPerformancePeriod = .today
        var isEstimated = false
        var detailItems: [Model] = []

        var leafItems: [Model] {
            isRemainder ? detailItems.flatMap(\.leafItems) : [self]
        }

        struct PerformanceSummary {
            let amount: Double
            let referenceValue: Double
            let knownCount: Int
            let totalCount: Int
            let isEstimated: Bool
            var isComplete: Bool { totalCount > 0 && knownCount == totalCount }
            /// The return over whatever is priced, not over everything.
            ///
            /// Requiring every leaf meant the merged block — which collects the
            /// smallest holdings, the ones most often missing a quote — showed
            /// nothing at all whenever a single one of thirty-odd lacked a
            /// price. A return over the priced majority is worth more than a
            /// blank, and `isComplete` still says whether it covers everything.
            var percent: Double? {
                referenceValue > 0 ? amount / referenceValue * 100 : nil
            }
        }

        func performanceSummary(dailyChanges: [String: Double] = [:]) -> PerformanceSummary {
            let leaves = leafItems
            var amount = 0.0
            var referenceValue = 0.0
            var knownCount = 0
            for item in leaves {
                guard item.performancePeriod == performancePeriod,
                      item.marketValue.isFinite, item.marketValue > 0 else { continue }
                let reference: Double
                if item.performancePeriod == .holdingPeriod, let holding = item.holding,
                   !item.isEstimated {
                    guard holding.publicDisclosure == nil, holding.averageCost > 0,
                          holding.unrealized.isFinite else { continue }
                    reference = item.marketValue - holding.unrealized
                } else {
                    let change = item.changePercent ?? (item.performancePeriod == .today ? dailyChanges[item.id.uppercased()] : nil)
                    guard let change, change.isFinite, change > -100 else { continue }
                    // Today's return is based on previous-close value; the
                    // holding-period return is based on allocated cost.
                    reference = item.marketValue / (1 + change / 100)
                }
                guard reference.isFinite, reference > 0 else { continue }
                amount += item.marketValue - reference
                referenceValue += reference
                knownCount += 1
            }
            return PerformanceSummary(amount: amount, referenceValue: referenceValue,
                                      knownCount: knownCount, totalCount: leaves.count,
                                      isEstimated: leaves.contains(where: \.isEstimated))
        }

        static func remainder(id: String, items: [Model]) -> Model {
            let leaves = items.flatMap(\.leafItems)
            var result = Model(
                id: id, content: .remainder(count: leaves.count),
                marketValue: items.reduce(0) { $0 + $1.marketValue },
                portfolioFraction: items.reduce(0) { $0 + $1.portfolioFraction },
                changePercent: nil, performanceTitle: items.first?.performanceTitle ?? "",
                performancePeriod: items.first?.performancePeriod ?? .today,
                detailItems: leaves
            )
            let summary = result.performanceSummary()
            result = Model(id: result.id, content: result.content, marketValue: result.marketValue,
                           portfolioFraction: result.portfolioFraction, changePercent: summary.percent,
                           performanceTitle: result.performanceTitle, performancePeriod: result.performancePeriod,
                           isEstimated: summary.isEstimated, detailItems: leaves)
            return result
        }

        /// A holding to open the security sheet with, for every row.
        ///
        /// A look-through constituent held only inside an ETF has no direct
        /// position — no shares, no cost — which is why half the rows in a
        /// sector sheet used to be inert while looking exactly like the rows
        /// that were not. It does have a ticker, a return and a real exposure,
        /// and that is enough for the price, volume and options sections.
        ///
        /// `shares == 0` is the signal: the detail sheet leaves its position
        /// blocks out rather than filling them with zeros, and no cost basis is
        /// invented for a position that does not exist.
        var detailHolding: Holding? {
            if let holding { return holding }
            guard case let .exposure(row, _) = content else { return nil }
            return Holding(
                ticker: row.ticker,
                logoSymbol: row.logoSymbol,
                displayName: row.name,
                sector: row.sector,
                source: nil,
                shares: 0,
                averageCost: 0,
                costCurrency: nil,
                quotePrice: 0,
                quoteCurrency: nil,
                todayChangePercent: performancePeriod == .today ? changePercent : nil,
                marketValue: marketValue,
                weight: portfolioFraction,
                unrealized: 0,
                unrealizedPercent: 0,
                fxPnl: nil,
                fxPnlPercent: nil,
                fxPnlStatus: nil,
                fxPnlSource: nil
            )
        }

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

    static func canShowIdentifier(in size: CGSize) -> Bool {
        (size.width >= 40 && size.height >= 22) || min(size.width, size.height) >= 24
    }

    static func usesCapsule(in size: CGSize) -> Bool {
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        return shortSide > 0 && shortSide <= 16 && longSide >= shortSide * 4
    }

    static func inset(in size: CGSize, maximum: CGFloat = 2) -> CGFloat {
        // Keep a consistent gutter; clamp only when a sliver cannot afford it.
        min(maximum, max(0, min(size.width, size.height)) / 4)
    }

    private var showsTicker: Bool {
        size.width >= 40 && size.height >= 22
    }

    private var showsChange: Bool {
        size.width >= 44 && size.height >= 44
    }

    private var showsLogo: Bool {
        size.width >= 88 && size.height >= 112
    }

    /// Wherever a return is shown, so is the weight. These were 8pt apart in
    /// height, which is why most mid-sized tiles carried one figure and not the
    /// pair; the weight's own scale drops instead of the tile going without it.
    private var showsWeight: Bool {
        showsChange
    }

    private var identifierScale: TypeScale {
        let side = min(size.width, size.height)
        if side >= 160 { return .title }
        if side >= 110 { return .heading }
        if side >= 80 { return .body }
        if side >= 56 { return .label }
        if side >= 32 { return .caption }
        return .nano
    }

    private var returnScale: TypeScale {
        let side = min(size.width, size.height)
        if side >= 160 { return .heading }
        if side >= 110 { return .subheading }
        if side >= 80 { return .callout }
        return .label
    }

    /// A step below what it was at every size. The weight is the secondary
    /// figure of the two and only has to be legible, not balanced against the
    /// return, and giving the pair room matters more than its own size.
    private var detailScale: TypeScale {
        let side = min(size.width, size.height)
        if side >= 160 { return .micro }
        if side >= 80 { return .nano }
        return .nano
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
        .background {
            if reportsFrame {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HeatmapTileFramesKey.self,
                        value: [proxy.frame(in: .named(HeatmapTileFramesKey.space))]
                    )
                }
            }
        }
    }

    private var tileBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tileRadius, style: tileCornerStyle)
                .fill(backgroundColor)

            if usesMicroSeparator {
                RoundedRectangle(cornerRadius: tileRadius, style: tileCornerStyle)
                    .strokeBorder(Color(uiColor: .systemBackground), lineWidth: 0.75)
            }

            tileContent
                .padding(tilePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: tileRadius, style: tileCornerStyle))
        .contentShape(RoundedRectangle(cornerRadius: tileRadius, style: tileCornerStyle))
    }

    @ViewBuilder
    private var tileContent: some View {
        switch model.content {
        case let .holding(holding):
            securityContent(ticker: holding.ticker, logoSymbol: holding.logoSymbol)

        case let .exposure(row, _):
            securityContent(ticker: row.ticker, logoSymbol: row.logoSymbol)

        case .remainder:
            let summary = model.performanceSummary()
            VStack(spacing: 3) {
                Text(L10n.text("其他"))
                    .appText(identifierScale, weight: .semibold)
                performanceLabels(change: summary.percent)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.65)
        }
    }

    @ViewBuilder
    private func securityContent(ticker: String, logoSymbol: String?) -> some View {
        if !showsChange && !showsLogo {
            if showsTicker {
                Text(ticker)
                    .appText(identifierScale, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else if Self.canShowIdentifier(in: size) {
                AssetLogo(ticker: ticker, logoSymbol: logoSymbol, size: min(22, min(size.width, size.height) - 6))
            }
        } else {
            VStack(spacing: showsLogo ? 6 : 3) {
                if showsLogo {
                    AssetLogo(ticker: ticker, logoSymbol: logoSymbol)
                }

                if showsTicker {
                    Text(ticker)
                        .appText(identifierScale, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }

                performanceLabels(change: model.changePercent)
            }
        }
    }

    /// The return sits above the weight, always.
    ///
    /// The weight used to slide up into the return's slot on a holding with no
    /// quote, so the top figure on one tile was a return and on the next one a
    /// weight — the same position meaning two different things. The row is held
    /// instead. Hidden rather than filled with a dash: a dash reads as zero,
    /// and an empty slot reads as missing, which is what it is.
    @ViewBuilder
    private func performanceLabels(change: Double?) -> some View {
        if showsChange {
            if let change {
                Text(DisplayFormat.percent(change))
                    .appNumber(returnScale, weight: .bold)
                    .foregroundStyle(changeColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            } else {
                Text(DisplayFormat.percent(0))
                    .appNumber(returnScale, weight: .bold)
                    .lineLimit(1)
                    .hidden()
            }
        }
        if showsWeight {
            Text(DisplayFormat.percent(fraction * 100, signed: false))
                .appNumber(detailScale)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var tileRadius: CGFloat {
        let shortestSide = max(0, min(size.width, size.height))
        if Self.usesCapsule(in: size) { return shortestSide / 2 }
        return min(11, shortestSide * 0.25)
    }

    private var tileCornerStyle: RoundedCornerStyle {
        Self.usesCapsule(in: size) ? .circular : .continuous
    }

    private var usesMicroSeparator: Bool {
        min(size.width, size.height) < 24
    }

    private var tilePadding: CGFloat {
        if min(size.width, size.height) < 48 { return 3 }
        return min(size.width, size.height) < 72 ? 5 : 9
    }

    private var changeText: String {
        model.changePercent.map { (model.isEstimated ? "≈" : "") + DisplayFormat.percent($0) } ?? L10n.text("暂无行情")
    }

    private var changeColor: Color {
        guard let change = model.changePercent, abs(change) >= 0.005 else { return .secondary }
        return change > 0 ? CatfolioPalette.green500 : CatfolioPalette.rose500
    }

    private var backgroundColor: Color {
        guard let change = model.changePercent, abs(change) >= 0.005 else {
            return CatfolioTheme.neutralFill
        }
        let intensity = min(abs(change) / 3, 1)
        let opacity = 0.12 + intensity * 0.22
        return (change > 0 ? CatfolioPalette.green500 : CatfolioPalette.rose500).opacity(opacity)
    }

    private var accessibilityText: String {
        switch model.content {
        case let .holding(holding):
            return L10n.text("\(holding.shortName)，占组合 \(DisplayFormat.percent(fraction * 100, signed: false))，\(model.performanceTitle) \(changeText)")
        case let .exposure(row, directHolding):
            let name = CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name)
            let source = directHolding == nil ? "ETF 穿透持仓" : "直接与 ETF 合并持仓"
            return L10n.text("\(name)，\(source)，占组合 \(DisplayFormat.percent(fraction * 100, signed: false))，\(model.performanceTitle) \(changeText)")
        case let .remainder(count):
            return L10n.text("其他 \(count) 项合并持仓")
        }
    }
}
