import Foundation

struct PortfolioSummary: Decodable, Equatable {
    let totalCost: Double
    let openPositions: Int
    let asOf: String?
    let marketValue: Double
    let unrealized: Double

    enum CodingKeys: String, CodingKey {
        case totalCost = "total_cost_usd_standard"
        case openPositions = "open_positions"
        case asOf = "as_of"
        case marketValue = "market_value_usd"
        case unrealized = "unrealized_usd"
    }
}

struct PortfolioOverview: Decodable {
    let summary: PortfolioSummary
    let todayPnl: Double
    let breadth: Breadth

    enum CodingKeys: String, CodingKey {
        case summary
        case todayPnl = "today_pnl_usd"
        case breadth
    }
}

struct Breadth: Decodable {
    let up: Int
    let down: Int
    let flat: Int
}

struct PortfolioChartResponse: Decodable {
    let positionCount: Int
    let positionHistory: PositionHistory
    let currentPoint: ChartPoint

    enum CodingKeys: String, CodingKey {
        case positionCount = "position_count"
        case positionHistory = "position_history"
        case currentPoint = "current_point"
    }
}

struct PositionHistory: Decodable {
    let available: Bool
    let rows: [ChartPoint]
}

struct ChartPoint: Decodable, Identifiable, Equatable {
    let dateText: String
    let marketValue: Double
    let cost: Double

    var id: String { dateText }
    var date: Date { DayDateFormatter.shared.date(from: dateText) ?? .distantPast }

    enum CodingKeys: String, CodingKey {
        case dateText = "date"
        case marketValue = "market_value_usd"
        case cost = "cost_usd"
    }
}

struct HoldingsResponse: Decodable {
    let summary: PortfolioSummary
    let rows: [Holding]
}

struct Holding: Decodable, Identifiable, Equatable {
    let ticker: String
    let logoSymbol: String?
    let displayName: String
    let sector: String?
    let shares: Double
    let averageCost: Double
    let costCurrency: String?
    let quotePrice: Double
    let quoteCurrency: String?
    let todayChangePercent: Double
    let marketValue: Double
    let weight: Double
    let unrealized: Double
    let unrealizedPercent: Double

    var id: String { ticker }
    var shortName: String {
        displayName.components(separatedBy: " / ").first ?? displayName
    }

    enum CodingKeys: String, CodingKey {
        case ticker
        case logoSymbol = "logo_symbol"
        case displayName = "display_name"
        case sector
        case shares
        case averageCost = "avg_cost_usd"
        case costCurrency = "cost_currency"
        case quotePrice = "quote_price"
        case quoteCurrency = "quote_currency"
        case todayChangePercent = "today_change_percent"
        case marketValue = "market_value_usd"
        case weight
        case unrealized = "unrealized_usd"
        case unrealizedPercent = "unrealized_percent"
    }
}

struct VolumeProfile: Decodable, Equatable {
    let ticker: String
    let currency: String
    let available: Bool
    let valueAreaHigh: Double
    let pointOfControl: Double
    let valueAreaLow: Double
    let sessions: Int
    let valueAreaPercent: Int
    let asOf: String

    enum CodingKeys: String, CodingKey {
        case ticker, currency, available, sessions
        case valueAreaHigh = "vah"
        case pointOfControl = "poc"
        case valueAreaLow = "val"
        case valueAreaPercent = "value_area_percent"
        case asOf = "as_of"
    }
}

struct ComparisonResponse: Decodable {
    let available: Bool
    let dates: [String]
    let portfolio: [Double?]
    let benchmarks: [String: [Double?]]
    let summary: ComparisonSummary
}

struct ComparisonSummary: Decodable {
    let portfolioReturn: Double?
    let benchmarkReturn: Double?
    let benchmarkReturns: [String: Double?]

    enum CodingKeys: String, CodingKey {
        case portfolioReturn = "portfolio_return"
        case benchmarkReturn = "benchmark_return"
        case benchmarkReturns = "benchmark_returns"
    }
}

struct ComparisonPoint: Identifiable, Equatable {
    let date: Date
    let portfolio: Double
    let benchmark: Double

    var id: Date { date }
}

struct BriefingResponse: Decodable {
    let briefing: String
}

struct AskResponse: Decodable {
    let answer: String
    let question: String
}

enum BrokerProvider: String, CaseIterable, Codable, Identifiable {
    case trading212
    case moomoo
    case ibkr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trading212: "Trading 212"
        case .moomoo: "Moomoo"
        case .ibkr: "Interactive Brokers"
        }
    }

    var systemImage: String {
        switch self {
        case .trading212: "chart.line.uptrend.xyaxis"
        case .moomoo: "network"
        case .ibkr: "building.columns"
        }
    }

    var setupHint: String {
        switch self {
        case .trading212:
            "由 Catfolio 服务端使用 API Key 同步。"
        case .moomoo:
            "需要在运行 Catfolio 的 Mac 上启动并登录 OpenD。"
        case .ibkr:
            "需要在运行 Catfolio 的 Mac 上启动并登录 Client Portal Gateway。"
        }
    }
}

struct BrokerOverview: Decodable {
    let provider: BrokerProvider
}

struct BrokerConnectionResult: Decodable {
    let ok: Bool
    let provider: BrokerProvider
    let message: String
    let accounts: [String]?
}

struct BrokerRefreshEnvelope: Decodable {
    let provider: BrokerProvider
    let refresh: BrokerRefreshResult
    let summary: PortfolioSummary
}

struct BrokerRefreshResult: Decodable {
    let ok: Bool
    let provider: BrokerProvider?
    let label: String?
    let holdings: Int?
    let changes: BrokerChanges?
    let warnings: [String]?
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case ok, provider, label, holdings, changes, warnings
        case durationSeconds = "duration_seconds"
    }
}

struct BrokerChanges: Decodable {
    let added: Int
    let updated: Int
    let removed: Int
    let unchanged: Int
}

struct SaveSettingResponse: Decodable {
    let ok: Bool
    let error: String?
}

enum ETFLookThroughBasis: String, CaseIterable, Identifiable {
    case market
    case cost

    var id: String { rawValue }
    var title: String { self == .market ? "市值" : "成本" }
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

    var id: String { ticker }

    enum CodingKeys: String, CodingKey {
        case ticker, name, sector
        case logoSymbol = "logo_symbol"
        case directUSD = "direct_usd"
        case fromETFUSD = "from_etf_usd"
        case totalUSD = "total_usd"
        case etfWeightPercent = "etf_weight_percent"
    }
}

enum BrokerConnectionState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)

    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
}

final class DayDateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
