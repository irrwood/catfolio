import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var isSidebarHoldingRow = false
}

struct HoldingPerformanceValues {
    let amount: Double
    let percent: Double
}

extension Holding {
    func performanceValues(
        for period: HoldingPerformancePeriod,
        dailyChangePercent: Double?
    ) -> HoldingPerformanceValues? {
        switch period {
        case .holdingPeriod:
            guard unrealized.isFinite, unrealizedPercent.isFinite else { return nil }
            return HoldingPerformanceValues(amount: unrealized, percent: unrealizedPercent)
        case .today:
            guard let dailyChangePercent,
                  let amount = PortfolioMath.dayContribution(
                      marketValue: marketValue, changePercent: dailyChangePercent) else { return nil }
            return HoldingPerformanceValues(amount: amount, percent: dailyChangePercent)
        }
    }
}

struct HoldingRow: View {
    @Environment(\.isSidebarHoldingRow) private var isSidebarHoldingRow
    @Environment(\.locale) private var appLocale
    @Environment(\.securityDetailZoomOrigin) private var zoomOrigin
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: PortfolioHoldingListItem
    let performancePeriod: HoldingPerformancePeriod
    let showsWeight: Bool
    let showsTicker: Bool
    let showsShares: Bool
    let showsPerformanceAmount: Bool
    let showsPerformancePercent: Bool
    let week52: Holding52WeekPrices?
    let volume: HoldingVolumePrices?

    // Match SidebarSecuritySearchRow's primary text while keeping phone rows
    // at their existing body size. Both use the shared Dynamic Type scale.
    private var titleScale: TypeScale { isSidebarHoldingRow ? .callout : .body }

    init(item: PortfolioHoldingListItem, performancePeriod: HoldingPerformancePeriod, showsWeight: Bool = true, showsTicker: Bool = true, showsShares: Bool = true,
         showsPerformanceAmount: Bool = true, showsPerformancePercent: Bool = true,
         week52: Holding52WeekPrices? = nil, volume: HoldingVolumePrices? = nil) {
        self.item = item
        self.performancePeriod = performancePeriod
        self.showsWeight = showsWeight
        self.showsTicker = showsTicker
        self.showsShares = showsShares
        self.showsPerformanceAmount = showsPerformanceAmount
        self.showsPerformancePercent = showsPerformancePercent
        self.week52 = week52
        self.volume = volume
    }

    init(holding: Holding, performancePeriod: HoldingPerformancePeriod, dailyChangePercent: Double?, showsWeight: Bool = true, showsTicker: Bool = true, showsShares: Bool = true,
         showsPerformanceAmount: Bool = true, showsPerformancePercent: Bool = true) {
        self.init(item: .holding(holding, performance: holding.performanceValues(
            for: performancePeriod, dailyChangePercent: dailyChangePercent)), performancePeriod: performancePeriod,
            showsWeight: showsWeight, showsTicker: showsTicker, showsShares: showsShares,
            showsPerformanceAmount: showsPerformanceAmount, showsPerformancePercent: showsPerformancePercent)
    }

    @ViewBuilder
    var body: some View {
        if let volume {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name + "，" + item.ticker)
                .accessibilityValue(withWeightDescription(volumeDescription(volume)))
                .accessibilityHint(L10n.text(item.ticker == "ETF 其他" ? "金额来源" : "打开个股"))
        } else if let week52 {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name + "，" + item.ticker)
                .accessibilityValue(withWeightDescription(week52Description(week52)))
                .accessibilityHint(L10n.text(item.ticker == "ETF 其他" ? "金额来源" : "打开个股"))
        } else if case let .holding(holding, _) = item {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(withWeightDescription(L10n.text("\(holding.shortName)，\(DisplayFormat.listShares(holding.shares, compact: false, locale: appLocale)) 股 \(holding.ticker)，市值 \(DisplayFormat.money(holding.marketValue))，\(performancePeriod.title)盈亏 \(profitDescription)")))
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityHint(L10n.text(item.ticker == "ETF 其他" ? "金额来源" : "打开个股"))
        }
    }

    private var content: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibleContent
            } else {
                HStack(alignment: .center, spacing: 10) {
                    logo
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .center, spacing: 8) {
                                SecurityDisplayName(name: item.name, scale: titleScale, weight: .semibold,
                                                    showsClassMarkers: false)
                                    .layoutPriority(1)
                                Spacer(minLength: 4)
                                // Keep the existing 1pt optical alignment of the number.
                                if let volume {
                                    price(volume.current, currency: volume.currency, isCost: false).offset(y: -1)
                                } else if let week52 {
                                    price(week52.current, currency: week52.currency, isCost: false).offset(y: -1)
                                } else {
                                    amount.offset(y: -1)
                                }
                            }
                            HStack(alignment: .center, spacing: 5) {
                                subtitle
                                Spacer(minLength: 2)
                                if let volume {
                                    price(volume.cost, currency: volume.currency, isCost: true)
                                } else if let week52 {
                                    price(week52.cost, currency: week52.currency, isCost: true)
                                } else {
                                    HoldingPerformanceLabel(performance: item.performance, showsAmount: showsPerformanceAmount, showsPercent: showsPerformancePercent)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let volume { HoldingVolumeProfileBar(prices: volume) }
                        else if let week52 { Holding52WeekBar(positions: week52.positions) }
                    }
                }
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var accessibleContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                logo
                if case let .holding(holding, _) = item {
                    VStack(alignment: .leading, spacing: 5) {
                        HoldingIdentity(holding: holding, compact: false, showsTicker: showsTicker, showsShares: showsShares,
                                        nameScale: titleScale)
                        if showsWeight {
                            Text(L10n.text("\(weightText) · 组合占比"))
                                .appNumber(.caption, weight: .medium).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    SecurityDisplayName(name: item.name, scale: titleScale, weight: .semibold, singleLine: false)
                }
            }
            if let volume {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("现价") + " " + priceText(volume.current, currency: volume.currency))
                            .appNumber(.callout, weight: .semibold)
                        Text(L10n.text("成本价") + " " + priceText(volume.cost, currency: volume.currency))
                            .appNumber(.footnote, weight: .medium).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    HoldingVolumeProfileBar(prices: volume)
                }
            } else if let week52 {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("现价") + " " + priceText(week52.current, currency: week52.currency))
                            .appNumber(.callout, weight: .semibold)
                        Text(L10n.text("成本价") + " " + priceText(week52.cost, currency: week52.currency))
                            .appNumber(.footnote, weight: .medium).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Holding52WeekBar(positions: week52.positions)
                }
            } else if case let .holding(holding, _) = item {
                HoldingMetrics(holding: holding, performance: item.performance, period: performancePeriod,
                               alignment: .leading, compact: false, showsPerformanceAmount: showsPerformanceAmount,
                               showsPerformancePercent: showsPerformancePercent)
            } else {
                amount
                subtitle
                HoldingPerformanceLabel(performance: item.performance, showsAmount: showsPerformanceAmount, showsPercent: showsPerformancePercent)
            }
        }
    }

    private var logo: some View {
        AssetLogo(ticker: item.ticker, logoSymbol: item.logoSymbol, size: 44, cornerRadius: 12)
            .securityDetailLogoSource(item.ticker, in: zoomOrigin)
    }

    @ViewBuilder
    private var amount: some View {
        let text = FinancialText(item.displayedMarketValue)
            .appNumber(.callout, weight: .semibold)
            .foregroundStyle(CatfolioTheme.primaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        if case .holding = item { text.numericTransition(item.marketValue) }
        else { text }
    }

    private var subtitle: some View {
        Group {
            switch item {
            case let .holding(holding, _):
                HStack(spacing: 2) {
                    if showsShares {
                        FinancialText(DisplayFormat.listShares(holding.shares, locale: appLocale))
                            .appNumber(.footnote, weight: .medium, monospaced: false)
                    }
                    if showsTicker { Text(holding.ticker).appText(.footnote, weight: .medium) }
                    SecurityClassBadges(markers: holding.classMarkers)
                    if showsWeight {
                        Text((showsShares || showsTicker || !holding.classMarkers.isEmpty ? " · " : "") + weightText).appNumber(.footnote, weight: .medium, monospaced: false)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            case let .exposure(row, _, _, _):
                let ticker = row.ticker == "ETF 其他" ? L10n.text("ETF 其他") : row.ticker
                HStack(spacing: 0) {
                    if showsTicker { Text(ticker) }
                    if showsWeight {
                        Text((showsTicker ? " · " : "") + weightText).fixedSize(horizontal: true, vertical: false)
                    }
                }
                .appText(.footnote, weight: .medium)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(withWeightDescription(ticker))
            }
        }
        .foregroundStyle(CatfolioPalette.fixedNeutralGray)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var profitDescription: String {
        guard let performance = item.performance else { return L10n.text("暂无数据") }
        return "\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) · \(DisplayFormat.percent(performance.percent))"
    }

    private var weightText: String {
        item.portfolioWeight.map { DisplayFormat.percent($0 * 100, signed: false) } ?? "—"
    }

    private func withWeightDescription(_ description: String) -> String {
        showsWeight ? description + "，" + L10n.text("\(weightText) · 组合占比") : description
    }

    private func price(_ value: Double?, currency: String?, isCost: Bool) -> some View {
        FinancialText(priceText(value, currency: currency))
            .appNumber(isCost ? .footnote : .callout, weight: isCost ? .medium : .semibold)
            .foregroundStyle(isCost ? CatfolioPalette.fixedNeutralGray : CatfolioTheme.primaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func priceText(_ value: Double?, currency: String?) -> String {
        guard let value, let currency else { return "—" }
        return DisplayFormat.money(value, currency: currency)
    }

    private func volumeDescription(_ prices: HoldingVolumePrices) -> String {
        var parts = [L10n.text("现价") + " " + priceText(prices.current, currency: prices.currency),
                     L10n.text("成本价") + " " + priceText(prices.cost, currency: prices.currency)]
        if let range = prices.range {
            parts.append(L10n.text("成交密集区") + " " + priceText(range.valueAreaLow, currency: range.currency)
                + " – " + priceText(range.valueAreaHigh, currency: range.currency))
            parts.append(L10n.text("成交最密集") + " " + priceText(range.pointOfControl, currency: range.currency))
        } else {
            parts.append(L10n.text("成交量分布暂无数据"))
        }
        return parts.joined(separator: "，")
    }

    private func week52Description(_ prices: Holding52WeekPrices) -> String {
        var parts = [L10n.text("现价") + " " + priceText(prices.current, currency: prices.currency),
                     L10n.text("成本价") + " " + priceText(prices.cost, currency: prices.currency)]
        if let range = prices.range {
            parts.append(L10n.text("52 周范围") + " " + priceText(range.low, currency: range.currency)
                + " – " + priceText(range.high, currency: range.currency))
            if let start = range.startPrice {
                parts.append(L10n.text("期初价") + " " + priceText(start, currency: range.currency))
            }
        } else {
            parts.append(L10n.text("52 周范围暂无数据"))
        }
        return parts.joined(separator: "，")
    }
}

/// A row's profit: the amount, then its percentage on a tinted tag — green
/// for a gain, red for a loss. The holdings list's, shared by the
/// look-through list so the two read the same.
struct HoldingPerformanceLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let performance: HoldingPerformanceValues?
    var showsAmount = true
    var showsPercent = true

    var body: some View {
        if showsAmount || showsPercent {
            if let performance {
                HStack(spacing: 4) {
                    if showsAmount {
                        FinancialText(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2), isDirectional: true)
                            .appNumber(.footnote, weight: .medium)
                            .foregroundStyle(rowAccent)
                            .numericTransition(performance.amount)
                    }
                    if showsPercent {
                        FinancialText(DisplayFormat.percent(abs(performance.percent), signed: false))
                            .accessibilityLabel(DisplayFormat.percent(performance.percent))
                            .appNumber(.caption, weight: .semibold, monospaced: false)
                            .foregroundStyle(rowAccent)
                            .numericTransition(performance.percent)
                            .padding(.horizontal, 5)
                            .frame(minHeight: 17)
                            .background(badgeColor, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            } else {
                Text(L10n.text("暂无数据"))
                    .font(PortfolioHomeTypography.medium(12, relativeTo: .caption))
                    .foregroundStyle(rowAccent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            }
        }
    }

    private var rowAccent: Color {
        if (performance?.amount ?? 0) >= 0 {
            return colorScheme == .light
                ? Color(red: 1 / 255, green: 184 / 255, blue: 1 / 255)
                : CatfolioTheme.gain(for: colorScheme)
        }
        return CatfolioTheme.loss(for: colorScheme)
    }

    private var badgeColor: Color {
        if (performance?.amount ?? 0) >= 0 {
            return colorScheme == .light
                ? Color(red: 220 / 255, green: 247 / 255, blue: 220 / 255)
                : rowAccent.opacity(0.18)
        }
        return CatfolioTheme.loss(for: colorScheme).opacity(0.18)
    }
}

struct SecurityDisplayName: View {
    let name: String
    let scale: TypeScale
    let weight: Font.Weight
    var singleLine = true
    var showsClassMarkers = true

    private var parts: SecurityNameParts { SecurityNameParts(name) }

    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            Text(parts.primary)
                .appText(scale, weight: weight)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(singleLine ? 1 : nil)
                .truncationMode(.tail)

            if showsClassMarkers {
                SecurityClassBadges(markers: parts.classMarkers)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

struct SecurityClassBadges: View {
    let markers: [String]

    var body: some View {
        ForEach(markers.indices, id: \.self) { index in
            SecurityClassBadge(marker: markers[index])
        }
    }
}

struct SecurityClassBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let marker: String
    @ScaledMetric(relativeTo: .caption) private var badgeHeight: CGFloat = 18

    private let gray = CatfolioPalette.fixedNeutralGray

    var body: some View {
        Text(marker)
            .appText(.caption, weight: .medium)
            .foregroundStyle(gray)
            .padding(.horizontal, 3)
            .frame(height: badgeHeight)
            .background(gray.opacity(colorScheme == .dark ? 0.24 : 0.1),
                        in: RoundedRectangle(cornerRadius: 3))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }
}

struct HoldingIdentity: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let compact: Bool
    var showsTicker = true
    var showsShares = true
    var nameScale: TypeScale = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SecurityDisplayName(name: holding.shortName, scale: nameScale, weight: .medium,
                                singleLine: compact, showsClassMarkers: false)

            HStack(spacing: 2) {
                if showsShares {
                    FinancialText(DisplayFormat.listShares(holding.shares, locale: appLocale))
                        .appNumber(.caption, monospaced: false)
                }
                if showsTicker {
                    Text(holding.ticker)
                        .appText(.caption, weight: .medium)
                }
                SecurityClassBadges(markers: holding.classMarkers)
            }
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 1 : nil)
        }
    }
}

struct HoldingMetrics: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let performance: HoldingPerformanceValues?
    let period: HoldingPerformancePeriod
    let alignment: HorizontalAlignment
    let compact: Bool
    var showsPerformanceAmount = true
    var showsPerformancePercent = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            FinancialText(holding.displayedMarketValue)
                .appNumber(.body)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(compact ? 1 : nil)
            // The separator is punctuation, not data. Carrying the gain or
            // loss colour it reads as part of the figure, and a row of red
            // dots between red numbers is noise the eye has to filter.
            if showsPerformanceAmount || showsPerformancePercent {
                Group {
                    if let performance {
                        FinancialText {
                            performanceLabel(performance)
                        }
                    } else {
                        FinancialText(L10n.text("\(period.title)暂无数据")).foregroundStyle(.secondary)
                    }
                }
                .appNumber(.caption, weight: .medium)
                .lineLimit(compact ? 1 : nil)
            }
        }
    }

    private func performanceLabel(_ performance: HoldingPerformanceValues) -> Text {
        let amount = Text(financial: DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2), isDirectional: true)
            .foregroundStyle(performanceColor)
        let percent = Text(financial: DisplayFormat.percent(performance.percent))
            .foregroundStyle(performanceColor)
        if showsPerformanceAmount && showsPerformancePercent {
            return amount + Text(" · ").foregroundStyle(.secondary) + percent
        }
        return showsPerformanceAmount ? amount : percent
    }

    private var performanceColor: Color {
        (performance?.amount ?? 0) >= 0
            ? (colorScheme == .light
                ? CatfolioTheme.gain(for: .light)
                : CatfolioTheme.gain(for: .dark))
            : CatfolioPalette.rose500
    }
}
