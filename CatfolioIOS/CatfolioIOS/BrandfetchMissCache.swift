import Foundation

/// Tickers Brandfetch has no logo for, remembered for a week so the app shows
/// the letter tile at once instead of opening a web view for a known 404.
///
/// Only the fact "no logo" is stored — never an image. Brandfetch's terms ask
/// for logos to be hotlinked rather than cached; see BrandfetchLogoImage.
final class BrandfetchMissCache: @unchecked Sendable {
    static let shared = BrandfetchMissCache(defaults: .standard)
    static let storageKey = "catfolio.brandfetch.misses"
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    static let capacity = 2_000

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var misses: [String: TimeInterval]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        misses = defaults.dictionary(forKey: Self.storageKey) as? [String: TimeInterval] ?? [:]
    }

    func isMissing(_ ticker: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let recorded = misses[Self.key(ticker)] else { return false }
        return now.timeIntervalSince1970 - recorded < Self.lifetime
    }

    func recordMissing(_ ticker: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let time = now.timeIntervalSince1970
        misses = misses.filter { time - $0.value < Self.lifetime }
        misses[Self.key(ticker)] = time
        if misses.count > Self.capacity {
            // Drop the oldest entries; a dropped ticker is simply tried again.
            for (key, _) in misses.sorted(by: { $0.value < $1.value }).prefix(misses.count - Self.capacity) {
                misses[key] = nil
            }
        }
        defaults.set(misses, forKey: Self.storageKey)
    }

    func clear(_ ticker: String) {
        lock.lock(); defer { lock.unlock() }
        guard misses.removeValue(forKey: Self.key(ticker)) != nil else { return }
        defaults.set(misses, forKey: Self.storageKey)
    }

    private static func key(_ ticker: String) -> String {
        ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
