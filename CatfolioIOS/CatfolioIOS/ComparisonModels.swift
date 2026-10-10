import Foundation

struct ComparisonResponse: Codable {
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
    /// What the rebuild assumed or could not use, for Settings to list.
    var dataIssues: [String]? = nil

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
        case dataIssues = "data_issues"
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

    /// Annualized money-weighted return, using the selected interval's
    /// opening assets and dated external investments/withdrawals.
    func annualizedReturn(startIndex: Int = 0, endIndex: Int? = nil) -> Double? {
        let end = endIndex ?? (dates.count - 1)
        guard startIndex >= 0, end > startIndex, end < dates.count,
              cashFlows.count == dates.count, values.count == dates.count else { return nil }
        let firstInvestment: Int?
        if startIndex > 0, let opening = values[startIndex], opening > 0 {
            firstInvestment = startIndex
        } else {
            firstInvestment = (startIndex...end).first { cashFlows[$0] > 0 }
        }
        guard let firstInvestment,
              let start = DayDateCodec.date(from: dates[firstInvestment]),
              let finish = DayDateCodec.date(from: dates[end]) else { return nil }
        let days = finish.timeIntervalSince(start) / 86400
        guard days >= 30,
              let periodReturn = returns(startIndex: startIndex, endIndex: end).portfolio.last ?? nil,
              periodReturn > -1 else { return nil }
        let annualized = pow(1 + periodReturn, 365.25 / days) - 1
        return annualized.isFinite ? annualized : nil
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

/// What the returns comparison measures the portfolio against. The reader
/// picks the list — any index fund or stock the market search finds — and
/// the eight index funds below are where it starts and what search
/// recommends.
enum ComparisonBenchmarkCatalog {
    static let defaults = ["SPY", "QQQ", "VTI", "VOO", "DIA", "IWM", "VEU", "GLD"]
    /// Each series draws a line and fetches a history, so the list is capped.
    static let maximumCount = 12
    /// The chosen symbols joined by commas; absent until the reader first
    /// changes the list. Held as one string so views can observe it through
    /// `@AppStorage`.
    static let preferenceKey = "returns.comparisonBenchmarks"
    private static let namesKey = "returns.comparisonBenchmarkNames"

    /// The chosen symbols, in the order they were added.
    static var symbols: [String] { symbols(from: UserDefaults.standard.string(forKey: preferenceKey)) }

    static func symbols(from stored: String?) -> [String] {
        guard let stored else { return defaults }
        return stored.split(separator: ",").map(String.init)
    }

    static func store(_ symbols: [String]) {
        var seen = Set<String>()
        let unique = symbols.filter { seen.insert($0).inserted }.prefix(maximumCount)
        UserDefaults.standard.set(unique.joined(separator: ","), forKey: preferenceKey)
    }

    /// Adds a symbol the search found, remembering its name for the list.
    static func add(_ symbol: String, name: String?) {
        guard !symbols.contains(symbol), symbols.count < maximumCount else { return }
        if let name, names[symbol] == nil {
            var stored = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
            stored[symbol] = name
            UserDefaults.standard.set(stored, forKey: namesKey)
        }
        store(symbols + [symbol])
    }

    static func remove(_ symbol: String) {
        store(symbols.filter { $0 != symbol })
    }

    static func name(for symbol: String) -> String? {
        names[symbol] ?? (UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String])?[symbol]
    }

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

struct ComparisonSummary: Codable {
    let portfolioReturn: Double?
    let benchmarkReturn: Double?
    let benchmarkReturns: [String: Double?]

    enum CodingKeys: String, CodingKey {
        case portfolioReturn = "portfolio_return"
        case benchmarkReturn = "benchmark_return"
        case benchmarkReturns = "benchmark_returns"
    }
}
