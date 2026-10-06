import Foundation

// Document scoping, source modes and presentation-cache publication.
// Shared observable state remains owned by AppModel.
extension AppModel {
    /// Adds up the broker's results on sales, each converted from the currency
    /// it was reported in. Never estimated: a sale without a result counts as
    /// a gap, not as zero.
    func updateRealisedProfit(from scoped: LocalPortfolioDocument) {
        let summary = LocalBrokerResultSummary(transactions: scoped.transactions ?? [])
        realisedProfitGaps = summary.missingCount
        realisedProfit = summary.usdTotal() ?? .nan
    }

    struct PreparedAccountScope {
        let accounts: [PortfolioAccount]
        let keys: Set<String>
        let document: LocalPortfolioDocument
        let realisedProfit: Double
        let realisedProfitGaps: Int
    }

    /// Account discovery groups the entire transaction ledger. Prepare it and
    /// the selected document together, away from the actor that handles taps.
    func prepareAccountScope(for loaded: LocalPortfolioDocument) async -> PreparedAccountScope {
        let savedKeys = Self.savedAccountKeys(forKey: selectedAccountsStorageKey, defaults: modeDefaults)
        let selectsAll = modeDefaults.bool(forKey: selectsAllAccountsStorageKey)
        return await Task.detached(priority: .userInitiated) {
            let accounts = loaded.accounts
            let availableKeys = Set(accounts.map(\.id))
            let selected = savedKeys.intersection(availableKeys)
            let keys = selectsAll || selected.isEmpty ? availableKeys : selected
            let scoped = loaded.scoped(to: keys, availableAccounts: accounts)
            let realised = LocalBrokerResultSummary(transactions: scoped.transactions ?? [])
            return PreparedAccountScope(accounts: accounts, keys: keys,
                document: scoped, realisedProfit: realised.usdTotal() ?? .nan,
                realisedProfitGaps: realised.missingCount)
        }.value
    }

    func apply(_ loaded: LocalPortfolioDocument, invalidatesDailyChanges: Bool = true,
                       loadsCachedChart: Bool = true, preservesChart: Bool = false,
                       localSelectionOnly: Bool = false,
                       preparedScope suppliedScope: PreparedAccountScope? = nil) async throws {
        let generation = portfolioRequestGeneration
        let previousDailyChanges = holdingDailyChanges
        let preparedScope: PreparedAccountScope
        if let suppliedScope {
            preparedScope = suppliedScope
        } else {
            preparedScope = await prepareAccountScope(for: loaded)
        }
        guard generation == portfolioRequestGeneration, !Task.isCancelled else { return }
        let accountKeys = preparedScope.keys
        let scoped = preparedScope.document
        let initialDocument = applyingDetailQuotes(to: scoped)
        var calculatedDocument = initialDocument
        var presentation = try await Task.detached(priority: .userInitiated) {
            try LocalPortfolioEngine.presentation(for: initialDocument)
        }.value
        let cachedChart: PortfolioChartResponse?
        if loadsCachedChart && !preservesChart && !isFakeDataMode && !isPublicInvestorMode && (!scoped.positions.isEmpty || !(scoped.transactions ?? []).isEmpty) {
            cachedChart = try? await LocalMarketDataClient().portfolioChart(
                document: scoped,
                cachedOnly: true
            )
        } else {
            cachedChart = nil
        }
        guard generation == portfolioRequestGeneration else { return }
        // Read the overlay after suspension so an in-flight disk refresh
        // cannot replace a quote the detail has just published.
        // A quote may arrive while the initial calculation or chart cache is
        // loading. Recalculate the overlaid document off-main and retry if a
        // newer quote arrives during that calculation.
        var overlaidFullDocument: LocalPortfolioDocument
        var overlaidScopedDocument: LocalPortfolioDocument
        var presentedAccounts = preparedScope.accounts
        while true {
            let quoteGeneration = detailQuoteGeneration
            overlaidFullDocument = applyingDetailQuotes(to: loaded)
            overlaidScopedDocument = applyingDetailQuotes(to: scoped)
            if overlaidScopedDocument.positions != calculatedDocument.positions {
                let snapshot = overlaidScopedDocument
                presentation = try await Task.detached(priority: .userInitiated) {
                    try LocalPortfolioEngine.presentation(for: snapshot)
                }.value
                calculatedDocument = snapshot
            }
            if overlaidFullDocument.positions != loaded.positions {
                let snapshot = overlaidFullDocument
                presentedAccounts = await Task.detached(priority: .userInitiated) {
                    snapshot.accounts
                }.value
            } else {
                presentedAccounts = preparedScope.accounts
            }
            guard generation == portfolioRequestGeneration, !Task.isCancelled else { return }
            if quoteGeneration == detailQuoteGeneration { break }
        }
        fullDocument = overlaidFullDocument
        document = overlaidScopedDocument
        presentedSource = portfolioSource
        realisedProfit = preparedScope.realisedProfit
        realisedProfitGaps = preparedScope.realisedProfitGaps
        accounts = presentedAccounts
        storedSelectedAccountKeys = accountKeys
        overview = presentation.0
        if !preservesChart {
            portfolioCachedAt = nil
            portfolioChart = cachedChart ?? presentation.1
            if portfolioChart?.currentPoint.marketValue.isFinite != true {
                portfolioChart = .currentHoldings(overview: presentation.0,
                    positionCount: presentation.2.count)
            }
            isPortfolioChartLoading = cachedChart == nil
                && !localSelectionOnly
                && !isFakeDataMode
                && !isPublicInvestorMode
                && (!scoped.positions.isEmpty || !(scoped.transactions ?? []).isEmpty)
            portfolioChartRevision &+= 1
        }
        if preservesChart, portfolioChart?.isCurrentHoldingsOnly == true {
            portfolioChart = .currentHoldings(overview: presentation.0,
                positionCount: presentation.2.count)
            portfolioChartRevision &+= 1
        }
        holdings = presentation.2
        if invalidatesDailyChanges {
            dailyChangesRequestGeneration &+= 1
        }
        holdingDailyChanges = previousDailyChanges.filter { $0.value.isFinite }
        for holding in presentation.2 {
            if let value = holding.todayChangePercent, value.isFinite {
                holdingDailyChanges[holding.ticker.uppercased()] = value
            }
        }
        applyDetailDailyChanges()
        if invalidatesDailyChanges {
            holdingDailyChangesSignature = ""
            isHoldingDailyChangesLoading = !presentation.2.isEmpty
        }
        if localSelectionOnly {
            holdingDailyChangesSignature = Self.dailyChangesSignature(for: presentation.2)
            isHoldingDailyChangesLoading = false
        }
        localSource = isPublicInvestorMode ? scoped.accounts.map(\.displayName).joined(separator: "、") : scoped.source
        localUpdatedAt = loaded.marketDataUpdatedAt
        comparison = nil
        returnsAnalytics = nil
        returnsAnalyticsPendingParts = []
        comparisonWarning = nil
        analyticsWarning = nil
        comparisonRevision &+= 1
        returnsAnalyticsRevision &+= 1
    }

    var portfolioSource: PortfolioSource {
        if isPublicInvestorMode { return .publicInvestors(publicInvestorSelection) }
        return isFakeDataMode ? .demo : .personal
    }

    /// The two flags and selection change synchronously, before any suspension.
    /// Switching never clears persisted portfolio or shared public-data caches.
    func setPortfolioMode(enabled: Bool, selection: String) {
        let chosen = enabled && selection.isEmpty ? PublicInvestorPreferences.defaultSelection : selection
        let normalized = PublicInvestorPreferences.selectedIDs(chosen).sorted().joined(separator: ",")
        let demo = enabled && PublicInvestorPreferences.isDemo(normalized)
        let investor = enabled && !demo
        guard demo != isFakeDataMode || investor != isPublicInvestorMode
                || normalized != publicInvestorSelection else { return }

        if presentedSource == portfolioSource {
            sourcePresentations[portfolioSource] = captureSourcePresentation()
        }
        portfolioSourceGeneration &+= 1
        let generation = portfolioSourceGeneration
        portfolioSourceTask?.cancel()
        invalidateInFlightRequests()
        let changedSelection = normalized != publicInvestorSelection
        storedFakeDataMode = demo
        storedPublicInvestorMode = investor
        storedPublicInvestorSelection = normalized
        modeDefaults.set(demo, forKey: Self.fakeDataModeKey)
        modeDefaults.set(investor, forKey: PublicInvestorPreferences.enabledKey)
        modeDefaults.set(normalized, forKey: PublicInvestorPreferences.selectionKey)
        if changedSelection {
            modeDefaults.set(true, forKey: "catfolio.publicSelectsAllAccounts")
        }
        fakeDataModeError = nil
        portfolioFailure = nil
        returnsError = nil
        comparisonWarning = nil
        analyticsWarning = nil
        if let cached = sourcePresentations[portfolioSource] {
            restoreSourcePresentation(cached)
        } else {
            clearSourcePresentation()
        }
        portfolioSourceTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled,
                  generation == self.portfolioSourceGeneration else { return }
            await self.refreshPortfolio()
            guard !Task.isCancelled, generation == self.portfolioSourceGeneration else { return }
            await self.refreshReturnsPage()
            if generation == self.portfolioSourceGeneration { self.portfolioSourceTask = nil }
        }
    }

    struct SourcePresentation {
        let document: LocalPortfolioDocument
        let fullDocument: LocalPortfolioDocument
        let overview: PortfolioOverview?
        let chart: PortfolioChartResponse?
        let holdings: [Holding]
        let accounts: [PortfolioAccount]
        let accountKeys: Set<String>
        let dailyChanges: [String: Double]
        let benchmark: Double?
        let comparison: ComparisonResponse?
        let analytics: ReturnsAnalyticsResponse?
        let source: String
        let updatedAt: Date?
        var cachedAt: Date? = nil
    }

    private func captureSourcePresentation() -> SourcePresentation {
        SourcePresentation(document: document, fullDocument: fullDocument, overview: overview, chart: portfolioChart,
            holdings: holdings, accounts: accounts, accountKeys: selectedAccountKeys,
            dailyChanges: holdingDailyChanges, benchmark: benchmarkDailyChange,
            comparison: comparison, analytics: returnsAnalytics, source: localSource, updatedAt: localUpdatedAt,
            cachedAt: portfolioCachedAt)
    }

    private func restoreSourcePresentation(
        _ cached: SourcePresentation, preparedScope: PreparedAccountScope? = nil
    ) {
        document = cached.document
        if let preparedScope {
            realisedProfit = preparedScope.realisedProfit
            realisedProfitGaps = preparedScope.realisedProfitGaps
        } else {
            // An in-memory source can be restored after FX rates changed.
            updateRealisedProfit(from: document)
        }
        fullDocument = cached.fullDocument
        overview = cached.overview
        portfolioChart = cached.chart
        holdings = cached.holdings
        accounts = cached.accounts
        storedSelectedAccountKeys = cached.accountKeys
        holdingDailyChanges = cached.dailyChanges
        benchmarkDailyChange = cached.benchmark
        comparison = cached.comparison
        returnsAnalytics = cached.analytics
        localSource = cached.source
        localUpdatedAt = cached.updatedAt
        portfolioCachedAt = cached.cachedAt
        presentedSource = portfolioSource
        portfolioChartRevision &+= 1
        comparisonRevision &+= 1
        returnsAnalyticsRevision &+= 1
    }

    private func clearSourcePresentation() {
        // Only the outgoing screen state; never a disk-cache deletion.
        document = .empty
        updateRealisedProfit(from: document)
        fullDocument = .empty
        presentedSource = nil
        holdings = []
        overview = nil
        portfolioChart = nil
        comparison = nil
        returnsAnalytics = nil
        accounts = []
        storedSelectedAccountKeys = []
        holdingDailyChanges = [:]
        localUpdatedAt = nil
        portfolioCachedAt = nil
        localSource = "尚未导入"
        portfolioChartRevision &+= 1
        comparisonRevision &+= 1
        returnsAnalyticsRevision &+= 1
    }

    var hasUsableHomeChart: Bool {
        presentedSource == portfolioSource && portfolioChart?.currentPoint.marketValue.isFinite == true
    }

    private func homeCacheContext(accountKeys: Set<String>) -> PortfolioPresentationCache.Context {
        .init(source: portfolioSource, accountKeys: accountKeys, language: ContentLanguage.current)
    }

    func canPreserveHomeChart(for loaded: LocalPortfolioDocument, accountKeys: Set<String>) async -> Bool {
        guard hasUsableHomeChart, selectedAccountKeys == accountKeys else { return false }
        return await presentationCache.sameLedger(fullDocument, loaded)
    }

    func restoreHomePresentation(
        from loaded: LocalPortfolioDocument, scope preparedScope: PreparedAccountScope, generation: Int
    ) async -> Bool {
        // An already visible presentation can contain newer detail-page quotes.
        guard overview == nil || presentedSource != portfolioSource,
              detailMarketObservations[portfolioSource]?.isEmpty != false else { return false }
        let context = homeCacheContext(accountKeys: preparedScope.keys)
        guard let cached = await presentationCache.load(document: loaded, context: context),
              generation == portfolioRequestGeneration, !Task.isCancelled else { return false }
        let scoped = preparedScope.document
        restoreSourcePresentation(SourcePresentation(
            document: scoped, fullDocument: loaded, overview: cached.overview, chart: cached.chart,
            holdings: cached.holdings, accounts: preparedScope.accounts, accountKeys: preparedScope.keys,
            dailyChanges: cached.dailyChanges, benchmark: cached.benchmark, comparison: nil, analytics: nil,
            source: isPublicInvestorMode ? scoped.accounts.map(\.displayName).joined(separator: "、") : scoped.source,
            updatedAt: cached.updatedAt, cachedAt: cached.savedAt), preparedScope: preparedScope)
        isPortfolioChartLoading = !hasUsableHomeChart
        isHoldingDailyChangesLoading = false
        // Keep refreshing in the background; restoration is not a fresh quote.
        holdingDailyChangesSignature = ""
        return true
    }

    func saveHomePresentation(generation: Int? = nil) async {
        guard !Task.isCancelled, generation == nil || generation == portfolioRequestGeneration,
              presentedSource == portfolioSource, let overview, let chart = portfolioChart else { return }
        let snapshot = PortfolioPresentationSnapshot(overview: overview, chart: chart, holdings: holdings,
            dailyChanges: holdingDailyChanges, benchmark: benchmarkDailyChange,
            updatedAt: localUpdatedAt, savedAt: Date())
        // Failure to write a disposable result cache must not fail a refresh.
        try? await presentationCache.save(snapshot, document: fullDocument,
            context: homeCacheContext(accountKeys: selectedAccountKeys))
    }

    func loadActiveDocument() async throws -> LocalPortfolioDocument {
        if isPublicInvestorMode {
            let catalog = try await PublicInvestorCatalogState.shared.get()
            return try await publicInvestorStore.load(catalog: catalog, selection: publicInvestorSelection)
        }
        #if DEBUG
        if LaunchArguments.contains("--verify-empty-account") { return FoundationRegressionChecks.emptyFixture }
        #endif
        if isFakeDataMode {
            return await Task.detached(priority: .userInitiated) { FakePortfolioGenerator.make() }.value
        }
        let loaded = try await personalDocumentLoader()
        if let notice = await LocalPortfolioStore.shared.recoveryNotice {
            portfolioRecoveryNotice = notice
        }
        return loaded
    }

    func activeDocument(from loaded: LocalPortfolioDocument) -> LocalPortfolioDocument {
        if isPublicInvestorMode {
            return document
        }
        return isFakeDataMode ? FakePortfolioGenerator.make() : loaded
    }

    private func resolvedAccountKeys(in loaded: LocalPortfolioDocument) -> Set<String> {
        let availableKeys = Set(loaded.accounts.map(\.id))
        let savedKeys = Self.savedAccountKeys(forKey: selectedAccountsStorageKey, defaults: modeDefaults).intersection(availableKeys)
        let selectsAll = modeDefaults.bool(forKey: selectsAllAccountsStorageKey)
        return selectsAll || savedKeys.isEmpty ? availableKeys : savedKeys
    }

    /// Resolve a pending account tap against the already published account
    /// list, without regrouping the full ledger on the main actor.
    func requestedAccountKeysFromDisplayedAccounts() -> Set<String> {
        let availableKeys = Set(accounts.map(\.id))
        let savedKeys = Self.savedAccountKeys(forKey: selectedAccountsStorageKey, defaults: modeDefaults)
            .intersection(availableKeys)
        let selectsAll = modeDefaults.bool(forKey: selectsAllAccountsStorageKey)
        return selectsAll || savedKeys.isEmpty ? availableKeys : savedKeys
    }

    func selectedDocument(from loaded: LocalPortfolioDocument) async -> LocalPortfolioDocument {
        let prepared = await prepareAccountScope(for: loaded)
        return prepared.document
    }

    func updateAccountSelection(_ keys: Set<String>, selectsAll: Bool) async {
        let availableKeys = Set(accounts.map(\.id))
        let next = keys.intersection(availableKeys)
        guard !next.isEmpty, presentedSource == portfolioSource else { return }
        let previousRequest = requestedAccountKeysFromDisplayedAccounts()
        Self.saveAccountKeys(next, forKey: selectedAccountsStorageKey, defaults: modeDefaults)
        modeDefaults.set(selectsAll, forKey: selectsAllAccountsStorageKey)
        guard next != previousRequest else { return }
        portfolioSourceTask?.cancel()
        portfolioSourceTask = nil
        let benchmark = benchmarkDailyChange
        invalidateInFlightRequests()
        let generation = portfolioRequestGeneration
        benchmarkDailyChange = benchmark
        portfolioFailure = nil
        do {
            // Re-scope the complete in-memory ledger, reusing quote and history
            // caches. Account visibility never triggers a broker or market refresh.
            try await apply(fullDocument, invalidatesDailyChanges: false, localSelectionOnly: true)
            await saveHomePresentation(generation: generation)
        } catch {
            guard generation == portfolioRequestGeneration else { return }
            portfolioFailure = error
        }
    }

    private var selectedAccountsStorageKey: String {
        isPublicInvestorMode ? "catfolio.publicSelectedAccounts" : (isFakeDataMode ? Self.fakeSelectedAccountsKey : Self.selectedAccountsKey)
    }

    private var selectsAllAccountsStorageKey: String {
        isPublicInvestorMode ? "catfolio.publicSelectsAllAccounts" : (isFakeDataMode ? Self.fakeSelectsAllAccountsKey : Self.selectsAllAccountsKey)
    }

    private static func savedAccountKeys(forKey key: String, defaults: UserDefaults) -> Set<String> {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(values)
    }

    private static func saveAccountKeys(_ keys: Set<String>, forKey key: String, defaults: UserDefaults) {
        let values = keys.sorted()
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }

    static func maskedAccountName(provider: String, accountID: String) -> String {
        let suffix = String(accountID.suffix(4))
        return suffix.isEmpty ? provider : "\(provider) · •••• \(suffix)"
    }

    static func nextGeneratedNickname(usedNames: Set<String>) -> String {
        if let nickname = AccountNaming.generatedNicknames.first(where: { candidate in
            !usedNames.contains(where: { $0 == candidate || $0.hasSuffix(" · \(candidate)") })
        }) {
            return nickname
        }
        var index = 2
        while usedNames.contains(where: { $0.hasSuffix(" · 橘子 \(index)") || $0 == "橘子 \(index)" }) {
            index += 1
        }
        return "橘子 \(index)"
    }

}
