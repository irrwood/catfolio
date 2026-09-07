import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    var overview: PortfolioOverview?
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
    var portfolioError: String?
    var returnsError: String?
    private var comparisonWarning: String?
    private var analyticsWarning: String?
    var activeBroker: BrokerProvider?
    var localSource = "尚未导入"
    var localUpdatedAt: Date?
    var accounts: [PortfolioAccount] = []
    var selectedAccountKeys: Set<String> = []
    private(set) var portfolioChartRevision = 0
    private(set) var comparisonRevision = 0
    private(set) var returnsAnalyticsRevision = 0
    private(set) var isFakeDataMode = UserDefaults.standard.bool(forKey: "catfolio.fakeDataMode")
    var fakeDataModeError: String?
    var portfolioRecoveryNotice: String?

    var returnsWarning: String? {
        let values = [comparisonWarning, analyticsWarning]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    @ObservationIgnored private var document = LocalPortfolioDocument.empty
    @ObservationIgnored private var portfolioRequestGeneration = 0
    @ObservationIgnored private var returnsRequestGeneration = 0
    @ObservationIgnored private var returnsAnalyticsRequestGeneration = 0
    @ObservationIgnored private var returnsPageRequestGeneration = 0
    @ObservationIgnored private var dailyChangesRequestGeneration = 0
    @ObservationIgnored private var holdingDailyChangesSignature = ""
    @ObservationIgnored private var returnsPageTask: Task<Void, Never>?
    private static let brokerKey = "catfolio.activeBroker"
    private static let selectedAccountsKey = "catfolio.selectedAccounts"
    private static let selectsAllAccountsKey = "catfolio.selectsAllAccounts"
    private static let fakeDataModeKey = "catfolio.fakeDataMode"
    private static let fakeSelectedAccountsKey = "catfolio.fakeDataSelectedAccounts"
    private static let fakeSelectsAllAccountsKey = "catfolio.fakeDataSelectsAllAccounts"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.brokerKey) {
            activeBroker = BrokerProvider(rawValue: raw)
        }
    }

    func refreshPortfolio() async {
        portfolioRequestGeneration &+= 1
        let generation = portfolioRequestGeneration
        isPortfolioLoading = true
        portfolioError = nil
        defer {
            if generation == portfolioRequestGeneration {
                isPortfolioLoading = false
            }
        }
        do {
            var loaded = try await loadActiveDocument()
            guard generation == portfolioRequestGeneration else { return }
            // Publish disk data before any network work. Slow/offline quote
            // providers must never hold the entire home screen in a skeleton.
            try await apply(loaded)
            if !isFakeDataMode {
                loaded = try await mergeCachedTrading212History(into: loaded)
                guard generation == portfolioRequestGeneration else { return }
                try await apply(loaded)
            }
            guard !loaded.positions.isEmpty else {
                isHoldingDailyChangesLoading = false
                return
            }
            async let dailyRefresh: Void = refreshHoldingDailyChanges()
            if !isFakeDataMode {
                async let fxRefresh: Void = LocalCurrentFXRefresh.shared.refresh()
                let quotes = await LocalMarketDataClient().latestQuotes(for: loaded.positions)
                await fxRefresh
                guard generation == portfolioRequestGeneration else { return }
                if !quotes.isEmpty {
                    loaded = try await LocalPortfolioStore.shared.updateMarketQuotes(quotes)
                }
            }
            await dailyRefresh
            guard generation == portfolioRequestGeneration else { return }
            try await apply(loaded, invalidatesDailyChanges: false)
            // Historical chart enrichment is independent of the already
            // published positions and daily contributions.
            await enrichPortfolioChart(from: document, generation: generation)
        } catch {
            guard generation == portfolioRequestGeneration else { return }
            // Retain the last usable local presentation on refresh failure.
            // An error is not an empty account and must not erase its bars.
            isHoldingDailyChangesLoading = false
            portfolioError = error.localizedDescription
        }
    }

    private func mergeCachedTrading212History(
        into loaded: LocalPortfolioDocument
    ) async throws -> LocalPortfolioDocument {
        let slots = Set(loaded.accounts.compactMap { account -> Int? in
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
        for account in loaded.accounts where account.source == "Trading 212" {
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
            let scoped = selectedDocument(from: loaded)
            document = scoped
            do {
                let enriched = try await LocalMarketDataClient().comparison(document: scoped)
                guard generation == returnsRequestGeneration else { return }
                comparison = enriched
                comparisonRevision &+= 1
                comparisonWarning = enriched.warnings?.joined(separator: "\n")
            } catch {
                guard generation == returnsRequestGeneration else { return }
                let localFallback = try await Task.detached(priority: .userInitiated) {
                    try LocalPortfolioEngine.comparison(for: scoped)
                }.value
                guard generation == returnsRequestGeneration else { return }
                comparison = localFallback
                comparisonRevision &+= 1
                comparisonWarning = (["历史行情读取失败：\(error.localizedDescription)"]
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
        returnsPageRequestGeneration &+= 1
        let generation = returnsPageRequestGeneration

        if let previous = returnsPageTask {
            previous.cancel()
            await previous.value
            guard generation == returnsPageRequestGeneration else { return }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.analyticsWarning = nil
            await self.refreshReturns()
            guard !Task.isCancelled, self.returnsError == nil else { return }
            await self.refreshReturnsAnalytics()
        }
        returnsPageTask = task
        await task.value
        if generation == returnsPageRequestGeneration {
            returnsPageTask = nil
        }
    }

    private func refreshReturnsAnalytics() async {
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
            let scoped = selectedDocument(from: loaded)
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
            analyticsWarning = "分析图表读取失败：\(error.localizedDescription)"
            returnsAnalyticsRevision &+= 1
        }
    }

    func volumeProfile(for ticker: String) async throws -> VolumeProfile {
        let holding = holdings.first(where: { $0.ticker == ticker })
        return try await LocalMarketDataClient().volumeProfile(
            ticker: ticker,
            currency: holding?.quoteCurrency ?? "USD",
            referencePrice: holding?.quotePrice
        )
    }

    func securityPriceHistory(for ticker: String) async throws -> SecurityPriceHistory {
        let loaded = try await loadActiveDocument()
        let scoped = selectedDocument(from: loaded)
        let holding = holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
        return try await LocalMarketDataClient().securityPriceHistory(
            ticker: ticker,
            currency: holding?.quoteCurrency ?? "USD",
            referencePrice: holding?.quotePrice,
            document: scoped
        )
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
                    $0 + $1.shares * $1.quotePrice
                }
                let marketValueUSD = try positions.reduce(0.0) { partial, position in
                    partial + (try LocalPortfolioEngine.usd(
                        position.shares * position.quotePrice,
                        currency: position.quoteCurrency
                    ))
                }
                let account = accountsByID[accountKey]
                return HoldingDetailAccountOption(
                    id: accountKey,
                    displayName: account?.displayName
                        ?? positions.first?.resolvedAccountName
                        ?? "账户",
                    marketValue: marketValue,
                    currency: quoteCurrency,
                    marketValueUSD: marketValueUSD
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
        accountKeys: Set<String>
    ) async throws -> SecurityPriceHistory {
        let context = try await holdingDetailAccountContext(for: ticker)
        let scoped = context.document(for: accountKeys)
        let scopedHolding = context.holding(for: accountKeys)
        return try await LocalMarketDataClient().securityPriceHistory(
            ticker: ticker,
            currency: scopedHolding?.quoteCurrency ?? "USD",
            referencePrice: scopedHolding?.quotePrice,
            document: scoped
        )
    }

    func refreshHoldingDailyChanges() async {
        let snapshot = holdings
        guard !snapshot.isEmpty else {
            holdingDailyChanges = [:]
            benchmarkDailyChange = nil
            holdingDailyChangesSignature = ""
            isHoldingDailyChangesLoading = false
            return
        }

        let signature = Self.dailyChangesSignature(for: snapshot)
        guard signature != holdingDailyChangesSignature else { return }

        dailyChangesRequestGeneration &+= 1
        let generation = dailyChangesRequestGeneration
        let activeTickers = Set(snapshot.map { $0.ticker.uppercased() })
        var changes = holdingDailyChanges.filter { activeTickers.contains($0.key) && $0.value.isFinite }
        var holdingsNeedingFetch: [Holding] = []
        for holding in snapshot {
            let key = holding.ticker.uppercased()
            if let value = holding.todayChangePercent, value.isFinite {
                changes[key] = value
            } else {
                // Existing values remain visible while their replacements are
                // fetched. Imported broker positions normally have no inline
                // daily change, so clearing here caused TODAY to flash as zero.
                holdingsNeedingFetch.append(holding)
            }
        }
        holdingDailyChanges = changes

        isHoldingDailyChangesLoading = true
        defer {
            if generation == dailyChangesRequestGeneration {
                isHoldingDailyChangesLoading = false
            }
        }
        let client = LocalMarketDataClient()
        let fetchSnapshot = holdingsNeedingFetch
        async let fetchedChanges = client.dailyChanges(for: fetchSnapshot)
        async let fetchedBenchmark = client.dailyChange(ticker: "SPY")
        let (fetched, benchmark) = await (fetchedChanges, fetchedBenchmark)
        guard !Task.isCancelled,
              generation == dailyChangesRequestGeneration,
              signature == Self.dailyChangesSignature(for: holdings) else { return }

        changes.merge(fetched) { _, latest in latest }
        holdingDailyChanges = changes
        if let benchmark, benchmark.isFinite {
            benchmarkDailyChange = benchmark
        }
        holdingDailyChangesSignature = signature
    }

    func loadBriefing() async throws -> String {
        let loaded = try await loadActiveDocument()
        return try await LocalAIClient().briefing(document: selectedDocument(from: loaded))
    }

    func askAI(_ question: String, attentionContext: String? = nil) async throws -> String {
        let loaded = try await loadActiveDocument()
        return try await LocalAIClient().answer(
            question,
            document: selectedDocument(from: loaded),
            additionalContext: attentionContext
        )
    }

    func portfolioAttention() async throws -> PortfolioAttentionReport {
        let loaded = try await loadActiveDocument()
        return try await LocalAIClient().portfolioAttention(document: selectedDocument(from: loaded))
    }

    func selectBroker(_ provider: BrokerProvider) {
        activeBroker = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.brokerKey)
    }

    func loadETFLookThrough(basis: ETFLookThroughBasis) async throws -> ETFLookThroughResponse {
        let loaded = try await loadActiveDocument()
        return try LocalETFLookThrough.make(document: selectedDocument(from: loaded), basis: basis)
    }

    func selectAllAccounts() async {
        await updateAccountSelection(Set(accounts.map(\.id)), selectsAll: true)
    }

    func toggleAccount(_ accountID: String) async {
        var next = selectedAccountKeys
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
        guard !isFakeDataMode else { return }
        _ = try await LocalPortfolioStore.shared.renameAccount(accountID, to: name)
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
        guard !isFakeDataMode else { return }
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
        guard !isFakeDataMode else { return 0 }
        let (_, removed) = try await LocalPortfolioStore.shared.deduplicateTransactions(for: accountID)
        if removed > 0 {
            await refreshPortfolio()
            await refreshReturnsPage()
        }
        return removed
    }

    func deleteAccount(_ accountID: String) async throws {
        guard !isFakeDataMode else { return }
        _ = try await LocalPortfolioStore.shared.removeAccount(accountID)
        await refreshPortfolio()
        if !accounts.isEmpty {
            await refreshReturnsPage()
        }
    }

    func resetLocalPortfolio() async throws {
        invalidateInFlightRequests()
        returnsPageTask?.cancel()
        returnsPageRequestGeneration &+= 1
        let backup = try await LocalPortfolioStore.shared.resetPortfolio()
        isFakeDataMode = false
        UserDefaults.standard.set(false, forKey: Self.fakeDataModeKey)
        UserDefaults.standard.removeObject(forKey: Self.selectedAccountsKey)
        UserDefaults.standard.removeObject(forKey: Self.selectsAllAccountsKey)
        document = .empty
        overview = nil
        portfolioChart = nil
        holdings = []
        accounts = []
        selectedAccountKeys = []
        holdingDailyChanges = [:]
        holdingDailyChangesSignature = ""
        comparison = nil
        returnsAnalytics = nil
        comparisonWarning = nil
        analyticsWarning = nil
        portfolioError = nil
        returnsError = nil
        localSource = "尚未导入"
        localUpdatedAt = nil
        portfolioChartRevision &+= 1
        comparisonRevision &+= 1
        returnsAnalyticsRevision &+= 1
        portfolioRecoveryNotice = backup.map {
            "本机组合已重置，原数据备份为 \($0.lastPathComponent)。券商授权和 AI 对话已保留。"
        } ?? "本机组合已重置。券商授权和 AI 对话已保留。"
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
        let (positions, transactions, result) = try await Task.detached(priority: .userInitiated) {
            try LocalCSVImporter.parse(data)
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
        replacingAccountsOnly: Bool = false
    ) async throws -> CSVImportResult {
        var warnings: [String] = []
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.quantity > 0 else { return nil }
            guard let average = position.averagePricePaid, average > 0 else {
                warnings.append("\(position.rawTicker) 缺少平均成本，已跳过")
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
                    ?? (position.accountSlot == 1 ? "Trading 212 · ISA" : "Trading 212 · Invest"),
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
                    ?? "成交历史正在分页同步，稍后再次同步会继续补全。"
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
                    ?? (transaction.accountSlot == 1 ? "Trading 212 · ISA" : "Trading 212 · Invest"),
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
            warnings.append("\(unavailableFXCount) 项持仓缺少完整历史数据，汇率影响标记为不可算")
        }
        let result = try await replace(
            enriched,
            source: "Trading 212",
            warnings: warnings,
            transactions: snapshot.hasCompleteTransactionHistory ? transactions : nil,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: snapshot.syncedAccounts.map { account in
                PortfolioAccount(
                    id: account.id, accountID: account.accountID, source: account.source,
                    name: account.accountID.flatMap { accountNames[$0] } ?? account.name,
                    baseCurrency: account.baseCurrency, positionCount: account.positionCount,
                    transactionCount: account.transactionCount,
                    manualTransactionCount: account.manualTransactionCount,
                    hasCSVImport: account.hasCSVImport, marketValueUSD: account.marketValueUSD
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
                warnings.append("\(position.code) 缺少有效成本价，已跳过")
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
            guard let currency = positionCurrencies["\(fill.accountID)|\(fill.code.uppercased())"] else {
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
                tradeID: fill.tradeID
            )
        }
        let enriched = await LocalFXImpactCalculator().enrich(
            positions: positions,
            transactions: transactions
        )
        let unavailableFXCount = enriched.filter { $0.fxPnlStatus == "unavailable" }.count
        if unavailableFXCount > 0 {
            warnings.append("\(unavailableFXCount) 项持仓缺少完整历史数据，汇率影响标记为不可算")
        }
        return try await replace(
            enriched,
            source: "Moomoo",
            warnings: warnings,
            transactions: transactions,
            replacingAccountsOnly: replacingAccountsOnly
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
                warnings.append("已跳过不受支持的 \(category) 持仓 \(position.symbol)")
                return nil
            }
            guard let average = position.averageCost, average > 0 else {
                warnings.append("\(position.symbol) 缺少平均成本，已跳过")
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
                accountCurrency: snapshot.accountCurrencies[position.accountID]
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
            warnings.append("Flex Query 缺少 Account Information → Base Currency，汇率影响暂不可计算")
        }
        if transactions.isEmpty {
            warnings.append("Flex Query 缺少 Trades → Executions；无建仓日时汇率影响将标记为不可算")
        }
        let enriched = await LocalFXImpactCalculator().enrich(
            positions: positions,
            transactions: transactions
        )
        let unavailableFXCount = enriched.filter { $0.fxPnlStatus == "unavailable" }.count
        if unavailableFXCount > 0 {
            warnings.append("\(unavailableFXCount) 项持仓缺少完整历史数据，汇率影响标记为不可算")
        }
        return try await replace(
            enriched,
            source: "IBKR Flex",
            warnings: warnings,
            transactions: transactions,
            replacingAccountsOnly: replacingAccountsOnly
        )
    }

    private func replace(
        _ rawPositions: [LocalPositionRecord],
        source: String,
        warnings: [String],
        transactions: [LocalTransactionRecord]? = nil,
        replacingAccountsOnly: Bool = false,
        syncedAccounts: [PortfolioAccount] = []
    ) async throws -> CSVImportResult {
        invalidateInFlightRequests()
        let generation = portfolioRequestGeneration
        let positions = Self.merge(rawPositions)
        let saved = try await LocalPortfolioStore.shared.replace(
            positions: positions,
            source: source,
            transactions: transactions,
            replacingAccountsOnly: replacingAccountsOnly,
            syncedAccounts: syncedAccounts
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

    private func apply(_ loaded: LocalPortfolioDocument, invalidatesDailyChanges: Bool = true) async throws {
        let generation = portfolioRequestGeneration
        let previousDailyChanges = holdingDailyChanges
        let scoped = selectedDocument(from: loaded)
        let presentation = try await Task.detached(priority: .userInitiated) {
            try LocalPortfolioEngine.presentation(for: scoped)
        }.value
        guard generation == portfolioRequestGeneration else { return }
        document = scoped
        overview = presentation.0
        portfolioChart = presentation.1
        portfolioChartRevision &+= 1
        holdings = presentation.2
        if invalidatesDailyChanges {
            dailyChangesRequestGeneration &+= 1
        }
        let activeTickers = Set(presentation.2.map { $0.ticker.uppercased() })
        holdingDailyChanges = previousDailyChanges.filter {
            activeTickers.contains($0.key) && $0.value.isFinite
        }
        for holding in presentation.2 {
            if let value = holding.todayChangePercent, value.isFinite {
                holdingDailyChanges[holding.ticker.uppercased()] = value
            }
        }
        if invalidatesDailyChanges {
            holdingDailyChangesSignature = ""
            isHoldingDailyChangesLoading = !presentation.2.isEmpty
        }
        localSource = scoped.source
        localUpdatedAt = loaded.marketDataUpdatedAt ?? loaded.updatedAt
        comparison = nil
        returnsAnalytics = nil
        returnsAnalyticsPendingParts = []
        comparisonWarning = nil
        analyticsWarning = nil
        comparisonRevision &+= 1
        returnsAnalyticsRevision &+= 1
    }

    func setFakeDataMode(_ enabled: Bool) async {
        guard enabled != isFakeDataMode else { return }
        fakeDataModeError = nil
        isFakeDataMode = enabled
        UserDefaults.standard.set(enabled, forKey: Self.fakeDataModeKey)
        invalidateInFlightRequests()
        await refreshPortfolio()
        await refreshReturnsPage()
    }

    private func loadActiveDocument() async throws -> LocalPortfolioDocument {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-empty-account") { return FoundationRegressionChecks.emptyFixture }
        #endif
        if isFakeDataMode { return FakePortfolioGenerator.make() }
        let loaded = try await LocalPortfolioStore.shared.load()
        if let notice = await LocalPortfolioStore.shared.recoveryNotice {
            portfolioRecoveryNotice = notice
        }
        return loaded
    }

    private func activeDocument(from loaded: LocalPortfolioDocument) -> LocalPortfolioDocument {
        isFakeDataMode ? FakePortfolioGenerator.make() : loaded
    }

    private func selectedDocument(from loaded: LocalPortfolioDocument) -> LocalPortfolioDocument {
        let availableAccounts = loaded.accounts
        let availableKeys = Set(availableAccounts.map(\.id))
        let savedKeys = Self.savedAccountKeys(forKey: selectedAccountsStorageKey).intersection(availableKeys)
        let selectsAll = UserDefaults.standard.bool(forKey: selectsAllAccountsStorageKey)
        let effectiveKeys = selectsAll || savedKeys.isEmpty ? availableKeys : savedKeys
        accounts = availableAccounts
        selectedAccountKeys = effectiveKeys
        return loaded.scoped(to: effectiveKeys)
    }

    private func updateAccountSelection(_ keys: Set<String>, selectsAll: Bool) async {
        let availableKeys = Set(accounts.map(\.id))
        let next = keys.intersection(availableKeys)
        guard !next.isEmpty else { return }
        selectedAccountKeys = next
        returnsRequestGeneration &+= 1
        returnsAnalyticsRequestGeneration &+= 1
        isReturnsLoading = false
        isReturnsAnalyticsLoading = false
        returnsAnalyticsPendingParts = []
        Self.saveAccountKeys(next, forKey: selectedAccountsStorageKey)
        UserDefaults.standard.set(selectsAll, forKey: selectsAllAccountsStorageKey)
        await refreshPortfolio()
        await refreshReturnsPage()
    }

    private var selectedAccountsStorageKey: String {
        isFakeDataMode ? Self.fakeSelectedAccountsKey : Self.selectedAccountsKey
    }

    private var selectsAllAccountsStorageKey: String {
        isFakeDataMode ? Self.fakeSelectsAllAccountsKey : Self.selectsAllAccountsKey
    }

    private static func savedAccountKeys(forKey key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(values)
    }

    private static func saveAccountKeys(_ keys: Set<String>, forKey key: String) {
        let values = keys.sorted()
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: key)
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

    private func enrichPortfolioChart(from loaded: LocalPortfolioDocument, generation: Int) async {
        if let enriched = try? await LocalMarketDataClient().portfolioChart(document: loaded) {
            guard generation == portfolioRequestGeneration else { return }
            portfolioChart = enriched
            portfolioChartRevision &+= 1
        }
    }

    private func invalidateInFlightRequests() {
        portfolioRequestGeneration &+= 1
        returnsRequestGeneration &+= 1
        returnsAnalyticsRequestGeneration &+= 1
        dailyChangesRequestGeneration &+= 1
        isPortfolioLoading = false
        isReturnsLoading = false
        isReturnsAnalyticsLoading = false
        returnsAnalyticsPendingParts = []
        isHoldingDailyChangesLoading = false
        benchmarkDailyChange = nil
    }

    private static func dailyChangesSignature(for holdings: [Holding]) -> String {
        holdings
            .map { "\($0.ticker.uppercased()):\($0.quotePrice):\($0.marketValue)" }
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
