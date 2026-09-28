import Foundation

/// Share a provider's 429 cooldown across callers. During the cooldown,
/// callers fail fast so their existing cache/fallback paths can run.
actor ProviderRequestCooldown {
    static let shared = ProviderRequestCooldown()
    private var deadlines: [String: Date] = [:]

    static func delay(retryAfter: String?, now: Date = Date()) -> TimeInterval {
        if let value = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return max(1, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let value = retryAfter, let date = formatter.date(from: value) {
            return max(1, date.timeIntervalSince(now))
        }
        return 60
    }

    func check(_ source: DataSource?, now: Date = Date()) throws {
        guard let source, let deadline = deadlines[source.id], deadline > now else { return }
        throw CooldownError()
    }

    func record(_ source: DataSource?, response: URLResponse, now: Date = Date()) {
        guard let source, ["fmp", "massive"].contains(source.id),
              let http = response as? HTTPURLResponse, http.statusCode == 429 else { return }
        let deadline = now.addingTimeInterval(Self.delay(retryAfter: http.value(forHTTPHeaderField: "Retry-After"), now: now))
        deadlines[source.id] = max(deadlines[source.id] ?? .distantPast, deadline)
    }

    struct CooldownError: LocalizedError {
        var errorDescription: String? { L10n.text("请求过于频繁（429），稍后重试") }
    }
}
