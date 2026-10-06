import Foundation

// Holding-detail caches, price history, quote publication and daily changes.
// Shared observable state remains owned by AppModel.
extension AppModel {
    struct HoldingDetailContentKey: Hashable {
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
        // A local holdings snapshot can follow new quotes without waiting for
        // a full account ledger. Complete account curves retain their basis.
        if portfolioChart?.isCurrentHoldingsOnly == true {
            portfolioChart = .currentHoldings(overview: presentation.0,
                positionCount: presentation.2.count)
            portfolioChartRevision &+= 1
        }
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

    func applyingDetailQuotes(to input: LocalPortfolioDocument, now: Date = .now) -> LocalPortfolioDocument {
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

    func applyDetailDailyChanges(now: Date = .now) {
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

}
