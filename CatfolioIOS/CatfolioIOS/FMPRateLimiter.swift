import Foundation

/// Every Financial Modeling Prep request in the app draws on one account
/// quota. This limiter already existed, but it was private to
/// LocalReturnsAnalytics and so paced exactly one of the five call sites that
/// spend that quota. Opening a stock page fires the analyst-consensus card,
/// the financials card and the historical-bar fetches at once; three of them
/// were unthrottled, and whichever rendered last collected the 429.
///
/// Promoted here so all of them share it, and given a back-off so that a
/// rejection seen by one caller holds the others back too — otherwise a single
/// 429 cascades as each client retries into an already-exhausted budget.
actor FMPRequestLimiter {
    static let shared = FMPRequestLimiter()

    private var nextAllowedAt = Date.distantPast
    private let spacing: TimeInterval

    init(spacing: TimeInterval = 0.20) {
        self.spacing = spacing
    }

    func waitForTurn() async throws {
        let now = Date()
        let slot = nextAllowedAt > now ? nextAllowedAt : now
        // Reserve this request's unique slot before suspending. Actors are
        // re-entrant across `await`, so updating afterwards can release a burst.
        nextAllowedAt = slot.addingTimeInterval(spacing)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
    }

    /// Honour `Retry-After` when the server sends one; otherwise wait long
    /// enough that a per-minute budget has a chance to recover.
    func backOff(retryAfter: String?) {
        let seconds = min(60, max(1, retryAfter.flatMap(Double.init) ?? 5))
        let resume = Date().addingTimeInterval(seconds)
        nextAllowedAt = max(nextAllowedAt, resume)
    }

    /// How long the next caller would wait, so a message can say so.
    var secondsUntilFreeSlot: TimeInterval {
        max(0, nextAllowedAt.timeIntervalSinceNow)
    }
}

enum FMPFailure: LocalizedError {
    case rateLimited(retryAfterSeconds: Int)
    case missingKey

    var errorDescription: String? {
        switch self {
        case let .rateLimited(seconds):
            "已达到 FMP 的请求频率上限（429）。这不是密钥或权限问题——同时打开多张数据卡片会更快触顶。约 \(seconds) 秒后可重试。"
        case .missingKey:
            "请先在设置 → 服务商中配置 FMP。筛选和财报接口需要相应的数据权限。"
        }
    }
}
