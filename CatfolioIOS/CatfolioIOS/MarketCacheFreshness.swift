import Foundation

/// Cache-fetch age is separate from the quote's market observation timestamp.
/// Reusing a cached response must never make an old quote look newly observed.
enum MarketCacheFreshness {
    static let intraday: TimeInterval = 5 * 60
    static let history: TimeInterval = 12 * 60 * 60
    static let volume: TimeInterval = 24 * 60 * 60

    static func isFresh(fetchedAt: Date, lifetime: TimeInterval, now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < lifetime
    }
}
