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
    let warning: String?
    /// Present for real account history (empty when unavailable). In this
    /// mode ChartPoint.cost means cumulative NET EXTERNAL DEPOSITS.
    var accountNAV: [String: Double]? = nil

    enum CodingKeys: String, CodingKey {
        case warning
        case positionCount = "position_count"
        case positionHistory = "position_history"
        case currentPoint = "current_point"
        case accountNAV = "account_nav"
    }

    static func unavailableAccountHistory(positionCount: Int, reason: String) -> Self {
        Self(positionCount: positionCount, positionHistory: .init(available: false, rows: []),
            currentPoint: .init(dateText: "", marketValue: .nan, cost: .nan), warning: reason, accountNAV: [:])
    }

    static func accountHistory(ledger: AccountMWRLedger, nav: [Double?], positionCount: Int) -> Self {
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
            currentPoint: points.last!, warning: "账户资产包含持仓和现金，按历史日线及汇率重建；净入金为累计入金减累计出金。金额显示扣除外部资金流后的盈亏，百分比为区间 TWR。股息按到账日计入，现金余额尚未与券商核对；不是实时账户余额。", accountNAV: units)
    }

    func accountPerformance(from startDate: String, to endDate: String) -> (amount: Double, percentage: Double) {
        guard let accountNAV, let start = positionHistory.rows.first(where: { $0.dateText == startDate }),
              let end = positionHistory.rows.first(where: { $0.dateText == endDate }), startDate <= endDate,
              let base = accountNAV[startDate], base > 0, let last = accountNAV[endDate] else { return (.nan, .nan) }
        return ((end.marketValue - start.marketValue) - (end.cost - start.cost), (last / base - 1) * 100)
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
    var date: Date { DayDateCodec.date(from: dateText) ?? .distantPast }

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
        return CompanyNameCatalog.displayName(ticker: ticker, fallback: original)
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

struct SecurityPriceHistory: Equatable, Sendable {
    let ticker: String
    let currency: String
    let points: [SecurityPricePoint]
    let intradayPoints: [SecurityPricePoint]
    let trades: [SecurityTrade]

    /// Use the same latest market observation for every chart range. A minute
    /// quote can update its own session, but must never replace a newer day.
    /// Never stamp an undated portfolio reference price onto today's history.
    var chartDailyPoints: [SecurityPricePoint] {
        let daily = points.filter { $0.close.isFinite && $0.close > 0 }.sorted { $0.date < $1.date }
        guard let minute = intradayPoints.filter({ $0.close.isFinite && $0.close > 0 && $0.timestamp != nil })
            .max(by: { $0.date < $1.date }) else { return daily }
        let sessionDay = DayDateCodec.string(from: minute.date)
        guard daily.last.map({ sessionDay >= $0.dateText }) ?? true else { return daily }
        return daily.filter { $0.dateText != sessionDay }
            + [SecurityPricePoint(dateText: sessionDay, close: minute.close)]
    }

    var latestAvailablePrice: Double? { chartDailyPoints.last?.close }
}

struct SecurityPricePoint: Equatable, Identifiable, Sendable {
    let dateText: String
    let close: Double
    let timestamp: Date?

    init(dateText: String, close: Double, timestamp: Date? = nil) {
        self.dateText = dateText
        self.close = close
        self.timestamp = timestamp
    }

    var id: String { dateText }
    var date: Date { timestamp ?? DayDateCodec.date(from: dateText) ?? .distantPast }
}

struct SecurityTrade: Equatable, Identifiable, Sendable {
    let dateText: String
    let action: String
    let quantity: Double
    let tradeCount: Int
    let accountKeys: Set<String>

    var id: String { "\(dateText)|\(action)" }
    var date: Date { DayDateCodec.date(from: dateText) ?? .distantPast }
    var isBuy: Bool { Self.canonicalAction(action) == "BUY" }
    var isSell: Bool { Self.canonicalAction(action) == "SELL" }

    static func canonicalAction(_ rawAction: String) -> String? {
        let action = rawAction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if ["SELL", "S", "SLD", "SELL_SHORT"].contains(action)
            || action.contains("SELL")
            || action.contains("卖出") {
            return "SELL"
        }
        if ["BUY", "B", "BOT", "BUY_BACK", "BUY_TO_COVER"].contains(action)
            || action.contains("BUY")
            || action.contains("买入") {
            return "BUY"
        }
        return nil
    }
}

struct ComparisonResponse: Decodable {
    let available: Bool
    let dates: [String]
    let portfolio: [Double?]
    let benchmarks: [String: [Double?]]
    let cashFlowPortfolioReturns: [Double?]?
    let cashFlowBenchmarkReturns: [String: [Double?]]?
    let mwrPortfolio: [Double?]?
    let mwrBenchmarks: [String: [Double?]]?
    let twrDates: [String]?
    let twrPortfolio: [Double?]?
    let twrBenchmarks: [String: [Double?]]?
    let warnings: [String]?
    let summary: ComparisonSummary
    var mwrLedger: AccountMWRLedger? = nil

    enum CodingKeys: String, CodingKey {
        case available, dates, portfolio, benchmarks, warnings, summary
        case cashFlowPortfolioReturns = "cash_flow_portfolio_returns"
        case cashFlowBenchmarkReturns = "cash_flow_benchmark_returns"
        case mwrPortfolio = "mwr_portfolio"
        case mwrBenchmarks = "mwr_benchmarks"
        case twrDates = "twr_dates"
        case twrPortfolio = "twr_portfolio"
        case twrBenchmarks = "twr_benchmarks"
        case mwrLedger = "mwr_ledger"
    }
}

enum MoneyWeightedReturnCalculator {
    /// Date-aware PERIOD return (not annualized XIRR). Positive cash flows
    /// enter the account; negative flows leave it. Inputs must be external
    /// investor flows, never changes in stock cost or trading proceeds.
    static func rolling(
        dates: [String],
        cashFlows: [Double],
        terminalValues: [Double?]
    ) -> [Double?] {
        let count = min(dates.count, cashFlows.count, terminalValues.count)
        guard count > 0 else { return [] }

        var events: [(date: Date, amount: Double)] = []
        var result: [Double?] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            guard let date = DayDateCodec.date(from: dates[index]) else {
                result.append(nil)
                continue
            }
            let cashFlow = cashFlows[index]
            if cashFlow.isFinite, abs(cashFlow) > 0.000_001 {
                events.append((date, -cashFlow))
            }
            guard let terminalValue = terminalValues[index],
                  terminalValue.isFinite,
                  terminalValue >= 0 else {
                result.append(nil)
                continue
            }
            result.append(solve(events: events, terminalDate: date, terminalValue: terminalValue))
        }
        return result
    }

    private static func solve(
        events: [(date: Date, amount: Double)],
        terminalDate: Date,
        terminalValue: Double
    ) -> Double? {
        guard let startDate = events.first?.date,
              terminalDate > startDate,
              events.contains(where: { $0.amount < 0 }) else { return nil }
        if terminalValue == 0, events.allSatisfy({ $0.amount <= 0 }) { return -1 }
        guard events.contains(where: { $0.amount > 0 }) || terminalValue > 0 else { return nil }

        let duration = terminalDate.timeIntervalSince(startDate)
        guard duration > 0 else { return nil }
        let flows = events + [(terminalDate, terminalValue)]
        guard flows.contains(where: { $0.amount > 0 }) else { return nil }
        let scale = flows.reduce(0) { $0 + abs($1.amount) }
        guard scale > 0 else { return nil }

        func npv(logGrowth: Double) -> (value: Double, derivative: Double) {
            var value = 0.0
            var derivative = 0.0
            for flow in flows {
                let fraction = max(0, flow.date.timeIntervalSince(startDate) / duration)
                let discount = exp(-fraction * logGrowth)
                value += flow.amount * discount
                derivative -= fraction * flow.amount * discount
            }
            return (value, derivative)
        }

        // Newton converges quickly for normal portfolio cash-flow streams.
        var logGrowth = log(1.1)
        for _ in 0..<32 {
            let current = npv(logGrowth: logGrowth)
            if abs(current.value) <= scale * 1e-10 {
                let rate = exp(logGrowth) - 1
                return rate.isFinite ? rate : nil
            }
            guard current.derivative.isFinite, abs(current.derivative) > scale * 1e-14 else { break }
            let next = logGrowth - current.value / current.derivative
            guard next.isFinite, (-20...20).contains(next) else { break }
            if abs(next - logGrowth) < 1e-11 {
                let rate = exp(next) - 1
                return rate.isFinite ? rate : nil
            }
            logGrowth = next
        }

        // Irregular deposits and withdrawals can defeat Newton. Scan the valid
        // growth domain and bisect the root nearest a flat return.
        let scan = stride(from: -20.0, through: 20.0, by: 0.25).map { $0 }
        var brackets: [(lower: Double, upper: Double)] = []
        var previousX = scan[0]
        var previousValue = npv(logGrowth: previousX).value
        for x in scan.dropFirst() {
            let value = npv(logGrowth: x).value
            if value == 0 {
                let rate = exp(x) - 1
                return rate.isFinite ? rate : nil
            }
            if previousValue.isFinite, value.isFinite,
               (previousValue < 0 && value > 0) || (previousValue > 0 && value < 0) {
                brackets.append((previousX, x))
            }
            previousX = x
            previousValue = value
        }
        guard var bracket = brackets.min(by: {
            abs(($0.lower + $0.upper) / 2) < abs(($1.lower + $1.upper) / 2)
        }) else { return nil }

        var lowerValue = npv(logGrowth: bracket.lower).value
        for _ in 0..<80 {
            let midpoint = (bracket.lower + bracket.upper) / 2
            let midpointValue = npv(logGrowth: midpoint).value
            if abs(midpointValue) <= scale * 1e-10 {
                let rate = exp(midpoint) - 1
                return rate.isFinite ? rate : nil
            }
            if (lowerValue < 0 && midpointValue > 0) || (lowerValue > 0 && midpointValue < 0) {
                bracket.upper = midpoint
            } else {
                bracket.lower = midpoint
                lowerValue = midpointValue
            }
        }
        let rate = exp((bracket.lower + bracket.upper) / 2) - 1
        return rate.isFinite ? rate : nil
    }
}

/// Shared, reconstructed account valuations and external flows in reporting USD.
/// Retain the inputs so each selected interval can solve its own MWR.
struct AccountMWRLedger: Codable, Sendable {
    var dates: [String]
    var cashFlows: [Double]
    var values: [Double?]
    var benchmarkValues: [String: [Double?]]
    var inflows: [Double]? = nil
    var outflows: [Double]? = nil

    /// USD assets plus actual cumulative withdrawals. Returns here are simple
    /// profit / gross deposits, not time- or money-weighted returns.
    func cashFlowComparison() -> (portfolio: [Double?], benchmarks: [String: [Double?]], portfolioReturns: [Double?], benchmarkReturns: [String: [Double?]])? {
        guard let inflows, let outflows, inflows.count == dates.count, outflows.count == dates.count,
              values.count == dates.count, cashFlows.count == dates.count,
              inflows.allSatisfy({ $0.isFinite && $0 >= 0 }), outflows.allSatisfy({ $0.isFinite && $0 >= 0 }),
              cashFlows.indices.allSatisfy({ cashFlows[$0].isFinite && abs(cashFlows[$0] - (inflows[$0] - outflows[$0])) < 1e-7 }) else { return nil }
        func adjust(_ series: [Double?]) -> (values: [Double?], returns: [Double?]) {
            guard series.count == dates.count else { return (dates.map { _ in nil }, dates.map { _ in nil }) }
            var deposited = 0.0
            var withdrawn = 0.0
            var adjusted: [Double?] = []
            var returns: [Double?] = []
            for index in dates.indices {
                deposited += inflows[index]
                withdrawn += outflows[index]
                guard let value = series[index], value.isFinite, value >= 0 else {
                    adjusted.append(nil); returns.append(nil); continue
                }
                adjusted.append(value + withdrawn)
                returns.append(deposited > 0 ? (value + withdrawn) / deposited - 1 : nil)
            }
            return (adjusted, returns)
        }
        let portfolio = adjust(values)
        let benchmarks = benchmarkValues.mapValues(adjust)
        return (portfolio.values, benchmarks.mapValues(\.values), portfolio.returns, benchmarks.mapValues(\.returns))
    }

    func returns(startIndex: Int = 0, endIndex: Int? = nil) -> (dates: [String], portfolio: [Double?], benchmarks: [String: [Double?]]) {
        let end = endIndex ?? (dates.count - 1)
        guard cashFlows.count == dates.count, values.count == dates.count,
              startIndex >= 0, end >= startIndex, end < dates.count,
              cashFlows.allSatisfy(\.isFinite) else { return ([], [], [:]) }
        let range = startIndex...end
        let selectedDates = Array(dates[range])
        func calculate(_ valuations: [Double?]) -> [Double?] {
            guard valuations.count == dates.count else { return selectedDates.map { _ in nil } }
            var flows = Array(cashFlows[range])
            if startIndex > 0 {
                // The opening valuation already includes that day's flows.
                guard let opening = valuations[startIndex], opening.isFinite, opening >= 0 else {
                    return selectedDates.map { _ in nil }
                }
                flows[0] = opening
            }
            return MoneyWeightedReturnCalculator.rolling(dates: selectedDates, cashFlows: flows,
                terminalValues: Array(valuations[range]))
        }
        return (selectedDates, calculate(values), benchmarkValues.mapValues(calculate))
    }

    /// Invest exactly the account's dated net external flows in a total-return
    /// benchmark. A withdrawal the benchmark cannot fund makes it unavailable;
    /// never clamp units to zero and pretend the same cash flow was funded.
    static func mirror(cashFlows: [Double], prices: [Double?]) -> [Double?] {
        guard prices.count == cashFlows.count else { return [] }
        var units = 0.0
        var valid = true
        return cashFlows.indices.map { index in
            if valid, units == 0, cashFlows[index] == 0 { return 0 }
            guard valid, cashFlows[index].isFinite, let price = prices[index], price.isFinite, price > 0 else {
                valid = false
                return nil
            }
            units += cashFlows[index] / price
            guard units >= -1e-10 else { valid = false; return nil }
            return max(0, units) * price
        }
    }
}

enum ComparisonBenchmarkCatalog {
    static let symbols = ["SPY", "QQQ", "VTI", "VOO", "DIA", "IWM", "VEU", "GLD"]

    static let names = [
        "SPY": "标普500",
        "QQQ": "纳斯达克100",
        "VTI": "美国全市场",
        "VOO": "先锋标普500",
        "DIA": "道琼斯30",
        "IWM": "罗素2000",
        "VEU": "全球除美",
        "GLD": "黄金",
    ]
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
    let benchmark: Double?

    var id: Date { date }
}

struct BriefingResponse: Decodable {
    let briefing: String
}

struct AskResponse: Decodable {
    let answer: String
    let question: String
}

enum PortfolioAttentionLevel: String, Codable, Sendable {
    case high, medium, none
}

enum PortfolioThesisStance: String, Codable, Sendable {
    case strengthening, maintaining, weakening
}

struct PortfolioAttentionSignal: Identifiable, Codable, Sendable {
    let kind: String
    let label: String
    let direction: String
    let value: Double

    var id: String { kind }
}

struct PortfolioAttentionSource: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    let publisher: String
    let url: URL
    let publishedAt: Date?
    let tier: String
}

struct PortfolioAttentionThesis: Codable, Sendable {
    var stance: PortfolioThesisStance
    var confidence: PortfolioAttentionLevel
    var whatChanged: String
    var whyItMatters: String
    var supportingEvidence: [String]
    var counterEvidence: [String]
    var risks: [String]
    var watchNext: [String]
    var riskFlags: [String]
}

struct PortfolioFundamentalSnapshot: Codable, Sendable {
    let source: String
    let latestPeriod: String?
    let revenueGrowthYoY: Double?
    let operatingIncomeGrowthYoY: Double?
    let freeCashFlowGrowthYoY: Double?
}

struct PortfolioAttentionHolding: Identifiable, Codable, Sendable {
    let ticker: String
    let name: String
    let attention: PortfolioAttentionLevel
    let weight: Double
    let portfolioContributionPercent: Double?
    let return60DPercent: Double?
    let volumeMultiple: Double?
    let distanceFrom52WHighPercent: Double?
    let distanceFrom52WLowPercent: Double?
    let ma200PositionPercent: Double?
    let signals: [PortfolioAttentionSignal]
    var fundamentals: PortfolioFundamentalSnapshot?
    var thesis: PortfolioAttentionThesis
    var sources: [PortfolioAttentionSource]

    var id: String { ticker }
}

struct PortfolioAttentionReport: Codable, Sendable {
    let generatedAt: Date
    let holdingsCount: Int
    let noMaterialChangeCount: Int
    var attentionRows: [PortfolioAttentionHolding]
    let warnings: [String]

    var contextSummary: String {
        let rows = attentionRows.map { row in
            let signals = row.signals.map(\.label).joined(separator: "、")
            return "\(row.ticker) | \(row.attention.rawValue) | \(row.thesis.stance.rawValue) | \(row.thesis.confidence.rawValue) | \(signals) | \(row.thesis.whyItMatters)"
        }.joined(separator: "\n")
        return "Portfolio Attention 扫描了 \(holdingsCount) 只持仓，\(attentionRows.count) 只需要关注。\n\(rows)"
    }

    var markdownFallback: String {
        var blocks = ["## 今天", "**\(holdingsCount) 只持仓中有 \(attentionRows.count) 只需要关注**"]
        for row in attentionRows {
            blocks.append("""
            ### \(row.ticker)
            \(row.attention.rawValue.capitalized) attention · \(row.thesis.stance.rawValue)

            \(row.signals.map(\.label).joined(separator: " · "))

            \(row.thesis.whyItMatters)

            **主要风险：** \(row.thesis.risks.first ?? "暂无已确认的公司级风险")
            """)
        }
        blocks.append("**其他持仓**\n\(noMaterialChangeCount) 只 · 无重大变化")
        return blocks.joined(separator: "\n\n")
    }
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
            "支持 iPhone 直连并合并两个账户。"
        case .moomoo:
            "支持 iPhone OAuth 2.1 + PKCE 直连。"
        case .ibkr:
            "支持 iPhone 直连 IBKR Flex Web Service。"
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

struct CSVImportResult: Decodable {
    let ok: Bool
    let holdingsCount: Int
    let transactionsCount: Int?
    let backupCreated: Bool?
    let warnings: [String]
    let holdings: [CSVImportedHolding]?

    enum CodingKeys: String, CodingKey {
        case ok, warnings, holdings
        case holdingsCount = "holdings_count"
        case transactionsCount = "transactions_count"
        case backupCreated = "backup_created"
    }
}

struct CSVImportedHolding: Decodable, Identifiable {
    let ticker: String
    let name: String
    let shares: Double
    let averageCost: Double
    let currency: String

    var id: String { ticker }

    enum CodingKeys: String, CodingKey {
        case ticker, name, shares, currency
        case averageCost = "avg_cost"
    }
}

enum ETFLookThroughBasis: String, CaseIterable, Identifiable {
    case market
    case cost

    var id: String { rawValue }
    var title: String { self == .market ? "ETF 市值" : "ETF 成本" }
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

    var id: String { ticker }

    enum CodingKeys: String, CodingKey {
        case ticker, name, sector
        case estimatedHoldingPeriodPercent = "estimated_holding_period_percent"
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

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
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
