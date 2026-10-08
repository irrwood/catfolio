import Foundation
import Observation

/// Account selection and its figures are published together. Rendering a
/// detail page only reads these values; it never rebuilds the portfolio.
@MainActor @Observable
final class HoldingDetailAccountSelection {
    private(set) var context: HoldingDetailAccountContext?
    private(set) var accountKeys: Set<String> = []
    private(set) var holding: Holding?

    typealias Prepare = @Sendable (HoldingDetailAccountContext, Set<String>) async -> Holding?
    @ObservationIgnored private let prepare: Prepare
    @ObservationIgnored private var requestedContext: HoldingDetailAccountContext?
    @ObservationIgnored private var requestedKeys: Set<String> = []
    @ObservationIgnored private var generation = 0
    private struct CachedHolding { let value: Holding? }
    @ObservationIgnored private var cache: [Set<String>: CachedHolding] = [:]
    @ObservationIgnored private var cacheOrder: [Set<String>] = []

    init(prepare: @escaping Prepare = { context, keys in
        await Task.detached(priority: .userInitiated) { context.holding(for: keys) }.value
    }) {
        self.prepare = prepare
    }

    func update(context newContext: HoldingDetailAccountContext) async {
        if requestedContext != newContext {
            requestedKeys = requestedContext.map { previous in
                requestedKeys == previous.allAccountKeys
                    ? newContext.allAccountKeys : requestedKeys.intersection(newContext.allAccountKeys)
            } ?? newContext.allAccountKeys
            requestedContext = newContext
            cache.removeAll()
            cacheOrder.removeAll()
        }
        await publishSelection()
    }

    func selectAll() async {
        guard let requestedContext else { return }
        requestedKeys = requestedContext.allAccountKeys
        await publishSelection()
    }

    func toggle(_ key: String) async {
        guard requestedContext?.allAccountKeys.contains(key) == true else { return }
        if !requestedKeys.insert(key).inserted { requestedKeys.remove(key) }
        await publishSelection()
    }

    /// Securities with no open position still show trades from closed accounts.
    func clear(accountKeys: Set<String> = []) {
        generation &+= 1
        requestedContext = nil
        requestedKeys = []
        cache.removeAll()
        cacheOrder.removeAll()
        context = nil
        self.accountKeys = accountKeys
        holding = nil
    }

    private func publishSelection() async {
        guard let nextContext = requestedContext else { return }
        let keys = requestedKeys
        generation &+= 1
        let request = generation
        let result: Holding?
        if let cached = cache[keys] {
            result = cached.value
        } else {
            result = keys.isEmpty ? nil : await prepare(nextContext, keys)
        }
        // A later tap, refreshed ledger or closed position owns the display.
        guard request == generation, !Task.isCancelled else { return }
        cache[keys] = CachedHolding(value: result)
        cacheOrder.removeAll { $0 == keys }
        cacheOrder.append(keys)
        while cacheOrder.count > 8 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        context = nextContext
        accountKeys = keys
        holding = result
    }
}
