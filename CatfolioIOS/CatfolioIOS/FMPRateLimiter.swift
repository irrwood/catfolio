import Foundation

/// Pace the app's shared FMP quota. During a server cooldown, fail promptly
/// so callers can continue to another provider or their saved market data.
actor FMPRequestLimiter {
    static let shared = FMPRequestLimiter()

    private var nextAllowedAt = Date.distantPast
    private let spacing: TimeInterval

    init(spacing: TimeInterval = 0.20) {
        self.spacing = spacing
    }

    private var blockedUntil = Date.distantPast

    func waitForTurn() async throws {
        // Recheck after pacing too: another caller may have exhausted the
        // quota while this one slept. Never wait out that server cooldown;
        // doing so blocks the caller's fallback path behind FMP.
        while true {
            try Task.checkCancellation()
            let now = Date()
            if blockedUntil > now {
                throw FMPFailure.rateLimited(
                    retryAfterSeconds: Int(blockedUntil.timeIntervalSince(now).rounded(.up))
                )
            }
            let ready = nextAllowedAt
            if ready <= now {
                nextAllowedAt = now.addingTimeInterval(spacing)
                return
            }
            try await Task.sleep(nanoseconds: UInt64(ready.timeIntervalSince(now) * 1_000_000_000))
        }
    }

    /// Honour `Retry-After` by skipping FMP until the quota can recover.
    /// Other providers and cached results remain available during this time.
    func backOff(retryAfter: String?) {
        let seconds = ProviderRequestCooldown.delay(retryAfter: retryAfter)
        let resume = Date().addingTimeInterval(seconds)
        blockedUntil = max(blockedUntil, resume)
    }

    /// How long until a new FMP request can be attempted.
    var secondsUntilFreeSlot: TimeInterval {
        max(0, max(nextAllowedAt, blockedUntil).timeIntervalSinceNow)
    }
}

enum FMPFailure: LocalizedError {
    case rateLimited(retryAfterSeconds: Int)
    case missingKey

    var errorDescription: String? {
        switch self {
        case let .rateLimited(seconds):
            L10n.text("已达到 FMP 的请求频率上限（429）。这不是密钥或权限问题——同时打开多张数据卡片会更快触顶。约 \(seconds) 秒后可重试。")
        case .missingKey:
            L10n.text("请先在设置 → 服务商中配置 FMP。筛选和财报接口需要相应的数据权限。")
        }
    }
}
