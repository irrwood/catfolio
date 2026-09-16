import SwiftUI
import UIKit
import Observation

/// All research spacing belongs to actual visible modules, including the top
/// gap. Known funds start without speculative company-analysis entry points.
struct HoldingResearchSection: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let price: Double?
    private let restoresCache: Bool
    private let cachedContent: HoldingDetailCachedContent?
    @State private var visibility: HoldingResearchVisibility
    @State private var consensus: AnalystConsensusData?
    @State private var earnings: EarningsSnapshot?
    @State private var predictionMarkets: [PolymarketRelatedMarket]?

    init(holding: Holding, price: Double?, restoresCache: Bool = true,
         initialAvailability: [HoldingResearchModule: HoldingResearchAvailability] = [:],
         initialEarnings: EarningsSnapshot? = nil, cachedContent: HoldingDetailCachedContent? = nil) {
        self.holding = holding
        self.price = price
        self.restoresCache = restoresCache
        self.cachedContent = cachedContent
        let cached = cachedContent?.research[AppLanguage.currentIdentifier]
        var policy = HoldingResearchVisibility(kind: HoldingSecurityKind.classify(holding), currency: holding.quoteCurrency)
        for (module, state) in cached?.availability ?? [:] { policy.record(state, for: module) }
        policy.record(AnalystConsensusView.hasHistory(symbol: holding.ticker) ? .available : .empty, for: .analystHistory)
        for (module, state) in initialAvailability { policy.record(state, for: module) }
        if let initialEarnings { policy.record(initialEarnings.hasUsableObservations ? .available : .empty, for: .earnings) }
        _visibility = State(initialValue: policy)
        _earnings = State(initialValue: initialEarnings ?? cached?.earnings)
        _consensus = State(initialValue: cached?.consensus)
        _predictionMarkets = State(initialValue: cached?.predictionMarkets)
    }

    /// Every caveat the visible sections carry, in page order. They are
    /// gathered here in small print rather than interrupting the cards.
    private var disclaimers: [String] {
        var lines = [L10n.text("期权持仓不代表成交量、买卖方向或必然的支撑与阻力。")]
        if visibility.shows(.predictionMarkets) {
            lines.append(L10n.text("Prediction-market probabilities are based on trading prices and are not facts or investment advice."))
        }
        if visibility.shows(.developments) {
            lines.append(L10n.text("事实附原文摘录；影响解读和观察项是分析，不代表已发生。"))
        }
        if visibility.shows(.consensus) {
            lines.append(L10n.text("目标价是分析师观点，不是收益承诺或 Catfolio 的买卖建议。"))
        }
        return lines
    }

    var body: some View {
        VStack(spacing: 0) {
            if visibility.hasVisibleModules || ManagementDeliveryRules.isEligible(holding) {
                // Eager, not lazy: a handful of cards whose heights change as
                // their content arrives. Lazily, the ones scrolled off above
                // were re-measured on reaching the page's end and threw the
                // scroll position back up by most of a screen.
                VStack(spacing: HoldingDetailCardStyle.spacing) {
                    // First, so it sits directly under the Data section above.
                    if visibility.shows(.predictionMarkets) {
                        HoldingPredictionMarketsCard(holding: holding, initialMarkets: predictionMarkets,
                            usesCachedContentOnlyInitially: visibility.kind == .fund,
                            onAvailability: { record($0, for: .predictionMarkets) },
                            onMarketsChange: { markets in
                                predictionMarkets = markets
                                saveCachedContent()
                            })
                    }
                    if visibility.shows(.developments) {
                        SecurityDebateCard(ticker: holding.ticker, name: holding.shortName)
                    }
                    if ManagementDeliveryRules.isEligible(holding) {
                        ManagementDeliveryCard(ticker: holding.ticker)
                    }
                    if visibility.shows(.consensus) || visibility.shows(.analystHistory) {
                        AnalystConsensusView(symbol: holding.ticker, currency: holding.quoteCurrency, price: price,
                            showsConsensus: visibility.shows(.consensus),
                            showsHistoryEntry: visibility.shows(.analystHistory), initialData: consensus,
                            onAvailability: { record($0, for: .consensus) })
                    }
                    if visibility.shows(.insiders) {
                        HoldingInsiderTradesCard(holding: holding)
                    }
                    if visibility.shows(.earnings) {
                        EarningsHistoryView(symbol: holding.ticker, initialSnapshot: earnings,
                            onAvailability: { record($0, for: .earnings) })
                    }
                    if visibility.shows(.financials) {
                        HoldingFinancialCard(holding: holding, onAvailability: { record($0, for: .financials) })
                    }
                }
                .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                // The same gap as between the cards above: one stack of cards.
                .padding(.top, HoldingDetailCardStyle.spacing)
                .accessibilityIdentifier("holding-research-section")
            }

            // Only under research cards: a fund with none keeps a zero-height
            // section, and the OI caveat stays in the wall's own ⓘ.
            if visibility.hasVisibleModules || ManagementDeliveryRules.isEligible(holding) {
                // One running paragraph, not a line per caveat.
                Text(L10n.sentences(disclaimers))
                .appText(.micro, weight: .regular)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                .padding(.top, 40)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("holding-detail-disclaimers")
            }
        }
        // This task also runs when the group has no visible cards. Missing
        // caches are unknown, never persisted as proof that a fund has no data.
        .task(id: "\(holding.ticker)|\(appLocale.identifier)") {
            guard restoresCache else { return }
            await restoreAvailableContent()
        }
    }

    private func record(_ state: HoldingResearchAvailability, for module: HoldingResearchModule) {
        visibility.record(state, for: module)
        saveCachedContent()
    }

    private func saveCachedContent() {
        cachedContent?.research[AppLanguage.currentIdentifier] = HoldingResearchCachedContent(
            availability: visibility.availability, consensus: consensus, earnings: earnings,
            predictionMarkets: predictionMarkets)
    }

    @MainActor private func restoreAvailableContent() async {
        let language = AppLanguage.currentIdentifier
        let symbol = holding.ticker
        let name = holding.displayName.components(separatedBy: " / ").first ?? holding.displayName
        async let analyst = AnalystConsensusClient.shared.cached(symbol: symbol)
        async let history = EarningsHistoryClient.shared.cached(symbol: symbol)
        async let statements = CompanyFinancialsClient.shared.cached(ticker: symbol)
        async let markets = PolymarketClient.shared.cachedRelatedMarkets(ticker: symbol, companyName: name, language: language)
        await SecurityDebateStore.shared.restore()
        let values = await (analyst, history, statements, markets)
        guard !Task.isCancelled, language == AppLanguage.currentIdentifier else { return }
        if let debate = SecurityDebateStore.shared.lastResult(for: symbol),
           !debate.questions.isEmpty, !debate.sources.isEmpty {
            record(.available, for: .developments)
        }
        consensus = values.0 ?? consensus
        earnings = values.1 ?? earnings
        predictionMarkets = values.3 ?? predictionMarkets
        if let value = values.0 { record(value.hasContent ? .available : .empty, for: .consensus) }
        if let value = values.1 { record(value.hasUsableObservations ? .available : .empty, for: .earnings) }
        if let value = values.2 { record(value.hasUsableStatements ? .available : .empty, for: .financials) }
        if let value = values.3 { record(value.isEmpty ? .empty : .available, for: .predictionMarkets) }
    }
}

struct HoldingFinancialCard: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    var onAvailability: (HoldingResearchAvailability) -> Void = { _ in }
    @State private var showsFinancials = false
    @State private var availability: HoldingResearchAvailability = .unknown

    var body: some View {
        Button {
            showsFinancials = true
        } label: {
            HoldingDetailActionCardLabel(
                title: L10n.text("Financial"),
                subtitle: L10n.text("Profit and Loss Statement, Balance Sheet and Cash Flow")
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open reported company financials")
        .sheet(isPresented: $showsFinancials, onDismiss: { onAvailability(availability) }) {
            NavigationStack {
                CompanyFinancialsView(holding: holding, onAvailability: { availability = $0 })
            }
            // Keep report scrolling separate from interactive zoom dismissal,
            // which lets a drag on the statement move the entire sheet.
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

struct HoldingPredictionMarketsCard: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let usesCachedContentOnlyInitially: Bool
    let onAvailability: (HoldingResearchAvailability) -> Void
    let onMarketsChange: ([PolymarketRelatedMarket]) -> Void

    init(holding: Holding, initialMarkets: [PolymarketRelatedMarket]? = nil,
         usesCachedContentOnlyInitially: Bool = false,
         onAvailability: @escaping (HoldingResearchAvailability) -> Void = { _ in },
         onMarketsChange: @escaping ([PolymarketRelatedMarket]) -> Void = { _ in }) {
        self.holding = holding
        self.usesCachedContentOnlyInitially = usesCachedContentOnlyInitially
        self.onAvailability = onAvailability
        self.onMarketsChange = onMarketsChange
        _markets = State(initialValue: initialMarkets ?? [])
        _isLoading = State(initialValue: initialMarkets == nil)
    }

    @Environment(\.openURL) private var openURL
    @State private var markets: [PolymarketRelatedMarket] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    private var taskID: String {
        "\(holding.ticker)|\(holding.displayName)|\(appLocale.identifier)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The same header as every research card: title, a secondary
            // line, and one quiet control where the others put their chevron.
            HStack(alignment: .center, spacing: 14) {
                HoldingDetailCardTitle(title: L10n.text("Predicting markets"), subtitle: predictionSubtitle)
                    .redacted(reason: isLoading && markets.isEmpty ? .placeholder : [])
                    .chartLoadingShimmer(active: isLoading && markets.isEmpty)
                if isLoading {
                    ChartSkeletonShape(width: 18, height: 18, cornerRadius: 9).frame(width: 24, height: 24).chartLoadingShimmer()
                } else {
                    Button {
                        Task { await load(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(L10n.text("Refresh predicting markets"))
                }
            }
            .padding(HoldingDetailCardStyle.contentInset)
            .frame(maxWidth: .infinity, minHeight: HoldingDetailCardStyle.minimumRowHeight, alignment: .leading)

            Group {
                if isLoading && markets.isEmpty {
                    predictionLoadingRows
                } else if markets.isEmpty {
                    predictionEmptyState
                } else {
                    predictionRows
                }
            }
            .padding(.horizontal, HoldingDetailCardStyle.contentInset)
            .padding(.bottom, HoldingDetailCardStyle.contentInset)
            // Its caveat is in the page's footer with the others.
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .holdingDetailGlassCard()
        .task(id: taskID) {
            if usesCachedContentOnlyInitially {
                isLoading = false
                onAvailability(markets.isEmpty ? .empty : .available)
                return
            }
            await load(forceRefresh: false)
        }
    }

    private var predictionSubtitle: String {
        if isLoading && markets.isEmpty { return "Polymarket · 3" }
        let events = PolymarketRelatedEvent.grouped(markets).count
        return events > 0 ? L10n.text("Polymarket · \(events) 个相关事件") : "Polymarket"
    }

    private var predictionRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(PolymarketRelatedEvent.grouped(markets).enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider().padding(.vertical, 18) }
                Button {
                    if let url = event.webURL { openURL(url) }
                } label: {
                    PolymarketEventCard(event: event)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var predictionLoadingRows: some View {
        VStack(spacing: 36) {
            ForEach(0..<3, id: \.self) { index in
                PolymarketEventCard(
                    event: PolymarketRelatedEvent(id: "holding-detail-placeholder-\(index)", markets: [PolymarketRelatedMarket(
                        id: "holding-detail-placeholder-\(index)",
                        question: "Loading the most active related prediction market",
                        eventTitle: "Polymarket",
                        eventSlug: "",
                        outcome: "Yes",
                        probability: 0.62,
                        volume24Hours: 12_500,
                        totalVolume: 220_000,
                        endDate: nil
                    )])
                )
                .redacted(reason: .placeholder)
            }
        }
        .allowsHitTesting(false)
        .chartLoadingShimmer()
        .accessibilityLabel(L10n.text("Loading prediction markets"))
    }

    private var predictionEmptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: errorMessage == nil ? "scope" : "wifi.exclamationmark")
                .foregroundStyle(.secondary)
            Text(errorMessage ?? L10n.text("暂时没有找到当前语言中与 \(holding.ticker) 相关的活跃盘口"))
                .font(HoldingDetailTypography.regular(13, relativeTo: .subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 60, alignment: .top)
    }

    @MainActor
    private func load(forceRefresh: Bool) async {
        let language = AppLanguage.currentIdentifier
        isLoading = forceRefresh || markets.isEmpty
        errorMessage = nil
        do {
            let companyName = holding.displayName.components(separatedBy: " / ").first
                ?? holding.displayName
            if markets.isEmpty, let cached = await PolymarketClient.shared.cachedRelatedMarkets(
                ticker: holding.ticker, companyName: companyName, language: language) {
                guard !Task.isCancelled, language == AppLanguage.currentIdentifier else { return }
                markets = cached.filter(\.hasUsableContent)
                onMarketsChange(markets)
                if !markets.isEmpty && !forceRefresh { isLoading = false }
            }
            guard !Task.isCancelled, language == AppLanguage.currentIdentifier else { return }
            let loaded = try await PolymarketClient.shared.relatedMarkets(
                ticker: holding.ticker,
                companyName: companyName,
                forceRefresh: forceRefresh, language: language
            )
            guard !Task.isCancelled, language == AppLanguage.currentIdentifier else { return }
            let usable = loaded.filter(\.hasUsableContent)
            if !usable.isEmpty || markets.isEmpty { markets = usable }
            onMarketsChange(markets)
            onAvailability(markets.isEmpty ? .empty : .available)
        } catch {
            guard !Task.isCancelled, language == AppLanguage.currentIdentifier else { return }
            errorMessage = error.localizedDescription
            onAvailability(markets.isEmpty ? .failed : .available)
        }
        isLoading = false
    }
}
