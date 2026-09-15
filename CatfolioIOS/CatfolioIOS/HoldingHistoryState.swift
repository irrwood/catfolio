import Foundation
import Observation

/// Publish saved prices before refreshing, and never let a cancelled or
/// superseded request replace the active portfolio's chart.
@MainActor @Observable
final class HoldingHistoryState {
    private(set) var history: HoldingValueHistory?
    private(set) var errorMessage: String?
    private(set) var revision = 0
    private var generation = 0

    func load(fetch: (Bool) async throws -> HoldingValueHistory) async {
        generation &+= 1
        let request = generation
        history = nil
        errorMessage = nil
        revision &+= 1

        func publish(_ value: HoldingValueHistory) {
            history = value
            errorMessage = nil
            revision &+= 1
        }

        if let cached = try? await fetch(true), !Task.isCancelled,
           request == generation, cached.rows.count > 1 {
            publish(cached)
        }
        guard !Task.isCancelled, request == generation else { return }

        for attempt in 0..<6 {
            do {
                let fresh = try await fetch(false)
                guard !Task.isCancelled, request == generation else { return }
                guard fresh.rows.count > 1 else { throw LocalServiceError.noHistoricalPrices }
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

