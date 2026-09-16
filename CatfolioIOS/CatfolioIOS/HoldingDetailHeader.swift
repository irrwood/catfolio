import SwiftUI
import UIKit
import Observation

struct HoldingDetailHeader: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var priceSize = 22.0
    @ScaledMetric(relativeTo: .headline) private var nameSize = 18.0
    let holding: Holding
    let marketTodayChange: Double?
    let selectedPrice: Double?
    let selectedReturn: Double?
    /// Tapping the price refreshes the quote; there is no separate button.
    var isRefreshing = false
    var onRefresh: (() -> Void)? = nil
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var refreshTaps = 0

    private var todayChange: Double? {
        selectedReturn ?? marketTodayChange ?? holding.todayChangePercent
    }

    private var displayedPrice: Double {
        selectedPrice ?? holding.quotePrice
    }

    private var displayName: String {
        holding.shortName
    }

    private var identityLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(Typography.text(size: nameSize, weight: .semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.76)
                    identityLayout {
                        // No count for a security with no shares behind it:
                        // "0" read as a position that had been sold.
                        if holding.shares > 0 {
                            Text(DisplayFormat.shares(holding.shares)).appNumber(.label, monospaced: false)
                        }
                        Text(holding.ticker.uppercased()).appCaps(.label)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                // Reserve the fixed close button's space at the top of the report.
                Color.clear.frame(width: 48, height: 48)
                    .accessibilityHidden(true)
            }
            if let onRefresh {
                Button {
                    refreshTaps += 1
                    onRefresh()
                } label: {
                    quote
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .sensoryFeedback(.impact(weight: .light), trigger: refreshTaps) { _, _ in hapticsEnabled }
                .accessibilityHint(L10n.text("刷新行情"))
                .accessibilityIdentifier("holding-detail-refresh")
            } else {
                quote
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quote: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(DisplayFormat.money(displayedPrice, currency: holding.quoteCurrency ?? "USD"))
                        .font(Typography.number(size: priceSize, weight: .semibold))
                        .numericTransition(displayedPrice)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .allowsTightening(true)
                    if isRefreshing {
                        ChartSkeletonShape(width: 16, height: 16, cornerRadius: 8).chartLoadingShimmer()
                    }
                }
                if let todayChangePercent = todayChange {
                    Text(DisplayFormat.percent(todayChangePercent))
                        .appNumber(.heading)
                        .foregroundStyle(
                            todayChangePercent >= 0
                                ? CatfolioTheme.gainDefault
                                : CatfolioTheme.lossDefault
                        )
                } else {
                    Text(L10n.text("Return —"))
                        .font(HoldingDetailTypography.medium(13, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
    }
}

struct HoldingPositionDetails: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    var realisedProfit: RealisedProfitSummary? = nil

    /// Resolved off the main thread, because reaching for it here would not
    /// be a lookup — it is the first touch of a 6 MB package, and on the
    /// launch where nothing has decoded it yet that cost lands inside
    /// whichever frame the section first appears in. The row is absent until
    /// the answer arrives, which is the correct state anyway: most holdings
    /// are shares and never get one.
    @State private var expenseRatio: Double?

    private var costBasis: Double {
        PortfolioMath.costBasis(marketValue: holding.marketValue, unrealized: holding.unrealized) ?? .nan
    }

    private var profitColor: Color {
        holding.unrealized >= 0
            ? CatfolioTheme.gainDefault
            : CatfolioTheme.lossDefault
    }

    /// The fund's own annual charge, and what that costs on this position.
    ///
    /// A percentage alone is unreadable at this scale — 0.03% and 0.30% look
    /// alike — so the money it comes to at the current value is shown beside
    /// it. It is a run rate at today's price, not a fee already paid, and not
    /// a figure to subtract from a return that already has it deducted.
    private var expenseRatioRow: HoldingDataRow.Model? {
        guard let expenseRatio else { return nil }
        let rate = (expenseRatio * 100).formatted(.number.precision(.fractionLength(2...4)))
        let annual = DisplayFormat.money(holding.marketValue * expenseRatio, fractionDigits: 2)
        return .init(
            title: L10n.text("Expense Ratio"),
            icon: .expenseRatio,
            value: "\(rate)%  ·  \(annual)/yr"
        )
    }

    private func loadExpenseRatio() async {
        let ticker = holding.ticker
        expenseRatio = await Task.detached(priority: .userInitiated) {
            try? FundFeeCatalog.bundled.get().fee(brokerSymbol: ticker)?.rate
        }.value
    }

    private var realisedProfitRow: HoldingDataRow.Model? {
        guard let realisedProfit else { return nil }
        let title: String
        if !realisedProfit.isComplete {
            title = L10n.text("Realised P&L · Known")
        } else if realisedProfit.estimatedCount > 0 {
            title = L10n.text("Realised P&L · Est.")
        } else {
            title = L10n.text("Realised P&L")
        }
        let value = realisedProfit.combinedUSD
        return .init(
            title: title,
            icon: .unrealisedProfitLoss,
            value: DisplayFormat.money(value, signed: true),
            color: value == 0 ? .secondary : (value > 0 ? CatfolioTheme.gainDefault : CatfolioTheme.lossDefault)
        )
    }

    private var rows: [HoldingDataRow.Model] {
        [
            .init(
                title: L10n.text("Value"),
                icon: .value,
                value: holding.displayedMarketValue,
                color: CatfolioTheme.gainDefault
            ),
            .init(
                title: L10n.text("Return"),
                icon: .returnValue,
                value: DisplayFormat.percent(holding.unrealizedPercent)
            ),
            .init(
                title: L10n.text("Shares"),
                icon: .shares,
                value: DisplayFormat.shares(holding.shares)
            ),
            .init(
                title: L10n.text("Cost"),
                icon: .cost,
                value: DisplayFormat.money(costBasis)
            ),
            .init(
                title: L10n.text("Average Cost"),
                icon: .averageCost,
                value: DisplayFormat.money(
                    holding.averageCost,
                    currency: holding.costCurrency ?? "USD"
                )
            ),
            .init(
                title: fxTitle,
                icon: .fxImpact,
                value: fxValue,
                color: fxColor
            ),
            .init(
                title: L10n.text("Proportion"),
                icon: .proportion,
                value: DisplayFormat.percent(holding.weight * 100, signed: false)
            ),
            // Amount and percentage on rows of their own, as in Figma 299:10086.
            .init(
                title: L10n.text("Unrealised P&L"),
                icon: .unrealisedProfitLoss,
                value: DisplayFormat.money(holding.unrealized, signed: true),
                color: profitColor
            ),
            .init(
                title: L10n.text("Unrealised P&L %"),
                icon: .unrealisedProfitLoss,
                value: DisplayFormat.percent(holding.unrealizedPercent),
                color: profitColor
            ),
        ] + [realisedProfitRow, expenseRatioRow].compactMap { $0 }
    }

    var body: some View {
        // One glass card: the title on the card's inset, the zebra stripes
        // edge to edge beneath it.
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("Data"))
                .appText(.subheading, weight: .medium)
                .padding([.horizontal, .top], HoldingDetailCardStyle.contentInset)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HoldingDataRow(model: row, isAlternating: index.isMultiple(of: 2))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: HoldingDetailCardStyle.cornerRadius, style: .continuous))
        .holdingDetailGlassCard()
        .animation(.snappy(duration: 0.2), value: expenseRatio)
        .task(id: holding.ticker) { await loadExpenseRatio() }
    }

    private var fxTitle: String {
        let suffix: String
        switch holding.fxPnlStatus {
        case "estimated": suffix = " · EST."
        case "reconstructed": suffix = " · CALC."
        case "broker_reported": suffix = " · REPORTED"
        case "unavailable": suffix = " · UNAVAILABLE"
        case "mixed": suffix = " · MIXED"
        default: suffix = ""
        }
        return "FX Impact\(suffix)"
    }

    private var fxValue: String {
        guard let value = holding.fxPnl else {
            return holding.fxPnlStatus == "unavailable" ? "Missing data" : "—"
        }
        let amount = DisplayFormat.money(value, signed: true)
        guard let percent = holding.fxPnlPercent else { return amount }
        return "\(amount)  ·  \(DisplayFormat.percent(percent))"
    }

    private var fxColor: Color {
        guard let value = holding.fxPnl else { return .secondary }
        if value > 0 { return CatfolioTheme.gainDefault }
        if value < 0 { return CatfolioTheme.lossDefault }
        return .secondary
    }
}

enum HoldingDataIcon {
    case value
    case returnValue
    case shares
    case cost
    case averageCost
    case fxImpact
    case proportion
    case unrealisedProfitLoss
    case expenseRatio

    /// Exact vector exports from the latest Figma icon source node 139:2920,
    /// as used by the Data section at node 115:5140. Rows that are not
    /// present in that frame keep their closest SF Symbol until the design
    /// supplies a dedicated glyph.
    var assetName: String? {
        switch self {
        case .value: "HoldingDataValue"
        case .returnValue: "HoldingDataReturn"
        case .cost: "HoldingDataCost"
        case .fxImpact: "HoldingDataFXImpact"
        case .proportion: "HoldingDataProportion"
        case .unrealisedProfitLoss: "HoldingDataUnrealisedPnL"
        case .shares, .averageCost, .expenseRatio: nil
        }
    }

    var systemName: String {
        switch self {
        case .value: "dollarsign"
        case .returnValue: "arrow.up.right"
        case .shares: "number"
        case .cost: "creditcard"
        case .averageCost: "divide.square"
        case .fxImpact: "arrow.left.arrow.right"
        case .proportion: "chart.pie"
        case .unrealisedProfitLoss: "chart.line.uptrend.xyaxis"
        case .expenseRatio: "percent"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .value: 22
        case .returnValue: 20
        case .shares: 21
        case .cost, .averageCost: 19
        case .fxImpact, .proportion, .unrealisedProfitLoss: 20
        case .expenseRatio: 19
        }
    }
}

struct HoldingDataRow: View {
    @Environment(\.locale) private var appLocale
    struct Model {
        let title: String
        let icon: HoldingDataIcon
        let value: String
        var color: Color = .primary
    }

    @Environment(\.colorScheme) private var colorScheme

    let model: Model
    let isAlternating: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let assetName = model.icon.assetName {
                    Image(assetName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                } else {
                    Image(systemName: model.icon.systemName)
                        .font(.system(size: model.icon.pointSize, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                }
            }
            .foregroundStyle(.primary.opacity(0.50))
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)

            Text(model.title.uppercased())
                .appText(.footnote, weight: .semibold)
                .foregroundStyle(.primary.opacity(0.50))
                .lineLimit(1)
                .minimumScaleFactor(0.74)

            Spacer(minLength: 8)

            Text(model.value)
                .appNumber(.footnote, weight: .semibold)
                .foregroundStyle(model.color)
                .lineLimit(1)
                .minimumScaleFactor(0.66)
                .layoutPriority(1)
        }
        // On the card's inset, so the icons line up under the card's title.
        .padding(.horizontal, HoldingDetailCardStyle.contentInset)
        .padding(.vertical, 12)
        // An explicit Rectangle: without a shape, inside the glass card on
        // iOS 26 the stripe took a rounded container shape and drew as a
        // capsule. The design's stripes are square at both ends.
        .background(alternatingBackground, in: Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Translucent, not a solid #f8f8f8 slab: on glass an opaque stripe sat
    /// on top of the card and hid its lit edge at both ends. The same tone
    /// laid over the glass keeps the edge running through every row.
    private var alternatingBackground: Color {
        guard isAlternating else { return .clear }
        return colorScheme == .dark ? .white.opacity(0.05) : .black.opacity(0.03)
    }
}
