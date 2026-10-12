import Foundation

/// U.S. exchange-local boundaries. A session label for a quote always comes
/// from its observation time, never from the phone's time zone.
enum USMarketSession: String, Codable, Sendable {
    case preMarket, regular, postMarket, closed

    static let timeZone = TimeZone(identifier: "America/New_York")!

    var isExtended: Bool { self == .preMarket || self == .postMarket }

    static func at(_ date: Date) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, (2...6).contains(weekday) else { return .closed }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        switch minute {
        case 240..<570: return .preMarket
        case 570..<960: return .regular
        case 960..<1200: return .postMarket
        default: return .closed
        }
    }

    static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct MarketSessionWindow: Codable, Equatable, Sendable {
    let session: USMarketSession
    let start: Date
    let end: Date

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

struct ExtendedHoursQuote: Equatable, Sendable {
    let session: USMarketSession
    let price: Double
    let changePercent: Double?
    let observedAt: Date
    var sessionWindow: MarketSessionWindow? = nil

    func isCurrentSession(at now: Date) -> Bool {
        session.isExtended && (sessionWindow?.contains(now) ?? (USMarketSession.at(now) == session))
            && USMarketSession.dayKey(now) == USMarketSession.dayKey(observedAt)
            && (-60...1800).contains(now.timeIntervalSince(observedAt))
    }
}
