import Foundation

struct HoldingDailyMarketData: Sendable {
    var closes: [String: [String: Double]]
    var benchmark: Double?

    static func load(holdings: [Holding], positions: [LocalPositionRecord], forceRefresh: Bool) async -> Self {
        let client = LocalMarketDataClient()
        async let closes = client.recentCloses(for: holdings, positions: positions, forceRefresh: forceRefresh)
        // SPY has no position quote overlay, so always ask for its current point.
        async let benchmark = client.dailyChange(ticker: "SPY", forceRefresh: true)
        return await Self(closes: closes, benchmark: benchmark)
    }
}

extension AppModel {
    func invalidateHoldingDailyChanges() {
        holdingDailyChangesTask?.cancel()
        holdingDailyChangesTask = nil
        dailyChangesRequestGeneration &+= 1
        holdingDailyChangesSignature = ""
        holdingDailyChangesUpdatedAt = nil
        isHoldingDailyChangesLoading = false
    }

    func refreshHoldingDailyChanges(forceRefresh: Bool = false) async {
        guard !Task.isCancelled else { return }
        await startHoldingDailyChangesRefresh(forceRefresh: forceRefresh)?.value
    }

    /// The model owns this task: a disappearing/rebuilt home cannot cancel it.
    /// Returning the same task also prevents repeated appearances from starting
    /// duplicate batches while a request or its retry is still in progress.
    @discardableResult
    func startHoldingDailyChangesRefresh(forceRefresh: Bool = false) -> Task<Void, Never>? {
        guard !holdings.isEmpty else {
            invalidateHoldingDailyChanges()
            holdingDailyChanges = [:]
            holdingRecentCloses = [:]
            benchmarkDailyChange = nil
            return nil
        }
        if !forceRefresh, let task = holdingDailyChangesTask { return task }
        let signature = Self.dailyChangesSignature(for: holdings)
        let complete = holdings.allSatisfy {
            (holdingDailyChanges[$0.ticker.uppercased()] ?? $0.todayChangePercent)?.isFinite == true
        }
        if !forceRefresh, complete, signature == holdingDailyChangesSignature,
           let updated = holdingDailyChangesUpdatedAt, Date().timeIntervalSince(updated) < 60 {
            return nil
        }

        invalidateHoldingDailyChanges()
        let generation = dailyChangesRequestGeneration
        let portfolioGeneration = portfolioRequestGeneration
        let snapshot = holdings
        let positions = document.positions
        // Publish loading before scheduling work, so a restored but incomplete
        // snapshot never briefly claims that quotes are unavailable.
        isHoldingDailyChangesLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadHoldingDailyChanges(snapshot: snapshot, positions: positions,
                signature: signature, generation: generation, portfolioGeneration: portfolioGeneration,
                forceRefresh: forceRefresh)
        }
        holdingDailyChangesTask = task
        return task
    }

    private func loadHoldingDailyChanges(
        snapshot: [Holding], positions: [LocalPositionRecord], signature: String,
        generation: Int, portfolioGeneration: Int, forceRefresh: Bool
    ) async {
        defer {
            if generation == dailyChangesRequestGeneration {
                isHoldingDailyChangesLoading = false
                holdingDailyChangesTask = nil
            }
        }
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == dailyChangesRequestGeneration
                && portfolioGeneration == portfolioRequestGeneration
                && signature == Self.dailyChangesSignature(for: holdings)
        }
        guard isCurrent() else { return }
        var pending: [Holding] = []
        for holding in snapshot {
            if let value = holding.todayChangePercent, value.isFinite, !forceRefresh || isFakeDataMode {
                holdingDailyChanges[holding.ticker.uppercased()] = value
            } else {
                pending.append(holding)
            }
        }
        applyDetailDailyChanges()
        var receivedBenchmark = false
        // One initial attempt plus two delayed retries; unavailable symbols
        // must not cause an unbounded background request loop.
        let delays: [Duration] = [.seconds(2), .seconds(5)]
        async let rates: Void = loadCurrencyHistories(forceRefresh: forceRefresh)
        for attempt in 0...delays.count {
            if attempt > 0 {
                do { try await dailyMarketRetryWait(delays[attempt - 1]) }
                catch { return }
            }
            guard isCurrent() else { return }
            let result = await dailyMarketLoader(pending, positions, forceRefresh || attempt > 0)
            guard isCurrent() else { return }
            let requested = Set(pending.map { $0.ticker.uppercased() })
            let closes = result.closes.filter {
                requested.contains($0.key) && LocalMarketDataClient.latestDailyChange(in: $0.value) != nil
            }
            let changes = closes.compactMapValues { LocalMarketDataClient.latestDailyChange(in: $0) }
            // Merge into current state, not a captured dictionary: detail-page
            // quotes may have arrived while this request was suspended.
            holdingRecentCloses.merge(closes) { _, latest in latest }
            holdingDailyChanges.merge(changes) { _, latest in latest }
            applyDetailDailyChanges()
            pending.removeAll { changes[$0.ticker.uppercased()] != nil }
            if let benchmark = result.benchmark, benchmark.isFinite {
                benchmarkDailyChange = benchmark
                receivedBenchmark = true
            }
            if pending.isEmpty && receivedBenchmark {
                holdingDailyChangesSignature = signature
                holdingDailyChangesUpdatedAt = Date()
            }
            await saveHomePresentation(generation: portfolioGeneration)
            guard isCurrent() else { return }
            if pending.isEmpty && receivedBenchmark { break }
        }
        await rates
        guard isCurrent() else { return }
        await saveHomePresentation(generation: portfolioGeneration)
    }
}
