import SwiftUI
import UIKit
import Observation

@MainActor @Observable
final class HoldingDetailCachedContent {
    var profile: VolumeProfile?
    var priceHistory: SecurityPriceHistory?
    var accountContext: HoldingDetailAccountContext?
    var selectedAccountKeys: Set<String> = []
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
    let holding: Holding
    let onClose: () -> Void
    var confirmsOpen = false
    var isPreview = false

    var body: some View {
        HoldingDetailContentView(holding: holding, onClose: onClose, confirmsOpen: confirmsOpen,
            isPreview: isPreview, cachedContent: model.cachedHoldingDetail(for: holding))
            .id(model.portfolioSource)
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
    var isPreview = false
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
        get { cachedContent.accountContext }
        nonmutating set { cachedContent.accountContext = newValue }
    }
    private var selectedAccountKeys: Set<String> {
        get { cachedContent.selectedAccountKeys }
        nonmutating set { cachedContent.selectedAccountKeys = newValue }
    }
    private var realisedProfit: RealisedProfitSummary? {
        get { cachedContent.realisedProfit }
        nonmutating set { cachedContent.realisedProfit = newValue }
    }
    @State private var presentationReady = false
    @State private var lowerSectionsRevealed = false
    @State private var cardInsight: SecurityCardInsightRequest?
    @State private var marketDataRevision = 0
    @State private var completedMarketDataRevision: Int?
    @State private var isLoadingMarketData = false

    private var displayedHolding: Holding {
        accountContext?.holding(for: selectedAccountKeys) ?? holding
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

    /// A preview has no presentation to wait for.
    private var showsLowerSections: Bool {
        lowerSectionsRevealed || isPreview || showsVolumeFocusedPreview
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
        // No `NavigationStack` of its own: nothing on this page navigates.
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
                                marketTodayChange: profile?.todayChangePercent,
                                priceHistory: priceHistory,
                                priceHistoryError: priceHistoryError,
                                presentationReady: presentationReady,
                                averageCost: averageCostInQuoteCurrency,
                                selectedAccountKeys: selectedAccountKeys,
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

                    // Everything below the price section waits for the zoom
                    // to land, then fades in. Built in the same update as the
                    // sheet, these cards were most of the half second between
                    // the tap and the zoom starting, and the frames it dropped
                    // on the way.
                    if showsLowerSections {
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
                                } else if presentationReady {
                                    VStack(alignment: .leading, spacing: 16) {
                                        ChartSkeletonShape(width: 140, height: 19)
                                        ChartShapeSkeleton(layout: .horizontalBars, appearanceID: "volume-profile|\(holding.ticker)")
                                            .frame(height: 184)
                                        ChartSkeletonShape(height: 12)
                                    }
                                    .padding(HoldingDetailCardStyle.contentInset)
                                    .holdingDetailGlassCard()
                                } else {
                                    Color.clear
                                        .frame(height: 72)
                                        .accessibilityHidden(true)
                                }

                                OptionsOIView(symbol: holding.ticker, currency: holding.quoteCurrency,
                                    price: priceHistory?.latestAvailablePrice ?? holding.quotePrice,
                                    costUSD: showsPosition ? VolumeProfileInterpretation.convertedPrice(
                                        displayedHolding.averageCost, from: displayedHolding.costCurrency, to: "USD",
                                        usdRate: LocalPortfolioEngine.usdRate(for:)) : nil,
                                    refreshRevision: marketDataRevision,
                                    initialSnapshots: cachedContent.optionsSnapshots,
                                    onSnapshot: { days, snapshot in cachedContent.optionsSnapshots[days] = snapshot })

                                if showsPosition {
                                    HoldingPositionDetails(holding: displayedHolding, realisedProfit: realisedProfit)
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
                            .padding(.bottom, 72)
                        }
                        .transition(.opacity)
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
            // A long press on a card's title reads that card aloud, so to
            // speak, in the same paper as "今天有什么动静？".
            .environment(\.securityCardInsight, isPreview ? nil : SecurityCardInsightAction { title, facts, source in
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
            .fullScreenCover(item: $cardInsight) { request in
                SecurityDailyMovePaper(card: request.context, logoSymbol: holding.logoSymbol,
                                       sourceFrame: request.sourceFrame)
            }
            .overlay(alignment: .topTrailing) {
                if !isPreview {
                    HoldingDetailCloseButton(action: {
                        SecurityDetailSnapshotTransition.shared.close(perform: onClose)
                    })
                        .padding(20)
                }
            }
            // Transparent: the ground is the presentation's, so the one
            // background there is is the one the system rounds.
            .background {
                PresentationDidAppearReader {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { presentationReady = true }
                    // Opened from a row, wait for the card to land as well.
                    SecurityDetailSnapshotTransition.shared.whenOpenSettles {
                        withAnimation(.easeOut(duration: 0.25)) { lowerSectionsRevealed = true }
                    }
                }
            }
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
        if profile == nil, let cached = try? await model.volumeProfile(for: holding.ticker,
            currency: holding.quoteCurrency, cachedOnly: true), !Task.isCancelled {
            profile = cached
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
                accountContext = nil
                if priceHistory == nil, let cached = try? await model.marketPriceHistory(
                    for: holding.ticker, currency: holding.quoteCurrency ?? "USD", cachedOnly: true),
                   !Task.isCancelled {
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
                accountContext = nil
                priceHistory = loaded
                priceHistoryError = nil
                return
            }
            guard !Task.isCancelled else { return }
            // Refresh data without resetting the user's account selection,
            // chart range, scroll position or the independent section caches.
            if let previous = accountContext {
                selectedAccountKeys = selectedAccountKeys == previous.allAccountKeys
                    ? context.allAccountKeys
                    : selectedAccountKeys.intersection(context.allAccountKeys)
            } else {
                selectedAccountKeys = context.allAccountKeys
            }
            accountContext = context
            if priceHistory == nil, let cached = try? await model.securityPriceHistory(
                for: holding.ticker, accountKeys: context.allAccountKeys, cachedOnly: true),
               !Task.isCancelled {
                priceHistory = cached
                if !forceRefresh { isLoadingMarketData = false }
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
        let holding = displayedHolding
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
        guard let accountContext else { return }
        selectedAccountKeys = accountContext.allAccountKeys
    }

    private func toggleDetailAccount(_ accountKey: String) {
        guard let accountContext else { return }
        guard accountContext.allAccountKeys.contains(accountKey) else { return }

        if selectedAccountKeys.contains(accountKey) {
            selectedAccountKeys.remove(accountKey)
        } else {
            selectedAccountKeys.insert(accountKey)
        }
    }
}

/// `EnvironmentValues.refresh` is read-only. A detail reached from a refreshed
/// list (including nested heatmap sheets) can inherit its UIRefreshControl even
/// though the detail has no refresh action of its own. Remove only that native
/// control; UIKit still owns scrolling, rubber-banding and sheet dismissal.
struct HoldingDetailScrollBoundary: UIViewRepresentable {
    func makeUIView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: BoundaryView, context: Context) {
        view.removeInheritedRefreshControl()
        // SwiftUI can recreate its inherited control later in this same
        // update even when the content size does not require another layout.
        DispatchQueue.main.async { [weak view] in view?.removeInheritedRefreshControl() }
    }

    final class BoundaryView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            removeInheritedRefreshControl()
            // SwiftUI may install its refresh control after attaching content.
            DispatchQueue.main.async { [weak self] in self?.removeInheritedRefreshControl() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            removeInheritedRefreshControl()
        }

        func removeInheritedRefreshControl() {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    if scrollView.refreshControl != nil {
                        scrollView.refreshControl = nil
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

struct HoldingHeaderActionLabel: View {
    let title: String
    let asset: String
    var isLoading = false
    var body: some View {
        HStack(spacing: 8) {
            if isLoading { ChartSkeletonShape(width: 18, height: 18, cornerRadius: 9).frame(width: 24, height: 24).chartLoadingShimmer() }
            else { Image(asset).resizable().scaledToFit().frame(width: 24, height: 24) }
            Text(title).appText(.footnote, weight: .medium).lineLimit(1).minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Capsule())
    }
}

struct HoldingDetailCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .background {
                    // Glass is decoration inside the label, never a separate
                    // interactive layer around the close button.
                    Group {
                        if #available(iOS 26.0, *) {
                            Circle().fill(.clear)
                                .glassEffect(.regular.tint(Color.primary.opacity(0.06)), in: Circle())
                        } else {
                            Circle().fill(.regularMaterial)
                        }
                    }
                    .allowsHitTesting(false)
                }
                // A plain image button otherwise only hits the glyph. Make
                // the whole visible circle respond, including its empty center.
                .contentShape(.interaction, Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("关闭"))
        .accessibilityIdentifier("holding-detail-close")
    }
}

struct HoldingHeaderButtonStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.plain).foregroundStyle(.primary)
                .glassEffect(.regular.tint(Color.primary.opacity(0.06)).interactive(), in: Capsule())
        } else {
            content.buttonStyle(.plain).foregroundStyle(.primary)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

struct HoldingDetailAccountSelector: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme

    @ScaledMetric(relativeTo: .subheadline) private var labelSize = 14.0
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight = 16.0

    let options: [HoldingDetailAccountOption]
    let selectedAccountKeys: Set<String>
    let onSelectAll: () -> Void
    let onToggleAccount: (String) -> Void

    private var allAccountKeys: Set<String> {
        Set(options.map(\.id))
    }

    private var allMarketValue: Double {
        options.reduce(0) { $0 + $1.marketValue }
    }

    private var displayCurrency: String {
        options.first?.currency ?? "USD"
    }

    private var allUnrealized: Double? {
        guard options.allSatisfy({ $0.unrealized != nil }) else { return nil }
        return options.compactMap(\.unrealized).reduce(0, +)
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                accountButton(
                    id: "all",
                    title: L10n.text("All"),
                    marketValue: allMarketValue,
                    currency: displayCurrency,
                    unrealized: allUnrealized,
                    isSelected: selectedAccountKeys == allAccountKeys,
                    action: onSelectAll
                )

                ForEach(options) { option in
                    accountButton(
                        id: option.id,
                        title: conciseAccountName(L10n.accountName(option.displayName)),
                        marketValue: option.marketValue,
                        currency: option.currency,
                        unrealized: option.unrealized,
                        isSelected: selectedAccountKeys.contains(option.id),
                        action: { onToggleAccount(option.id) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
    }

    private func accountButton(
        id: String,
        title: String,
        marketValue: Double,
        currency: String,
        unrealized: Double?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // Figma 282:2115: title, then a tightly grouped pair of account figures.
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: labelSize, weight: .medium))
                    .tracking(0.28)
                    .lineLimit(1)
                    .frame(height: lineHeight, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DisplayFormat.money(marketValue, currency: currency, fractionDigits: 0))
                        .foregroundStyle(Color.primary.opacity(0.50))
                        .lineLimit(1)
                        .frame(height: lineHeight, alignment: .leading)
                    Text(unrealized.map { DisplayFormat.money($0, currency: currency, signed: true, fractionDigits: 0) } ?? "—")
                        .foregroundStyle(Color.primary.opacity(0.20))
                        .lineLimit(1)
                        .frame(height: lineHeight, alignment: .leading)
                        .accessibilityLabel(L10n.text("未实现盈亏"))
                }
                .font(Typography.number(size: labelSize, weight: .medium))
            }
            .textCase(.uppercase)
            .foregroundStyle(Color.primary)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 16)
            .padding(.trailing, 58)
            .padding(.vertical, 10)
            .frame(minWidth: 128, minHeight: 74, alignment: .leading)
            .modifier(AccountGlassSurface(isSelected: isSelected, colorScheme: colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("holding-detail-account-\(id)")
        .accessibilityLabel(
            L10n.text("\(title)，持仓市值 \(DisplayFormat.money(marketValue, currency: currency))")
        )
        .accessibilityValue(L10n.text("未实现盈亏") + " " + (unrealized.map { DisplayFormat.money($0, currency: currency, signed: true) } ?? "—"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func conciseAccountName(_ value: String) -> String {
        guard let component = value.components(separatedBy: "·").last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !component.isEmpty else { return value }
        return component
    }

    private struct AccountGlassSurface: ViewModifier {
        let isSelected: Bool
        let colorScheme: ColorScheme

        private var tint: Color {
            if isSelected {
                return Color(red: 0, green: 0.92, blue: 1).opacity(colorScheme == .dark ? 0.25 : 0.22)
            }
            return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05)
        }

        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content
                    .background {
                        if isSelected {
                            LinearGradient(colors: [Color.black.opacity(colorScheme == .dark ? 0.30 : 0.02), tint],
                                startPoint: .top, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                        }
                    }
                    .glassEffect(.regular.tint(isSelected ? .clear : tint).interactive(), in: .rect(cornerRadius: 22))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .background(tint, in: RoundedRectangle(cornerRadius: 22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.06), lineWidth: 0.75)
                    }
            }
        }
    }
}

struct HoldingDetailLoadingPlaceholder: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme

    private var skeletonColor: Color {
        CatfolioTheme.skeletonFill
    }

    private var skeletonSurface: Color {
        CatfolioTheme.subtleFill
    }

    private var skeletonCardBackground: Color {
        CatfolioTheme.surface(for: colorScheme)
    }

    private var accountSkeletonColor: Color {
        CatfolioTheme.skeletonFill
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(skeletonColor)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 7) {
                        skeletonBar(width: 64, height: 14)
                        HStack(spacing: 8) {
                            skeletonBar(width: 59, height: 10)
                            skeletonBar(width: 40, height: 10)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 7) {
                        skeletonBar(width: 70, height: 14)
                        skeletonBar(width: 82, height: 10)
                    }
                }
                .frame(height: 64)
                .padding(.horizontal, 20)

                StandardLineChartSkeleton(
                    leadingLineOverflow: 30,
                    trailingEndpointInset: 9,
                    lineWidths: [2.5]
                )
                    .frame(height: SecurityPriceChartState.plotHeight)

                ChartTimeRangePickerSkeleton()
                    .frame(height: 62)

                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 7) {
                                skeletonBar(
                                    width: index == 1 ? 53 : (index == 2 ? 24 : 28),
                                    height: 11,
                                    color: accountSkeletonColor
                                )
                                skeletonBar(width: 68, height: 11, color: accountSkeletonColor)
                            }
                            .padding(.horizontal, 24)
                            .frame(minWidth: 116, minHeight: 64, alignment: .leading)
                            .background(skeletonSurface, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .scrollIndicators(.hidden)
                .frame(height: 92)
            }
            .padding(.top, 15)

            LazyVStack(spacing: 64) {
                volumeProfileSkeleton
                fiftyTwoWeekSkeleton
                dataSkeleton
                financialSkeleton
                predictionMarketsSkeleton
            }
            .padding(.horizontal, HoldingDetailCardStyle.pageInset)
            .padding(.top, 40)
            .padding(.bottom, 72)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("正在加载个股详情"))
    }

    private var volumeProfileSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    skeletonBar(width: 142, height: 15)
                    Spacer()
                    skeletonBar(width: 89, height: 12)
                }
                .frame(height: 23)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(skeletonSurface)

                    VStack(alignment: .leading) {
                        skeletonBar(width: 66, height: 10, color: accountSkeletonColor)
                        Spacer()
                        skeletonBar(width: 56, height: 10, color: accountSkeletonColor)
                    }
                    .padding(10)
                }
                .frame(height: 303)
            }

            VStack(alignment: .leading, spacing: 6) {
                Capsule()
                    .fill(skeletonColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
                Capsule()
                    .fill(skeletonColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
            }
            .frame(height: 48, alignment: .center)
        }
        .frame(height: 410, alignment: .top)
    }

    private var fiftyTwoWeekSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                skeletonBar(width: 355, height: 15)
            }
            .frame(height: 23, alignment: .center)

            HStack(alignment: .center, spacing: 3.1) {
                ForEach(0..<51, id: \.self) { index in
                    Capsule()
                        .fill(skeletonColor)
                        .frame(width: index == 25 ? 7 : 4, height: index == 25 ? 110 : 98)
                }
            }
            .frame(height: 110)
            .padding(.top, 20)

            HStack {
                skeletonBar(width: 82, height: 11)
                Spacer()
                skeletonBar(width: 90, height: 11)
            }
            .frame(height: 16)
            .padding(.top, 7)
        }
        .frame(height: 176, alignment: .top)
    }

    private var dataSkeleton: some View {
        let rows: [(HoldingDataIcon, CGFloat, CGFloat)] = [
            (.value, 45, 40),
            (.returnValue, 56, 30),
            (.cost, 36, 30),
            (.fxImpact, 72, 49),
            (.proportion, 93, 46),
            (.unrealisedProfitLoss, 117, 143),
        ]

        return VStack(alignment: .leading, spacing: 0) {
            skeletonBar(width: 46, height: 15)
                .frame(height: 23, alignment: .center)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    dataSkeletonRow(
                        icon: row.0,
                        labelWidth: row.1,
                        valueWidth: row.2,
                        isCombinedValue: index == rows.count - 1,
                        isAlternating: index.isMultiple(of: 2) == false
                    )
                }
            }
            .padding(.top, 20)
        }
        .frame(height: 307, alignment: .top)
    }

    private var financialSkeleton: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                skeletonBar(width: 79, height: 14)
                VStack(alignment: .leading, spacing: 6) {
                    skeletonBar(width: 237, height: 10)
                    skeletonBar(width: 184, height: 10)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(skeletonColor)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 105, maxHeight: 105, alignment: .leading)
        .background(skeletonCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(skeletonColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var predictionMarketsSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                skeletonBar(width: 166, height: 14)
                Spacer(minLength: 8)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(skeletonColor)
                    .frame(width: 24, height: 24)
            }
            .frame(height: 24)

            VStack(spacing: 20) {
                ForEach(0..<5, id: \.self) { index in
                    predictionMarketRowSkeleton(index: index)
                }
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        // The real card no longer ends in a disclaimer row (it moved to the
        // page footer), so neither does its placeholder: 563 less that row.
        .frame(maxWidth: .infinity, minHeight: 507, maxHeight: 507, alignment: .topLeading)
        .background(skeletonCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(skeletonColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func dataSkeletonRow(
        icon: HoldingDataIcon,
        labelWidth: CGFloat,
        valueWidth: CGFloat,
        isCombinedValue: Bool,
        isAlternating: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Group {
                if let assetName = icon.assetName {
                    Image(assetName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                } else {
                    Image(systemName: icon.systemName)
                        .font(.system(size: icon.pointSize, weight: .regular))
                }
            }
            .foregroundStyle(skeletonColor)
            .frame(width: 24, height: 24)

            skeletonBar(width: labelWidth, height: 10)

            Spacer(minLength: 8)

            if isCombinedValue {
                HStack(spacing: 8) {
                    skeletonBar(width: 81, height: 10)
                    Circle()
                        .fill(skeletonColor)
                        .frame(width: 4, height: 4)
                    skeletonBar(width: 42, height: 10)
                }
            } else {
                skeletonBar(width: valueWidth, height: 10)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 44)
        .background(
            isAlternating ? skeletonSurface : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func predictionMarketRowSkeleton(index: Int) -> some View {
        let statWidths: [CGFloat] = [47, 53, 47, 47, 47]

        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    skeletonBar(width: 260, height: 10)
                    skeletonBar(width: 260, height: 10)
                }
                .frame(height: 36, alignment: .top)

                HStack(spacing: 8) {
                    skeletonBar(width: 63, height: 9)
                    Circle()
                        .fill(skeletonColor)
                        .frame(width: 4, height: 4)
                    skeletonBar(width: 70, height: 9)
                }
                .frame(height: 16)
            }
            .frame(width: 260, alignment: .leading)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                skeletonBar(width: statWidths[index], height: 10)
                skeletonBar(width: index == 1 ? 19 : 23, height: 9)
            }
            .frame(height: 38, alignment: .topTrailing)
        }
        .frame(height: 60, alignment: .top)
    }

    private func skeletonBar(width: CGFloat, height: CGFloat, color: Color? = nil) -> some View {
        Capsule()
            .fill(color ?? skeletonColor)
            .frame(width: width, height: height)
    }
}
