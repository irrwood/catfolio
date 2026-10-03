import Foundation
import Observation

/// A manual home refresh reports what actually changed, rather than treating
/// a completed request (or restored presentation cache) as a new quote.
enum PortfolioRefreshResult: Equatable {
    case quotesUpdated
    case portfolioLoaded
    case portfolioLoadedWithoutNewQuotes
    case unchangedQuotes
    case unchangedContent
    case noHeldQuotes
    case failed(retainsData: Bool)

    static func acceptedQuoteCount(before: LocalPortfolioDocument, after: LocalPortfolioDocument) -> Int {
        var previous: [String: Date] = [:]
        for position in before.positions {
            guard let observedAt = position.quoteObservedAt else { continue }
            let key = LocalMarketQuoteKey.make(ticker: position.ticker, currency: position.quoteCurrency)
            previous[key] = max(previous[key] ?? .distantPast, observedAt)
        }
        return Set(after.positions.compactMap { position -> String? in
            let key = LocalMarketQuoteKey.make(ticker: position.ticker, currency: position.quoteCurrency)
            guard let observedAt = position.quoteObservedAt,
                  observedAt > (previous[key] ?? .distantPast) else { return nil }
            return key
        }).count
    }

    static func completed(previous: LocalPortfolioDocument?, loaded: LocalPortfolioDocument,
                          acceptedQuoteCount: Int, refreshedDisclosure: Bool, tracksQuotes: Bool) -> Self {
        if acceptedQuoteCount > 0 { return .quotesUpdated }
        if refreshedDisclosure { return .portfolioLoaded }
        let changed = previous.map { old in
            old.source != loaded.source || old.positions != loaded.positions || old.snapshots != loaded.snapshots
                || old.transactions != loaded.transactions || old.knownAccounts != loaded.knownAccounts
        } ?? (!loaded.positions.isEmpty || !loaded.snapshots.isEmpty || !(loaded.transactions ?? []).isEmpty)
        if changed { return tracksQuotes ? .portfolioLoadedWithoutNewQuotes : .portfolioLoaded }
        return tracksQuotes ? .unchangedQuotes : .unchangedContent
    }
}

@Observable
@MainActor
final class AppModel {
    var overview: PortfolioOverview?
    /// Profit already taken in the selected accounts, in USD: the broker's own
    /// result on every sale it reported one for. `.nan` when no sale carries
    /// one, which is not the same as zero profit.
    private(set) var realisedProfit: Double = .nan
    /// Sales the broker gave no result for. The figure above is short by
    /// whatever those made or lost, so the reader is told rather than shown a
    /// total that looks complete.
    private(set) var realisedProfitGaps = 0
    var portfolioChart: PortfolioChartResponse?
    var holdings: [Holding] = []
    private(set) var holdingDailyChanges: [String: Double] = [:]
    private(set) var benchmarkDailyChange: Double?
    private(set) var isHoldingDailyChangesLoading = false
    var comparison: ComparisonResponse?
    var returnsAnalytics: ReturnsAnalyticsResponse?
    var isPortfolioLoading = false
    var isReturnsLoading = false
    var isReturnsAnalyticsLoading = false
    var returnsAnalyticsPendingParts: Set<ReturnsAnalyticsPart> = []
    // Keep the error, not its translated snapshot: the home empty state must
    // follow language changes made in Settings without reloading the portfolio.
    private var portfolioFailure: Error?
    var portfolioError: String? { portfolioFailure?.localizedDescription }
    var returnsError: String?
    private var comparisonWarning: String?
    private var analyticsWarning: String?
    var activeBroker: BrokerProvider?
    var localSource = "尚未导入"
    var localUpdatedAt: Date?
    private(set) var portfolioCachedAt: Date?
    var accounts: [PortfolioAccount] = []
    var selectedAccountKeys: Set<String> = []
    private(set) var portfolioChartRevision = 0
    private(set) var isPortfolioChartLoading = false
    private(set) var comparisonRevision = 0
    private(set) var returnsAnalyticsRevision = 0
    private(set) var isFakeDataMode: Bool
    private(set) var isPublicInvestorMode: Bool
    private(set) var publicInvestorSelection: String
    var publicDisclosureSummary: PublicAccountDisclosure? {
        let rows = document.positions.compactMap(\.publicDisclosure)
        return rows.isEmpty ? nil : PublicAccountDisclosure.combining(rows)
    }
    var fakeDataModeError: String?
    var portfolioRecoveryNotice: String?

    var returnsWarning: String? {
        let values = [comparisonWarning, analyticsWarning]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    @ObservationIgnored private var document = LocalPortfolioDocument.empty
    @ObservationIgnored private var fullDocument = LocalPortfolioDocument.empty
    @ObservationIgnored private var portfolioRequestGeneration = 0
    @ObservationIgnored private var returnsRequestGeneration = 0
    @ObservationIgnored private var returnsAnalyticsRequestGeneration = 0
    @ObservationIgnored private var returnsPageRequestGeneration = 0
    @ObservationIgnored private var dailyChangesRequestGeneration = 0
    @ObservationIgnored private var holdingDailyChangesSignature = ""
    @ObservationIgnored private var detailMarketObservations: [PortfolioSource: [String: SecurityMarketObservation]] = [:]
    @ObservationIgnored private var detailQuoteGeneration = 0
    @ObservationIgnored private var holdingDetailContent: [HoldingDetailContentKey: HoldingDetailCachedContent] = [:]
    @ObservationIgnored private var holdingDetailContentOrder: [HoldingDetailContentKey] = []
    @ObservationIgnored private var holdingDetailMemoryObserver: NSObjectProtocol?
    /// Each entry holds a page's whole history, volume profile, options and
    /// research; a handful covers going back and forth between holdings.
    static let holdingDetailCacheLimit = 8
    @ObservationIgnored private var returnsPageTask: Task<Void, Never>?
    @ObservationIgnored private var detailChartTask: Task<Void, Never>?
    @ObservationIgnored private var portfolioSourceTask: Task<Void, Never>?
    @ObservationIgnored private var portfolioSourceGeneration = 0
    @ObservationIgnored private var presentedSource: PortfolioSource?
    @ObservationIgnored private var sourcePresentations: [PortfolioSource: SourcePresentation] = [:]
    @ObservationIgnored private let modeDefaults: UserDefaults
    @ObservationIgnored private let publicInvestorStore: PublicInvestorSimulationStore
    @ObservationIgnored private let personalDocumentLoader: @Sendable () async throws -> LocalPortfolioDocument
    @ObservationIgnored private let personalDocumentResetter: @Sendable () async throws -> URL?
    @ObservationIgnored private let presentationCache: PortfolioPresentationCache
    private static let brokerKey = "catfolio.activeBroker"
    private static let selectedAccountsKey = "catfolio.selectedAccounts"
    private static let selectsAllAccountsKey = "catfolio.selectsAllAccounts"
    private static let fakeDataModeKey = "catfolio.fakeDataMode"
    private static let fakeSelectedAccountsKey = "catfolio.fakeDataSelectedAccounts"
    private static let fakeSelectsAllAccountsKey = "catfolio.fakeDataSelectsAllAccounts"

    init(
        defaults: UserDefaults = .standard,
        publicInvestorStore: PublicInvestorSimulationStore = .shared,
        personalDocumentLoader: @escaping @Sendable () async throws -> LocalPortfolioDocument = {
            try LocalPortfolioStore.shared.load()
        },
        personalDocumentResetter: @escaping @Sendable () async throws -> URL? = {
            try LocalPortfolioStore.shared.resetPortfolio()
        },
        presentationCache: PortfolioPresentationCache = .shared
    ) {
        modeDefaults = defaults
        self.publicInvestorStore = publicInvestorStore
        self.personalDocumentLoader = personalDocumentLoader
        self.personalDocumentResetter = personalDocumentResetter
        self.presentationCache = presentationCache
        publicInvestorSelection = defaults.string(forKey: PublicInvestorPreferences.selectionKey) ?? PublicInvestorPreferences.defaultSelection
        isFakeDataMode = defaults.bool(forKey: Self.fakeDataModeKey)
        isPublicInvestorMode = defaults.bool(forKey: PublicInvestorPreferences.enabledKey)
        if isFakeDataMode && isPublicInvestorMode {
            isFakeDataMode = PublicInvestorPreferences.isDemo(publicInvestorSelection)
            isPublicInvestorMode = !isFakeDataMode
        }
        if let raw = defaults.string(forKey: Self.brokerKey) {
            activeBroker = BrokerProvider(rawValue: raw)
        }
    }

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
    private var comparisonCacheScope: String {
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

    private struct HoldingDetailContentKey: Hashable {
        let source: PortfolioSource
        let quote: String
        let accounts: [String]
    }

    /// Keep prepared detail content alive after its sheet closes. Account data
    /// is scoped to the portfolio source; opening another source cannot reuse it.
    func cachedHoldingDetail(for holding: Holding) -> HoldingDetailCachedContent {
        let key = HoldingDetailContentKey(source: portfolioSource,
            quote: LocalMarketQuoteKey.make(ticker: holding.ticker, currency: holding.quoteCurrency ?? "USD"),
            accounts: accounts.map(\.id).sorted())
        observeMemoryWarningsForHoldingDetails()
        holdingDetailContentOrder.removeAll { $0 == key }
        holdingDetailContentOrder.append(key)
        if let cached = holdingDetailContent[key] { return cached }
        let content = HoldingDetailCachedContent()
        holdingDetailContent[key] = content
        while holdingDetailContentOrder.count > Self.holdingDetailCacheLimit {
            holdingDetailContent.removeValue(forKey: holdingDetailContentOrder.removeFirst())
        }
        return content
    }

    /// Under memory pressure the kept pages go; an open page keeps its own
    /// content, which it holds itself.
    private func observeMemoryWarningsForHoldingDetails() {
        guard holdingDetailMemoryObserver == nil else { return }
        holdingDetailMemoryObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearHoldingDetailCache() }
        }
    }

    func clearHoldingDetailCache() {
        holdingDetailContent = [:]
        holdingDetailContentOrder = []
    }

    /// `currency` stands in for a security that is not held, whose listing
    /// currency no holding can supply.
    func volumeProfile(for ticker: String, currency: String? = nil, forceRefresh: Bool = false,
                       cachedOnly: Bool = false) async throws -> VolumeProfile {
        let holding = holdings.first(where: { $0.ticker == ticker })
        return try await LocalMarketDataClient().volumeProfile(
            ticker: ticker,
            currency: holding?.quoteCurrency ?? currency ?? "USD",
            referencePrice: holding?.quotePrice.isFinite == true ? holding?.quotePrice : nil,
            forceRefresh: forceRefresh,
            cachedOnly: cachedOnly
        )
    }

    func securityPriceHistory(for ticker: String) async throws -> SecurityPriceHistory {
        let source = portfolioSource
        let loaded = try await loadActiveDocument()
        let scoped = await selectedDocument(from: loaded)
        let holding = holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
        let history = try await LocalMarketDataClient().securityPriceHistory(
            ticker: ticker,
            currency: holding?.quoteCurrency ?? "USD",
            referencePrice: holding?.quotePrice.isFinite == true ? holding?.quotePrice : nil,
            document: scoped
        )
        try await publishSecurityPriceHistory(history, source: source)
        return history
    }

    /// A security held in no account — one opened from search, found only
    /// inside an ETF, or sold out of entirely. Its market history, with the
    /// ledger's past trades in it marked, so a closed position keeps its
    /// buy and sell points.
    func marketPriceHistory(for ticker: String, currency: String, forceRefresh: Bool = false,
                            cachedOnly: Bool = false) async throws -> SecurityPriceHistory {
        let source = portfolioSource
        var ledger = LocalPortfolioDocument.empty
        if let loaded = try? await loadActiveDocument() {
            let scoped = await selectedDocument(from: loaded)
            ledger.transactions = (scoped.transactions ?? []).filter {
                $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame
            }
        }
        let history = try await LocalMarketDataClient().securityPriceHistory(
            ticker: ticker,
            currency: currency,
            document: ledger,
            forceRefresh: forceRefresh,
            cachedOnly: cachedOnly
        )
        try await publishSecurityPriceHistory(history, source: source)
        return history
    }

    /// Holdings as they stand inside a subset of accounts.
    ///
    /// The published `holdings` are the whole portfolio. A screen with its
    /// own account filter needs the positions those accounts actually hold,
    /// re-derived rather than apportioned, because weight and market value
    /// are properties of the scope they are computed in.
    func holdings(forAccounts accountIDs: Set<String>) async throws -> [Holding] {
        let document = try await loadActiveDocument()
        return try await Task.detached(priority: .userInitiated) {
            try LocalPortfolioEngine.presentation(for: document.scoped(to: accountIDs)).2
        }.value
    }

    func holdingDetailAccountContext(for ticker: String) async throws -> HoldingDetailAccountContext {
        let loaded = try await loadActiveDocument()
        let normalizedTicker = ticker.uppercased()
        let matchingPositions = loaded.positions.filter {
            $0.ticker.uppercased() == normalizedTicker
        }
        guard !matchingPositions.isEmpty else { throw LocalPortfolioError.noPortfolio }

        let accountsByID = Dictionary(uniqueKeysWithValues: loaded.accounts.map { ($0.id, $0) })
        let options = try Dictionary(grouping: matchingPositions, by: \.accountKey)
            .map { accountKey, positions -> HoldingDetailAccountOption in
                let quoteCurrency = positions.first?.quoteCurrency ?? "USD"
                let marketValue = positions.reduce(0.0) {
                    $0 + ($1.publicDisclosure.map { $0.value ?? .nan } ?? ($1.shares * $1.quotePrice))
                }
                let marketValueUSD = try positions.reduce(0.0) { partial, position in
                    partial + (try LocalPortfolioEngine.usd(
                        position.publicDisclosure.map { $0.value ?? .nan } ?? (position.shares * position.quotePrice),
                        currency: position.quoteCurrency
                    ))
                }
                let account = accountsByID[accountKey]
                let unrealized: Double?
                if positions.contains(where: { $0.publicDisclosure != nil }) {
                    unrealized = nil
                } else {
                    let totals = try LocalPortfolioEngine.totals(for: positions)
                    let unitUSD = try LocalPortfolioEngine.usd(1, currency: quoteCurrency)
                    let value = (totals.marketValue - totals.cost) / unitUSD
                    unrealized = value.isFinite ? value : nil
                }
                return HoldingDetailAccountOption(
                    id: accountKey,
                    displayName: account?.displayName
                        ?? positions.first?.resolvedAccountName
                        ?? "账户",
                    marketValue: marketValue,
                    currency: quoteCurrency,
                    marketValueUSD: marketValueUSD,
                    unrealized: unrealized
                )
            }
            .sorted { lhs, rhs in
                if lhs.marketValueUSD == rhs.marketValueUSD {
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.marketValueUSD > rhs.marketValueUSD
            }

        return HoldingDetailAccountContext(
            ticker: ticker,
            document: loaded,
            options: options
        )
    }

    func securityPriceHistory(
        for ticker: String,
        accountKeys: Set<String>,
        forceRefresh: Bool = false,
        cachedOnly: Bool = false
    ) async throws -> SecurityPriceHistory {
        let source = portfolioSource
        let context = try await holdingDetailAccountContext(for: ticker)
        // Positions from the picked accounts; trades also from any account
        // that has since sold out, so their buys and sells stay marked.
        let scoped = context.document.scoped(to: context.tradeAccountKeys(for: accountKeys))
        let scopedHolding = context.holding(for: accountKeys)
        let history = try await LocalMarketDataClient().securityPriceHistory(
            ticker: ticker,
            currency: scopedHolding?.quoteCurrency ?? "USD",
            referencePrice: scopedHolding?.quotePrice.isFinite == true ? scopedHolding?.quotePrice : nil,
            document: scoped,
            forceRefresh: forceRefresh,
            cachedOnly: cachedOnly
        )
        try await publishSecurityPriceHistory(history, source: source)
        return history
    }

    /// Detail and outer pages share the same observed quote. Keep these
    /// overlays through background portfolio/daily-change refreshes, which
    /// may have started before the detail request finished.
    func publishSecurityPriceHistory(_ history: SecurityPriceHistory, source: PortfolioSource,
                                     now: Date = .now) async throws {
        guard !Task.isCancelled, source == portfolioSource,
              let observation = history.latestMarketObservation,
              observation.observedAt <= now.addingTimeInterval(60),
              observation.observedAt >= now.addingTimeInterval(-7 * 86_400) else { return }
        let key = LocalMarketQuoteKey.make(ticker: history.ticker, currency: history.currency)
        guard detailMarketObservations[source]?[key].map({ observation.observedAt > $0.observedAt }) ?? true else { return }
        let matching = document.positions.filter {
            LocalMarketQuoteKey.make(ticker: $0.ticker, currency: $0.quoteCurrency) == key
        }
        if matching.isEmpty {
            // ETF-only constituents have no position to reprice. Share their
            // USD market change without creating a holding or changing totals.
            guard history.currency.uppercased() == "USD",
                  !holdings.contains(where: { $0.ticker.uppercased() == observation.ticker }) else { return }
            detailMarketObservations[source, default: [:]][key] = observation
            applyDetailDailyChanges(now: now)
            return
        }
        guard matching.allSatisfy({ observation.observedAt >= quoteDate($0, in: document) }) else { return }
        detailMarketObservations[source, default: [:]][key] = observation
        detailQuoteGeneration &+= 1
        let quoteGeneration = detailQuoteGeneration
        let requestGeneration = portfolioRequestGeneration
        let originalDocument = document
        let updated = applyingDetailQuotes(to: originalDocument, now: now)
        // This derives FX impact for every holding from the entire trade
        // ledger. Running it on the main actor stalls scrolling and the
        // detail-to-home transition for large portfolios.
        let presentation = try await Task.detached(priority: .userInitiated) {
            try LocalPortfolioEngine.presentation(for: updated)
        }.value
        guard !Task.isCancelled, source == portfolioSource,
              quoteGeneration == detailQuoteGeneration,
              requestGeneration == portfolioRequestGeneration,
              document == originalDocument else { return }
        document = updated
        overview = presentation.0
        holdings = presentation.2
        applyDetailDailyChanges(now: now)
        detailChartTask?.cancel()
        let generation = portfolioRequestGeneration
        detailChartTask = Task { [weak self] in
            guard let self else { return }
            if let chart = try? await LocalMarketDataClient().portfolioChart(document: updated, cachedOnly: true),
               !Task.isCancelled, generation == self.portfolioRequestGeneration,
               self.document == updated, chart.currentPoint.marketValue.isFinite {
                self.portfolioChart = chart
                self.portfolioChartRevision &+= 1
                await self.saveHomePresentation(generation: generation)
            }
        }
    }

    private func quoteDate(_ position: LocalPositionRecord, in document: LocalPortfolioDocument) -> Date {
        position.quoteObservedAt ?? (position.source == "CSV" ? nil : document.marketDataUpdatedAt) ?? .distantPast
    }

    private func applyingDetailQuotes(to input: LocalPortfolioDocument, now: Date = .now) -> LocalPortfolioDocument {
        guard let observations = detailMarketObservations[portfolioSource] else { return input }
        var result = input
        result.positions = input.positions.map { position in
            let key = LocalMarketQuoteKey.make(ticker: position.ticker, currency: position.quoteCurrency)
            guard let observation = observations[key],
                  observation.observedAt >= now.addingTimeInterval(-7 * 86_400),
                  observation.observedAt > quoteDate(position, in: input) else { return position }
            return position.withQuotePrice(observation.price, observedAt: observation.observedAt)
        }
        return result
    }

    private func applyDetailDailyChanges(now: Date = .now) {
        guard let observations = detailMarketObservations[portfolioSource], !observations.isEmpty else { return }
        let heldTickers = Set(holdings.map { $0.ticker.uppercased() })
        let positionsByQuoteKey = Dictionary(grouping: document.positions) {
            LocalMarketQuoteKey.make(ticker: $0.ticker, currency: $0.quoteCurrency)
        }
        for observation in observations.values where !heldTickers.contains(observation.ticker) {
            guard observation.currency.uppercased() == "USD", let change = observation.changePercent,
                  observation.observedAt >= now.addingTimeInterval(-7 * 86_400) else { continue }
            holdingDailyChanges[observation.ticker] = change
        }
        for holding in holdings {
            let key = LocalMarketQuoteKey.make(ticker: holding.ticker, currency: holding.quoteCurrency ?? "USD")
            guard let observation = observations[key], let change = observation.changePercent,
                  observation.observedAt >= now.addingTimeInterval(-7 * 86_400) else { continue }
            let matching = positionsByQuoteKey[key] ?? []
            guard matching.allSatisfy({ observation.observedAt >= quoteDate($0, in: document) }) else { continue }
            holdingDailyChanges[holding.ticker.uppercased()] = change
        }
    }

    func refreshHoldingDailyChanges(forceRefresh: Bool = false) async {
        let portfolioGeneration = portfolioRequestGeneration
        let snapshot = holdings
        guard !snapshot.isEmpty else {
            holdingDailyChanges = [:]
            benchmarkDailyChange = nil
            holdingDailyChangesSignature = ""
            isHoldingDailyChangesLoading = false
            return
        }

        let signature = Self.dailyChangesSignature(for: snapshot)
        guard forceRefresh || signature != holdingDailyChangesSignature else { return }

        dailyChangesRequestGeneration &+= 1
        let generation = dailyChangesRequestGeneration
        var changes = holdingDailyChanges.filter { $0.value.isFinite }
        var holdingsNeedingFetch: [Holding] = []
        for holding in snapshot {
            let key = holding.ticker.uppercased()
            if let value = holding.todayChangePercent, value.isFinite, !forceRefresh || isFakeDataMode {
                changes[key] = value
            } else {
                // Existing values remain visible while their replacements are
                // fetched. Imported broker positions normally have no inline
                // daily change, so clearing here caused TODAY to flash as zero.
                holdingsNeedingFetch.append(holding)
            }
        }
        holdingDailyChanges = changes
        applyDetailDailyChanges()

        isHoldingDailyChangesLoading = true
        defer {
            if generation == dailyChangesRequestGeneration {
                isHoldingDailyChangesLoading = false
            }
        }
        let client = LocalMarketDataClient()
        let fetchSnapshot = holdingsNeedingFetch
        async let fetchedChanges = client.dailyChanges(for: fetchSnapshot, positions: document.positions, forceRefresh: forceRefresh)
        // Holdings can combine a fresh quote with saved daily closes. SPY has
        // no portfolio quote overlay, so fetch its current daily point even
        // when the wider history refresh is allowed to use its cache.
        async let fetchedBenchmark = client.dailyChange(ticker: "SPY", forceRefresh: true)
        let (fetched, benchmark) = await (fetchedChanges, fetchedBenchmark)
        guard !Task.isCancelled,
              generation == dailyChangesRequestGeneration,
              portfolioGeneration == portfolioRequestGeneration,
              signature == Self.dailyChangesSignature(for: holdings) else { return }

        changes.merge(fetched) { _, latest in latest }
        holdingDailyChanges = changes
        applyDetailDailyChanges()
        if let benchmark, benchmark.isFinite {
            benchmarkDailyChange = benchmark
        }
        holdingDailyChangesSignature = signature
        await saveHomePresentation(generation: portfolioGeneration)
    }

    func loadBriefing() async throws -> String {
        let loaded = try await loadActiveDocument()
        let scoped = await selectedDocument(from: loaded)
        return try await LocalAIClient().briefing(document: scoped)
    }

    func askAI(_ question: String, attentionContext: String? = nil) async throws -> String {
        let scope = comparisonCacheScope
        let loaded = try await loadActiveDocument()
        let scoped = await selectedDocument(from: loaded)
        guard scope == comparisonCacheScope else { throw CancellationError() }
        return try await LocalAIClient().answer(
            question,
            document: scoped,
            additionalContext: computedAIContext(for: scoped, attentionContext: attentionContext)
        )
    }

    /// `askAI`, delivered as the model writes it.
    func streamAI(_ question: String, attentionContext: String? = nil, webSearch: Bool = false) async throws -> AsyncThrowingStream<AIStreamEvent, Error> {
        let scope = comparisonCacheScope
        let loaded = try await loadActiveDocument()
        let scoped = await selectedDocument(from: loaded)
        guard scope == comparisonCacheScope else { throw CancellationError() }
        return LocalAIClient().streamAnswer(
            question,
            document: scoped,
            additionalContext: computedAIContext(for: scoped, attentionContext: attentionContext),
            webSearch: webSearch
        )
    }

    private func computedAIContext(for scoped: LocalPortfolioDocument, attentionContext: String?) -> String {
        var sections: [String] = []
        if presentedSource == portfolioSource,
           Set(document.accounts.map(\.id)) == Set(scoped.accounts.map(\.id)) {
            sections.append(AIComputedContext.build(
                overview: overview, holdings: holdings, dailyChanges: holdingDailyChanges,
                realisedProfit: realisedProfit, realisedProfitGaps: realisedProfitGaps,
                comparison: comparison, analytics: returnsAnalytics,
                updatedAt: localUpdatedAt, cachedAt: portfolioCachedAt))
        }
        if let attentionContext, !attentionContext.isEmpty {
            sections.append("上一次 Portfolio Attention 的结果（保留信号、thesis 与 confidence）：\n" + attentionContext)
        }
        return sections.joined(separator: "\n\n")
    }

    func rejudgeAttention(_ row: PortfolioAttentionHolding, supporting: [String], counter: [String],
                          notes: [String]) async throws -> PortfolioAttentionThesis {
        try await LocalAIClient().rejudgeAttention(row: row, supporting: supporting, counter: counter, notes: notes)
    }

    func followUpAttention(_ row: PortfolioAttentionHolding, question: String,
                           history: [PortfolioAttentionFollowUp]) async throws -> (text: String, searched: Bool) {
        try await LocalAIClient().followUpAttention(row: row, question: question, history: history)
    }

    func portfolioAttention() async throws -> PortfolioAttentionReport {
        let loaded = try await loadActiveDocument()
        let scoped = await selectedDocument(from: loaded)
        return try await LocalAIClient().portfolioAttention(document: scoped)
    }

    func selectBroker(_ provider: BrokerProvider) {
        activeBroker = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.brokerKey)
    }

    func loadETFLookThrough(basis: ETFLookThroughBasis) async throws -> ETFLookThroughResponse {
        let snapshot: LocalPortfolioDocument
        if presentedSource == portfolioSource {
            snapshot = document
        } else {
            snapshot = await selectedDocument(from: try await loadActiveDocument())
        }
        let preparation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let response = try LocalETFLookThrough.make(document: snapshot, basis: basis)
            try Task.checkCancellation()
            return response
        }
        return try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }

    func selectAllAccounts() async {
        await updateAccountSelection(Set(accounts.map(\.id)), selectsAll: true)
    }

    func toggleAccount(_ accountID: String) async {
        // Read the latest requested keys: a second tap can arrive before the
        // first selection has finished publishing its new presentation.
        var next = requestedAccountKeysFromDisplayedAccounts()
        if next.contains(accountID) {
            guard next.count > 1 else { return }
            next.remove(accountID)
        } else {
            next.insert(accountID)
        }
        await updateAccountSelection(next, selectsAll: false)
    }

    func transactions(for accountID: String) async throws -> [LocalTransactionRecord] {
        let loaded = try await loadActiveDocument()
        return (loaded.transactions ?? [])
            .filter { $0.accountKey == accountID }
            .sorted {
                if $0.date == $1.date { return $0.id < $1.id }
                return $0.date > $1.date
            }
    }

    func activityLedger() async throws -> PortfolioActivityLedger {
        let loaded = try await loadActiveDocument()
        // Off the main actor: sorting a long history there held up the push
        // of the page that asked for it.
        return await Task.detached(priority: .userInitiated) {
            let names = loaded.positions.reduce(into: [String: String]()) { result, position in
                let key = position.ticker.uppercased()
                if result[key] == nil || result[key] == key {
                    result[key] = position.name.isEmpty ? key : position.name
                }
            }
            return PortfolioActivityLedger(
                accounts: loaded.accounts,
                transactions: (loaded.transactions ?? []).sorted { lhs, rhs in
                    if lhs.date == rhs.date {
                        return (lhs.tradeID ?? lhs.ticker) > (rhs.tradeID ?? rhs.ticker)
                    }
                    return lhs.date > rhs.date
                },
                securityNames: names
            )
        }.value
    }

    /// Creates the account up front so a broker connection is visible and
    /// editable while its first report is still being generated.
    func registerPendingAccount(
        id: String, source: String, name: String, baseCurrency: String
    ) async throws {
        let saved = try await LocalPortfolioStore.shared.registerAccount(
            PortfolioAccount(
                id: id, accountID: nil, source: source, name: name,
                baseCurrency: baseCurrency, positionCount: 0, transactionCount: 0,
                manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0
            )
        )
        try await apply(activeDocument(from: saved))
    }

    func renameAccount(_ accountID: String, to name: String) async throws {
        guard !isFakeDataMode && !isPublicInvestorMode else { return }
        _ = try await LocalPortfolioStore.shared.renameAccount(accountID, to: name)
        await refreshPortfolio()
    }

    /// Stores which Trading 212 product an account is. The API never reports
    /// it, so this is the only source for the account detail's type row.
    func setTrading212AccountType(_ accountType: Trading212AccountType, for accountKey: String) async throws {
        guard !isFakeDataMode && !isPublicInvestorMode else { return }
        _ = try await LocalPortfolioStore.shared.setAccountTypeOverride(accountType.rawValue, for: accountKey)
        await refreshPortfolio()
    }

    func addHistoricalTransaction(
        to account: PortfolioAccount,
        date: Date,
        action: String,
        ticker: String,
        quantity: Double,
        price: Double,
        currency: String
    ) async throws {
        guard !isFakeDataMode && !isPublicInvestorMode else { return }
        let transaction = LocalTransactionRecord(
            date: DayDateCodec.string(from: date),
            action: action.uppercased(),
            ticker: ticker.uppercased(),
            quantity: quantity,
            price: price,
            currency: currency.uppercased(),
            source: account.source,
            accountID: account.accountID,
            accountName: account.name,
            entryMethod: "manual"
        )
        _ = try await LocalPortfolioStore.shared.appendHistoricalTransaction(transaction)
        await refreshPortfolio()
        await refreshReturnsPage()
    }

    func deduplicateTransactions(for accountID: String) async throws -> Int {
        guard !isFakeDataMode && !isPublicInvestorMode else { return 0 }
        let (_, removed) = try await LocalPortfolioStore.shared.deduplicateTransactions(for: accountID)
        if removed > 0 {
            await refreshPortfolio()
            await refreshReturnsPage()
        }
        return removed
    }

    func deleteAccount(_ accountID: String) async throws {
        guard !isFakeDataMode && !isPublicInvestorMode else { return }
        invalidateInFlightRequests()
        _ = try await LocalPortfolioStore.shared.removeAccount(accountID)
        await presentationCache.removePersonal()
        sourcePresentations.removeValue(forKey: .personal)
        await refreshPortfolio()
        if !accounts.isEmpty {
            await refreshReturnsPage()
        }
    }

    func resetLocalPortfolio() async throws {
        portfolioSourceGeneration &+= 1
        portfolioSourceTask?.cancel()
        portfolioSourceTask = nil
        invalidateInFlightRequests()
        returnsPageTask?.cancel()
        returnsPageRequestGeneration &+= 1
        let backup = try await personalDocumentResetter()
        await presentationCache.removePersonal()
        // The explicit reset action must not restore an old personal screen.
        // Shared public-data caches and built-in account snapshots stay intact.
        sourcePresentations.removeValue(forKey: .personal)
        holdingDetailContent = holdingDetailContent.filter { $0.key.source != .personal }
        holdingDetailContentOrder.removeAll { $0.source == .personal }
        presentedSource = nil
        isFakeDataMode = false
        modeDefaults.set(false, forKey: Self.fakeDataModeKey)
        modeDefaults.removeObject(forKey: Self.selectedAccountsKey)
        modeDefaults.removeObject(forKey: Self.selectsAllAccountsKey)
        document = .empty
        updateRealisedProfit(from: document)
        fullDocument = .empty
        overview = nil
        portfolioChart = nil
        isPortfolioChartLoading = false
        holdings = []
        accounts = []
        selectedAccountKeys = []
        holdingDailyChanges = [:]
        holdingDailyChangesSignature = ""
        comparison = nil
        returnsAnalytics = nil
        comparisonWarning = nil
        analyticsWarning = nil
        portfolioFailure = nil
        returnsError = nil
        localSource = "尚未导入"
        localUpdatedAt = nil
        portfolioCachedAt = nil
        portfolioChartRevision &+= 1
        comparisonRevision &+= 1
        returnsAnalyticsRevision &+= 1
        portfolioRecoveryNotice = backup.map {
            L10n.text("本机组合已重置，原数据备份为 \($0.lastPathComponent)。券商授权和 AI 对话已保留。")
        } ?? L10n.text("本机组合已重置。券商授权和 AI 对话已保留。")
    }

    func suggestedAccountNickname(detectedName: String? = nil) -> String {
        if let detectedName {
            let detected = detectedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detected.isEmpty { return detected }
        }
        return Self.nextGeneratedNickname(usedNames: Set(accounts.map(\.displayName)))
    }

    func accountNames(
        source: String,
        accountIDs: [String],
        preferredNickname: String,
        targetAccountID: String? = nil
    ) -> [String: String] {
        let provider = AccountNaming.providerName(for: source)
        let existing = Dictionary(uniqueKeysWithValues: accounts
            .filter { $0.source == source }
            .compactMap { account in account.accountID.map { ($0, account.name) } })
        var usedNames = Set(accounts.map(\.displayName))
        var result: [String: String] = [:]
        var usedPreferredNickname = false

        for accountID in Array(Set(accountIDs)).sorted() {
            if accountID != targetAccountID, let existingName = existing[accountID] {
                result[accountID] = existingName
                usedNames.insert(existingName)
                continue
            }
            let nickname: String
            if !usedPreferredNickname,
               !preferredNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nickname = preferredNickname
                usedPreferredNickname = true
            } else {
                nickname = Self.nextGeneratedNickname(usedNames: usedNames)
            }
            let displayName = AccountNaming.displayName(provider: provider, nickname: nickname)
            result[accountID] = displayName
            usedNames.insert(displayName)
        }
        return result
    }

    func importCSV(
        _ data: Data,
        filename _: String,
        accountID: String? = nil,
        accountName: String? = nil,
        source: String = "CSV",
        replacingAccountsOnly: Bool = false
    ) async throws -> CSVImportResult {
        let isins = LocalCSVImporter.isinRequests(in: data)
        let resolved = isins.isEmpty ? [:] : await SecurityIdentityResolver.shared.tickers(forISINs: isins)
        let (positions, transactions, result) = try await Task.detached(priority: .userInitiated) {
            try LocalCSVImporter.parse(data, resolvedISINs: resolved)
        }.value
        let namedPositions: [LocalPositionRecord]
        let namedTransactions: [LocalTransactionRecord]
        if let accountName {
            namedPositions = positions.map { $0.assignedAccount(id: accountID, name: accountName, source: source) }
            namedTransactions = transactions.map { $0.assignedAccount(id: accountID, name: accountName, source: source) }
        } else {
            namedPositions = positions
            namedTransactions = transactions
        }
        invalidateInFlightRequests()
        let generation = portfolioRequestGeneration
        let saved = try await LocalPortfolioStore.shared.replace(
            positions: namedPositions,
            source: source,
            transactions: namedTransactions,
            replacingAccountsOnly: replacingAccountsOnly
        )
        try await apply(activeDocument(from: saved))
        await enrichPortfolioChart(from: document, generation: generation)
        return result
    }

    func importTrading212(
        _ snapshot: Trading212Snapshot,
        accountNames: [String: String] = [:],
        accountTypeOverrides: [String: String] = [:],
        replacingAccountsOnly: Bool = false
    ) async throws -> CSVImportResult {
        var warnings: [String] = []
        // Trading 212 never reports whether an account is an ISA. A sync that
        // does not carry a freshly chosen type must keep the stored one, since
        // nothing else on the device knows it.
        let storedTypes = Dictionary(
            accounts.filter { $0.source == "Trading 212" }
                .compactMap { account in
                    account.accountID.flatMap { id in account.accountTypeOverride.map { (id, $0) } }
                },
            uniquingKeysWith: { _, last in last }
        )
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.quantity > 0 else { return nil }
            guard let average = position.averagePricePaid, average > 0 else {
                warnings.append(L10n.text("\(position.rawTicker) 缺少平均成本，已跳过"))
                return nil
            }
            return LocalPositionRecord(
                ticker: position.ticker, name: position.name, shares: position.quantity,
                averageCost: average, currency: position.currency,
                quotePrice: position.currentPrice ?? average, quoteCurrency: position.currency,
                source: "Trading 212",
                openedDate: position.createdAt.map { String($0.prefix(10)) },
                accountID: "account-\(position.accountSlot)",
                accountName: accountNames["account-\(position.accountSlot)"]
                    ?? L10n.text("账户 \(position.accountSlot)"),
                accountCurrency: position.accountCurrency ?? "GBP",
                brokerPnl: position.ppl,
                brokerPnlCurrency: position.ppl == nil ? nil : (position.accountCurrency ?? "GBP"),
                // Trading 212 returns fxPpl in the account currency. Keep the
                // broker value even if currency discovery used its desktop-
                // compatible fallback; dropping it here made iOS show “暂无”.
                brokerFxPnl: position.fxPpl,
                brokerFxPnlCurrency: position.fxPpl == nil ? nil : (position.accountCurrency ?? "GBP"),
                fxPnl: position.fxPpl,
                fxPnlCurrency: position.fxPpl == nil ? nil : (position.accountCurrency ?? "GBP"),
                fxPnlStatus: position.fxPpl == nil ? nil : "broker_reported",
                fxPnlSource: position.fxPpl == nil ? nil : "trading212_wallet_impact"
            )
        }
        if !snapshot.hasCompleteTransactionHistory {
            warnings.append(
                snapshot.transactionHistoryStatus
                    ?? L10n.text("成交历史正在分页同步，稍后再次同步会继续补全。")
            )
        }
        let transactions = snapshot.transactions.map { transaction in
            LocalTransactionRecord(
                date: transaction.date,
                action: transaction.action,
                ticker: transaction.ticker,
                quantity: transaction.quantity,
                price: transaction.price,
                currency: transaction.currency,
                source: "Trading 212",
                accountID: "account-\(transaction.accountSlot)",
                accountName: accountNames["account-\(transaction.accountSlot)"]
                    ?? L10n.text("账户 \(transaction.accountSlot)"),
                tradeID: transaction.reference,
                brokerFXRate: transaction.brokerFXRate,
                realisedProfitLoss: transaction.realisedProfitLoss,
                realisedProfitLossCurrency: transaction.realisedProfitLossCurrency,
                executedAt: transaction.executedAt
            )
        }
        let enriched = await LocalFXImpactCalculator().enrich(
            positions: positions,
            transactions: transactions
        )
        let unavailableFXCount = enriched.filter { $0.fxPnlStatus == "unavailable" }.count
        if unavailableFXCount > 0 {
            warnings.append(L10n.text("\(unavailableFXCount) 项持仓缺少完整历史数据，汇率影响标记为不可算"))
        }
        let result = try await replace(
            enriched,
            source: "Trading 212",
            warnings: warnings,
            transactions: snapshot.hasCompleteTransactionHistory ? transactions : nil,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: snapshot.syncedAccounts.map { account in
                let accountTypeOverride = account.accountID.flatMap { id in
                    accountTypeOverrides[id] ?? storedTypes[id]
                }
                return PortfolioAccount(
                    id: account.id, accountID: account.accountID, source: account.source,
                    name: account.accountID.flatMap { accountNames[$0] } ?? account.name,
                    baseCurrency: account.baseCurrency, positionCount: account.positionCount,
                    transactionCount: account.transactionCount,
                    manualTransactionCount: account.manualTransactionCount,
                    hasCSVImport: account.hasCSVImport, marketValueUSD: account.marketValueUSD,
                    accountTypeOverride: accountTypeOverride
                )
            }
        )
        if !snapshot.hasCompleteTransactionHistory, !transactions.isEmpty {
            invalidateInFlightRequests()
            let generation = portfolioRequestGeneration
            let merged = try await LocalPortfolioStore.shared.mergeTransactions(transactions)
            try await apply(activeDocument(from: merged))
            await enrichPortfolioChart(from: document, generation: generation)
        }
        return result
    }

    func importMoomoo(
        _ snapshot: MoomooSnapshot,
        accountNames preferredAccountNames: [String: String] = [:],
        replacingAccountsOnly: Bool = false
    ) async throws -> CSVImportResult {
        var warnings = snapshot.historyWarnings
        let accountNames = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { account in
            let visibleID = account.accountCardNumber.isEmpty ? account.accountID : account.accountCardNumber
            return (
                account.accountID,
                preferredAccountNames[account.accountID]
                    ?? Self.maskedAccountName(provider: "Moomoo", accountID: visibleID)
            )
        })
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.positionSide.uppercased() != "SHORT", position.quantityValue > 0 else { return nil }
            guard let average = position.costPriceValue, average > 0 else {
                warnings.append(L10n.text("\(position.code) 缺少有效成本价，已跳过"))
                return nil
            }
            return LocalPositionRecord(
                ticker: Self.moomooTicker(position.code), name: position.stockName,
                shares: position.quantityValue, averageCost: average,
                currency: position.currency.uppercased(), quotePrice: position.nominalPriceValue ?? average,
                quoteCurrency: position.currency.uppercased(), source: "Moomoo",
                openedDate: nil,
                accountID: position.accountID,
                accountName: accountNames[position.accountID] ?? Self.maskedAccountName(provider: "Moomoo", accountID: position.accountID),
                accountCurrency: snapshot.accountCurrencies[position.accountID]
            )
        }
        let positionCurrencies = snapshot.positions.reduce(into: [String: String]()) { result, position in
            result["\(position.accountID)|\(position.code.uppercased())"] = position.currency.uppercased()
        }
        let transactions = snapshot.fills.compactMap { fill -> LocalTransactionRecord? in
            guard fill.quantity > 0, fill.price > 0, !fill.date.isEmpty else { return nil }
            let side = fill.side.uppercased()
            let action: String
            if ["BUY", "BUY_BACK"].contains(side) {
                action = "BUY"
            } else if ["SELL", "SELL_SHORT"].contains(side) {
                action = "SELL"
            } else {
                return nil
            }
            guard let currency = positionCurrencies["\(fill.accountID)|\(fill.code.uppercased())"]
                    ?? fill.quoteCurrency else {
                warnings.append(L10n.text("\(fill.code) 缺少可核实的成交币种，已保留原有历史。"))
                return nil
            }
            return LocalTransactionRecord(
                date: fill.date,
                action: action,
                ticker: Self.moomooTicker(fill.code),
                quantity: fill.quantity,
                price: fill.price,
                currency: currency,
                source: "Moomoo",
                accountID: fill.accountID,
                accountName: accountNames[fill.accountID],
                tradeID: fill.tradeID,
                executedAt: ISO8601DateFormatter().string(from: Date(
                    timeIntervalSince1970: TimeInterval(fill.executedAtMicroseconds) / 1_000_000))
            )
        }
        let enriched = await LocalFXImpactCalculator().enrich(
            positions: positions,
            transactions: transactions
        )
        let unavailableFXCount = enriched.filter { $0.fxPnlStatus == "unavailable" }.count
        if unavailableFXCount > 0 {
            warnings.append(L10n.text("\(unavailableFXCount) 项持仓缺少完整历史数据，汇率影响标记为不可算"))
        }
        return try await replace(
            enriched,
            source: "Moomoo",
            warnings: warnings,
            transactions: transactions,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: snapshot.accounts.map { account in
                PortfolioAccount(
                    id: "Moomoo|\(account.accountID)", accountID: account.accountID, source: "Moomoo",
                    name: accountNames[account.accountID] ?? account.accountCardNumber,
                    baseCurrency: snapshot.accountCurrencies[account.accountID] ?? "USD",
                    positionCount: 0, transactionCount: 0, manualTransactionCount: 0,
                    hasCSVImport: false, marketValueUSD: 0
                )
            },
            mergesTransactionHistory: true
        )
    }

    func importRobinhood(
        _ snapshot: RobinhoodAccountSnapshot,
        context: AccountConnectorContext,
        nickname: String
    ) async throws -> CSVImportResult {
        guard !isFakeDataMode && !isPublicInvestorMode else { throw RobinhoodAccountError.unsupported }
        guard await RobinhoodMCPClient.shared.connectionGeneration() == snapshot.connectionGeneration,
              await RobinhoodMCPClient.shared.isConnected() else { throw RobinhoodAccountError.disconnected }
        try Task.checkCancellation()
        try snapshot.validate(context: context, existing: accounts)
        let name = context.account?.name ?? AccountNaming.displayName(provider: "Robinhood", nickname: nickname)
        return try await replace(
            snapshot.positions.map { $0.renamedAccount(to: name) },
            source: "Robinhood", warnings: [], replacingAccountsOnly: true,
            syncedAccounts: [snapshot.portfolioAccount(name: name)]
        )
    }

    func importSnapTrade(
        _ snapshot: SnapTradeSnapshot,
        context: AccountConnectorContext,
        nickname: String
    ) async throws -> CSVImportResult {
        guard !isFakeDataMode && !isPublicInvestorMode else { throw SnapTradeError.accountUnavailable }
        try snapshot.validate(context: context, existing: accounts)
        let name = context.account?.name ?? AccountNaming.displayName(provider: "SnapTrade", nickname: nickname)
        return try await replace(
            snapshot.positions.map { $0.renamedAccount(to: name) },
            source: "SnapTrade", warnings: [], replacingAccountsOnly: true,
            syncedAccounts: [snapshot.portfolioAccount(name: name)]
        )
    }

    func importIBKR(
        _ snapshot: IBKRFlexSnapshot,
        accountNames: [String: String] = [:],
        replacingAccountsOnly: Bool = false
    ) async throws -> CSVImportResult {
        var warnings: [String] = []
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.quantity > 0 else { return nil }
            let category = position.assetCategory.uppercased()
            guard category.isEmpty || category == "STK" else {
                warnings.append(L10n.text("已跳过不受支持的 \(category) 持仓 \(position.symbol)"))
                return nil
            }
            guard let average = position.averageCost, average > 0 else {
                warnings.append(L10n.text("\(position.symbol) 缺少平均成本，已跳过"))
                return nil
            }
            let currency = position.currency.isEmpty ? "USD" : position.currency.uppercased()
            let quote = position.markPrice ?? position.marketValue.map { $0 / position.quantity } ?? average
            return LocalPositionRecord(
                ticker: position.symbol.uppercased(), name: position.name, shares: position.quantity,
                averageCost: average, currency: currency, quotePrice: quote,
                quoteCurrency: currency, source: "IBKR Flex",
                openedDate: position.openDate,
                accountID: position.accountID,
                accountName: accountNames[position.accountID] ?? "IBKR · Individual",
                accountCurrency: snapshot.accountCurrencies[position.accountID],
                quoteObservedAt: snapshot.quoteObservedAt
            )
        }
        let transactions = snapshot.transactions.map { transaction in
            LocalTransactionRecord(
                date: transaction.tradeDate,
                action: transaction.side,
                ticker: transaction.symbol,
                quantity: transaction.quantity,
                price: transaction.price,
                currency: transaction.currency,
                source: "IBKR Flex",
                accountID: transaction.accountID,
                accountName: accountNames[transaction.accountID] ?? "IBKR · Individual",
                tradeID: transaction.tradeID,
                brokerFXRate: transaction.fxRateToBase,
                realisedProfitLoss: transaction.side.uppercased() == "SELL"
                    ? transaction.realisedProfitLoss
                    : nil,
                realisedProfitLossCurrency: transaction.realisedProfitLoss == nil
                    ? nil
                    : transaction.currency
            )
        }
        if snapshot.accountCurrencies.isEmpty {
            warnings.append(L10n.text("Flex Query 缺少 Account Information → Base Currency，汇率影响暂不可计算"))
        }
        if transactions.isEmpty {
            warnings.append(L10n.text("Flex Query 缺少 Trades → Executions；无建仓日时汇率影响将标记为不可算"))
        }
        let enriched = await LocalFXImpactCalculator().enrich(
            positions: positions,
            transactions: transactions
        )
        let unavailableFXCount = enriched.filter { $0.fxPnlStatus == "unavailable" }.count
        if unavailableFXCount > 0 {
            warnings.append(L10n.text("\(unavailableFXCount) 项持仓缺少完整历史数据，汇率影响标记为不可算"))
        }
        return try await replace(
            enriched,
            source: "IBKR Flex",
            warnings: warnings,
            transactions: transactions,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: snapshot.syncedPositionAccountIDs.sorted().map { id in
                PortfolioAccount(
                    id: "IBKR Flex|\(id)", accountID: id, source: "IBKR Flex",
                    name: accountNames[id] ?? snapshot.accountNames[id]
                        ?? Self.maskedAccountName(provider: "IBKR", accountID: id),
                    baseCurrency: snapshot.accountCurrencies[id] ?? "USD",
                    positionCount: 0, transactionCount: 0, manualTransactionCount: 0,
                    hasCSVImport: false, marketValueUSD: 0
                )
            },
            mergesTransactionHistory: true
        )
    }

    private func replace(
        _ rawPositions: [LocalPositionRecord],
        source: String,
        warnings: [String],
        transactions: [LocalTransactionRecord]? = nil,
        replacingAccountsOnly: Bool = false,
        syncedAccounts: [PortfolioAccount] = [],
        mergesTransactionHistory: Bool = false
    ) async throws -> CSVImportResult {
        invalidateInFlightRequests()
        let generation = portfolioRequestGeneration
        let positions = Self.merge(rawPositions)
        let saved = try await LocalPortfolioStore.shared.replace(
            positions: positions,
            source: source,
            transactions: transactions,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: syncedAccounts,
            mergesTransactionHistory: mergesTransactionHistory
        )
        try await apply(activeDocument(from: saved))
        await enrichPortfolioChart(from: document, generation: generation)
        return CSVImportResult(
            ok: true, holdingsCount: positions.count, transactionsCount: nil,
            backupCreated: false, warnings: warnings,
            holdings: positions.map {
                CSVImportedHolding(ticker: $0.ticker, name: $0.name, shares: $0.shares, averageCost: $0.averageCost, currency: $0.currency)
            }
        )
    }

    /// Adds up the broker's results on sales, each converted from the currency
    /// it was reported in. Never estimated: a sale without a result counts as
    /// a gap, not as zero.
    private func updateRealisedProfit(from scoped: LocalPortfolioDocument) {
        let summary = LocalBrokerResultSummary(transactions: scoped.transactions ?? [])
        realisedProfitGaps = summary.missingCount
        realisedProfit = summary.usdTotal() ?? .nan
    }

    private struct PreparedAccountScope {
        let accounts: [PortfolioAccount]
        let keys: Set<String>
        let document: LocalPortfolioDocument
        let realisedProfit: Double
        let realisedProfitGaps: Int
    }

    /// Account discovery groups the entire transaction ledger. Prepare it and
    /// the selected document together, away from the actor that handles taps.
    private func prepareAccountScope(for loaded: LocalPortfolioDocument) async -> PreparedAccountScope {
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

    private func apply(_ loaded: LocalPortfolioDocument, invalidatesDailyChanges: Bool = true,
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
        selectedAccountKeys = accountKeys
        overview = presentation.0
        if !preservesChart {
            portfolioCachedAt = nil
            portfolioChart = cachedChart ?? presentation.1
            if localSelectionOnly, portfolioChart?.currentPoint.marketValue.isFinite != true {
                // Account NAV needs historical cash flows. Without that cache,
                // show the locally known holdings value/cost under their own basis.
                portfolioChart = PortfolioChartResponse(
                    positionCount: presentation.2.count,
                    positionHistory: PositionHistory(available: false, rows: []),
                    currentPoint: ChartPoint(dateText: DayDateCodec.string(from: Date()),
                        marketValue: presentation.0.summary.marketValue, cost: presentation.0.summary.totalCost),
                    warning: L10n.text("历史行情缓存不完整，当前显示所选账户的持仓市值与成本。"))
            }
            isPortfolioChartLoading = cachedChart == nil
                && !localSelectionOnly
                && !isFakeDataMode
                && !isPublicInvestorMode
                && (!scoped.positions.isEmpty || !(scoped.transactions ?? []).isEmpty)
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
        isFakeDataMode = demo
        isPublicInvestorMode = investor
        publicInvestorSelection = normalized
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

    private struct SourcePresentation {
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
        selectedAccountKeys = cached.accountKeys
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
        selectedAccountKeys = []
        holdingDailyChanges = [:]
        localUpdatedAt = nil
        portfolioCachedAt = nil
        localSource = "尚未导入"
        portfolioChartRevision &+= 1
        comparisonRevision &+= 1
        returnsAnalyticsRevision &+= 1
    }

    private var hasUsableHomeChart: Bool {
        presentedSource == portfolioSource && portfolioChart?.currentPoint.marketValue.isFinite == true
    }

    private func homeCacheContext(accountKeys: Set<String>) -> PortfolioPresentationCache.Context {
        .init(source: portfolioSource, accountKeys: accountKeys, language: ContentLanguage.current)
    }

    private func canPreserveHomeChart(for loaded: LocalPortfolioDocument, accountKeys: Set<String>) async -> Bool {
        guard hasUsableHomeChart, selectedAccountKeys == accountKeys else { return false }
        return await presentationCache.sameLedger(fullDocument, loaded)
    }

    private func restoreHomePresentation(
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

    private func loadActiveDocument() async throws -> LocalPortfolioDocument {
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

    private func activeDocument(from loaded: LocalPortfolioDocument) -> LocalPortfolioDocument {
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
    private func requestedAccountKeysFromDisplayedAccounts() -> Set<String> {
        let availableKeys = Set(accounts.map(\.id))
        let savedKeys = Self.savedAccountKeys(forKey: selectedAccountsStorageKey, defaults: modeDefaults)
            .intersection(availableKeys)
        let selectsAll = modeDefaults.bool(forKey: selectsAllAccountsStorageKey)
        return selectsAll || savedKeys.isEmpty ? availableKeys : savedKeys
    }

    private func selectedDocument(from loaded: LocalPortfolioDocument) async -> LocalPortfolioDocument {
        let prepared = await prepareAccountScope(for: loaded)
        return prepared.document
    }

    private func updateAccountSelection(_ keys: Set<String>, selectsAll: Bool) async {
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

    private static func maskedAccountName(provider: String, accountID: String) -> String {
        let suffix = String(accountID.suffix(4))
        return suffix.isEmpty ? provider : "\(provider) · •••• \(suffix)"
    }

    private static func nextGeneratedNickname(usedNames: Set<String>) -> String {
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

    private func refreshHistoricalChart(
        from loaded: LocalPortfolioDocument, generation: Int, forceRefresh: Bool = true
    ) async {
        guard !isFakeDataMode else { return }
        // A new/invalid result cache should still try existing price history
        // locally before entering the slow provider refresh/fallback pipeline.
        if !hasUsableHomeChart,
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

    private func enrichPortfolioChart(
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
            portfolioChart = enriched
            if enriched.currentPoint.marketValue.isFinite { portfolioCachedAt = nil }
            portfolioChartRevision &+= 1
            await saveHomePresentation(generation: generation)
        }
    }

    private func invalidateInFlightRequests() {
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

    /// Which tickers the daily changes were read for — nothing else.
    ///
    /// A day's change belongs to the ticker, not to the latest quote or the
    /// size of the position. Keying on price and market value meant the quote
    /// update that follows every home refresh left the signature stale, so
    /// opening the heatmap fetched every change again (with its spinner) that
    /// the home list was already showing. A real refresh still resets this
    /// signature and reads the changes afresh.
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

    private static func dailyChangesSignature(for holdings: [Holding]) -> String {
        Set(holdings.map { $0.ticker.uppercased() })
            .sorted()
            .joined(separator: "|")
    }

    private static func merge(_ positions: [LocalPositionRecord]) -> [LocalPositionRecord] {
        var grouped: [String: LocalPositionRecord] = [:]
        for position in positions {
            let key = "\(position.accountKey)|\(position.ticker.uppercased())"
            guard let existing = grouped[key], existing.currency == position.currency,
                  existing.quoteCurrency == position.quoteCurrency else {
                grouped[key] = position
                continue
            }
            let shares = existing.shares + position.shares
            guard shares > 0 else { continue }
            grouped[key] = LocalPositionRecord(
                ticker: position.ticker.uppercased(), name: existing.name.isEmpty ? position.name : existing.name, shares: shares,
                averageCost: (existing.averageCost * existing.shares + position.averageCost * position.shares) / shares,
                currency: existing.currency,
                quotePrice: (existing.quotePrice * existing.shares + position.quotePrice * position.shares) / shares,
                quoteCurrency: existing.quoteCurrency, source: existing.source,
                openedDate: [existing.openedDate, position.openedDate].compactMap { $0 }.min(),
                accountID: existing.accountID,
                accountName: existing.accountName,
                accountCurrency: existing.accountCurrency == position.accountCurrency
                    ? existing.accountCurrency
                    : nil,
                brokerPnl: existing.brokerPnlCurrency == position.brokerPnlCurrency
                    ? Self.combinedOptional(existing.brokerPnl, position.brokerPnl)
                    : nil,
                brokerPnlCurrency: existing.brokerPnlCurrency == position.brokerPnlCurrency
                    ? existing.brokerPnlCurrency
                    : nil,
                brokerFxPnl: existing.brokerFxPnlCurrency == position.brokerFxPnlCurrency
                    ? Self.combinedOptional(existing.brokerFxPnl, position.brokerFxPnl)
                    : nil,
                brokerFxPnlCurrency: existing.brokerFxPnlCurrency == position.brokerFxPnlCurrency
                    ? existing.brokerFxPnlCurrency
                    : nil,
                fxPnl: existing.fxPnlCurrency == position.fxPnlCurrency
                    ? Self.combinedOptional(existing.fxPnl, position.fxPnl)
                    : nil,
                fxPnlCurrency: existing.fxPnlCurrency == position.fxPnlCurrency ? existing.fxPnlCurrency : nil,
                fxPnlStatus: existing.fxPnlStatus == position.fxPnlStatus
                    ? existing.fxPnlStatus
                    : "mixed",
                fxPnlSource: existing.fxPnlSource == position.fxPnlSource
                    ? existing.fxPnlSource
                    : [existing.fxPnlSource, position.fxPnlSource].compactMap { $0 }.sorted().joined(separator: " + ")
            )
        }
        return grouped.values.sorted { $0.ticker < $1.ticker }
    }

    private static func combinedOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }

    private static func moomooTicker(_ value: String) -> String {
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return value.uppercased() }
        let market = parts[0].uppercased()
        var code = parts[1].uppercased()
        if ["HK", "SEHK"].contains(market), code.count == 5, code.first == "0" { code.removeFirst() }
        let suffixes = [
            "US": "", "NASDAQ": "", "NYSE": "", "AMEX": "", "ARCA": "",
            "HK": ".HK", "SEHK": ".HK", "SG": ".SI", "SGX": ".SI",
            "JP": ".T", "JA": ".T", "TSE": ".T", "AU": ".AX", "ASX": ".AX",
            "CA": ".TO", "TSX": ".TO", "SH": ".SS", "SZ": ".SZ", "BMS": ".KL",
        ]
        return suffixes[market].map { code + $0 } ?? value.uppercased()
    }
}
