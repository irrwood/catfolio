import Foundation

struct SecurityPriceHistory: Equatable, Sendable {
    let ticker: String
    let currency: String
    let points: [SecurityPricePoint]
    let intradayPoints: [SecurityPricePoint]
    let trades: [SecurityTrade]
    var extendedHoursPoints: [SecurityPricePoint] = []

    /// One observed trading day, including its pre-market and after-hours.
    /// Regular minute prices remain separate for daily closes and valuations.
    var chartIntradayPoints: [SecurityPricePoint] {
        let sorted = SecurityPricePoint.sortedByDate((intradayPoints + extendedHoursPoints)
            .filter { $0.close.isFinite && $0.close > 0 && $0.date != .distantPast })
        guard let latest = sorted.last else { return [] }
        let symbol = LocalMarketDataClient.yahooSymbol(ticker: ticker, currency: currency)
        let day = LocalMarketDataClient.sessionKey(for: latest.date, symbol: symbol)
        return sorted.filter { LocalMarketDataClient.sessionKey(for: $0.date, symbol: symbol) == day }
    }

    /// Longer chart ranges end at the latest extended print, too. Only the
    /// plotted day's value changes; daily closes and portfolio quotes keep
    /// their regular-session basis in `chartDailyPoints`.
    var chartDailyDisplayPoints: [SecurityPricePoint] {
        let daily = chartDailyPoints
        guard let latest = latestExtendedHoursPoint() else { return daily }
        let day = USMarketSession.dayKey(latest.date)
        return daily.filter { $0.dateText != day }
            + [SecurityPricePoint(dateText: day, close: latest.close)]
    }

    private func latestExtendedHoursPoint(at now: Date? = nil) -> SecurityPricePoint? {
        let symbol = LocalMarketDataClient.yahooSymbol(ticker: ticker, currency: currency)
        guard LocalMarketDataClient.supportsMassiveStockSymbol(symbol),
              let latest = extendedHoursPoints.filter({ point in
                  point.timestamp != nil && point.close.isFinite && point.close > 0 && point.marketSession.isExtended
                      && (now.map { (-60...604_800).contains($0.timeIntervalSince(point.date)) } ?? true)
              }).max(by: { $0.date < $1.date }) else { return nil }
        let day = USMarketSession.dayKey(latest.date)
        // A close already recorded for the pre-market print's day is newer
        // than that print, even when no regular minute bars were returned.
        guard chartDailyPoints.last.map({
                  $0.dateText < day || ($0.dateText == day && latest.marketSession == .postMarket)
              }) ?? true,
              intradayPoints.filter({ $0.timestamp != nil && $0.close.isFinite && $0.close > 0 })
                  .allSatisfy({ $0.date <= latest.date }) else { return nil }
        return latest
    }

    func extendedHoursQuote(at now: Date = .now) -> ExtendedHoursQuote? {
        guard let latest = latestExtendedHoursPoint(at: now) else { return nil }
        // A vendor-confirmed early-close post session can start while the
        // ordinary wall-clock schedule would still say regular trading.
        guard USMarketSession.at(now) != .regular || latest.sessionWindow?.contains(now) == true else { return nil }
        let day = USMarketSession.dayKey(latest.date)
        let daily = chartDailyPoints
        let session = latest.marketSession
        let baseline = daily.last { session == .preMarket ? $0.dateText < day : $0.dateText <= day }
        let change = baseline.map { (latest.close / $0.close - 1) * 100 }
        return ExtendedHoursQuote(session: session, price: latest.close,
            changePercent: change.flatMap { $0.isFinite ? $0 : nil }, observedAt: latest.date,
            sessionWindow: latest.sessionWindow)
    }

    /// Use the same latest market observation for every chart range. A minute
    /// quote can update its own session, but must never replace a newer day.
    /// Never stamp an undated portfolio reference price onto today's history.
    var chartDailyPoints: [SecurityPricePoint] {
        let daily = SecurityPricePoint.sortedByDate(points.filter { $0.close.isFinite && $0.close > 0 })
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
    let sessionWindow: MarketSessionWindow?

    init(dateText: String, close: Double, timestamp: Date? = nil, sessionWindow: MarketSessionWindow? = nil) {
        self.dateText = dateText
        self.close = close
        self.timestamp = timestamp
        self.sessionWindow = sessionWindow
    }

    var id: String { dateText }
    var date: Date { timestamp ?? DayDateCodec.date(from: dateText) ?? .distantPast }
    var marketSession: USMarketSession { sessionWindow?.session ?? USMarketSession.at(date) }

    /// Oldest first. `date` parses the day text, and comparing it inside the
    /// sort parsed every point dozens of times over — the bulk of a long
    /// history's cost on the stock page. Daily closes carry no time, and
    /// their `yyyy-MM-dd` text sorts as their dates do, so it is compared
    /// directly; with any timed point each date is read once.
    static func sortedByDate(_ points: [SecurityPricePoint]) -> [SecurityPricePoint] {
        if points.allSatisfy({ $0.timestamp == nil && $0.dateText.count == 10 }) {
            return points.sorted { $0.dateText < $1.dateText }
        }
        return points.map { ($0, $0.date) }.sorted { $0.1 < $1.1 }.map(\.0)
    }
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

/// A cheap stand-in for a price history's content: which security, how many
/// points of each kind and the latest of each. Comparing it costs nothing,
/// where comparing or re-deriving the history walks thousands of points.
struct SecurityPriceHistoryFingerprint: Hashable {
    let ticker: String
    let currency: String
    let dailyCount: Int
    let lastDaily: String?
    let lastDailyClose: Double?
    let intradayCount: Int
    let lastIntraday: Date?
    let extendedCount: Int
    let lastExtended: Date?

    init(_ history: SecurityPriceHistory) {
        ticker = history.ticker
        currency = history.currency
        dailyCount = history.points.count
        lastDaily = history.points.last?.dateText
        lastDailyClose = history.points.last?.close
        intradayCount = history.intradayPoints.count
        lastIntraday = history.intradayPoints.last?.timestamp
        extendedCount = history.extendedHoursPoints.count
        lastExtended = history.extendedHoursPoints.last?.timestamp
    }
}

/// One value derived from a price history, kept until the history or the
/// extra key changes. The stock page redraws its header on every step of a
/// chart scrub; deriving from the whole history each time made it stutter.
final class SecurityPriceHistoryMemo<Extra: Hashable, Value> {
    private var key: (SecurityPriceHistoryFingerprint, Extra)?
    private var value: Value?
    /// How many times the value was actually derived, for tests.
    private(set) var computations = 0

    func value(for history: SecurityPriceHistory, extra: Extra,
               derive: (SecurityPriceHistory) -> Value) -> Value {
        let fingerprint = SecurityPriceHistoryFingerprint(history)
        if let key, key.0 == fingerprint, key.1 == extra, let value { return value }
        computations += 1
        let derived = derive(history)
        key = (fingerprint, extra)
        value = derived
        return derived
    }
}

/// The after-hours quote changes only when new prices arrive or the minute
/// turns, so it is worked out once per minute and history.
final class ExtendedHoursQuoteCache {
    private let memo = SecurityPriceHistoryMemo<Int, ExtendedHoursQuote?>()
    var computations: Int { memo.computations }

    func quote(for history: SecurityPriceHistory, at date: Date) -> ExtendedHoursQuote? {
        memo.value(for: history, extra: Int((date.timeIntervalSince1970 / 60).rounded(.down))) {
            $0.extendedHoursQuote(at: date)
        }
    }
}
