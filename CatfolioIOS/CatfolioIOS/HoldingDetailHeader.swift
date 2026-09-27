import SwiftUI
import UIKit
import Observation

struct HoldingDetailHeader: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var priceSize = 22.0
    @ScaledMetric(relativeTo: .headline) private var nameSize = 18.0
    @ScaledMetric(relativeTo: .title2) private var quoteColumnWidth = 130.0
    let holding: Holding
    let marketTodayChange: Double?
    let selectedPrice: Double?
    let selectedReturn: Double?
    var selectedTrades: [SecurityTrade] = []
    /// Actual historical readouts that can appear while scrubbing. Hidden
    /// representatives reserve their measured size before a trade is selected.
    var tradeReadoutReservations: [SecurityTradeReadout.Measurement] = []
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

    /// The share class leaves the title for a badge beside the ticker.
    private var displayName: String {
        SecurityNameParts(holding.shortName).primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityHeader
            HoldingQuoteTradeLayout(quoteColumnWidth: quoteColumnWidth) {
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
                if !selectedTrades.isEmpty {
                    SecurityTradeReadout(trades: selectedTrades)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
                ForEach(tradeReadoutReservations.indices, id: \.self) { index in
                    SecurityTradeReadout(measurement: tradeReadoutReservations[index])
                        .hidden()
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, Self.topInset)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let inset: CGFloat = 20
    /// Below the safe area, for the logo and the close button alike.
    static let topInset: CGFloat = 4
    static let logoSize: CGFloat = 56

    /// Where the logo sits on the page's first screen, in the page's
    /// coordinates. Every layout puts it top-left, so the security page's zoom
    /// lines its row up on this rather than measuring the page.
    static func logoFrame(safeAreaTop: CGFloat) -> CGRect {
        CGRect(x: inset, y: safeAreaTop + topInset, width: logoSize, height: logoSize)
    }

    @ViewBuilder
    private var identityHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // At large sizes the logo and fixed close control must not take
            // most of the width away from a name or an exact share quantity.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    logo
                    Spacer(minLength: 8)
                    closeReservation
                }
                Text(displayName)
                    .font(Typography.text(size: nameSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                identity
            }
        } else {
            // The row is the logo's height whatever the name: the text centres
            // on the logo and a second line of name spills evenly above and
            // below it, so the price and chart sit in the same place on every
            // security.
            HStack(spacing: 12) {
                logo
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(Typography.text(size: nameSize, weight: .semibold))
                        .lineLimit(2)
                        .lineSpacing(-3)
                    identity
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 56)
                Spacer(minLength: 8)
                closeReservation
            }
            .frame(height: 56)
        }
    }

    private var logo: some View {
        AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: Self.logoSize)
    }

    private var closeReservation: some View {
        Color.clear.frame(width: 48, height: 48).accessibilityHidden(true)
    }

    private var identity: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { identityText }.fixedSize()
            VStack(alignment: .leading, spacing: 2) { identityText }
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var identityText: some View {
        // No count for a security with no shares behind it.
        if holding.shares > 0 {
            Text(DisplayFormat.shares(holding.shares)).appNumber(.label, monospaced: false)
        }
        Text(holding.ticker.uppercased()).appCaps(.label)
        // The home list's badges, written out: "Acc", "Class A".
        SecurityClassBadges(markers: holding.classLabels)
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
                // 0 until the day's move is known, then counts to it in place:
                // the line never appears, disappears or changes size.
                let change = todayChange ?? 0
                Text(DisplayFormat.percent(change))
                    .appNumber(.heading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(
                        todayChange == nil ? Color.secondary
                            : change >= 0 ? CatfolioTheme.gainDefault : CatfolioTheme.lossDefault
                    )
                    .contentTransition(.numericText(value: change))
                    .animation(.snappy(duration: 0.3), value: change)
            }
            .contentShape(Rectangle())
    }
}

/// The hidden historical readouts take part in measurement, but never in
/// accessibility or hit testing. Scrubbing cannot move the plot underneath
/// the finger when a date has both a buy and a sell.
struct HoldingQuoteTradeLayout: Layout {
    let quoteColumnWidth: CGFloat
    private let spacing: CGFloat = 12

    private func geometry(width: CGFloat, subviews: Subviews) -> (vertical: Bool, quote: CGSize, trade: CGSize) {
        guard let quote = subviews.first else { return (false, .zero, .zero) }
        let readouts = subviews.dropFirst()
        let idealTradeWidth = readouts.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let vertical = idealTradeWidth > 0 && quoteColumnWidth + spacing + idealTradeWidth > width
        let quoteWidth = vertical ? width : min(quoteColumnWidth, width)
        let quoteSize = quote.sizeThatFits(.init(width: quoteWidth, height: nil))
        let tradeWidth = vertical ? width : max(0, width - quoteWidth - spacing)
        let tradeHeight = readouts.map { $0.sizeThatFits(.init(width: tradeWidth, height: nil)).height }.max() ?? 0
        return (vertical, CGSize(width: quoteWidth, height: quoteSize.height), CGSize(width: tradeWidth, height: tradeHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
        let sizes = geometry(width: width, subviews: subviews)
        // Side by side, the quote alone sets the height: a readout for a day
        // of several trades runs two or three rows, and reserving them pushed
        // the fixed-height chart below down by that much — only for the
        // securities with such a day. The extra rows lie over the top of the
        // plot while the reader scrubs, which is when they show.
        let height = sizes.vertical
            ? sizes.quote.height + spacing + sizes.trade.height
            : sizes.quote.height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let quote = subviews.first else { return }
        let sizes = geometry(width: bounds.width, subviews: subviews)
        quote.place(at: bounds.origin, anchor: .topLeading,
                    proposal: .init(width: sizes.quote.width, height: sizes.quote.height))
        for readout in subviews.dropFirst() {
            readout.place(at: CGPoint(x: bounds.maxX, y: bounds.minY + (sizes.vertical ? sizes.quote.height + spacing : 0)),
                          anchor: .topTrailing, proposal: .init(width: sizes.trade.width, height: nil))
        }
    }
}

/// Figma 282:2003: a compact, trailing readout beside the historical quote.
struct SecurityTradeReadout: View {
    @ScaledMetric(relativeTo: .body) private var badgeSize = 16.0
    @ScaledMetric(relativeTo: .body) private var amountSize = 18.0
    private let rows: [Row]

    init(trades: [SecurityTrade]) {
        rows = trades.map(Row.init)
    }

    /// This initializer is only used by the hidden geometry reservations.
    init(measurement: Measurement) {
        rows = measurement.rows
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(rows) { row in
                VStack(alignment: .trailing, spacing: 2) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 4) {
                            badge(row)
                            amounts(row)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .trailing, spacing: 4) {
                            badge(row)
                            amounts(row)
                        }
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(row.details.indices, id: \.self) { index in
                            let detail = row.details[index]
                            Text(detail.text)
                                .foregroundStyle(detail.isPositive.map {
                                    $0 ? CatfolioTheme.gainDefault : CatfolioTheme.lossDefault
                                } ?? .secondary)
                        }
                    }
                    .accessibilityLabel(row.isBuy ? row.details[0].text : L10n.text("已实现盈亏"))
                }
                .font(Typography.number(size: amountSize, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("security-trade-readout")
    }

    private func badge(_ row: Row) -> some View {
        Text(L10n.text(row.isBuy ? "买入" : "卖出"))
            .font(Typography.number(size: badgeSize, weight: .semibold))
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color.primary.opacity(0.1), in: Capsule())
    }

    private func amounts(_ row: Row) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(row.amounts.indices, id: \.self) { index in
                Text(row.amounts[index])
            }
        }
        .font(Typography.number(size: amountSize, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Presentation-only strings, never transactions or input to financial
    /// calculations. Each currency/line shape keeps one synthetic readout
    /// containing its widest amount, quantity and result fields.
    struct Measurement: Equatable, Identifiable {
        let id: String
        fileprivate var rows: [Row]
    }

    fileprivate struct Detail: Equatable {
        let text: String
        let isPositive: Bool?
    }

    fileprivate struct Row: Equatable, Identifiable {
        let id: String
        let isBuy: Bool
        var amounts: [String]
        var details: [Detail]

        init(_ trade: SecurityTrade) {
            id = trade.id
            isBuy = trade.isBuy
            amounts = trade.amountTotals.map { totals in
                totals.keys.sorted().map { DisplayFormat.money(totals[$0]!, currency: $0, fractionDigits: 2) }
            } ?? ["—"]
            if trade.isSell {
                details = trade.profitTotals.map { totals in
                    totals.keys.sorted().map {
                        Detail(text: DisplayFormat.money(totals[$0]!, currency: $0, signed: true, fractionDigits: 2),
                               isPositive: totals[$0]! >= 0)
                    }
                } ?? [Detail(text: "—", isPositive: nil)]
            } else {
                details = [Detail(text: L10n.text("数量") + " " + DisplayFormat.shares(trade.quantity), isPositive: nil)]
            }
        }
    }

    static func reservationCandidates(for trades: [SecurityTrade]) -> [Measurement] {
        var candidates: [String: Measurement] = [:]
        let groups = Dictionary(grouping: trades, by: \.dateText)
        for date in groups.keys.sorted() {
            let group = groups[date]!.sorted { $0.id < $1.id }
            let shape = group.map { trade in
                trade.action + ":" + (trade.amountTotals?.keys.sorted().joined(separator: ",") ?? "—")
                    + ":" + (trade.isSell ? (trade.profitTotals?.keys.sorted().joined(separator: ",") ?? "—") : "quantity")
            }.joined(separator: "|")
            let rows = group.map(Row.init)
            if var current = candidates[shape] {
                for index in rows.indices {
                    for field in rows[index].amounts.indices where
                        measuredWidth(rows[index].amounts[field], weight: .semibold)
                            > measuredWidth(current.rows[index].amounts[field], weight: .semibold) {
                        current.rows[index].amounts[field] = rows[index].amounts[field]
                    }
                    for field in rows[index].details.indices where
                        measuredWidth(rows[index].details[field].text, weight: .medium)
                            > measuredWidth(current.rows[index].details[field].text, weight: .medium) {
                        current.rows[index].details[field] = rows[index].details[field]
                    }
                }
                candidates[shape] = current
            } else {
                candidates[shape] = Measurement(id: shape, rows: rows)
            }
        }
        return candidates.keys.sorted().compactMap { candidates[$0] }
    }

    /// All figures share one scaled font, so relative widths can be compared
    /// at its base size. Monospaced digits match the displayed numeric face.
    private static func measuredWidth(_ text: String, weight: UIFont.Weight) -> CGFloat {
        let base = NumericAlternates.font(size: 18, weight: weight, rounded: true)
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [
            [UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
             UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]
        ]])
        return (text as NSString).size(withAttributes: [.font: UIFont(descriptor: descriptor, size: 18)]).width
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
        .holdingDetailCard()
        .animation(.snappy(duration: 0.2), value: expenseRatio)
        .task(id: holding.ticker) { await loadExpenseRatio() }
    }

    /// Marked only when the figure is not the broker's own: a broker-reported
    /// value is the normal case and needs no label.
    private var fxTitle: String {
        let suffix: String
        switch holding.fxPnlStatus {
        case "estimated", "reconstructed": suffix = " · " + L10n.text("估算")
        case "unavailable": suffix = " · " + L10n.text("不可算")
        case "mixed": suffix = " · " + L10n.text("部分估算")
        default: suffix = ""
        }
        return L10n.text("汇率影响") + suffix
    }

    private var fxValue: String {
        guard let value = holding.fxPnl else {
            return holding.fxPnlStatus == "unavailable" ? L10n.text("缺少数据") : "—"
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                icon
                title.fixedSize()
                Spacer(minLength: 8)
                value.fixedSize()
            }
            HStack(alignment: .top, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 6) {
                    title
                        .fixedSize(horizontal: false, vertical: true)
                    value
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
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

    private var icon: some View {
        Group {
            if let assetName = model.icon.assetName {
                Image(assetName).resizable().renderingMode(.template).scaledToFit()
            } else {
                Image(systemName: model.icon.systemName)
                    .font(.system(size: model.icon.pointSize, weight: .regular))
                    .symbolRenderingMode(.monochrome)
            }
        }
        .foregroundStyle(.primary.opacity(0.50))
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var title: some View {
        Text(model.title.uppercased())
            .appText(.footnote, weight: .semibold)
            .foregroundStyle(.primary.opacity(0.50))
    }

    private var value: some View {
        Text(model.value)
            .appNumber(.footnote, weight: .semibold)
            .foregroundStyle(model.color)
    }

    /// Translucent, not a solid #f8f8f8 slab: on glass an opaque stripe sat
    /// on top of the card and hid its lit edge at both ends. The same tone
    /// laid over the glass keeps the edge running through every row.
    private var alternatingBackground: Color {
        guard isAlternating else { return .clear }
        return colorScheme == .dark ? .white.opacity(0.05) : .black.opacity(0.03)
    }
}
