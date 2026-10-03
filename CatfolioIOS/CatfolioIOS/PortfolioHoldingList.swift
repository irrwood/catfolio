import Foundation

/// The list has two data sources, with shared sorting and security navigation.
/// Keep the exposure separate from the real position used by the detail page.
enum PortfolioHoldingListItem: Identifiable {
    case holding(Holding, performance: HoldingPerformanceValues?)
    case exposure(ETFLookThroughRow, direct: Holding?, portfolioTotal: Double,
                  performance: HoldingPerformanceValues?)

    var id: String { ticker }
    var ticker: String {
        switch self {
        case let .holding(holding, _): holding.ticker
        case let .exposure(row, _, _, _): row.ticker
        }
    }
    var name: String {
        switch self {
        case let .holding(holding, _): holding.shortName
        case let .exposure(row, _, _, _):
            row.ticker == "ETF 其他" ? L10n.text("ETF 其他")
                : CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name)
        }
    }
    var logoSymbol: String? {
        switch self {
        case let .holding(holding, _): holding.logoSymbol
        case let .exposure(row, _, _, _): row.logoSymbol
        }
    }
    var marketValue: Double {
        switch self {
        case let .holding(holding, _): holding.marketValue
        case let .exposure(row, _, _, _): row.totalUSD
        }
    }
    var displayedMarketValue: String {
        if case let .holding(holding, _) = self { return holding.displayedMarketValue }
        return DisplayFormat.money(marketValue, fractionDigits: 2)
    }
    var performance: HoldingPerformanceValues? {
        switch self {
        case let .holding(_, performance), let .exposure(_, _, _, performance): performance
        }
    }
    var detailHolding: Holding? {
        switch self {
        case let .holding(holding, _): holding
        case let .exposure(row, direct, total, _):
            row.detailHolding(directHolding: direct, portfolioFraction: total > 0 ? row.totalUSD / total : 0)
        }
    }

    static func make(holdings: [Holding], exposures: [ETFLookThroughRow]? = nil,
                     period: HoldingPerformancePeriod, dailyChanges: [String: Double]) -> [Self] {
        guard let exposures else {
            return holdings.map { holding in
                .holding(holding, performance: holding.performanceValues(for: period,
                    dailyChangePercent: dailyChanges[holding.ticker.uppercased()] ?? holding.todayChangePercent))
            }
        }
        let direct = Dictionary(holdings.map { ($0.ticker.uppercased(), $0) },
                                uniquingKeysWith: { first, _ in first })
        let total = exposures.reduce(0) { $0 + $1.totalUSD }
        return exposures.map { row in
            .exposure(row, direct: direct[row.ticker.uppercased()], portfolioTotal: total,
                performance: row.mergedPerformance(for: period, holdings: direct, dailyChanges: dailyChanges))
        }
    }

    static func sorted(_ items: [Self], by field: HoldingSortField, ascending: Bool,
                       week52Ranges: [String: Holding52WeekRange] = [:],
                       volumeRanges: [String: HoldingVolumeRange] = [:]) -> [Self] {
        // Resolve display names and numeric keys once, outside the comparator.
        let entries = items.map { item in
            let value: Double? = switch field {
            case .marketValue: item.marketValue
            case .unrealized: item.performance?.amount
            case .unrealizedPercent: item.performance?.percent
            case .week52Position:
                Holding52WeekPrices(holding: item.detailHolding,
                    range: week52Ranges[item.ticker.uppercased()]).rangePosition
            case .volumeArea:
                HoldingVolumePrices(holding: item.detailHolding,
                    range: volumeRanges[item.ticker.uppercased()]).valueAreaPosition
            case .name: nil
            }
            return (item: item, name: field == .name ? item.name : "", value: value)
        }
        return entries.sorted { left, right in
            func ordered(_ comparison: ComparisonResult) -> Bool {
                ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
            if field == .name {
                let comparison = left.name.localizedStandardCompare(right.name)
                if comparison != .orderedSame { return ordered(comparison) }
            } else {
                switch (left.value, right.value) {
                case let (.some(a), .some(b)):
                    if a.isFinite != b.isFinite { return a.isFinite }
                    if a.isFinite && a != b { return ascending ? a < b : a > b }
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): break
                }
            }
            return ordered(left.item.ticker.localizedStandardCompare(right.item.ticker))
        }.map(\.item)
    }
}
