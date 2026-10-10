import Foundation

/// Separates trailing distribution and share classes from a security's display name.
struct SecurityNameParts: Equatable {
    let primary: String
    /// Compact badges for a list row: "A" (Acc), "D" (Dist), a class letter.
    let classMarkers: [String]
    /// The same, written out for a page with room: "Acc", "Dist", "Class A".
    let classLabels: [String]

    private static let trailingDistributionClass = try! NSRegularExpression(
        pattern: #"\s+(?:\((Acc|Dist|Accumulating|Distributing)\)(?:\s+([A-Z]))?|(Acc|Dist|Accumulating|Distributing))$"#,
        options: [.caseInsensitive]
    )
    private static let trailingShareClass = try! NSRegularExpression(
        pattern: #"\s+(?:-\s*)?(?:\((?:Class|Cl|Series)\s+([A-Z])\)|(?:Class|Cl|Series)\s+([A-Z])(?:\s+(?:Common Stock|Ordinary Shares?|Shares?))?)$"#,
        options: [.caseInsensitive]
    )

    init(_ name: String) {
        var remaining = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var markers: [String] = []
        var labels: [String] = []

        // Work from the end so "ETF (Acc) Class B" and "ETF Class B (Acc)"
        // both leave the base name intact and keep the badges in source order.
        for _ in 0..<3 {
            let range = NSRange(remaining.startIndex..., in: remaining)
            if let match = Self.trailingShareClass.firstMatch(in: remaining, range: range),
               let suffix = Range(match.range, in: remaining) {
                let base = String(remaining[..<suffix.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let group = match.range(at: 1).location == NSNotFound ? 2 : 1
                guard !base.isEmpty, let letter = Range(match.range(at: group), in: remaining) else { break }
                markers.append(String(remaining[letter]).uppercased())
                labels.append("Class \(remaining[letter].uppercased())")
                remaining = base
                continue
            }
            if let match = Self.trailingDistributionClass.firstMatch(in: remaining, range: range),
               let suffix = Range(match.range, in: remaining) {
                let base = String(remaining[..<suffix.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let group = match.range(at: 1).location == NSNotFound ? 3 : 1
                guard !base.isEmpty, let token = Range(match.range(at: group), in: remaining) else { break }
                let marker = remaining[token].lowercased().hasPrefix("acc") ? "A" : "D"
                let classLetter = Range(match.range(at: 2), in: remaining)
                    .map { " \(remaining[$0].uppercased())" } ?? ""
                markers.append(marker + classLetter)
                labels.append((marker == "A" ? "Acc" : "Dist") + classLetter)
                remaining = base
                continue
            }
            break
        }
        primary = remaining
        classMarkers = Array(markers.reversed())
        classLabels = Array(labels.reversed())
    }
}

struct PortfolioSummary: Codable, Equatable {
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

/// Today's figures are not part of this: the ledger has no intraday state,
/// so every screen reads today's move from `AppModel.holdingDailyChanges`.
/// The server-era `today_pnl_usd` and `breadth` fields were filled with
/// zeroes here and read by nothing.
struct PortfolioOverview: Codable {
    let summary: PortfolioSummary

    enum CodingKeys: String, CodingKey {
        case summary
    }
}

struct PortfolioChartResponse: Codable {
    let positionCount: Int
    let positionHistory: PositionHistory
    let currentPoint: ChartPoint
    let warning: String?
    /// Present for real account history (empty when unavailable). In this
    /// mode ChartPoint.cost means cumulative NET EXTERNAL DEPOSITS.
    var accountNAV: [String: Double]? = nil
    /// What the rebuild assumed or could not use, for Settings to list. The
    /// chart is drawn regardless.
    var dataIssues: [String]? = nil
    /// Actual quote sessions, excluding calendar days carried forward by the ledger.
    var marketDates: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case warning
        case positionCount = "position_count"
        case positionHistory = "position_history"
        case currentPoint = "current_point"
        case accountNAV = "account_nav"
        case dataIssues = "data_issues"
        case marketDates = "market_dates"
    }

    var isCurrentHoldingsOnly: Bool {
        accountNAV == nil && positionHistory.rows.isEmpty
    }

    static func currentHoldings(overview: PortfolioOverview, positionCount: Int) -> Self {
        Self(positionCount: positionCount, positionHistory: .init(available: false, rows: []),
            currentPoint: .init(dateText: DayDateCodec.string(from: Date()),
                marketValue: overview.summary.marketValue, cost: overview.summary.totalCost),
            warning: L10n.text("历史行情缓存不完整，当前显示所选账户的持仓市值与成本。"))
    }

    static func unavailableAccountHistory(positionCount: Int, reason: String) -> Self {
        Self(positionCount: positionCount, positionHistory: .init(available: false, rows: []),
            currentPoint: .init(dateText: "", marketValue: .nan, cost: .nan), warning: reason, accountNAV: [:])
    }

    static func accountHistory(ledger: AccountMWRLedger, nav: [Double?], positionCount: Int, assumptions: [String] = []) -> Self {
        guard ledger.values.count == ledger.dates.count, ledger.cashFlows.count == ledger.dates.count,
              nav.count == ledger.dates.count, !ledger.dates.isEmpty else {
            return .unavailableAccountHistory(positionCount: positionCount, reason: "账户账本与净值日期不完整。")
        }
        var netDeposit = 0.0
        var points: [ChartPoint] = []
        var units: [String: Double] = [:]
        for index in ledger.dates.indices {
            guard ledger.cashFlows[index].isFinite, let value = ledger.values[index], value.isFinite,
                  let unit = nav[index], unit.isFinite else {
                return .unavailableAccountHistory(positionCount: positionCount, reason: "账户账本与净值日期不完整。")
            }
            netDeposit += ledger.cashFlows[index]
            points.append(.init(dateText: ledger.dates[index], marketValue: value, cost: netDeposit))
            units[ledger.dates[index]] = unit
        }
        return Self(positionCount: positionCount, positionHistory: .init(available: points.count > 1, rows: points),
            currentPoint: points.last!,
            warning: (assumptions.isEmpty ? "" : LocalMarketDataClient.impliedFundingNote + "\n\n" + "每条推算和数据问题列在 设置 → 本机数据 → 数据问题。" + "\n\n")
                + "账户资产包含持仓和现金，按历史日线及汇率重建，最新持仓估值接入有效报价。1 日显示最近交易日相对前一交易日的估值变化，不是分钟线。净入金为累计入金减累计出金；盈亏扣除外部资金流，百分比为区间 TWR。股息按到账日计入，现金余额尚未与券商核对。",
            accountNAV: units,
            dataIssues: assumptions.isEmpty ? nil : assumptions)
    }

    func accountPerformance(from startDate: String, to endDate: String) -> (amount: Double, percentage: Double) {
        guard let accountNAV, let start = positionHistory.rows.first(where: { $0.dateText == startDate }),
              let end = positionHistory.rows.first(where: { $0.dateText == endDate }), startDate <= endDate,
              let base = accountNAV[startDate], base > 0, let last = accountNAV[endDate] else { return (.nan, .nan) }
        return ((end.marketValue - start.marketValue) - (end.cost - start.cost), (last / base - 1) * 100)
    }
}

struct PositionHistory: Codable {
    let available: Bool
    let rows: [ChartPoint]
}

struct ChartPoint: Codable, Identifiable, Equatable {
    let dateText: String
    let marketValue: Double
    let cost: Double

    var id: String { dateText }
    var date: Date { DayDateCodec.date(from: dateText) ?? .distantPast }

    enum CodingKeys: String, CodingKey {
        case dateText = "date"
        case marketValue = "market_value_usd"
        case cost = "cost_usd"
    }
}

struct Holding: Codable, Identifiable, Equatable {
    var publicDisclosure: PublicAccountDisclosure? = nil
    var displayedMarketValue: String {
        if let publicDisclosure { return publicDisclosure.amountLabel }
        return DisplayFormat.money(marketValue, fractionDigits: 2)
    }
    let ticker: String
    let logoSymbol: String?
    let displayName: String
    let sector: String?
    let source: String?
    let shares: Double
    let averageCost: Double
    let costCurrency: String?
    let quotePrice: Double
    let quoteCurrency: String?
    let todayChangePercent: Double?
    let marketValue: Double
    let weight: Double
    let unrealized: Double
    let unrealizedPercent: Double
    let fxPnl: Double?
    let fxPnlPercent: Double?
    let fxPnlStatus: String?
    let fxPnlSource: String?

    var id: String { ticker }
    var shortName: String {
        let original = displayName.components(separatedBy: " / ").first ?? displayName
        if let disclosure = publicDisclosure {
            return PublicDisclosureFormat.securityName(
                ticker: disclosure.underlyingTicker ?? ticker, name: original)
        }
        if source == PublicInvestorAccountAdapter.source {
            return PublicDisclosureFormat.securityName(ticker: ticker, name: original)
        }
        return CompanyNameCatalog.displayName(ticker: ticker, fallback: original)
    }

    var classMarkers: [String] { classParts.classMarkers }

    /// Share class written out — "Acc", "Class A" — for the security page.
    var classLabels: [String] { classParts.classLabels }

    private var classParts: SecurityNameParts {
        let original = displayName.components(separatedBy: " / ").first ?? displayName
        let displaySource = (publicDisclosure != nil || source == PublicInvestorAccountAdapter.source)
            ? PublicDisclosureFormat.sourceName(ticker: publicDisclosure?.underlyingTicker ?? ticker, name: original).cleanName
            : original
        let sourceParts = SecurityNameParts(displaySource)
        return sourceParts.classMarkers.isEmpty ? SecurityNameParts(shortName) : sourceParts
    }

    /// The company's own name, whatever 公司名称 is set to: what a news
    /// search, a filing lookup and a model prompt need.
    var researchName: String {
        let original = displayName.components(separatedBy: " / ").first ?? displayName
        if let disclosure = publicDisclosure {
            return PublicDisclosureFormat.securityName(
                ticker: disclosure.underlyingTicker ?? ticker, name: original)
        }
        if source == PublicInvestorAccountAdapter.source {
            return PublicDisclosureFormat.securityName(ticker: ticker, name: original, mode: .original)
        }
        return CompanyNameCatalog.displayName(ticker: ticker, fallback: original, mode: .original)
    }

    enum CodingKeys: String, CodingKey {
        case publicDisclosure
        case ticker
        case logoSymbol = "logo_symbol"
        case displayName = "display_name"
        case sector
        case source
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
        case fxPnl = "broker_fx_ppl_usd"
        case fxPnlPercent = "broker_fx_ppl_percent"
        case fxPnlStatus = "fx_pnl_status"
        case fxPnlSource = "fx_pnl_source"
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
    let fiftyTwoWeekHigh: Double?
    let fiftyTwoWeekLow: Double?
    let fiftyTwoWeekStartPrice: Double?
    let todayChangePercent: Double?
    let bins: [VolumeProfileBin]?

    enum CodingKeys: String, CodingKey {
        case ticker, currency, available, sessions
        case valueAreaHigh = "vah"
        case pointOfControl = "poc"
        case valueAreaLow = "val"
        case valueAreaPercent = "value_area_percent"
        case asOf = "as_of"
        case fiftyTwoWeekHigh = "high_52w"
        case fiftyTwoWeekLow = "low_52w"
        case fiftyTwoWeekStartPrice = "start_price_52w"
        case todayChangePercent = "today_change_percent"
        case bins
    }
}

struct VolumeProfileBin: Codable, Equatable, Identifiable {
    let priceLow: Double
    let priceHigh: Double
    let volume: Double

    var id: Double { priceLow }
    var midpoint: Double { (priceLow + priceHigh) / 2 }

    enum CodingKeys: String, CodingKey {
        case priceLow = "price_low"
        case priceHigh = "price_high"
        case volume
    }
}

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
    /// What the model shared of its thinking before it answered. Absent in
    /// messages saved before it was kept, and from models that share none.
    var reasoning: String? = nil
    /// From the question to the first word of the answer.
    var thinkingSeconds: Double? = nil

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        reasoning: String? = nil,
        thinkingSeconds: Double? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.reasoning = reasoning
        self.thinkingSeconds = thinkingSeconds
    }
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

/// A formatter-free codec for hot and concurrent market-data paths. DateFormatter
/// is relatively expensive and its shared instance becomes a synchronization
/// point when Yahoo responses are decoded in parallel.
enum DayDateCodec {
    static func date(from text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = values.year, let month = values.month, let day = values.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
