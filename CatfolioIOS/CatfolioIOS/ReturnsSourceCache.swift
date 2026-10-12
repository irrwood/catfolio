import Foundation
import Observation

/// Page-independent, bounded storage. A change of account, data mode or
/// accounting method selects a different entry before the first frame.
@MainActor
final class ReturnsSourceCache {
    enum Kind: String { case current, includingSold, drawdown }
    struct Key: Hashable {
        let scope: String
        let kind: Kind
    }
    private var entries: [Key: ReturnsSourceCacheEntry] = [:]
    private var order: [Key] = []

    func entry(scope: String, kind: Kind) -> ReturnsSourceCacheEntry {
        let key = Key(scope: scope, kind: kind)
        if let entry = entries[key] { return entry }
        let entry = ReturnsSourceCacheEntry()
        entries[key] = entry
        order.append(key)
        if order.count > 6 { entries.removeValue(forKey: order.removeFirst()) }
        return entry
    }
}

@MainActor
final class ReturnsSourceCacheEntry {
    let loading = HoldingHistoryState()
    let gains = ReturnsSourcePreparations<HoldingContributionStack>()
    let losses = ReturnsSourcePreparations<HoldingLossRanges>()
    let drawdowns = ReturnsSourcePreparation<[ChartTimeRange: UnderwaterSeries]>()
    let gainPlots = HoldingContributionPreparedCache()
    private var task: Task<Void, Never>?
    private var requestedRevision: Int?
    private var completedRevision: Int?
    private var generation = 0

    /// Readers join the same request; leaving a page does not cancel another
    /// reader or discard a result that can serve the next visit.
    func load(revision: Int, forceRefresh: Bool = false,
              fetch: @escaping @MainActor (Bool) async throws -> HoldingValueHistory) async {
        if !forceRefresh, requestedRevision == revision, let task {
            await task.value
            return
        }
        if !forceRefresh, completedRevision == revision, let history = loading.history,
           history.rows.count > 1, HoldingHistoryState.reachesLatestSession(history) { return }
        generation &+= 1
        let request = generation
        task?.cancel()
        requestedRevision = revision
        let work = Task { await loading.load(forceRefresh: forceRefresh, fetch: fetch) }
        task = work
        await work.value
        guard request == generation else { return }
        task = nil
        if loading.didLoadHistory { completedRevision = revision }
    }
}

/// Keep common visibility/language variants apart, so returning with default
/// controls cannot briefly show the last visit's hidden holdings.
@MainActor
final class ReturnsSourcePreparations<Value: Sendable> {
    private var entries: [String: ReturnsSourcePreparation<Value>] = [:]
    private var order: [String] = []
    func entry(configuration: String) -> ReturnsSourcePreparation<Value> {
        if let entry = entries[configuration] { return entry }
        let entry = ReturnsSourcePreparation<Value>()
        entries[configuration] = entry
        order.append(configuration)
        if order.count > 4 { entries.removeValue(forKey: order.removeFirst()) }
        return entry
    }
}

/// Prepared values survive navigation and remain visible during recomputation.
/// Each instance belongs to exactly one portfolio/accounting scope.
@MainActor @Observable
final class ReturnsSourcePreparation<Value: Sendable> {
    let id = UUID()
    private(set) var value: Value?
    private(set) var revision = 0
    private(set) var key: String?
    private var generation = 0

    func prepare(key nextKey: String, build: @escaping @Sendable () throws -> Value) async {
        guard key != nextKey else { return }
        generation &+= 1
        let request = generation
        let work = Task.detached(priority: .userInitiated, operation: build)
        let result = try? await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
        guard !Task.isCancelled, request == generation, let result else { return }
        value = result
        key = nextKey
        revision &+= 1
    }
}

extension AppModel {
    func returnsSourceEntry(kind: ReturnsSourceCache.Kind) -> ReturnsSourceCacheEntry {
        returnsSourceCache.entry(scope: comparisonCacheScope, kind: kind)
    }

    /// Capture the document before suspending so an old account's request can
    /// never publish the newly selected account's data into its cache entry.
    func returnsSourceFetch(kind: ReturnsSourceCache.Kind) -> @MainActor (Bool) async throws -> HoldingValueHistory {
        let source = document
        return { cachedOnly in
            let client = LocalMarketDataClient()
            switch kind {
            case .current: return try await client.holdingValueHistory(document: source, cachedOnly: cachedOnly)
            case .includingSold: return try await client.actualHoldingValueHistory(document: source, cachedOnly: cachedOnly)
            case .drawdown: return try await client.fixedShareHistory(document: source, cachedOnly: cachedOnly)
            }
        }
    }
}
