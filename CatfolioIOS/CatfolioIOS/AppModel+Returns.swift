import Foundation

// Performance comparison, analytics and holding-value history.
// Shared observable state remains owned by AppModel.
extension AppModel {
    func refreshReturns() async {
        guard !Task.isCancelled else { return }
        returnsRequestGeneration &+= 1
        let generation = returnsRequestGeneration
        isReturnsLoading = true
        returnsError = nil
        comparisonWarning = nil
        defer {
            if generation == returnsRequestGeneration {
                isReturnsLoading = false
            }
        }
        do {
            let loaded = try await loadActiveDocument()
            guard generation == returnsRequestGeneration else { return }
            let scoped = await selectedDocument(from: loaded)
            guard generation == returnsRequestGeneration, !Task.isCancelled else { return }
            document = scoped
            // The saved comparison is drawn at once. When nothing it was
            // computed from has changed today, it is the answer; otherwise
            // it stays on screen while the rebuild runs behind it.
            let scope = comparisonCacheScope
            let fingerprint = await Task.detached(priority: .userInitiated) {
                ComparisonSnapshotCache.fingerprint(for: scoped)
            }.value
            let saved = await Task.detached(priority: .userInitiated) {
                ComparisonSnapshotCache.load(scope: scope)
            }.value
            guard generation == returnsRequestGeneration else { return }
            if let saved, saved.fingerprint == fingerprint || comparison == nil {
                comparison = saved.response
                comparisonRevision &+= 1
                comparisonWarning = saved.response.warnings?.joined(separator: "\n")
                if saved.fingerprint == fingerprint { return }
            }
            do {
                let enriched = try await LocalMarketDataClient().comparison(document: scoped)
                guard generation == returnsRequestGeneration else { return }
                comparison = enriched
                comparisonRevision &+= 1
                comparisonWarning = enriched.warnings?.joined(separator: "\n")
                Task.detached(priority: .utility) {
                    ComparisonSnapshotCache.save(enriched, fingerprint: fingerprint, scope: scope)
                }
            } catch {
                guard generation == returnsRequestGeneration else { return }
                let localFallback = try await Task.detached(priority: .userInitiated) {
                    try LocalPortfolioEngine.comparison(for: scoped)
                }.value
                guard generation == returnsRequestGeneration else { return }
                comparison = localFallback
                comparisonRevision &+= 1
                comparisonWarning = ([L10n.text("历史行情读取失败：\(error.localizedDescription)")]
                    + (localFallback.warnings ?? []))
                    .joined(separator: "\n")
            }
        } catch {
            guard generation == returnsRequestGeneration else { return }
            comparison = nil
            comparisonRevision &+= 1
            returnsError = error.localizedDescription
        }
    }

    func refreshReturnsPage() async {
        guard !Task.isCancelled else { return }
        returnsPageRequestGeneration &+= 1
        let generation = returnsPageRequestGeneration
        returnsPageTask?.cancel()
        // Invalidate every old continuation without waiting for a slow vendor
        // request to acknowledge cancellation.
        returnsRequestGeneration &+= 1
        returnsAnalyticsRequestGeneration &+= 1

        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  generation == self.returnsPageRequestGeneration else { return }
            self.analyticsWarning = nil
            self.isReturnsAnalyticsLoading = false
            self.returnsAnalyticsPendingParts = []
            await self.refreshReturns()
            guard !Task.isCancelled, generation == self.returnsPageRequestGeneration,
                  self.returnsError == nil else { return }
            await self.refreshReturnsAnalytics()
        }
        returnsPageTask = task
        await task.value
        if generation == returnsPageRequestGeneration {
            returnsPageTask = nil
        }
    }

    /// One saved comparison per data mode and account selection.
    var comparisonCacheScope: String {
        let mode = isPublicInvestorMode ? "public:\(publicInvestorSelection)" : (isFakeDataMode ? "demo" : "real")
        return ([mode] + selectedAccountKeys.sorted()).joined(separator: "|")
    }

    func refreshReturnsAnalytics() async {
        guard !Task.isCancelled else { return }
        returnsAnalyticsRequestGeneration &+= 1
        let generation = returnsAnalyticsRequestGeneration
        isReturnsAnalyticsLoading = true
        returnsAnalyticsPendingParts = [.drawdown, .valuation]
        defer {
            if generation == returnsAnalyticsRequestGeneration {
                isReturnsAnalyticsLoading = false
                returnsAnalyticsPendingParts = []
            }
        }
        do {
            let loaded = try await loadActiveDocument()
            guard generation == returnsAnalyticsRequestGeneration else { return }
            let scoped = await selectedDocument(from: loaded)
            guard generation == returnsAnalyticsRequestGeneration, !Task.isCancelled else { return }
            document = scoped
            let response = await LocalReturnsAnalyticsClient().load(document: scoped) {
                [weak self] completedPart, partialResponse in
                guard let self,
                      generation == self.returnsAnalyticsRequestGeneration else { return }
                self.returnsAnalytics = partialResponse
                self.returnsAnalyticsPendingParts.remove(completedPart)
                self.analyticsWarning = partialResponse.warnings.isEmpty
                    ? nil
                    : partialResponse.warnings.joined(separator: "\n")
                self.returnsAnalyticsRevision &+= 1
            }
            guard generation == returnsAnalyticsRequestGeneration else { return }
            returnsAnalytics = response
            analyticsWarning = response.warnings.isEmpty ? nil : response.warnings.joined(separator: "\n")
            returnsAnalyticsRevision &+= 1
        } catch {
            guard generation == returnsAnalyticsRequestGeneration else { return }
            returnsAnalytics = nil
            analyticsWarning = L10n.text("分析图表读取失败：\(error.localizedDescription)")
            returnsAnalyticsRevision &+= 1
        }
    }

    /// Each current holding's value by day, for the revenue-sources chart on
    /// the Performance tab. Built from the same document and history as the
    /// home chart.
    func holdingValueHistory(cachedOnly: Bool = false) async throws -> HoldingValueHistory {
        try await LocalMarketDataClient().holdingValueHistory(document: document, cachedOnly: cachedOnly)
    }

    /// Current share counts over five years, for the underwater analysis.
    func fixedShareHistory(cachedOnly: Bool = false) async throws -> HoldingValueHistory {
        try await LocalMarketDataClient().fixedShareHistory(document: document, cachedOnly: cachedOnly)
    }

}
