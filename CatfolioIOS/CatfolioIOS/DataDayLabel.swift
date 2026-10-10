import SwiftUI
import UIKit

/// Names the day a set of figures belongs to, the way a person would:
/// 今天, 昨天, the weekday within the past week, the date before that.
enum DataDayLabel {
    /// `now` is read on the reader's own calendar: just past midnight is
    /// already the next day for them, whatever the date is in UTC.
    static func text(for dayKey: String, locale: Locale, now: Date = Date(),
                     timeZone: TimeZone = .current) -> String {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: now)
        let today = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard let date = DayDateCodec.date(from: dayKey),
              let current = DayDateCodec.date(from: today) else { return dayKey }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var style = Date.FormatStyle(date: .omitted, time: .omitted).locale(locale)
        style.timeZone = calendar.timeZone
        switch calendar.dateComponents([.day], from: date, to: current).day ?? 0 {
        case ...0: return L10n.text("今天")
        case 1: return L10n.text("昨天")
        case 2...6: return date.formatted(style.weekday(.abbreviated))
        default: return date.formatted(style.month(.abbreviated).day())
        }
    }

    /// No selection, or the newest available session, keeps the home title.
    /// Market opening hours do not determine whether data is the latest.
    static func homeTitle(displayedDay: String?, latestDay: String?, locale: Locale,
                          now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let displayedDay, let latestDay, displayedDay < latestDay else { return "CATFOLIO" }
        return text(for: displayedDay, locale: locale, now: now, timeZone: timeZone)
    }

    /// The latest trading day among these dates. A snapshot taken on a
    /// Saturday is dated Saturday, but its prices are Friday's.
    static func latestSession(in dates: [String]) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return dates.filter { key in
            guard let date = DayDateCodec.date(from: key) else { return false }
            return !calendar.isDateInWeekend(date)
        }.max()
    }

    /// True while any held listing's market is in session, so its prices are
    /// moving now.
    static func isLive(_ holdings: [Holding], at date: Date = Date()) -> Bool {
        holdings.contains { MarketHours.isOpen(ticker: $0.ticker, at: date) }
    }
}
