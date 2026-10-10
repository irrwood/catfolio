import Foundation

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

    /// Preserve the feed's observation time when publishing a detail quote.
    /// Daily-only data stays at its session date; it is never stamped as now.
    var latestMarketObservation: SecurityMarketObservation? {
        let daily = chartDailyPoints
        guard let last = daily.last, last.date != .distantPast else { return nil }
        let minute = intradayPoints.filter {
            $0.timestamp != nil && $0.close.isFinite && $0.close > 0
                && DayDateCodec.string(from: $0.date) == last.dateText
        }.max { $0.date < $1.date }
        let previous = daily.last { $0.dateText < last.dateText }
        let change = previous.map { (last.close / $0.close - 1) * 100 }
        return SecurityMarketObservation(ticker: ticker.uppercased(), currency: currency,
                                         price: last.close, observedAt: minute?.date ?? last.date,
                                         changePercent: change.flatMap { $0.isFinite ? $0 : nil })
    }
}

struct SecurityMarketObservation: Sendable {
    let ticker: String
    let currency: String
    let price: Double
    let observedAt: Date
    let changePercent: Double?
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
    struct Execution: Equatable, Sendable {
        let accountKey: String
        let quantity: Double
        let amount: Double?
        let currency: String
        let profit: Double?
        let profitCurrency: String?
        /// When the fill executed, where the broker says; places it on the
        /// intraday line.
        var executedAt: Date? = nil
    }

    let dateText: String
    let action: String
    let quantity: Double
    let tradeCount: Int
    let accountKeys: Set<String>
    var executions: [Execution] = []

    var amountTotals: [String: Double]? { totals(profit: false) }
    var profitTotals: [String: Double]? { isSell ? totals(profit: true) : nil }

    private func totals(profit: Bool) -> [String: Double]? {
        guard !executions.isEmpty else { return nil }
        var result: [String: Double] = [:]
        for row in executions {
            guard let value = profit ? row.profit : row.amount,
                  let currency = profit ? row.profitCurrency : row.currency,
                  value.isFinite, !currency.isEmpty else { return nil }
            let key = currency == "GBp" ? "GBX" : currency.uppercased()
            result[key, default: 0] += value
        }
        return result.values.allSatisfy(\.isFinite) ? result : nil
    }

    static func grouped(_ transactions: [LocalTransactionRecord]) -> [SecurityTrade] {
        let rows = transactions.filter { canonicalAction($0.action) != nil }
        return Dictionary(grouping: rows) { "\($0.date)|\(canonicalAction($0.action)!)" }
            .values.compactMap { rows in
                guard let first = rows.first else { return nil }
                return SecurityTrade(dateText: first.date, action: canonicalAction(first.action)!,
                    quantity: rows.reduce(0) { $0 + abs($1.quantity) }, tradeCount: rows.count,
                    accountKeys: Set(rows.map(\.accountKey)), executions: rows.map { row in
                        let amount = abs(row.quantity) * row.price
                        let currency = row.currency.trimmingCharacters(in: .whitespacesAndNewlines)
                        let profitCurrency = row.realisedProfitLossCurrency?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return Execution(accountKey: row.accountKey, quantity: abs(row.quantity),
                            amount: amount.isFinite && row.price > 0 && !currency.isEmpty ? amount : nil,
                            currency: currency,
                            profit: row.realisedProfitLoss.flatMap { $0.isFinite ? $0 : nil },
                            profitCurrency: profitCurrency?.isEmpty == false ? profitCurrency : nil,
                            executedAt: row.executedAt.flatMap(Self.executionDate))
                    })
            }.sorted { $0.id < $1.id }
    }

    func filtered(accounts: Set<String>) -> SecurityTrade? {
        guard !accountKeys.isDisjoint(with: accounts) else { return nil }
        guard !executions.isEmpty else { return self }
        let rows = executions.filter { accounts.contains($0.accountKey) }
        guard !rows.isEmpty else { return nil }
        return SecurityTrade(dateText: dateText, action: action,
            quantity: rows.reduce(0) { $0 + $1.quantity }, tradeCount: rows.count,
            accountKeys: Set(rows.map(\.accountKey)), executions: rows)
    }

    var id: String { "\(dateText)|\(action)" }
    var date: Date { DayDateCodec.date(from: dateText) ?? .distantPast }
    /// The earliest known execution time of the day's fills.
    var executedAt: Date? { executions.compactMap(\.executedAt).min() }

    private static func executionDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
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
