import Foundation

// Home refresh, quote/history sequencing and request invalidation.
// Shared observable state remains owned by AppModel.
extension AppModel {
    /// Cached figures are on screen and public data is still coming in.
    /// The home page sweeps a halo over the figures this affects rather than
    /// replacing them with a skeleton.
    var isHomeRefreshingBehindCache: Bool {
        #if DEBUG
        // `--demo-refresh-glow` holds the halo on, for looking at it.
        if LaunchArguments.contains("--demo-refresh-glow") { return overview != nil }
        #endif
        return overview != nil && !holdings.isEmpty
            && (isPortfolioLoading || isPortfolioChartLoading || isHoldingDailyChangesLoading)
    }

    func refreshPortfolio(refreshMarketData: Bool = true) async {
        _ = await refreshPortfolioResult(refreshMarketData: refreshMarketData, policy: .automatic)
    }

    /// Only the two explicit home actions use this result. Automatic loads and
    /// source switches keep using `refreshPortfolio()` without user feedback.
    func refreshPortfolioReportingResult(refreshMarketData: Bool = true) async -> PortfolioRefreshResult? {
        await refreshPortfolioResult(refreshMarketData: refreshMarketData, policy: .userInitiated)
    }

    private enum PortfolioRefreshPolicy {
        case automatic
        case userInitiated

        var forcesProviderRefresh: Bool { self == .userInitiated }
    }

    private func refreshPortfolioResult(
        refreshMarketData: Bool, policy: PortfolioRefreshPolicy
    ) async -> PortfolioRefreshResult? {
        guard !Task.isCancelled else { return nil }
        portfolioRequestGeneration &+= 1
        let generation = portfolioRequestGeneration
        let previousDocument = presentedSource == portfolioSource && overview != nil ? fullDocument : nil
        var acceptedQuotes = 0
        var refreshedDisclosure = false
        isPortfolioLoading = true
        isPortfolioChartLoading = !hasUsableHomeChart
        portfolioFailure = nil
        defer {
            if generation == portfolioRequestGeneration {
                isPortfolioLoading = false
            }
        }
        do {
            var loaded = try await loadActiveDocument()
            guard generation == portfolioRequestGeneration else { return nil }
            let initialScope = await prepareAccountScope(for: loaded)
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
            // Publish disk data before any network work. Slow/offline quote
            // providers must never hold the entire home screen in a skeleton.
            let restored = await restoreHomePresentation(from: loaded, scope: initialScope, generation: generation)
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
            if !restored {
                let preservesChart = await canPreserveHomeChart(for: loaded, accountKeys: initialScope.keys)
                guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                try await apply(loaded, loadsCachedChart: false, preservesChart: preservesChart,
                    preparedScope: initialScope)
            }
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
            // Loading the selected source is finished. Public data can update
            // behind the usable cached presentation without locking controls.
            isPortfolioLoading = false
            guard refreshMarketData else {
                isPortfolioChartLoading = false
                isHoldingDailyChangesLoading = false
                if !restored { await saveHomePresentation(generation: generation) }
                return PortfolioRefreshResult.completed(previous: previousDocument, loaded: loaded,
                    acceptedQuoteCount: 0, refreshedDisclosure: false, tracksQuotes: false)
            }
            if isPublicInvestorMode {
                let catalog = try await PublicInvestorCatalogState.shared.get()
                if let fresh = try await publicInvestorStore.refreshIfNeeded(
                    catalog: catalog, selection: publicInvestorSelection
                ) {
                    guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                    try await apply(fresh)
                    guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                    refreshedDisclosure = true
                }
                await enrichPortfolioChart(from: document, generation: generation)
                guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                await refreshHoldingDailyChanges()
                guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                await saveHomePresentation(generation: generation)
                return PortfolioRefreshResult.completed(previous: previousDocument, loaded: fullDocument,
                    acceptedQuoteCount: 0, refreshedDisclosure: refreshedDisclosure, tracksQuotes: false)
            }
            if !isFakeDataMode {
                loaded = try await mergeCachedTrading212History(into: loaded,
                    accounts: initialScope.accounts)
                guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                if loaded != fullDocument {
                    let updatedScope = await prepareAccountScope(for: loaded)
                    guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                    let preservesChart = await canPreserveHomeChart(for: loaded, accountKeys: updatedScope.keys)
                    guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                    try await apply(loaded, loadsCachedChart: false, preservesChart: preservesChart,
                        preparedScope: updatedScope)
                }
                guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
            }
            guard !loaded.positions.isEmpty else {
                isHoldingDailyChangesLoading = false
                await refreshHistoricalChart(from: document, generation: generation,
                    forceRefresh: policy.forcesProviderRefresh)
                guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                await saveHomePresentation(generation: generation)
                return .noHeldQuotes
            }
            if !isFakeDataMode {
                async let fxRefresh: Void = LocalCurrentFXRefresh.shared.refresh()
                let quotes = await LocalMarketDataClient().latestQuotes(for: loaded.positions,
                    forceRefresh: policy.forcesProviderRefresh)
                await fxRefresh
                guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
                if !quotes.isEmpty {
                    let updated = try await LocalPortfolioStore.shared.updateMarketQuotes(quotes)
                    acceptedQuotes = PortfolioRefreshResult.acceptedQuoteCount(before: loaded, after: updated)
                    loaded = updated
                }
            }
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
            try await apply(loaded, invalidatesDailyChanges: false, loadsCachedChart: false, preservesChart: true)
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
            // Both consumers receive the same observed quotes. Rebuilding
            // before apply() let a stale daily curve win after a live refresh.
            async let historyRefresh: Void = refreshHistoricalChart(from: document, generation: generation,
                forceRefresh: policy.forcesProviderRefresh)
            async let dailyRefresh: Void = refreshHoldingDailyChanges(
                forceRefresh: policy.forcesProviderRefresh)
            _ = await (historyRefresh, dailyRefresh)
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
            await saveHomePresentation(generation: generation)
            return PortfolioRefreshResult.completed(previous: previousDocument, loaded: loaded,
                acceptedQuoteCount: acceptedQuotes, refreshedDisclosure: false, tracksQuotes: !isFakeDataMode)
        } catch {
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return nil }
            // Retain the last usable local presentation on refresh failure.
            // An error is not an empty account and must not erase its bars.
            isHoldingDailyChangesLoading = false
            isPortfolioChartLoading = false
            portfolioFailure = error
            return .failed(retainsData: overview != nil)
        }
    }

    private func mergeCachedTrading212History(
        into loaded: LocalPortfolioDocument, accounts: [PortfolioAccount]
    ) async throws -> LocalPortfolioDocument {
        let slots = Set(accounts.compactMap { account -> Int? in
            guard account.source == "Trading 212", let accountID = account.accountID else { return nil }
            return Int(accountID.replacingOccurrences(of: "account-", with: ""))
        })
        let credentials = slots.sorted().compactMap { slot -> Trading212AccountCredentials? in
            guard let apiKey = KeychainStore.string(for: "trading212.account-\(slot).api-key"),
                  let apiSecret = KeychainStore.string(for: "trading212.account-\(slot).api-secret"),
                  let value = try? Trading212Credentials(apiKey: apiKey, apiSecret: apiSecret) else {
                return nil
            }
            return Trading212AccountCredentials(slot: slot, credentials: value)
        }
        guard !credentials.isEmpty else { return loaded }
        let environment = UserDefaults.standard.string(forKey: "trading212.environment")
            .flatMap(Trading212Environment.init(rawValue:)) ?? .live
        let cached = await Trading212Client().cachedTransactions(
            accounts: credentials,
            environment: environment
        )
        guard !cached.isEmpty else { return loaded }
        var accountNames: [String: String] = [:]
        for account in accounts where account.source == "Trading 212" {
            if let accountID = account.accountID {
                accountNames[accountID] = account.name
            }
        }
        let local = cached.map { transaction in
            let accountID = "account-\(transaction.accountSlot)"
            return LocalTransactionRecord(
                date: transaction.date,
                action: transaction.action,
                ticker: transaction.ticker,
                quantity: transaction.quantity,
                price: transaction.price,
                currency: transaction.currency,
                source: "Trading 212",
                accountID: accountID,
                accountName: accountNames[accountID],
                tradeID: transaction.reference,
                brokerFXRate: transaction.brokerFXRate,
                realisedProfitLoss: transaction.realisedProfitLoss,
                realisedProfitLossCurrency: transaction.realisedProfitLossCurrency,
                executedAt: transaction.executedAt
            )
        }
        return try await LocalPortfolioStore.shared.mergeTransactions(local)
    }

    private func refreshHistoricalChart(
        from loaded: LocalPortfolioDocument, generation: Int, forceRefresh: Bool = true
    ) async {
        guard !isFakeDataMode else { return }
        // A new/invalid result cache should still try existing price history
        // locally before entering the slow provider refresh/fallback pipeline.
        if !hasUsableHomeChart || portfolioChart?.isCurrentHoldingsOnly == true,
           let cached = try? await LocalMarketDataClient().portfolioChart(document: loaded, cachedOnly: true),
           cached.currentPoint.marketValue.isFinite {
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return }
            portfolioChart = cached
            isPortfolioChartLoading = false
            portfolioChartRevision &+= 1
            await saveHomePresentation(generation: generation)
        }
        guard generation == portfolioRequestGeneration, !Task.isCancelled else { return }
        await enrichPortfolioChart(from: loaded, generation: generation, forceRefresh: forceRefresh)
    }

    func enrichPortfolioChart(
        from loaded: LocalPortfolioDocument, generation: Int, forceRefresh: Bool = true
    ) async {
        defer {
            if generation == portfolioRequestGeneration {
                isPortfolioChartLoading = false
            }
        }
        if var enriched = try? await LocalMarketDataClient().portfolioChart(
            document: loaded, forceRefresh: forceRefresh
        ) {
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return }
            // A detail quote may arrive while history is loading. Reuse the
            // fetched history and value it with the latest document before publishing.
            while loaded != document {
                let latest = document
                guard let refreshed = try? await LocalMarketDataClient().portfolioChart(document: latest, cachedOnly: true),
                      generation == portfolioRequestGeneration, !Task.isCancelled else { return }
                enriched = refreshed
                if latest == document { break }
            }
            // A failed/offline rebuild can return an unavailable response.
            // Keep the last valid cached curve and its timestamp in that case.
            guard enriched.currentPoint.marketValue.isFinite || !hasUsableHomeChart else { return }
            // An interim response can have a valid current number but no
            // rebuilt history. Keep the complete cache on disk as well as on
            // screen, until a complete replacement arrives for this scope.
            if hasUsableHomeChart, enriched.positionHistory.rows.count <= 1,
               (portfolioChart?.positionHistory.rows.count ?? 0) > 1 { return }
            portfolioChart = enriched
            if enriched.currentPoint.marketValue.isFinite { portfolioCachedAt = nil }
            portfolioChartRevision &+= 1
            await saveHomePresentation(generation: generation)
        }
    }

    func invalidateInFlightRequests() {
        detailChartTask?.cancel()
        returnsPageRequestGeneration &+= 1
        returnsPageTask?.cancel()
        returnsPageTask = nil
        portfolioRequestGeneration &+= 1
        returnsRequestGeneration &+= 1
        returnsAnalyticsRequestGeneration &+= 1
        dailyChangesRequestGeneration &+= 1
        isPortfolioLoading = false
        isPortfolioChartLoading = false
        isReturnsLoading = false
        isReturnsAnalyticsLoading = false
        returnsAnalyticsPendingParts = []
        isHoldingDailyChangesLoading = false
        benchmarkDailyChange = nil
        holdingDailyChangesSignature = ""
    }

    /// A daily-change cache is keyed by tickers, independent of quote updates.
    static func dailyChangesSignature(for holdings: [Holding]) -> String {
        Set(holdings.map { $0.ticker.uppercased() })
            .sorted()
            .joined(separator: "|")
    }

}
