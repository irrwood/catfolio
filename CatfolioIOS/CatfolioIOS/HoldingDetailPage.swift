import SwiftUI
import UIKit
import Observation

@MainActor @Observable
final class HoldingDetailCachedContent {
    var profile: VolumeProfile?
    var priceHistory: SecurityPriceHistory?
    let accountSelection = HoldingDetailAccountSelection()
    var accountContext: HoldingDetailAccountContext? { accountSelection.context }
    var selectedAccountKeys: Set<String> { accountSelection.accountKeys }
    var realisedProfit: RealisedProfitSummary?
    var realisedProfitRequest: HoldingDetailRealisedProfitRequest?
    var optionsSnapshots: [Int: OISnapshot] = [:]
    var preparedChart: (request: SecurityPricePreparationRequest, data: SecurityPricePreparedData)?
    var research: [String: HoldingResearchCachedContent] = [:]
}

struct HoldingResearchCachedContent {
    var availability: [HoldingResearchModule: HoldingResearchAvailability] = [:]
    var consensus: AnalystConsensusData?
    var earnings: EarningsSnapshot?
    var predictionMarkets: [PolymarketRelatedMarket]?
}

struct HoldingDetailView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ChinaMarketSource.preferenceKey) private var chinaSource = ChinaMarketSource.automatic.rawValue
    @AppStorage(ChinaMarketConfiguration.revisionKey) private var chinaCredentialsRevision = ""
    let holding: Holding
    let onClose: () -> Void
    var confirmsOpen = false

    var body: some View {
        HoldingDetailContentView(holding: holding, onClose: onClose, confirmsOpen: confirmsOpen,
            cachedContent: model.cachedHoldingDetail(for: holding))
            .id(DetailSourceIdentity(portfolio: model.portfolioSource,
                china: ChinaSecurity(holding.ticker, currency: holding.quoteCurrency) == nil ? nil :
                    ChinaMarketConfiguration(source: ChinaMarketSource(rawValue: chinaSource) ?? .automatic,
                                             credentialsRevision: chinaCredentialsRevision)))
    }

    private struct DetailSourceIdentity: Hashable {
        let portfolio: PortfolioSource
        let china: ChinaMarketConfiguration?
    }
}

struct HoldingDetailContentView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    let holding: Holding
    /// The presenting page owns dismissal, including nested and zoomed sheets.
    let onClose: () -> Void
    /// Set only where the presenter has no state of its own to key the open
    /// click to — a `NavigationLink` push. Sheet presenters click at the tap.
    var confirmsOpen = false
    let cachedContent: HoldingDetailCachedContent
    @State private var hasConfirmedOpen = false

    private var profile: VolumeProfile? {
        get { cachedContent.profile }
        nonmutating set { cachedContent.profile = newValue }
    }
    @State private var errorMessage: String?
    private var priceHistory: SecurityPriceHistory? {
        get { cachedContent.priceHistory }
        nonmutating set { cachedContent.priceHistory = newValue }
    }
    @State private var priceHistoryError: String?
    private var accountContext: HoldingDetailAccountContext? {
        cachedContent.accountContext
    }
    private var selectedAccountKeys: Set<String> {
        cachedContent.selectedAccountKeys
    }
    private var realisedProfit: RealisedProfitSummary? {
        get { cachedContent.realisedProfit }
        nonmutating set { cachedContent.realisedProfit = newValue }
    }
    @State private var showsTransactionHistory = false
    @State private var cardInsight: SecurityCardInsightRequest?
    @State private var marketDataRevision = 0
    @State private var completedMarketDataRevision: Int?
    @State private var isLoadingMarketData = false

    private var displayedHolding: Holding {
        cachedContent.accountSelection.holding ?? holding
    }

    private var hasSelectedDetailAccounts: Bool {
        accountContext == nil || !selectedAccountKeys.isEmpty
    }

    /// Whether there is a position behind this security at all.
    ///
    /// An ETF look-through constituent opens this screen with a real ticker and
    /// a real quote but no shares and no cost. The position blocks are left out
    /// rather than shown as zeros, and nothing invents a cost basis for it.
    private var hasPosition: Bool {
        displayedHolding.shares > 0
    }

    private var showsPosition: Bool {
        hasSelectedDetailAccounts && hasPosition
    }

    private var showsInitialLoadingPlaceholder: Bool {
        LaunchArguments.contains("--show-security-detail-loading")
    }

    private var showsDataDesignPreview: Bool {
        LaunchArguments.contains("--show-security-data")
    }

    private var showsVolumeFocusedPreview: Bool {
        #if DEBUG
        LaunchArguments.contains("--show-volume-focused")
        #else
        false
        #endif
    }

    var body: some View {
        // History opens in its own sheet; the detail needs no NavigationStack.
        // The stack was a second, opaque, rectangular view controller under
        // the sheet — outside the clip the zoom and the drag apply to the
        // sheet — with a hidden bar whose inset settled only after the page
        // had appeared, which is the jump at the end of the zoom. Pushed from
        // Research it was also a stack inside a stack.
            ScrollView {
                Group {
                if showsDataDesignPreview {
                    HoldingPositionDetails(holding: displayedHolding, realisedProfit: realisedProfit)
                        .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                        .padding(.top, 40)
                        .padding(.bottom, 72)
                } else if showsInitialLoadingPlaceholder {
                    HoldingDetailLoadingPlaceholder()
                } else {
                    // Keep the header chart and its time picker resident while
                    // they cross the scroll viewport boundary. Recycling this
                    // outer container rebuilt every prepared chart range and
                    // caused a hitch as the picker appeared or disappeared.
                    // The lower cards are eager too; see below.
                    VStack(spacing: 0) {
                    if !showsVolumeFocusedPreview {
                        VStack(spacing: 0) {
                            HoldingDetailPriceSection(
                                holding: displayedHolding,
                                priceHistory: priceHistory,
                                priceHistoryError: priceHistoryError,
                                averageCost: averageCostInQuoteCurrency,
                                selectedAccountKeys: selectedAccountKeys,
                                tradeAccountKeys: accountContext?.tradeAccountKeys(for: selectedAccountKeys),
                                accountOptions: accountContext?.options ?? [],
                                onSelectAll: selectAllDetailAccounts,
                                onToggleAccount: toggleDetailAccount,
                                isRefreshing: isLoadingMarketData,
                                refreshError: marketDataRevision > 0 ? priceHistoryError ?? errorMessage : nil,
                                onRefresh: { marketDataRevision += 1 },
                                cachedContent: cachedContent
                            )
                        }
                    }

                    VStack(spacing: 0) {
                        // A plain stack: built once when the page lands. Lazily,
                        // the options wall was created as it scrolled in and
                        // the volume chart torn down as it scrolled out, and
                        // each was a hitch under the reader's finger.
                        VStack(spacing: HoldingDetailCardStyle.spacing) {
                            if let profile {
                                VolumePriceChart(
                                    profile: profile,
                                    holding: displayedHolding,
                                    showsHoldingCost: showsPosition
                                )
                                .onAppear { ChartAppearanceHistory.record("volume-profile|\(holding.ticker)") }

                                if let high = profile.fiftyTwoWeekHigh,
                                   let low = profile.fiftyTwoWeekLow,
                                   high > low {
                                    FiftyTwoWeekRange(
                                        low: low,
                                        high: high,
                                        current: priceHistory?.latestAvailablePrice ?? displayedHolding.quotePrice,
                                        periodStart: profile.fiftyTwoWeekStartPrice,
                                        currency: profile.currency
                                    )
                                }
                            } else if let errorMessage {
                                HoldingDetailSectionCard(title: L10n.text("Volume Profile")) {
                                    StatusNotice(text: errorMessage, kind: .info)
                                }
                            } else {
                                HoldingVolumeProfileLoadingPlaceholder(ticker: holding.ticker)
                            }

                            // Left out for a security with no options: one
                            // the panel cannot read, or whose chain lists
                            // no expiry at all.
                            if OptionsOIView.supports(symbol: holding.ticker, currency: holding.quoteCurrency),
                               !cachedContent.optionsSnapshots.values.contains(where: { $0.listsOptions == false }) {
                                OptionsOIView(symbol: holding.ticker, currency: holding.quoteCurrency,
                                    price: priceHistory?.latestAvailablePrice ?? holding.quotePrice,
                                    costUSD: showsPosition ? VolumeProfileInterpretation.convertedPrice(
                                        displayedHolding.averageCost, from: displayedHolding.costCurrency, to: "USD",
                                        usdRate: LocalPortfolioEngine.usdRate(for:)) : nil,
                                    refreshRevision: marketDataRevision,
                                    initialSnapshots: cachedContent.optionsSnapshots,
                                    onSnapshot: { days, snapshot in cachedContent.optionsSnapshots[days] = snapshot })
                            }

                            if showsPosition {
                                HoldingPositionDetails(holding: displayedHolding, realisedProfit: realisedProfit)
                            }
                            if (holding.shares > 0 || holding.marketValue > 0),
                               HoldingSecurityKind.classify(holding) != .fund {
                                HoldingAmountSourcesCard(ticker: holding.ticker)
                            }
                        }
                        // One 16pt page margin below the price chart, the same as
                        // the research cards; only the header chart keeps its own.
                        .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                        .padding(.top, showsVolumeFocusedPreview ? 28 : 24)

                        HoldingResearchSection(holding: holding,
                            price: priceHistory?.latestAvailablePrice ?? holding.quotePrice,
                            cachedContent: cachedContent)
                        .id("\(holding.ticker)|\(appLocale.identifier)")

                        DividendIncomeCalculatorCard(ticker: holding.ticker, heldShares: showsPosition ? displayedHolding.shares : 0)
                            .padding(.horizontal, HoldingDetailCardStyle.pageInset)

                        Button { showsTransactionHistory = true } label: {
                            HoldingDetailActionCardLabel(
                                title: L10n.text("交易历史"),
                                subtitle: L10n.text("买入、卖出与股息")
                            )
                        }
                        .buttonStyle(PanelPressButtonStyle())
                        .accessibilityIdentifier("holding.transaction-history")
                        .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                        .padding(.top, HoldingDetailCardStyle.spacing)
                        .padding(.bottom, 72)
                    }
                    }
                }
                }
                // This must be inside the scroll content: only this scroll
                // view loses inherited refresh, never its presenting page or
                // the independently refreshable analyst/financial sheets.
                .background(HoldingDetailScrollBoundary())
            }
            .accessibilityIdentifier("holding-detail-scroll")
            .sheet(isPresented: $showsTransactionHistory) {
                NavigationStack {
                    HistoryView(ticker: holding.ticker)
                        .environment(model)
                        .toolbar {
                            HoldingDetailCloseToolbar { showsTransactionHistory = false }
                        }
                }
            }
            // A long press on a card's title reads that card aloud, so to
            // speak, in the same paper as "今天有什么动静？".
            .environment(\.securityCardInsight, SecurityCardInsightAction { title, facts, source in
                let isFund = HoldingSecurityKind.classify(holding) == .fund
                let context = SecurityCardInsightContext(
                    ticker: holding.ticker,
                    name: isFund ? holding.displayName : holding.shortName,
                    currency: holding.quoteCurrency ?? "USD",
                    cardTitle: title,
                    facts: facts
                )
                // Ask at the press, so the answer is researched while the
                // paper opens.
                SecurityCardInsightStore.shared.start(context)
                SecurityDailyMovePresentation.withoutSystemTransition {
                    cardInsight = SecurityCardInsightRequest(context: context, sourceFrame: source)
                }
            })
            .appFullScreenCover(item: $cardInsight) { request in
                SecurityDailyMovePaper(card: request.context, logoSymbol: holding.logoSymbol,
                                       sourceFrame: request.sourceFrame)
            }
            .overlay(alignment: .topTrailing) {
                HoldingDetailCloseButton(action: onClose)
                    .padding(.horizontal, HoldingDetailHeader.inset)
                    .padding(.top, HoldingDetailHeader.topInset)
            }
            // Transparent: the ground is the presentation's, so the one
            // background there is is the one the system rounds.
            // Start cache-backed work as soon as SwiftUI inserts the sheet,
            // while the native presentation animation is still running. The
            // available holding header renders immediately; only genuinely
            // missing chart sections show their own loading treatment.
            .task(id: HoldingDetailRealisedProfitRequest(context: accountContext, accountKeys: selectedAccountKeys)) {
                let request = HoldingDetailRealisedProfitRequest(context: accountContext, accountKeys: selectedAccountKeys)
                guard cachedContent.realisedProfitRequest != request else { return }
                if cachedContent.realisedProfitRequest?.accountKeys != request.accountKeys { realisedProfit = nil }
                let summary = await Task.detached(priority: .userInitiated) { request.summary() }.value
                guard !Task.isCancelled else { return }
                realisedProfit = summary
                cachedContent.realisedProfitRequest = request
            }
            .task(id: marketDataRevision) {
                guard completedMarketDataRevision != marketDataRevision else { return }
                isLoadingMarketData = marketDataRevision > 0 || priceHistory == nil
                async let volume: Void = loadVolumeProfile(forceRefresh: marketDataRevision > 0)
                async let prices: Void = loadPriceHistory(forceRefresh: marketDataRevision > 0)
                _ = await (volume, prices)
                guard !Task.isCancelled else { return }
                completedMarketDataRevision = marketDataRevision
                isLoadingMarketData = false
            }
        // `onAppear` is the frame the push begins in, which is as close to
        // the tap as a pushed page can get. Not `viewDidAppear`, which is where
        // the old click fired: that is the frame the zoom ends in.
        .onAppear {
            if confirmsOpen && !hasConfirmedOpen { hasConfirmedOpen = true }
        }
        .sensoryFeedback(SecurityDetailPresentation.openFeedback, trigger: hasConfirmedOpen) { _, confirmed in
            hapticsEnabled && confirmed
        }
    }

    @MainActor
    private func loadVolumeProfile(forceRefresh: Bool) async {
        if profile == nil {
            let cached = try? await model.volumeProfile(for: holding.ticker,
                currency: holding.quoteCurrency, cachedOnly: true)
            if let cached, !Task.isCancelled { profile = cached }
        }
        guard !Task.isCancelled else { return }
        do {
            let loaded = try await model.volumeProfile(for: holding.ticker, currency: holding.quoteCurrency,
                                                       forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            profile = loaded
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadPriceHistory(forceRefresh: Bool) async {
        do {
            let context: HoldingDetailAccountContext
            do {
                context = try await model.holdingDetailAccountContext(for: holding.ticker)
            } catch LocalPortfolioError.noPortfolio {
                // Held in no account: the market's history stands alone,
                // with no accounts to pick and no trades to mark.
                cachedContent.accountSelection.clear()
                if priceHistory == nil, let cached = try? await model.marketPriceHistory(
                    for: holding.ticker, currency: holding.quoteCurrency ?? "USD", cachedOnly: true),
                   !Task.isCancelled {
                    cachedContent.accountSelection.clear(accountKeys: Set(cached.trades.flatMap(\.accountKeys)))
                    priceHistory = cached
                    if !forceRefresh { isLoadingMarketData = false }
                }
                guard !Task.isCancelled else { return }
                let loaded = try await model.marketPriceHistory(
                    for: holding.ticker,
                    currency: holding.quoteCurrency ?? "USD",
                    forceRefresh: forceRefresh
                )
                guard !Task.isCancelled else { return }
                // No position to pick accounts from: mark every account's
                // past trades, so a closed position keeps its points.
                cachedContent.accountSelection.clear(accountKeys: Set(loaded.trades.flatMap(\.accountKeys)))
                priceHistory = loaded
                priceHistoryError = nil
                return
            }
            guard !Task.isCancelled else { return }
            // Refresh data without resetting the user's account selection,
            // chart range, scroll position or the independent section caches.
            await cachedContent.accountSelection.update(context: context)
            guard !Task.isCancelled else { return }
            if priceHistory == nil {
                let cached = try? await model.securityPriceHistory(
                    for: holding.ticker, accountKeys: context.allAccountKeys, cachedOnly: true)
                if let cached, !Task.isCancelled {
                    priceHistory = cached
                    if !forceRefresh { isLoadingMarketData = false }
                }
            }
            guard !Task.isCancelled else { return }
            let loaded = try await model.securityPriceHistory(
                for: holding.ticker,
                accountKeys: context.allAccountKeys,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled else { return }
            priceHistory = loaded
            priceHistoryError = nil
        } catch {
            guard !Task.isCancelled else { return }
            priceHistoryError = error.localizedDescription
        }
    }

    private var averageCostInQuoteCurrency: Double? {
        guard hasSelectedDetailAccounts else { return nil }
        return Self.averageCostInQuoteCurrency(of: displayedHolding)
    }

    /// The cost line's price, in the currency the chart is quoted in.
    static func averageCostInQuoteCurrency(of holding: Holding) -> Double? {
        guard holding.averageCost.isFinite, holding.averageCost > 0 else { return nil }
        let costCurrency = (holding.costCurrency ?? holding.quoteCurrency ?? "USD").uppercased()
        let quoteCurrency = (holding.quoteCurrency ?? costCurrency).uppercased()
        guard costCurrency != quoteCurrency else { return holding.averageCost }
        guard let costUSD = LocalPortfolioEngine.usdRate(for: costCurrency),
              let quoteUSD = LocalPortfolioEngine.usdRate(for: quoteCurrency),
              quoteUSD > 0 else { return nil }
        return holding.averageCost * costUSD / quoteUSD
    }

    private func selectAllDetailAccounts() {
        Task { await cachedContent.accountSelection.selectAll() }
    }

    private func toggleDetailAccount(_ accountKey: String) {
        Task { await cachedContent.accountSelection.toggle(accountKey) }
    }
}

extension HoldingDetailContentView {
    /// At the tap, while the card is still in the air: the page's cached price
    /// history and volume profile read from disk, and its chart prepared, so
    /// the page's first frame has them. Measured (`--trace-security-load`),
    /// both were on disk on every open and read in about a tenth of a second,
    /// yet the chart waited until 1.1–1.5s — its preparation began only once
    /// the page existed, and was thrown away when the network answered.
    /// Only fills what the cache does not have yet; the page's own loading
    /// still runs and refreshes from the network.
    static func prefetch(_ holding: Holding, model: AppModel) {
        let content = model.cachedHoldingDetail(for: holding)
        let chinaScope = ChinaMarketConfiguration.scope(ticker: holding.ticker, currency: holding.quoteCurrency)
        func sourceIsCurrent() -> Bool {
            chinaScope == ChinaMarketConfiguration.scope(ticker: holding.ticker, currency: holding.quoteCurrency)
        }
        Task { @MainActor in
            guard sourceIsCurrent() else { return }
            if content.profile == nil,
               let cached = try? await model.volumeProfile(for: holding.ticker, currency: holding.quoteCurrency,
                                                           cachedOnly: true),
               content.profile == nil, sourceIsCurrent() {
                content.profile = cached
            }
        }
        guard content.priceHistory == nil else { return }
        Task { @MainActor in
            guard sourceIsCurrent() else { return }
            var history: SecurityPriceHistory?
            var accountKeys: Set<String> = []
            var shown = holding
            var hasAccounts = true
            do {
                let context = try await model.holdingDetailAccountContext(for: holding.ticker)
                if content.accountContext == nil {
                    await content.accountSelection.update(context: context)
                }
                accountKeys = content.selectedAccountKeys
                hasAccounts = !accountKeys.isEmpty
                shown = content.accountSelection.holding ?? holding
                history = try? await model.securityPriceHistory(
                    for: holding.ticker, accountKeys: context.allAccountKeys, cachedOnly: true)
            } catch LocalPortfolioError.noPortfolio {
                history = try? await model.marketPriceHistory(
                    for: holding.ticker, currency: holding.quoteCurrency ?? "USD", cachedOnly: true)
                accountKeys = Set(history?.trades.flatMap(\.accountKeys) ?? [])
                if content.accountContext == nil, content.selectedAccountKeys.isEmpty {
                    content.accountSelection.clear(accountKeys: accountKeys)
                }
            } catch {
                return
            }
            guard let history, content.priceHistory == nil, sourceIsCurrent() else { return }
            content.priceHistory = history
            // The chart, prepared exactly as the page will ask for it, so the
            // page takes it from the cache instead of preparing it again.
            let averageCost = hasAccounts ? averageCostInQuoteCurrency(of: shown) : nil
            let tradeKeys = content.accountContext?.tradeAccountKeys(for: accountKeys) ?? accountKeys
            let request = SecurityPricePreparationRequest(history: history, averageCost: averageCost,
                                                          accountKeys: tradeKeys)
            guard content.preparedChart?.request != request else { return }
            let prepared = await Task.detached(priority: .userInitiated) {
                SecurityPricePreparedData(history: history, averageCost: averageCost,
                                          selectedAccountKeys: tradeKeys)
            }.value
            if content.preparedChart == nil {
                content.preparedChart = (request, prepared)
            }
        }
    }
}
