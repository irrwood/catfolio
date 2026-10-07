import Foundation
import Observation

/// Reuse saved prices while they reach the latest trading day; otherwise show
/// them and fetch newer ones behind them. Never let a cancelled or superseded
/// request replace the active portfolio's chart.
@MainActor @Observable
final class HoldingHistoryState {
    private(set) var history: HoldingValueHistory?
    private(set) var errorMessage: String?
    private(set) var revision = 0
    private var generation = 0

    /// Whether the history reaches the latest session New York has closed.
    /// Before the close, yesterday's prices are current: in Asia's daytime
    /// the US day has not finished.
    nonisolated static func reachesLatestSession(_ history: HoldingValueHistory, now: Date = .now) -> Bool {
        guard let last = history.rows.last?.dateText else { return false }
        return last >= latestClosedSession(now: now)
    }

    /// The exchange's own calendar where it is known (holidays and early
    /// closes); past it, the latest weekday after 16:00 New York, and a
    /// holiday then reads as stale and costs a request that returns the same
    /// prices — the cheap side to be wrong on.
    nonisolated static func latestClosedSession(now: Date) -> String {
        if let session = (try? PolicyUSSessionCalendar.completedSessions(asOf: now))?.last { return session }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var day = calendar.component(.hour, from: now) < 16
            ? calendar.date(byAdding: .day, value: -1, to: now) ?? now : now
        while calendar.isDateInWeekend(day), let previous = calendar.date(byAdding: .day, value: -1, to: day) {
            day = previous
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func load(forceRefresh: Bool = false, fetch: (Bool) async throws -> HoldingValueHistory) async {
        generation &+= 1
        let request = generation
        history = nil
        errorMessage = nil
        revision &+= 1

        func publish(_ value: HoldingValueHistory) {
            if value.rows.count <= 1, (history?.rows.count ?? 0) > 1 { return }
            history = value
            errorMessage = nil
            revision &+= 1
        }

        if let cached = try? await fetch(true), !Task.isCancelled,
           request == generation, !cached.rows.isEmpty {
            publish(cached)
            // A complete curve that is days old is still worth showing at
            // once, but not worth stopping at: the page would otherwise sit
            // on last week's prices until the reader pulled to refresh.
            if !forceRefresh, cached.rows.count > 1, Self.reachesLatestSession(cached) { return }
        }
        guard !Task.isCancelled, request == generation else { return }

        for attempt in 0..<6 {
            do {
                let fresh = try await fetch(false)
                guard !Task.isCancelled, request == generation else { return }
                guard !fresh.rows.isEmpty else { throw LocalServiceError.noHistoricalPrices }
                publish(fresh)
                return
            } catch is CancellationError {
                return
            } catch LocalPortfolioError.noPortfolio where attempt < 5 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled, request == generation else { return }
            } catch {
                guard !Task.isCancelled, request == generation else { return }
                if history == nil { errorMessage = error.localizedDescription }
                return
            }
        }
    }
}
