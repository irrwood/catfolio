import Foundation

/// Bounded, reviewed exchange schedule, not an inferred calendar from missing
/// price bars. Exceptional closures remain missing-data diagnostics. Sources
/// reviewed 2026-09-10: nasdaqtrader.com/trader.aspx?id=Calendar and
/// nyse.com/trade/hours-calendars. No extrapolation beyond 2026.
enum PolicyUSSessionCalendar {
    static let sources = "https://www.nasdaqtrader.com/trader.aspx?id=Calendar ; https://www.nyse.com/trade/hours-calendars ; reviewed 2026-09-10"
    static func completedSessions(asOf: Date) throws -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        guard calendar.component(.year, from: asOf) == 2026 else { throw PolicyContractError(message: L10n.text("交易日历仅覆盖2026年，不能外推")) }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let closed: Set<String> = ["2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25"]
        let early: Set<String> = ["2026-11-27", "2026-12-24"]
        var day = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        var result: [String] = []
        while day <= asOf {
            let key = formatter.string(from: day)
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1 && weekday != 7 && !closed.contains(key),
               let close = calendar.date(bySettingHour: early.contains(key) ? 13 : 16, minute: 0, second: 0, of: day), close <= asOf { result.append(key) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }
}

enum PolicyTruth: String, Codable, Sendable {
    case yes = "TRUE", no = "FALSE", unknown = "UNKNOWN"
    static func any(_ values: [PolicyTruth]) -> PolicyTruth {
        values.contains(.yes) ? .yes : (values.allSatisfy { $0 == .no } ? .no : .unknown)
    }
    static func all(_ values: [PolicyTruth]) -> PolicyTruth {
        values.contains(.no) ? .no : (values.allSatisfy { $0 == .yes } ? .yes : .unknown)
    }
}

struct PolicyPricePoint: Codable, Sendable { let day: String; let close: Double }

/// The indicators and comparisons a DCA condition is evaluated with.
enum PolicyExecution {
    static func indicator(metric: String, closes: [Double], window: Int) -> Double? {
        let required = metric == "price" ? 1 : (metric == "sma" ? window : window + 1)
        guard window >= 0, required > 0, closes.count >= required else { return nil }
        let values = Array(closes.suffix(required))
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        if metric == "price" { return values.last }
        if metric == "sma" { return values.reduce(0, +) / Double(window) }
        if metric == "return" { return 100 * (values.last! / values.first! - 1) }
        if metric == "rsi" {
            let differences = zip(values.dropFirst(), values).map(-)
            let up = differences.reduce(0) { $0 + max(0, $1) }
            let down = differences.reduce(0) { $0 + max(0, -$1) }
            if up == 0 && down == 0 { return 50 }
            return down == 0 ? 100 : 100 - 100 / (1 + up / down)
        }
        if metric == "volatility", window >= 2 {
            let returns = zip(values.dropFirst(), values).map { log($0 / $1) }
            let mean = returns.reduce(0, +) / Double(window)
            return sqrt(returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(window - 1)) * sqrt(252) * 100
        }
        return nil
    }
    static func compare(_ value: Double?, to threshold: Double, operation: String) -> PolicyTruth {
        guard let value, value.isFinite, threshold.isFinite else { return .unknown }
        switch operation {
        case "LT": return value < threshold ? .yes : .no
        case "LTE": return value <= threshold ? .yes : .no
        case "EQ": return value == threshold ? .yes : .no
        case "GTE": return value >= threshold ? .yes : .no
        case "GT": return value > threshold ? .yes : .no
        case "NE": return value != threshold ? .yes : .no
        default: return .unknown
        }
    }
}
