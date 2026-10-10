import Foundation

enum ETFLookThroughBasis: String, CaseIterable, Identifiable {
    case market
    case cost

    var id: String { rawValue }
    var title: String { self == .market ? L10n.text("ETF 市值") : L10n.text("ETF 成本") }
}

struct ETFLookThroughResponse: Decodable {
    let basis: String
    let etfTickers: [String]
    let etfTotalUSD: Double
    let coveredWeightPercent: Double
    let otherWeightPercent: Double
    let constituentCount: Int
    let holdingsAsOf: String?
    let holdingsSource: String?
    let holdingsSourceURL: String?
    let rows: [ETFLookThroughRow]

    enum CodingKeys: String, CodingKey {
        case basis, rows
        case etfTickers = "etf_tickers"
        case etfTotalUSD = "etf_total_usd"
        case coveredWeightPercent = "covered_weight_percent"
        case otherWeightPercent = "other_weight_percent"
        case constituentCount = "constituent_count"
        case holdingsAsOf = "holdings_as_of"
        case holdingsSource = "holdings_source"
        case holdingsSourceURL = "holdings_source_url"
    }
}

struct ETFLookThroughRow: Decodable, Identifiable {
    let ticker: String
    let logoSymbol: String?
    let name: String
    let directUSD: Double
    let fromETFUSD: Double
    let totalUSD: Double
    let etfWeightPercent: Double
    let sector: String?
    var estimatedHoldingPeriodPercent: Double? = nil
    /// Direct cost plus each fund's cost allocated with the same weights as value.
    var allocatedCostUSD: Double? = nil
    /// Fund ticker -> allocated market value; preserves each fund's own daily P/L.
    var fundMarketValues: [String: Double]? = nil

    var id: String { ticker }

    /// Open a real security page without treating ETF exposure as shares or cost.
    /// The residual bucket represents multiple securities and has no such page.
    func detailHolding(directHolding: Holding?, portfolioFraction: Double,
                       dailyChangePercent: Double? = nil) -> Holding? {
        guard ticker != "ETF 其他", !ticker.isEmpty else { return nil }
        if let directHolding { return directHolding }
        return Holding(
            ticker: ticker, logoSymbol: logoSymbol, displayName: name, sector: sector,
            source: nil, shares: 0, averageCost: 0, costCurrency: nil,
            quotePrice: 0, quoteCurrency: nil, todayChangePercent: dailyChangePercent,
            marketValue: totalUSD, weight: portfolioFraction, unrealized: 0, unrealizedPercent: 0,
            fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case ticker, name, sector
        case estimatedHoldingPeriodPercent = "estimated_holding_period_percent"
        case allocatedCostUSD = "allocated_cost_usd"
        case fundMarketValues = "fund_market_values"
        case logoSymbol = "logo_symbol"
        case directUSD = "direct_usd"
        case fromETFUSD = "from_etf_usd"
        case totalUSD = "total_usd"
        case etfWeightPercent = "etf_weight_percent"
    }
}
