import Foundation

/// A DCA-specific cash-flow simulation, sharing the composer's indicator and
/// three-valued predicate implementation. It does not rebalance or place orders.
enum DCAJoin: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, any
    var id: String { rawValue }
    var title: String { self == .all ? L10n.text("全部满足") : L10n.text("任一满足") }
    func evaluate(_ values: [PolicyTruth]) -> PolicyTruth {
        guard !values.isEmpty else { return .yes }
        return self == .all ? PolicyTruth.all(values) : PolicyTruth.any(values)
    }
}

enum DCAFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case weekly, monthly
    var id: String { rawValue }
    var title: String { self == .weekly ? L10n.text("每周") : L10n.text("每月") }
}

struct DCASettings: Codable, Equatable, Sendable {
    var symbol = "SPY"
    var baseAmount = 500.0
    var frequency = DCAFrequency.weekly
    // Retired saved fields are ignored by Codable and never affect execution.
    var conditionPlan: DCAConditionPlan? = nil
    var start = DCASimulation.calendar.date(byAdding: .year, value: -3, to: Date())!
    var end = DCASimulation.calendar.date(byAdding: .day, value: -1, to: Date())!
    var normalizedSymbol: String { symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: ".", with: "-") }
    var validationError: String? {
        guard normalizedSymbol.range(of: #"^[A-Z]{1,6}(-[AB])?$"#, options: .regularExpression) != nil else { return L10n.text("请输入美股或 ETF 代码") }
        guard start < end, end <= Date(), end.timeIntervalSince(start) <= 366 * 10 * 86400 else { return L10n.text("请选择有效日期，回测范围最多十年") }
        guard baseAmount.isFinite, (50...100_000).contains(baseAmount)
        else { return L10n.text("定投参数超出有效范围") }
        return conditionPlan?.validationError
    }
}

enum DCABranch: String, Codable, Sendable {
    case add, base, reduce, unknown
    var title: String {
        switch self {
        case .add: L10n.text("加仓分支")
        case .base: L10n.text("基础分支")
        case .reduce: L10n.text("减量分支")
        case .unknown: L10n.text("数据不足，暂停本期买入")
        }
    }
}

struct DCADecision: Sendable {
    let branch: DCABranch
    let multiplier: Double
    let gate: PolicyTruth
    let boost: PolicyTruth
}

struct DCATrade: Identifiable, Sendable {
    var id: String { date }
    let date: String
    let signalDate: String?
    let price: Double
    let scheduledAmount: Double
    let amount: Double
    let shares: Double
    let decision: DCADecision
    var deposit: Double { amount }
    var actualMultiplier: Double { scheduledAmount > 0 ? amount / scheduledAmount : 0 }
}

struct DCACurvePoint: Identifiable, Sendable {
    var id: String { day }
    let day: String
    let date: Date
    let contributed: Double
    let value: Double
    let holdings: Double
    let baseline: Double
    let baselineContributed: Double
    let drawdown: Double
}

struct DCAResult: Sendable {
    let settings: DCASettings
    let curve: [DCACurvePoint]
    let trades: [DCATrade]
    let annualizedReturn: Double?
    let baselineAnnualizedReturn: Double?
    let baselineMaxDrawdown: Double
    let baselineBuyCount: Int
    let warnings: [String]
    var final: DCACurvePoint { curve.last! }
    var profit: Double { final.value - final.contributed }
    var returnRatio: Double { final.contributed > 0 ? profit / final.contributed : 0 }
    var maxDrawdown: Double { curve.map(\.drawdown).min() ?? 0 }
    var baselineProfit: Double { final.baseline - final.baselineContributed }
    var baselineReturnRatio: Double { final.baselineContributed > 0 ? baselineProfit / final.baselineContributed : 0 }
    var excessProfit: Double { profit - baselineProfit }
    var excessReturnRatio: Double { returnRatio - baselineReturnRatio }
    var shares: Double { trades.reduce(0) { $0 + $1.shares } }
    var buyCount: Int { trades.filter { $0.amount > 0.000001 }.count }
}

struct DCAError: LocalizedError { let message: String; var errorDescription: String? { message } }

enum DCASimulation {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    /// Monthly cadence remains anchored to the original day even after February.
    static func scheduledDate(start: Date, period: Int, frequency: DCAFrequency) -> Date {
        let anchor = calendar.startOfDay(for: start)
        if frequency == .weekly { return calendar.date(byAdding: .day, value: period * 7, to: anchor)! }
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor))!
        let month = calendar.date(byAdding: .month, value: period, to: monthStart)!
        let day = min(calendar.component(.day, from: anchor), calendar.range(of: .day, in: .month, for: month)!.count)
        return calendar.date(byAdding: .day, value: day - 1, to: month)!
    }

    static func run(settings c: DCASettings, prices input: [PolicyPricePoint]) throws -> DCAResult {
        if let error = c.validationError { throw DCAError(message: error) }
        guard input.allSatisfy({ $0.close.isFinite && $0.close > 0 && DayDateCodec.date(from: $0.day) != nil }),
              Set(input.map(\.day)).count == input.count else { throw DCAError(message: L10n.text("历史价格无效或存在重复日期")) }
        let today = DayDateCodec.string(from: Date())
        let rows = input.filter { $0.day < today }.sorted { $0.day < $1.day }
        let startKey = DayDateCodec.string(from: c.start), endKey = DayDateCodec.string(from: c.end)
        let indices = rows.indices.filter { rows[$0].day >= startKey && rows[$0].day <= endKey }
        guard indices.count >= 2 else { throw DCAError(message: L10n.text("所选区间历史行情不足")) }
        let anchor = max(calendar.startOfDay(for: c.start), DayDateCodec.date(from: rows[0].day)!)
        var period = 0, shares = 0.0, baseShares = 0.0
        var contributed = 0.0, baseContributed = 0.0, previousValue = 0.0, unitNAV = 1.0, peakNAV = 1.0
        var previousBaseValue = 0.0, baseUnitNAV = 1.0, basePeakNAV = 1.0, baseMaxDrawdown = 0.0
        var baseBuyCount = 0
        var curve: [DCACurvePoint] = [], trades: [DCATrade] = []
        var deposits: [Double] = [], baselineDeposits: [Double] = []
        for index in indices {
            try Task.checkCancellation()
            let row = rows[index], day = DayDateCodec.date(from: row.day)!
            let beforeFlow = shares * row.close
            if previousValue > 0 { unitNAV *= beforeFlow / previousValue }
            peakNAV = max(peakNAV, unitNAV)
            let drawdown = unitNAV / peakNAV - 1
            // Measure each portfolio before its own external investment.
            let baseBeforeFlow = baseShares * row.close
            if previousBaseValue > 0 { baseUnitNAV *= baseBeforeFlow / previousBaseValue }
            basePeakNAV = max(basePeakNAV, baseUnitNAV)
            baseMaxDrawdown = min(baseMaxDrawdown, baseUnitNAV / basePeakNAV - 1)
            var scheduledAmount = 0.0, actualInvestment = 0.0
            if day >= scheduledDate(start: anchor, period: period, frequency: c.frequency) {
                repeat { scheduledAmount += c.baseAmount; period += 1 }
                while day >= scheduledDate(start: anchor, period: period, frequency: c.frequency)
                let decision = c.conditionPlan?.decision(priorPrices: rows[..<index])
                    ?? DCADecision(branch: .base, multiplier: 1, gate: .yes, boost: .no)
                // Invest the strategy amount directly. There is no prefunded cash account.
                actualInvestment = scheduledAmount * decision.multiplier
                contributed += actualInvestment
                baseContributed += scheduledAmount
                shares += actualInvestment / row.close
                baseShares += scheduledAmount / row.close
                if scheduledAmount > 0.000001 { baseBuyCount += 1 }
                trades.append(.init(date: row.day, signalDate: index > 0 ? rows[index - 1].day : nil,
                                    price: row.close, scheduledAmount: scheduledAmount, amount: actualInvestment,
                                    shares: actualInvestment / row.close, decision: decision))
            }
            previousValue = shares * row.close
            previousBaseValue = baseShares * row.close
            curve.append(.init(day: row.day, date: day, contributed: contributed, value: previousValue,
                               holdings: previousValue, baseline: previousBaseValue,
                               baselineContributed: baseContributed, drawdown: drawdown))
            deposits.append(actualInvestment)
            baselineDeposits.append(scheduledAmount)
        }
        // Each series uses its actual purchases as external cash flows and its own first investment date.
        func annualizedReturn(flows: [Double], terminalValue: Double) -> Double? {
            guard let first = flows.firstIndex(where: { $0 > 0 }),
                  let last = curve.last else { return nil }
            let duration = last.date.timeIntervalSince(curve[first].date) / 86400
            guard duration >= 30 else { return nil }
            let periodReturn = MoneyWeightedReturnCalculator.rolling(dates: curve.map(\.day), cashFlows: flows,
                terminalValues: curve.indices.map { $0 == curve.count - 1 ? terminalValue : nil }).last ?? nil
            return periodReturn.flatMap {
                let rate = pow(1 + $0, 365.25 / duration) - 1
                return rate.isFinite ? rate : nil
            }
        }
        var warnings: [String] = []
        if rows[0].day > startKey { warnings.append(L10n.text("开始日期早于行情，已按可用区间回测")) }
        if c.end.timeIntervalSince(curve.last!.date) > 4 * 86400 { warnings.append(L10n.text("结束日期晚于行情，结果截至最后可用交易日")) }
        if trades.contains(where: { $0.decision.branch == .unknown }) { warnings.append(L10n.text("部分指标历史不足，对应期次未投入、未买入。")) }
        return .init(settings: c, curve: curve, trades: trades,
                     annualizedReturn: annualizedReturn(flows: deposits, terminalValue: curve.last!.value),
                     baselineAnnualizedReturn: annualizedReturn(flows: baselineDeposits, terminalValue: curve.last!.baseline),
                     baselineMaxDrawdown: baseMaxDrawdown, baselineBuyCount: baseBuyCount,
                     warnings: warnings)
    }

    static func demoPrices(symbol: String, end: Date) -> [PolicyPricePoint] {
        let first = calendar.date(byAdding: .year, value: -6, to: end)!
        let seed = Double(symbol.utf8.reduce(0) { $0 + Int($1) })
        var day = calendar.startOfDay(for: first), result: [PolicyPricePoint] = [], index = 0.0
        while day <= end {
            if ![1,7].contains(calendar.component(.weekday, from: day)) {
                let price = 100 * exp(index * 0.00035 + 0.19 * sin(index / 73 + seed) + 0.045 * sin(index / 9))
                result.append(.init(day: DayDateCodec.string(from: day), close: price)); index += 1
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }
}
