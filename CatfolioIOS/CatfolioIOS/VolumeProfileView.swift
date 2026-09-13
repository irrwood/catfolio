import SwiftUI
import UIKit

private typealias HoldingDetailTypography = LegacyType

struct HoldingDetailView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    let holding: Holding
    /// Set only where the presenter has no state of its own to key the open
    /// click to — a `NavigationLink` push. Sheet presenters click at the tap.
    var confirmsOpen = false
    @State private var hasConfirmedOpen = false

    @State private var profile: VolumeProfile?
    @State private var errorMessage: String?
    @State private var priceHistory: SecurityPriceHistory?
    @State private var priceHistoryError: String?
    @State private var accountContext: HoldingDetailAccountContext?
    @State private var selectedAccountKeys: Set<String> = []
    @State private var presentationReady = false
    @State private var marketDataRevision = 0
    @State private var completedMarketDataRevision: Int?
    @State private var isLoadingMarketData = true

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

    private var showsInitialLoadingPlaceholder: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-security-detail-loading")
    }

    private var showsDataDesignPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-security-data")
    }

    private var showsVolumeFocusedPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--show-volume-focused")
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
                    HoldingPositionDetails(holding: displayedHolding)
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
                    // The lower, genuinely long section remains a LazyVStack.
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
                                onRefresh: { marketDataRevision += 1 }
                            )
                        }
                    }

                    LazyVStack(spacing: 64) {
                        if let profile {
                            VolumePriceChart(
                                profile: profile,
                                holding: displayedHolding,
                                showsHoldingCost: showsPosition
                            )

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
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.text("Volume Profile"))
                                    .font(HoldingDetailTypography.medium(19, relativeTo: .headline))
                                StatusNotice(text: errorMessage, kind: .info)
                            }
                        } else if presentationReady {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(L10n.text("正在读取成交量与 52 周数据…"))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
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
                            refreshRevision: marketDataRevision)

                        if showsPosition {
                            HoldingPositionDetails(holding: displayedHolding)
                        }
                    }
                    // One 16pt page margin below the price chart, the same as
                    // the research cards; only the header chart keeps its own.
                    .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                    .padding(.top, showsVolumeFocusedPreview ? 28 : 40)

                    HoldingResearchSection(holding: holding,
                        price: priceHistory?.latestAvailablePrice ?? holding.quotePrice)
                    .id("\(holding.ticker)|\(appLocale.identifier)")
                    .padding(.bottom, 72)
                    }
                }
                }
                // This must be inside the scroll content: only this scroll
                // view loses inherited refresh, never its presenting page or
                // the independently refreshable analyst/financial sheets.
                .background(HoldingDetailScrollBoundary())
            }
            .accessibilityIdentifier("holding-detail-scroll")
            // Transparent: the ground is the presentation's, so the one
            // background there is is the one the system rounds.
            .background {
                PresentationDidAppearReader {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { presentationReady = true }
                }
            }
            // Start cache-backed work as soon as SwiftUI inserts the sheet,
            // while the native presentation animation is still running. The
            // available holding header renders immediately; only genuinely
            // missing chart sections show their own loading treatment.
            .task(id: marketDataRevision) {
                guard completedMarketDataRevision != marketDataRevision else { return }
                isLoadingMarketData = true
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
        guard forceRefresh || profile == nil else { return }
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
        guard forceRefresh || priceHistory == nil else { return }
        do {
            let context: HoldingDetailAccountContext
            do {
                context = try await model.holdingDetailAccountContext(for: holding.ticker)
            } catch LocalPortfolioError.noPortfolio {
                // Held in no account: the market's history stands alone,
                // with no accounts to pick and no trades to mark.
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

/// Owns the fast-changing chart selection so dragging never invalidates the
/// volume profile, 52-week range, financials and analyst sections below it.
struct HoldingDetailPriceSection: View {
    let holding: Holding
    let marketTodayChange: Double?
    let priceHistory: SecurityPriceHistory?
    let priceHistoryError: String?
    let presentationReady: Bool
    let averageCost: Double?
    let selectedAccountKeys: Set<String>
    var accountOptions: [HoldingDetailAccountOption] = []
    var onSelectAll: () -> Void = {}
    var onToggleAccount: (String) -> Void = { _ in }
    var isRefreshing = false
    var refreshError: String?
    var onRefresh: () -> Void = {}

    @State private var priceSelection: SecurityPriceSelection?
    @State private var explanation: SecurityPaperRequest?
    @State private var explanationAnchor = SecurityPaperSourceAnchor()

    private var movement: SecurityPriceMoveContext? {
        guard let priceHistory else { return nil }
        return SecurityPriceMoveContext.latestSession(history: priceHistory, name: holding.shortName)
    }

    var body: some View {
        VStack(spacing: 0) {
            HoldingDetailHeader(
                holding: holding,
                marketTodayChange: marketTodayChange,
                selectedPrice: priceSelection?.price ?? priceHistory?.latestAvailablePrice,
                selectedReturn: priceSelection?.returnPercent,
                isRefreshing: isRefreshing,
                onRefresh: onRefresh
            )

            if let priceHistory {
                SecurityPriceChart(
                    history: priceHistory,
                    averageCost: averageCost,
                    selectedAccountKeys: selectedAccountKeys,
                    onSelectionChange: { selection in
                        guard priceSelection != selection else { return }
                        priceSelection = selection
                    }
                )
            } else if let priceHistoryError {
                SecurityPriceChartState(
                    title: L10n.text("暂无价格走势"),
                    message: priceHistoryError,
                    isLoading: false
                )
            } else if presentationReady {
                SecurityPriceChartState(
                    title: L10n.text("正在读取价格走势"),
                    message: L10n.text("正在整理历史行情与买卖记录"),
                    isLoading: true
                )
            } else {
                Color.clear
                    .frame(height: SecurityPriceChartState.fixedHeight)
                    .accessibilityHidden(true)
            }

            if accountOptions.count > 1 {
                HoldingDetailAccountSelector(options: accountOptions, selectedAccountKeys: selectedAccountKeys,
                    onSelectAll: onSelectAll, onToggleAccount: onToggleAccount)
            }

            HStack(spacing: 12) {
                Button {
                    guard let movement,
                          let request = SecurityPaperRequest(context: movement, sourceFrame: explanationAnchor.frame) else { return }
                    // Ask at the tap, before the cover is even inserted, so the
                    // whole entrance and flip run while the note is researched.
                    // The paper's own `start` then joins this request.
                    SecurityDailyMoveStore.shared.start(movement)
                    SecurityDailyMovePresentation.withoutSystemTransition { explanation = request }
                } label: {
                    HoldingHeaderActionLabel(title: movement?.noteTitle ?? L10n.text("今天有什么动静？"),
                        asset: "HoldingWhyMove")
                }
                .modifier(HoldingHeaderButtonStyle())
                .disabled(movement == nil)
                .background(SecurityPaperSourceReader(anchor: explanationAnchor))
                .accessibilityIdentifier("holding-detail-why-move")
                .accessibilityHint(movement?.intervalText ?? L10n.text("等待带日期的价格走势"))
                // Refreshing is a tap on the price above, not a button here.
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if let refreshError {
                Text(refreshError).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 20)
            }
        }
        .fullScreenCover(item: $explanation) { request in
            SecurityDailyMovePaper(context: request.context, logoSymbol: holding.logoSymbol, sourceFrame: request.sourceFrame)
        }
        .onChange(of: selectedAccountKeys) { _, _ in
            priceSelection = nil
        }
    }
}

private struct HoldingHeaderActionLabel: View {
    let title: String
    let asset: String
    var isLoading = false
    var body: some View {
        HStack(spacing: 8) {
            if isLoading { ProgressView().controlSize(.small).frame(width: 24, height: 24) }
            else { Image(asset).resizable().scaledToFit().frame(width: 24, height: 24) }
            Text(title).appText(.footnote, weight: .medium).lineLimit(1).minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Capsule())
    }
}

private struct HoldingHeaderButtonStyle: ViewModifier {
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

private struct HoldingDetailAccountSelector: View {
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

private struct HoldingDetailModalHandle: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            colorScheme == .dark ? Color.black : Color.white

            Capsule()
                .fill(CatfolioTheme.skeletonEmphasis)
                .frame(width: 32, height: 4)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 15)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HoldingDetailLoadingPlaceholder: View {
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
                    showsSeries: false
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

private struct SecurityPriceChartState: View {
    @Environment(\.locale) private var appLocale
    static let plotHeight: CGFloat = 293
    static let fixedHeight: CGFloat = plotHeight + 62

    let title: String
    let message: String
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 0) {
                    StandardLineChartSkeleton(
                        leadingLineOverflow: 30,
                        trailingEndpointInset: 9,
                        showsSeries: false
                    )
                        .frame(height: Self.plotHeight)

                    ChartTimeRangePickerSkeleton()
                        .frame(height: 62)
                }
            } else {
                VStack(spacing: 0) {
                    StandardLineChartPlaceholder(
                        title: title,
                        message: message,
                        isLoading: false,
                        maximumLines: 2
                    )
                    .frame(height: Self.plotHeight)

                    Color.clear
                        .frame(height: 62)
                }
            }
        }
        .frame(height: Self.fixedHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("价格走势，\(title)，\(message)"))
    }
}

private struct SecurityPriceSelection: Equatable {
    // Only a historical touch/measurement overrides the independent latest quote.
    let price: Double?
    let returnPercent: Double
    let startDate: Date
    let endDate: Date
    let startPrice: Double
    let endPrice: Double
    let rangeLabel: String
    let isIntraday: Bool
}

private struct SecurityPriceChart: View {
    @Environment(\.locale) private var appLocale
    let history: SecurityPriceHistory
    let averageCost: Double?
    let selectedAccountKeys: Set<String>
    let onSelectionChange: (SecurityPriceSelection?) -> Void
    @State private var prepared: SecurityPricePreparedData?
    @State private var isPreparing = true
    @State private var range: ChartTimeRange
    @State private var selectedDate: Date?
    @State private var measuredRange: ChartDateRange?
    @State private var lastHeaderPublishTime: TimeInterval = 0

    init(
        history: SecurityPriceHistory,
        averageCost: Double?,
        selectedAccountKeys: Set<String>,
        onSelectionChange: @escaping (SecurityPriceSelection?) -> Void = { _ in }
    ) {
        self.history = history
        self.averageCost = averageCost
        self.selectedAccountKeys = selectedAccountKeys
        self.onSelectionChange = onSelectionChange
        let arguments = ProcessInfo.processInfo.arguments
        _range = State(initialValue: arguments.contains("--show-security-chart-1d")
            ? .oneDay
            : arguments.contains("--show-security-chart-max") ? .maximum : .oneYear)
    }

    private var data: SecurityPriceRangeData {
        prepared?.data(for: range) ?? .empty
    }

    private var selectedPoint: SecurityPricePlotPoint? {
        guard let selectedDate else { return data.points.last }
        return data.nearest(to: selectedDate)
    }

    private var selectionIndicatorLabel: String? {
        if let measuredRange {
            return "\(dateLabel(measuredRange.start)) – \(dateLabel(measuredRange.end))"
        }
        guard selectedDate != nil, let selectedPoint else { return nil }
        return dateLabel(selectedPoint.date)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                // Blank only before the first preparation. Re-preparing for
                // another account keeps the line on screen and lets the chart
                // morph to the new data; swapping in a blank tore the chart
                // down and replayed its entrance — the flash on account change.
                if isPreparing && prepared == nil {
                    Color.clear
                } else if data.points.count > 1 {
                    SecurityPricePlot(
                        data: data,
                        currency: history.currency,
                        transitionKey: "\(range.rawValue)|\(selectionSignature)",
                        selectedPoint: selectedDate == nil && measuredRange == nil ? nil : selectedPoint,
                        measuredRange: measuredRange,
                        selectionIndicatorLabel: selectionIndicatorLabel,
                        onSelect: { date in
                            guard measuredRange != nil || selectedDate != date else { return }
                            measuredRange = nil
                            selectedDate = date
                            publishInteractiveSelection(selection(at: date))
                        },
                        onMeasure: { measuredRange in
                            guard self.measuredRange != measuredRange else { return }
                            self.measuredRange = measuredRange
                            selectedDate = measuredRange.end
                            publishInteractiveSelection(selection(for: measuredRange))
                        },
                        onInteractionEnded: { _ in clearInteraction() }
                    )
                } else {
                    StandardLineChartPlaceholder(
                        title: L10n.text("暂无日内行情"),
                        message: L10n.text("Massive 与 Yahoo 暂未返回分钟级数据"),
                        isLoading: false,
                        maximumLines: 2
                    )
                }
            }
            .frame(height: SecurityPriceChartState.plotHeight)
            .accessibilityLabel(L10n.text("\(history.ticker) 价格走势，买入点为绿色圆环，卖出点为黄色圆环，横向玻璃线为持仓成本"))

            ChartTimeRangePicker(selection: $range, isDisabled: isPreparing)
            .frame(height: 62)
            .accessibilityLabel(L10n.text("价格走势时间范围"))
        }
        .frame(height: SecurityPriceChartState.fixedHeight, alignment: .top)
        .onChange(of: range) { _, _ in clearInteraction() }
        .onChange(of: selectedAccountKeys) { _, _ in clearInteraction() }
        .onDisappear { onSelectionChange(nil) }
        .task(id: preparationSignature) {
            isPreparing = true
            let history = history
            let averageCost = averageCost
            let selectedAccountKeys = selectedAccountKeys
            let prepared = await Task.detached(priority: .userInitiated) {
                SecurityPricePreparedData(
                    history: history,
                    averageCost: averageCost,
                    selectedAccountKeys: selectedAccountKeys
                )
            }.value
            guard !Task.isCancelled else { return }
            self.prepared = prepared
            isPreparing = false
            if selectedDate == nil, measuredRange == nil {
                onSelectionChange(rangeSelection)
            }
        }
        .task(id: "\(range.rawValue)|\(selectionSignature)") {
            // Publish the selected time window even when the user is not
            // touching the chart. The header then uses the same start/end
            // basis as the line currently on screen.
            await Task.yield()
            guard !Task.isCancelled, !isPreparing,
                  selectedDate == nil, measuredRange == nil else { return }
            onSelectionChange(rangeSelection)
        }
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--show-security-chart-1d") { range = .oneDay }
            if arguments.contains("--show-security-chart-max") { range = .maximum }
        }
    }

    private var selectionSignature: String {
        selectedAccountKeys.sorted().joined(separator: "|")
    }

    private var preparationSignature: String {
        let lastDaily = history.points.last
        let lastMinute = history.intradayPoints.last
        return [
            history.ticker,
            "\(history.points.count):\(lastDaily?.dateText ?? "-"):\(lastDaily?.close ?? 0)",
            "\(history.intradayPoints.count):\(lastMinute?.dateText ?? "-"):\(lastMinute?.close ?? 0)",
            "\(history.trades.count)",
            "\(averageCost ?? 0)",
            selectionSignature,
        ].joined(separator: "|")
    }

    private func dateLabel(_ date: Date) -> String {
        data.isIntraday
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private func selection(at date: Date) -> SecurityPriceSelection? {
        guard let first = data.points.first, let point = data.nearest(to: date) else { return nil }
        return makeSelection(start: first, end: point, price: point.price, label: range.rawValue)
    }

    private var rangeSelection: SecurityPriceSelection? {
        guard let first = data.points.first, let latest = data.points.last else { return nil }
        return makeSelection(start: first, end: latest, price: nil, label: range.rawValue)
    }

    private func selection(for range: ChartDateRange) -> SecurityPriceSelection? {
        guard let start = data.nearest(to: range.start),
              let end = data.nearest(to: range.end),
              start.price > 0 else { return nil }
        return makeSelection(start: start, end: end, price: end.price, label: L10n.text("区间测量"))
    }

    private func makeSelection(start: SecurityPricePlotPoint, end: SecurityPricePlotPoint,
                               price: Double?, label: String) -> SecurityPriceSelection {
        SecurityPriceSelection(price: price, returnPercent: (end.price / start.price - 1) * 100,
            startDate: start.date, endDate: end.date, startPrice: start.price, endPrice: end.price,
            rangeLabel: label, isIntraday: data.isIntraday)
    }

    private func clearInteraction() {
        selectedDate = nil
        measuredRange = nil
        lastHeaderPublishTime = 0
        onSelectionChange(rangeSelection)
    }

    /// The crosshair and bubble stay local and update for every snapped point.
    /// The large price text above the chart does not need 120 writes/second;
    /// bounding that parent-facing update prevents repeated header layout.
    private func publishInteractiveSelection(_ selection: SecurityPriceSelection?) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastHeaderPublishTime >= 1.0 / 30.0 else { return }
        lastHeaderPublishTime = now
        onSelectionChange(selection)
    }
}

private struct SecurityPriceCostLegend: View {
    @Environment(\.locale) private var appLocale
    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(CatfolioStyle.green)
                        .frame(width: 4, height: 2)
                }
            }
            Text(L10n.text("成本"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("绿色虚线为持仓成本"))
    }
}

private struct SecurityPricePlot: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme

    let data: SecurityPriceRangeData
    let currency: String
    let transitionKey: String
    let selectedPoint: SecurityPricePlotPoint?
    let measuredRange: ChartDateRange?
    let selectionIndicatorLabel: String?
    let onSelect: (Date) -> Void
    let onMeasure: (ChartDateRange) -> Void
    let onInteractionEnded: (Int) -> Void

    var body: some View {
        let priceSeries = StandardLineChartSeries(
            id: "price",
            points: data.sampledPoints.map {
                StandardLineChartPoint(id: $0.id, date: $0.date, value: $0.price)
            },
            color: CatfolioPalette.securityPriceLine,
            lineWidth: 3,
            selectionRadius: 4,
            latestPointRadius: 5,
            latestPointColor: colorScheme == .dark ? .white : Color(red: 10 / 255, green: 11 / 255, blue: 12 / 255),
            latestPointUsesGlass: false
        )
        let costReference = data.averageCost.map {
            StandardLineChartReferenceLine(
                id: "cost",
                value: $0,
                color: CatfolioPalette.tradeBuy,
                label: axisPriceLabel($0),
                lineWidth: 2,
                minimumAxisLabelSpacing: 20
            )
        }
        StandardLineChart(
            series: [priceSeries],
            interactionDates: data.points.map(\.date),
            domain: data.domain,
            yTicks: (0..<4).map { index in
                let fraction = Double(index) / 3
                return data.domain.upperBound
                    - (data.domain.upperBound - data.domain.lowerBound) * fraction
            },
            axisWidth: 49,
            topInset: 15,
            bottomHeight: 0,
            leadingLineOverflow: 30,
            gridOpacity: 0.08,
            transitionKey: transitionKey,
            dataTransition: .viewportZoom,
            animatesInitialAppearance: true,
            markers: data.trades.map { trade in
                StandardLineChartMarker(
                    id: trade.id,
                    point: StandardLineChartPoint(
                        id: trade.id,
                        date: trade.point.date,
                        value: trade.point.price
                    ),
                    color: trade.trade.isBuy
                        ? CatfolioPalette.tradeBuy
                        : (colorScheme == .dark
                            ? CatfolioPalette.tradeSellDark
                            : CatfolioPalette.tradeSellLight),
                    radius: 4,
                    outlineColor: nil,
                    outlineWidth: 2,
                    style: .ring,
                    seriesID: "price"
                )
            },
            referenceLines: [costReference].compactMap { $0 },
            selectedDate: selectedPoint?.date,
            measuredRange: measuredRange,
            selectionIndicatorLabel: selectionIndicatorLabel,
            selectionSeriesIDs: ["price"],
            rangeSeriesIDs: ["price"],
            rangePrimarySeriesID: "price",
            dimsFutureDuringSelection: true,
            yAxisFont: Typography.number(.footnote),
            yAxisColor: Color.primary.opacity(0.20),
            referenceAxisFont: Typography.number(.footnote, weight: .semibold),
            yAxisLabel: axisPriceLabel,
            xAxisLabel: { _ in "" },
            onSelect: onSelect,
            onMeasure: onMeasure,
            onInteractionEnded: onInteractionEnded
        )
    }

    private func axisPriceLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private func shortDate(_ date: Date) -> String {
        if data.isIntraday {
            return date.formatted(.dateTime.hour().minute())
        }
        if data.isMaximumRange {
            return date.formatted(.dateTime.year())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private final class SecurityPricePreparedData: @unchecked Sendable {
    private let ranges: [ChartTimeRange: SecurityPriceRangeData]

    init(
        history: SecurityPriceHistory,
        averageCost: Double?,
        selectedAccountKeys: Set<String>
    ) {
        ranges = Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases.map {
            ($0, SecurityPriceRangeData(
                history: history,
                range: $0,
                averageCost: averageCost,
                selectedAccountKeys: selectedAccountKeys
            ))
        })
    }

    func data(for range: ChartTimeRange) -> SecurityPriceRangeData {
        ranges[range] ?? ranges[.maximum] ?? .empty
    }
}

private struct SecurityPriceRangeData: @unchecked Sendable {
    struct TradePoint: Identifiable {
        let trade: SecurityTrade
        let point: SecurityPricePlotPoint
        var id: String { trade.id }
    }

    let points: [SecurityPricePlotPoint]
    let sampledPoints: [SecurityPricePlotPoint]
    let trades: [TradePoint]
    let domain: ClosedRange<Double>
    let averageCost: Double?
    let isIntraday: Bool
    let isMaximumRange: Bool

    static let empty = SecurityPriceRangeData(
        points: [],
        sampledPoints: [],
        trades: [],
        domain: -1...1,
        averageCost: nil,
        isIntraday: false,
        isMaximumRange: false
    )

    private init(
        points: [SecurityPricePlotPoint],
        sampledPoints: [SecurityPricePlotPoint],
        trades: [TradePoint],
        domain: ClosedRange<Double>,
        averageCost: Double?,
        isIntraday: Bool,
        isMaximumRange: Bool
    ) {
        self.points = points
        self.sampledPoints = sampledPoints
        self.trades = trades
        self.domain = domain
        self.averageCost = averageCost
        self.isIntraday = isIntraday
        self.isMaximumRange = isMaximumRange
    }

    init(
        history: SecurityPriceHistory,
        range: ChartTimeRange,
        averageCost: Double?,
        selectedAccountKeys: Set<String>
    ) {
        let usesIntraday = range == .oneDay
        isIntraday = usesIntraday
        isMaximumRange = range == .maximum
        let source = usesIntraday ? history.intradayPoints : history.chartDailyPoints
        let all = source.map {
            SecurityPricePlotPoint(dateText: $0.dateText, date: $0.date, price: $0.close, returnPercent: 0)
        }.sorted { $0.date < $1.date }
        let filtered = Self.filtered(all, range: range)
        let rangeBase: Double? = {
            guard usesIntraday, let sessionStart = filtered.first?.date else {
                return filtered.first?.price
            }
            let sessionDay = DayDateCodec.string(from: sessionStart)
            return history.points
                .filter { $0.dateText < sessionDay }
                .max(by: { $0.dateText < $1.dateText })?
                .close ?? filtered.first?.price
        }()
        guard let base = rangeBase, base > 0 else {
            points = []
            sampledPoints = []
            trades = []
            domain = -1...1
            self.averageCost = nil
            return
        }
        let normalizedPoints = filtered.map {
            SecurityPricePlotPoint(
                dateText: $0.dateText,
                date: $0.date,
                price: $0.price,
                returnPercent: ($0.price / base - 1) * 100
            )
        }
        let step = max(1, Int(ceil(Double(normalizedPoints.count) / 150)))
        var sampled = Array(stride(from: 0, to: normalizedPoints.count, by: step)).map { normalizedPoints[$0] }
        if sampled.last?.id != normalizedPoints.last?.id, let last = normalizedPoints.last { sampled.append(last) }

        let visibleStart = normalizedPoints.first?.date ?? .distantFuture
        let visibleEnd = normalizedPoints.last?.date ?? .distantPast
        let visibleTrades: [TradePoint] = usesIntraday ? [] : history.trades.compactMap { trade -> TradePoint? in
            guard !trade.accountKeys.isDisjoint(with: selectedAccountKeys) else { return nil }
            guard trade.date >= visibleStart, trade.date <= visibleEnd,
                  let point = Self.nearestPoint(to: trade.date, in: normalizedPoints) else { return nil }
            return TradePoint(trade: trade, point: point)
        }

        let visibleCost = averageCost.flatMap { cost -> Double? in
            guard cost.isFinite, cost > 0 else { return nil }
            return cost
        }
        let values = normalizedPoints.map(\.price) + [visibleCost].compactMap { $0 }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let minimumSpan = max(abs(maximum) * 0.02, 0.01)
        let span = max(maximum - minimum, minimumSpan)
        let padding = span * 0.12
        points = normalizedPoints
        // Keep every annotated vertex in the rendered polyline. Otherwise an
        // exact trade-day quote can float off a downsampled line even at rest.
        sampledPoints = Dictionary(grouping: sampled + visibleTrades.map(\.point), by: \.date)
            .values.compactMap(\.first).sorted { $0.date < $1.date }
        trades = visibleTrades
        domain = (minimum - padding)...(maximum + padding)
        self.averageCost = visibleCost
    }

    func nearest(to date: Date) -> SecurityPricePlotPoint? {
        Self.nearestPoint(to: date, in: points)
    }

    private static func filtered(
        _ points: [SecurityPricePlotPoint],
        range: ChartTimeRange
    ) -> [SecurityPricePlotPoint] {
        guard let last = points.last?.date else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start: Date?
        switch range {
        case .oneDay: start = nil
        case .oneWeek: start = calendar.date(byAdding: .day, value: -7, to: last)
        case .oneMonth: start = calendar.date(byAdding: .month, value: -1, to: last)
        case .twoMonths: start = calendar.date(byAdding: .month, value: -2, to: last)
        case .yearToDate:
            start = calendar.date(from: DateComponents(
                year: calendar.component(.year, from: last), month: 1, day: 1
            ))
        case .sixMonths: start = calendar.date(byAdding: .month, value: -6, to: last)
        case .oneYear: start = calendar.date(byAdding: .year, value: -1, to: last)
        case .twoYears: start = calendar.date(byAdding: .year, value: -2, to: last)
        case .fiveYears: start = calendar.date(byAdding: .year, value: -5, to: last)
        case .maximum: start = nil
        }
        guard let start else { return points }
        let result = points.filter { $0.date >= start }
        return result.count > 1 ? result : Array(points.suffix(2))
    }

    private static func nearestPoint(
        to date: Date,
        in points: [SecurityPricePlotPoint]
    ) -> SecurityPricePlotPoint? {
        guard !points.isEmpty else { return nil }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return points[0] }
        guard lower < points.count else { return points[points.count - 1] }
        let before = points[lower - 1]
        let after = points[lower]
        return abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
    }
}

private struct SecurityPricePlotPoint: Identifiable {
    let dateText: String
    let date: Date
    let price: Double
    let returnPercent: Double

    var id: String { dateText }
}

struct HoldingDetailHeader: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var priceSize = 22.0
    @ScaledMetric(relativeTo: .headline) private var nameSize = 18.0
    let holding: Holding
    let marketTodayChange: Double?
    let selectedPrice: Double?
    let selectedReturn: Double?
    /// Tapping the price refreshes the quote; there is no separate button.
    var isRefreshing = false
    var onRefresh: (() -> Void)? = nil
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var refreshTaps = 0

    private var todayChange: Double? {
        selectedReturn ?? holding.todayChangePercent ?? marketTodayChange
    }

    private var displayedPrice: Double {
        selectedPrice ?? holding.quotePrice
    }

    private var displayName: String {
        guard let original = holding.displayName.components(separatedBy: " / ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !original.isEmpty else { return holding.ticker }
        return original
    }

    private var identityLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(Typography.text(size: nameSize, weight: .semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.76)
                    identityLayout {
                        // No count for a security with no shares behind it:
                        // "0" read as a position that had been sold.
                        if holding.shares > 0 {
                            Text(DisplayFormat.shares(holding.shares)).appNumber(.label, monospaced: false)
                        }
                        Text(holding.ticker.uppercased()).appCaps(.label)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                        .frame(width: 48, height: 48)
                }
                .modifier(HoldingHeaderButtonStyle())
                .accessibilityLabel(L10n.text("关闭"))
                .accessibilityIdentifier("holding-detail-close")
            }
            if let onRefresh {
                Button {
                    refreshTaps += 1
                    onRefresh()
                } label: {
                    quote
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .sensoryFeedback(.impact(weight: .light), trigger: refreshTaps) { _, _ in hapticsEnabled }
                .accessibilityHint(L10n.text("刷新行情"))
                .accessibilityIdentifier("holding-detail-refresh")
            } else {
                quote
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quote: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(DisplayFormat.money(displayedPrice, currency: holding.quoteCurrency ?? "USD"))
                        .font(Typography.number(size: priceSize, weight: .semibold))
                        .numericTransition(displayedPrice)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .allowsTightening(true)
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
                if let todayChangePercent = todayChange {
                    Text(DisplayFormat.percent(todayChangePercent))
                        .appNumber(.heading)
                        .foregroundStyle(
                            todayChangePercent >= 0
                                ? CatfolioTheme.gainDefault
                                : CatfolioTheme.lossDefault
                        )
                } else {
                    Text(L10n.text("Return —"))
                        .font(HoldingDetailTypography.medium(13, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
    }
}

private struct HoldingPositionDetails: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding

    /// Resolved off the main thread, because reaching for it here would not
    /// be a lookup — it is the first touch of a 6 MB package, and on the
    /// launch where nothing has decoded it yet that cost lands inside
    /// whichever frame the section first appears in. The row is absent until
    /// the answer arrives, which is the correct state anyway: most holdings
    /// are shares and never get one.
    @State private var expenseRatio: Double?

    private var costBasis: Double {
        holding.marketValue - holding.unrealized
    }

    private var profitColor: Color {
        holding.unrealized >= 0
            ? CatfolioTheme.gainDefault
            : CatfolioTheme.lossDefault
    }

    /// The fund's own annual charge, and what that costs on this position.
    ///
    /// A percentage alone is unreadable at this scale — 0.03% and 0.30% look
    /// alike — so the money it comes to at the current value is shown beside
    /// it. It is a run rate at today's price, not a fee already paid, and not
    /// a figure to subtract from a return that already has it deducted.
    private var expenseRatioRow: HoldingDataRow.Model? {
        guard let expenseRatio else { return nil }
        let rate = (expenseRatio * 100).formatted(.number.precision(.fractionLength(2...4)))
        let annual = DisplayFormat.money(holding.marketValue * expenseRatio, fractionDigits: 2)
        return .init(
            title: L10n.text("Expense Ratio"),
            icon: .expenseRatio,
            value: "\(rate)%  ·  \(annual)/yr"
        )
    }

    private func loadExpenseRatio() async {
        let ticker = holding.ticker
        expenseRatio = await Task.detached(priority: .userInitiated) {
            try? FundFeeCatalog.bundled.get().fee(brokerSymbol: ticker)?.rate
        }.value
    }

    private var rows: [HoldingDataRow.Model] {
        [
            .init(
                title: L10n.text("Value"),
                icon: .value,
                value: holding.displayedMarketValue,
                color: CatfolioTheme.gainDefault
            ),
            .init(
                title: L10n.text("Return"),
                icon: .returnValue,
                value: DisplayFormat.percent(holding.unrealizedPercent)
            ),
            .init(
                title: L10n.text("Shares"),
                icon: .shares,
                value: DisplayFormat.shares(holding.shares)
            ),
            .init(
                title: L10n.text("Cost"),
                icon: .cost,
                value: DisplayFormat.money(costBasis)
            ),
            .init(
                title: L10n.text("Average Cost"),
                icon: .averageCost,
                value: DisplayFormat.money(
                    holding.averageCost,
                    currency: holding.costCurrency ?? "USD"
                )
            ),
            .init(
                title: fxTitle,
                icon: .fxImpact,
                value: fxValue,
                color: fxColor
            ),
            .init(
                title: L10n.text("Proportion"),
                icon: .proportion,
                value: DisplayFormat.percent(holding.weight * 100, signed: false)
            ),
            // Amount and percentage on rows of their own, as in Figma 299:10086.
            .init(
                title: L10n.text("Unrealised P&L"),
                icon: .unrealisedProfitLoss,
                value: DisplayFormat.money(holding.unrealized, signed: true),
                color: profitColor
            ),
            .init(
                title: L10n.text("Unrealised P&L %"),
                icon: .unrealisedProfitLoss,
                value: DisplayFormat.percent(holding.unrealizedPercent),
                color: profitColor
            ),
        ] + [expenseRatioRow].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.text("Data"))
                .font(HoldingDetailTypography.medium(19, relativeTo: .headline))

            // One glass card; the zebra stripes run edge to edge inside it.
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HoldingDataRow(model: row, isAlternating: index.isMultiple(of: 2) == false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HoldingDetailCardStyle.cornerRadius, style: .continuous))
            .holdingDetailGlassCard()
        }
        .animation(.snappy(duration: 0.2), value: expenseRatio)
        .task(id: holding.ticker) { await loadExpenseRatio() }
    }

    private var fxTitle: String {
        let suffix: String
        switch holding.fxPnlStatus {
        case "estimated": suffix = " · EST."
        case "reconstructed": suffix = " · CALC."
        case "broker_reported": suffix = " · REPORTED"
        case "unavailable": suffix = " · UNAVAILABLE"
        case "mixed": suffix = " · MIXED"
        default: suffix = ""
        }
        return "FX Impact\(suffix)"
    }

    private var fxValue: String {
        guard let value = holding.fxPnl else {
            return holding.fxPnlStatus == "unavailable" ? "Missing data" : "—"
        }
        let amount = DisplayFormat.money(value, signed: true)
        guard let percent = holding.fxPnlPercent else { return amount }
        return "\(amount)  ·  \(DisplayFormat.percent(percent))"
    }

    private var fxColor: Color {
        guard let value = holding.fxPnl else { return .secondary }
        if value > 0 { return CatfolioTheme.gainDefault }
        if value < 0 { return CatfolioTheme.lossDefault }
        return .secondary
    }
}

private enum HoldingDataIcon {
    case value
    case returnValue
    case shares
    case cost
    case averageCost
    case fxImpact
    case proportion
    case unrealisedProfitLoss
    case expenseRatio

    /// Exact vector exports from the latest Figma icon source node 139:2920,
    /// as used by the Data section at node 115:5140. Rows that are not
    /// present in that frame keep their closest SF Symbol until the design
    /// supplies a dedicated glyph.
    var assetName: String? {
        switch self {
        case .value: "HoldingDataValue"
        case .returnValue: "HoldingDataReturn"
        case .cost: "HoldingDataCost"
        case .fxImpact: "HoldingDataFXImpact"
        case .proportion: "HoldingDataProportion"
        case .unrealisedProfitLoss: "HoldingDataUnrealisedPnL"
        case .shares, .averageCost, .expenseRatio: nil
        }
    }

    var systemName: String {
        switch self {
        case .value: "dollarsign"
        case .returnValue: "arrow.up.right"
        case .shares: "number"
        case .cost: "creditcard"
        case .averageCost: "divide.square"
        case .fxImpact: "arrow.left.arrow.right"
        case .proportion: "chart.pie"
        case .unrealisedProfitLoss: "chart.line.uptrend.xyaxis"
        case .expenseRatio: "percent"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .value: 22
        case .returnValue: 20
        case .shares: 21
        case .cost, .averageCost: 19
        case .fxImpact, .proportion, .unrealisedProfitLoss: 20
        case .expenseRatio: 19
        }
    }
}

private struct HoldingDataRow: View {
    @Environment(\.locale) private var appLocale
    struct Model {
        let title: String
        let icon: HoldingDataIcon
        let value: String
        var color: Color = .primary
    }

    @Environment(\.colorScheme) private var colorScheme

    let model: Model
    let isAlternating: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let assetName = model.icon.assetName {
                    Image(assetName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                } else {
                    Image(systemName: model.icon.systemName)
                        .font(.system(size: model.icon.pointSize, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                }
            }
            .foregroundStyle(.primary.opacity(0.50))
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)

            Text(model.title.uppercased())
                .appText(.footnote, weight: .semibold)
                .foregroundStyle(.primary.opacity(0.50))
                .lineLimit(1)
                .minimumScaleFactor(0.74)

            Spacer(minLength: 8)

            Text(model.value)
                .appNumber(.footnote, weight: .semibold)
                .foregroundStyle(model.color)
                .lineLimit(1)
                .minimumScaleFactor(0.66)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // An explicit Rectangle: without a shape, inside the glass card on
        // iOS 26 the stripe took a rounded container shape and drew as a
        // capsule. The design's stripes are square at both ends.
        .background(alternatingBackground, in: Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Translucent, not a solid #f8f8f8 slab: on glass an opaque stripe sat
    /// on top of the card and hid its lit edge at both ends. The same tone
    /// laid over the glass keeps the edge running through every row.
    private var alternatingBackground: Color {
        guard isAlternating else { return .clear }
        return colorScheme == .dark ? .white.opacity(0.05) : .black.opacity(0.03)
    }
}

private struct HoldingMetric: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let value: String
    var detail: String? = nil
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .appNumber(.subheading, weight: .bold)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if let detail {
                Text(detail)
                    .appNumber(.caption, weight: .semibold)
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// All research spacing belongs to actual visible modules, including the top
/// gap. Known funds start without speculative company-analysis entry points.
struct HoldingResearchSection: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let price: Double?
    private let restoresCache: Bool
    @State private var visibility: HoldingResearchVisibility
    @State private var consensus: AnalystConsensusData?
    @State private var earnings: EarningsSnapshot?
    @State private var predictionMarkets: [PolymarketRelatedMarket]?

    init(holding: Holding, price: Double?, restoresCache: Bool = true,
         initialAvailability: [HoldingResearchModule: HoldingResearchAvailability] = [:],
         initialEarnings: EarningsSnapshot? = nil) {
        self.holding = holding
        self.price = price
        self.restoresCache = restoresCache
        var policy = HoldingResearchVisibility(kind: HoldingSecurityKind.classify(holding), currency: holding.quoteCurrency)
        policy.record(AnalystConsensusView.hasHistory(symbol: holding.ticker) ? .available : .empty, for: .analystHistory)
        for (module, state) in initialAvailability { policy.record(state, for: module) }
        if let initialEarnings { policy.record(initialEarnings.hasUsableObservations ? .available : .empty, for: .earnings) }
        _visibility = State(initialValue: policy)
        _earnings = State(initialValue: initialEarnings)
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
            if visibility.hasVisibleModules {
                // Eager, not lazy: a handful of cards whose heights change as
                // their content arrives. Lazily, the ones scrolled off above
                // were re-measured on reaching the page's end and threw the
                // scroll position back up by most of a screen.
                VStack(spacing: HoldingDetailCardStyle.spacing) {
                    // First, so it sits directly under the Data section above.
                    if visibility.shows(.predictionMarkets) {
                        HoldingPredictionMarketsCard(holding: holding, initialMarkets: predictionMarkets,
                            usesCachedContentOnlyInitially: visibility.kind == .fund,
                            onAvailability: { record($0, for: .predictionMarkets) })
                    }
                    if visibility.shows(.developments) {
                        SecurityDebateCard(ticker: holding.ticker, name: holding.shortName)
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
                .padding(.top, 40)
                .accessibilityIdentifier("holding-research-section")
            }

            // Only under research cards: a fund with none keeps a zero-height
            // section, and the OI caveat stays in the wall's own ⓘ.
            if visibility.hasVisibleModules {
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
        consensus = values.0
        earnings = values.1
        predictionMarkets = values.3
        if let value = values.0 { record(value.hasContent ? .available : .empty, for: .consensus) }
        if let value = values.1 { record(value.hasUsableObservations ? .available : .empty, for: .earnings) }
        if let value = values.2 { record(value.hasUsableStatements ? .available : .empty, for: .financials) }
        if let value = values.3 { record(value.isEmpty ? .empty : .available, for: .predictionMarkets) }
    }
}

private struct HoldingFinancialCard: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    var onAvailability: (HoldingResearchAvailability) -> Void = { _ in }
    @State private var showsFinancials = false
    @State private var availability: HoldingResearchAvailability = .unknown
    @Namespace private var zoom

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
        .matchedTransitionSource(id: holding.ticker, in: zoom)
        .accessibilityHint("Open reported company financials")
        .sheet(isPresented: $showsFinancials, onDismiss: { onAvailability(availability) }) {
            NavigationStack {
                CompanyFinancialsView(holding: holding, onAvailability: { availability = $0 })
            }
            .navigationTransition(.zoom(sourceID: holding.ticker, in: zoom))
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct HoldingPredictionMarketsCard: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let usesCachedContentOnlyInitially: Bool
    let onAvailability: (HoldingResearchAvailability) -> Void

    init(holding: Holding, initialMarkets: [PolymarketRelatedMarket]? = nil,
         usesCachedContentOnlyInitially: Bool = false,
         onAvailability: @escaping (HoldingResearchAvailability) -> Void = { _ in }) {
        self.holding = holding
        self.usesCachedContentOnlyInitially = usesCachedContentOnlyInitially
        self.onAvailability = onAvailability
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
                if isLoading {
                    ProgressView().controlSize(.small).frame(width: 24, height: 24)
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
                if isLoading {
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
        if isLoading { return L10n.text("正在读取 Polymarket 盘口") }
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
        isLoading = true
        errorMessage = nil
        do {
            let companyName = holding.displayName.components(separatedBy: " / ").first
                ?? holding.displayName
            let loaded = try await PolymarketClient.shared.relatedMarkets(
                ticker: holding.ticker,
                companyName: companyName,
                forceRefresh: forceRefresh, language: language
            )
            guard !Task.isCancelled, language == AppLanguage.currentIdentifier else { return }
            let usable = loaded.filter(\.hasUsableContent)
            if !usable.isEmpty || markets.isEmpty { markets = usable }
            onAvailability(markets.isEmpty ? .empty : .available)
        } catch {
            guard !Task.isCancelled, language == AppLanguage.currentIdentifier else { return }
            errorMessage = error.localizedDescription
            onAvailability(markets.isEmpty ? .failed : .available)
        }
        isLoading = false
    }
}


enum HoldingDetailCardStyle {
    static let pageInset: CGFloat = 16
    static let contentInset: CGFloat = 20
    static let spacing: CGFloat = 16
    static let cornerRadius: CGFloat = 24
    static let minimumRowHeight: CGFloat = 105
}

/// Shared label for the Financial and AI entry cards. The caller owns the
/// button action and presentation; the label owns only appearance.
struct HoldingDetailActionCardLabel: View {
    let title: String
    let subtitle: String
    var symbol: String? = "chevron.right"
    var isLoading = false

    var body: some View {
        HoldingDetailCardHeader(title: title, subtitle: subtitle, symbol: symbol, isLoading: isLoading)
            .contentShape(RoundedRectangle(cornerRadius: HoldingDetailCardStyle.cornerRadius, style: .continuous))
            .holdingDetailGlassCard()
    }
}

/// A research card that opens in place rather than presenting a sheet. Closed
/// it is an action card with a downward chevron; open, the same glass grows to
/// hold the section beneath the same header, so nothing moves but the content.
struct HoldingDetailDisclosureCard<Content: View>: View {
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let title: String
    let subtitle: String
    @Binding var isExpanded: Bool
    var isLoading = false
    var isEnabled = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HoldingDetailCardHeader(title: title, subtitle: subtitle, symbol: "chevron.down",
                    isLoading: isLoading, symbolRotation: .degrees(isExpanded ? 180 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityValue(L10n.text(isExpanded ? "已展开" : "已收起"))

            if isExpanded {
                content()
                    .padding(.horizontal, HoldingDetailCardStyle.contentInset)
                    .padding(.bottom, HoldingDetailCardStyle.contentInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .holdingDetailGlassCard()
        .sensoryFeedback(.selection, trigger: isExpanded) { _, _ in hapticsEnabled }
    }
}

/// Title and secondary line, set the same way on every research card —
/// action, disclosure, and the prediction markets card alike.
struct HoldingDetailCardTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appText(.subheading, weight: .medium)
                .foregroundStyle(.primary)
            Text(subtitle)
                .appText(.label, weight: .medium)
                .foregroundStyle(.primary.opacity(0.50))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The row the action card and the disclosure card are both made of.
struct HoldingDetailCardHeader: View {
    let title: String
    let subtitle: String
    var symbol: String?
    var isLoading = false
    var symbolRotation: Angle = .zero

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HoldingDetailCardTitle(title: title, subtitle: subtitle)

            if isLoading {
                ProgressView().controlSize(.small).frame(width: 16, height: 24)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(symbolRotation)
                    .frame(width: 16, height: 24)
                    .accessibilityHidden(true)
            }
        }
        .padding(HoldingDetailCardStyle.contentInset)
        .frame(maxWidth: .infinity, minHeight: HoldingDetailCardStyle.minimumRowHeight, alignment: .leading)
    }
}

struct HoldingDetailGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HoldingDetailCardStyle.cornerRadius, style: .continuous)
    }

    private var fallbackTint: Color {
        colorScheme == .dark
            ? Color(red: 22 / 255, green: 25 / 255, blue: 28 / 255).opacity(0.88)
            : .white.opacity(0.78)
    }

    /// Lit from above, as the Home Screen widgets are: brighter along the top
    /// edge, settling towards the bottom. On a plain page there is no
    /// wallpaper for the glass to bend, so this is what gives it its lift.
    private var sheen: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [.white.opacity(0.05), .white.opacity(0.01)]
                : [.white.opacity(0.55), .white.opacity(0.18)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.08)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Untinted system glass with no drawn border: the dark tint and
            // the hairline were covering the glass's own edge highlight,
            // which is what makes the widgets read as clear and bright.
            content
                .background(sheen, in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(fallbackTint, in: shape)
                .overlay { shape.stroke(borderColor, lineWidth: 1) }
        }
    }
}

/// One shell for the holding detail's research entries and expanded cards.
/// Keep glass, radius and border shared across every section and state.
extension View {
    func holdingDetailGlassCard() -> some View {
        modifier(HoldingDetailGlassCardModifier())
    }
}

/// Presentation-only rubber band; the selected price never exceeds the range.
enum FiftyTwoWeekEdgeElasticity {
    static let limit: CGFloat = 18

    static func pull(location: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard location.isFinite, lower.isFinite, upper.isFinite, upper > lower else { return 0 }
        let distance = location < lower ? location - lower : (location > upper ? location - upper : 0)
        let resisted = abs(distance) * 0.55
        return (distance < 0 ? -1 : 1) * limit * (1 - 1 / (1 + resisted / limit))
    }

    static func influence(index: Int, count: Int, pull: CGFloat) -> CGFloat {
        guard count > 1, (0..<count).contains(index), pull != 0 else { return 0 }
        let distance = pull < 0 ? index : count - 1 - index
        return pow(max(0, 1 - CGFloat(distance) / 7), 2)
    }
}

private struct FiftyTwoWeekRange: View {
    @Environment(\.locale) private var appLocale
    let low: Double
    let high: Double
    let current: Double
    let periodStart: Double?
    let currency: String

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var selectedIndex: Int?
    @State private var edgePull: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let markerCount = 45
    private let tickWidth: CGFloat = 4
    private let tickHeight: CGFloat = 98
    private let currentTickHeight: CGFloat = 110
    private let selectedPushPadding: CGFloat = 2
    private let specialMarkerSnapRadius: CGFloat = 12
    private var currentTickWidth: CGFloat {
        colorScheme == .dark ? 6 : 7
    }

    private var currentPosition: Double {
        normalized(current)
    }

    private var startPosition: Double? {
        periodStart.map(normalized)
    }

    private var performanceColor: Color {
        guard let periodStart else { return CatfolioStyle.blue }
        return current >= periodStart
            ? Color(red: 0, green: 1, blue: 35 / 255).opacity(0.90)
            : Color(red: 1, green: 16 / 255, blue: 89 / 255)
    }

    private var highlightedGradientColors: [Color] {
        guard let periodStart else { return [CatfolioStyle.blue.opacity(0.35), CatfolioStyle.blue] }
        if current >= periodStart {
            return colorScheme == .dark
                ? [
                    Color(red: 8 / 255, green: 123 / 255, blue: 24 / 255).opacity(0.80),
                    Color(red: 15 / 255, green: 225 / 255, blue: 44 / 255).opacity(0.80),
                ]
                : [
                    Color(red: 219 / 255, green: 1, blue: 161 / 255),
                    Color(red: 26 / 255, green: 1, blue: 57 / 255),
                ]
        }
        return colorScheme == .dark
            ? [
                Color(red: 153 / 255, green: 10 / 255, blue: 53 / 255),
                Color(red: 1, green: 16 / 255, blue: 89 / 255),
            ]
            : [
                Color(red: 249 / 255, green: 150 / 255, blue: 250 / 255),
                Color(red: 1, green: 16 / 255, blue: 89 / 255),
            ]
    }

    private var performanceGlowColor: Color {
        guard let periodStart, current < periodStart else {
            return Color(red: 128 / 255, green: 1, blue: 93 / 255)
        }
        return Color(red: 1, green: 51 / 255, blue: 122 / 255)
    }

    private var changePercent: Double? {
        guard let periodStart, periodStart > 0 else { return nil }
        return (current / periodStart - 1) * 100
    }

    private var inactiveTickColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.20)
            : Color(red: 240 / 255, green: 240 / 255, blue: 240 / 255)
    }

    private var inactiveTickGlowColor: Color {
        .white.opacity(0.18)
    }

    private var rangeLabelColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.36)
            : Color(red: 190 / 255, green: 191 / 255, blue: 191 / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("52-Week Range"))
                .font(HoldingDetailTypography.medium(19, relativeTo: .headline))
                .frame(height: 23, alignment: .leading)

            GeometryReader { geometry in
                rangePlot(size: geometry.size)
            }
            .frame(height: 141)
        }
        .frame(height: 184, alignment: .top)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: selectedIndex)
        .sensoryFeedback(.selection, trigger: selectedIndex) { oldValue, newValue in
            hapticsEnabled && oldValue != nil && newValue != nil
        }
        .onChange(of: reduceMotion) { _, enabled in if enabled { edgePull = 0 } }
        .onDisappear { edgePull = 0; selectedIndex = nil }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(L10n.text("按住并横向拖动可查看任意价格"))
    }

    @ViewBuilder
    private func rangePlot(size: CGSize) -> some View {
        let currentIndex = markerIndex(for: currentPosition)
        let startIndex = startPosition.map(markerIndex)
        let highlightedRange = startIndex.map {
            min($0, currentIndex)...max($0, currentIndex)
        }
        let currentX = xPosition(
            for: currentIndex,
            currentIndex: currentIndex,
            selectedIndex: selectedIndex,
            width: size.width
        )
        let rangeStartX = startIndex.map {
            xPosition(
                for: $0,
                currentIndex: currentIndex,
                selectedIndex: selectedIndex,
                width: size.width
            )
        } ?? currentX
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(0..<markerCount, id: \.self) { index in
                    let isCurrent = index == currentIndex
                    let isSelected = selectedIndex == index
                    let isActiveTick = isCurrent || isSelected
                    let isHighlighted = isCurrent || highlightedRange?.contains(index) == true
                    let width = isActiveTick ? currentTickWidth : tickWidth
                    let height = isActiveTick ? currentTickHeight : tickHeight
                    let showsCurrentGlow = selectedIndex == nil && isCurrent
                    let x = xPosition(
                        for: index,
                        currentIndex: currentIndex,
                        selectedIndex: selectedIndex,
                        width: size.width
                    )

                    let influence = FiftyTwoWeekEdgeElasticity.influence(index: index, count: markerCount, pull: edgePull)
                    let stretch = abs(edgePull) / FiftyTwoWeekEdgeElasticity.limit * influence
                    rangeTick(
                        isCurrent: isCurrent,
                        isHighlighted: isHighlighted,
                        showsGlow: isSelected || showsCurrentGlow,
                        x: x,
                        rangeStartX: rangeStartX,
                        rangeEndX: currentX,
                        width: width,
                        height: height
                    )
                    .scaleEffect(x: 1 + stretch * 0.32, y: 1 - stretch * 0.12)
                    .rotationEffect(.degrees(Double(edgePull / FiftyTwoWeekEdgeElasticity.limit * influence * 6)))
                    .position(x: x + edgePull * influence, y: (isActiveTick ? 0 : 6) + height / 2)
                    .animation(reduceMotion || edgePull != 0 ? nil : .spring(response: 0.42, dampingFraction: 0.58), value: edgePull)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72, blendDuration: 0.08),
                value: selectedIndex
            )

            if let selectedIndex {
                let selectedX = xPosition(
                    for: selectedIndex,
                    currentIndex: currentIndex,
                    selectedIndex: selectedIndex,
                    width: size.width
                )
                let bubble = bubbleDetails(
                    for: selectedIndex,
                    currentIndex: currentIndex,
                    startIndex: startIndex
                )
                markerBubble(title: bubble.title, price: bubble.price)
                    .position(
                        x: bubbleX(selectedX, width: size.width),
                        y: -1
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .zIndex(2)
            }

            HStack(spacing: 12) {
                Text(L10n.text("Lowest \(DisplayFormat.money(low, currency: currency))"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("\(DisplayFormat.money(high, currency: currency)) Highest"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .appNumber(.callout)
            .foregroundStyle(rangeLabelColor)
            .frame(width: size.width)
            .position(x: size.width / 2, y: 129)

            ChartPointInteractionOverlay(
                onLocationChanged: { location in
                    // Measure against the stable endpoints, not the already stretched ticks.
                    edgePull = reduceMotion ? 0 : FiftyTwoWeekEdgeElasticity.pull(
                        location: location.x,
                        lower: xPosition(for: 0, currentIndex: currentIndex, selectedIndex: nil, width: size.width),
                        upper: xPosition(for: markerCount - 1, currentIndex: currentIndex, selectedIndex: nil, width: size.width))
                    let nextIndex = markerIndex(
                        at: location.x,
                        currentIndex: currentIndex,
                        width: size.width
                    )
                    guard nextIndex != selectedIndex else { return }
                    selectedIndex = nextIndex
                },
                onInteractionEnded: {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.58)) {
                        edgePull = 0
                        selectedIndex = nil
                    }
                }
            )
            .frame(width: size.width, height: size.height)
            .position(x: size.width / 2, y: size.height / 2)
            .zIndex(3)
        }
    }

    @ViewBuilder
    private func rangeTick(
        isCurrent: Bool,
        isHighlighted: Bool,
        showsGlow: Bool,
        x: CGFloat,
        rangeStartX: CGFloat,
        rangeEndX: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let rectMinX = x - width / 2
        let localStartX = (rangeStartX - rectMinX) / max(width, 0.001)
        let localEndX = (rangeEndX - rectMinX) / max(width, 0.001)
        let usesVisibleGlow = showsGlow && (isCurrent || colorScheme == .dark)

        Group {
            if isCurrent {
                Capsule().fill(performanceColor)
            } else if isHighlighted {
                Capsule().fill(
                    LinearGradient(
                        colors: highlightedGradientColors,
                        startPoint: UnitPoint(x: localStartX, y: 0.5),
                        endPoint: UnitPoint(x: localEndX, y: 0.5)
                    )
                )
            } else {
                Capsule().fill(inactiveTickColor)
            }
        }
        .frame(width: width, height: height)
        .shadow(
            color: usesVisibleGlow
                ? (isHighlighted ? performanceGlowColor : inactiveTickGlowColor)
                : .clear,
            radius: usesVisibleGlow ? (isCurrent ? 8 : 5) : 0
        )
    }

    private func bubbleDetails(
        for index: Int,
        currentIndex: Int,
        startIndex: Int?
    ) -> (title: String, price: Double) {
        if index == currentIndex { return (L10n.text("现价"), current) }
        if index == startIndex, let periodStart { return (L10n.text("周期开始"), periodStart) }
        let fraction = Double(index) / Double(max(markerCount - 1, 1))
        return (L10n.text("价格"), low + (high - low) * fraction)
    }

    @ViewBuilder
    private func markerBubble(title: String, price: Double) -> some View {
        let label = Text("\(title) \(DisplayFormat.money(price, currency: currency))")
            .font(Typography.number(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)

        if #available(iOS 26.0, *) {
            label.glassEffect(.clear.interactive(), in: Capsule())
        } else {
            label
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.30), lineWidth: 0.5)
                }
        }
    }

    private func bubbleX(_ rawX: CGFloat, width: CGFloat) -> CGFloat {
        let inset: CGFloat = 72
        return min(width - inset, max(inset, rawX))
    }

    private func normalized(_ price: Double) -> Double {
        guard high > low else { return 0 }
        return min(1, max(0, (price - low) / (high - low)))
    }

    private func markerIndex(for position: Double) -> Int {
        min(markerCount - 1, max(0, Int((position * Double(markerCount - 1)).rounded())))
    }

    private func markerIndex(at x: CGFloat, currentIndex: Int, width: CGFloat) -> Int {
        // Overscrolling selects the exact endpoint, even near a snapping key marker.
        if x <= xPosition(for: 0, currentIndex: currentIndex, selectedIndex: nil, width: width) { return 0 }
        if x >= xPosition(for: markerCount - 1, currentIndex: currentIndex, selectedIndex: nil, width: width) { return markerCount - 1 }
        let startIndex = startPosition.map(markerIndex)
        let specialIndices = [currentIndex, startIndex]
            .compactMap { $0 }
            .reduce(into: [Int]()) { indices, index in
                if !indices.contains(index) { indices.append(index) }
            }
        let nearestSpecial = specialIndices
            .map { index in
                (
                    index: index,
                    distance: abs(xPosition(
                        for: index,
                        currentIndex: currentIndex,
                        selectedIndex: nil,
                        width: width
                    ) - x)
                )
            }
            .min { $0.distance < $1.distance }

        if let nearestSpecial, nearestSpecial.distance <= specialMarkerSnapRadius {
            return nearestSpecial.index
        }

        return (0..<markerCount).min { lhs, rhs in
            abs(xPosition(
                for: lhs,
                currentIndex: currentIndex,
                selectedIndex: nil,
                width: width
            ) - x)
                < abs(xPosition(
                    for: rhs,
                    currentIndex: currentIndex,
                    selectedIndex: nil,
                    width: width
                ) - x)
        } ?? currentIndex
    }

    private func xPosition(
        for index: Int,
        currentIndex: Int,
        selectedIndex: Int?,
        width: CGFloat
    ) -> CGFloat {
        guard markerCount > 1 else { return width / 2 }
        let currentExtraWidth = currentTickWidth - tickWidth
        let hasSeparateSelection = selectedIndex.map { $0 != currentIndex } ?? false
        let selectedSlotWidth = currentTickWidth + selectedPushPadding * 2
        let selectedExtraWidth = hasSeparateSelection ? selectedSlotWidth - tickWidth : 0
        let totalTickWidth = CGFloat(markerCount) * tickWidth
            + currentExtraWidth
            + selectedExtraWidth
        let gap = max(0.5, (width - totalTickWidth) / CGFloat(markerCount - 1))
        let isSelected = selectedIndex == index && index != currentIndex
        let itemSlotWidth = isSelected
            ? selectedSlotWidth
            : (index == currentIndex ? currentTickWidth : tickWidth)
        let precedingCurrentExtra = index > currentIndex ? currentExtraWidth : 0
        let precedingSelectedExtra: CGFloat
        if let selectedIndex, selectedIndex != currentIndex, index > selectedIndex {
            precedingSelectedExtra = selectedExtraWidth
        } else {
            precedingSelectedExtra = 0
        }
        return CGFloat(index) * (tickWidth + gap)
            + precedingCurrentExtra
            + precedingSelectedExtra
            + itemSlotWidth / 2
    }

    private var accessibilityText: String {
        var components = [
            L10n.text("52 周最低 \(DisplayFormat.money(low, currency: currency))"),
            L10n.text("最高 \(DisplayFormat.money(high, currency: currency))"),
            L10n.text("当前价格 \(DisplayFormat.money(current, currency: currency))"),
        ]
        if let periodStart {
            components.append(L10n.text("52 周前价格 \(DisplayFormat.money(periodStart, currency: currency))"))
        }
        if let changePercent {
            components.append(L10n.text("52 周变化 \(DisplayFormat.percent(changePercent))"))
        }
        return components.joined(separator: "，")
    }
}

enum VolumeProfileInterpretation {
    /// Product rule: "near the POC" means no farther than 10% of the
    /// selected historical value area's width. This is a presentation rule,
    /// not a market or accounting standard.
    static let pointOfControlProximityFraction = 0.10

    /// Product rule: costs within 1% of the current quote are described as
    /// broadly aligned. This is deliberately centralized for copy consistency.
    static let costParityFraction = 0.01

    enum PricePosition: Equatable {
        case below
        case inside
        case above
        case unavailable
    }

    enum CostPosition: Equatable {
        case belowCurrent
        case aligned
        case aboveCurrent
        case unavailable
    }

    struct Result: Equatable {
        let text: String
        let pricePosition: PricePosition
        let costPosition: CostPosition
        let isNearPointOfControl: Bool
        let costDifferencePercent: Double?
    }

    struct TailPresence: Equatable {
        let hasUpper: Bool
        let hasLower: Bool
    }

    struct BinSlice: Equatable {
        let priceLow: Double
        let priceHigh: Double
        let volume: Double
    }

    static func tailPresence(
        bins: [(priceLow: Double, priceHigh: Double, volume: Double)],
        valueAreaLow: Double,
        valueAreaHigh: Double
    ) -> TailPresence {
        guard valueAreaLow.isFinite,
              valueAreaHigh.isFinite,
              valueAreaHigh > valueAreaLow else {
            return TailPresence(hasUpper: false, hasLower: false)
        }
        let validBins = bins.filter {
            $0.volume.isFinite
                && $0.volume > 0
                && $0.priceLow.isFinite
                && $0.priceHigh.isFinite
                && $0.priceHigh > $0.priceLow
        }
        return TailPresence(
            hasUpper: validBins.contains { $0.priceHigh > valueAreaHigh },
            hasLower: validBins.contains { $0.priceLow < valueAreaLow }
        )
    }

    static func curveVerticalHandle(distance: Double) -> Double {
        guard distance.isFinite, distance > 0 else { return 0 }
        return distance / 3
    }

    /// Builds one continuous price profile. Real zero-volume buckets are kept as
    /// zero-width anchors, and missing price intervals receive a synthetic
    /// zero-volume anchor. The renderer can therefore keep one silhouette and
    /// taper empty regions into a narrow visual neck instead of separate islands.
    static func continuousSlices(
        bins: [(priceLow: Double, priceHigh: Double, volume: Double)],
        lowerBound: Double,
        upperBound: Double
    ) -> [BinSlice] {
        guard lowerBound.isFinite,
              upperBound.isFinite,
              upperBound > lowerBound else { return [] }

        let sortedBins = bins.filter {
            $0.volume.isFinite
                && $0.volume >= 0
                && $0.priceLow.isFinite
                && $0.priceHigh.isFinite
                && $0.priceHigh > $0.priceLow
        }.sorted { ($0.priceLow + $0.priceHigh) < ($1.priceLow + $1.priceHigh) }

        var slices: [BinSlice] = []
        var previousHigh = lowerBound
        var hasPositiveVolume = false

        for bin in sortedBins {
            let clippedLow = max(bin.priceLow, lowerBound)
            let clippedHigh = min(bin.priceHigh, upperBound)
            guard clippedHigh > clippedLow else { continue }
            let tolerance = max(0.000_000_001, max(abs(previousHigh), abs(clippedLow)) * 0.000_000_001)
            if clippedLow > previousHigh + tolerance {
                slices.append(BinSlice(priceLow: previousHigh, priceHigh: clippedLow, volume: 0))
            }
            slices.append(BinSlice(priceLow: clippedLow, priceHigh: clippedHigh, volume: bin.volume))
            hasPositiveVolume = hasPositiveVolume || bin.volume > 0
            previousHigh = max(previousHigh, clippedHigh)
        }
        let trailingTolerance = max(
            0.000_000_001,
            max(abs(previousHigh), abs(upperBound)) * 0.000_000_001
        )
        if previousHigh < upperBound - trailingTolerance {
            slices.append(BinSlice(priceLow: previousHigh, priceHigh: upperBound, volume: 0))
        }
        return hasPositiveVolume ? slices : []
    }

    static func constrainedCornerRadius(
        height: Double,
        topWidth: Double,
        bottomWidth: Double
    ) -> Double {
        guard height.isFinite,
              topWidth.isFinite,
              bottomWidth.isFinite else { return 0 }
        return max(0, min(18, min(height / 2, min(topWidth / 2, bottomWidth / 2))))
    }

    static func result(
        sessions: Int,
        quote: Double,
        valueAreaLow: Double,
        valueAreaHigh: Double,
        pointOfControl: Double?,
        cost: Double?
    ) -> Result {
        guard quote.isFinite,
              quote > 0,
              valueAreaLow.isFinite,
              valueAreaHigh.isFinite,
              valueAreaHigh > valueAreaLow else {
            return Result(
                text: L10n.text("当前价格或主成交区数据暂不可用。"),
                pricePosition: .unavailable,
                costPosition: .unavailable,
                isNearPointOfControl: false,
                costDifferencePercent: nil
            )
        }

        let period = sessions > 0 ? L10n.text("过去\(sessions)个交易日") : L10n.text("所选历史区间")
        let areaWidth = valueAreaHigh - valueAreaLow
        let isNearPointOfControl = pointOfControl.map { point in
            point.isFinite
                && point >= valueAreaLow
                && point <= valueAreaHigh
                && abs(quote - point) <= areaWidth * pointOfControlProximityFraction
        } ?? false

        let pricePosition: PricePosition
        var priceText: String
        if quote < valueAreaLow {
            pricePosition = .below
            priceText = L10n.text("当前价格低于\(period)的主要成交区域，说明市场相对于所选历史成交区域处于弱势位置。")
        } else if quote > valueAreaHigh {
            pricePosition = .above
            priceText = L10n.text("当前价格已高于\(period)的主要成交密集区，说明市场相对于所选历史成交区域处于较高位置。")
        } else {
            pricePosition = .inside
            priceText = L10n.text("当前价格位于\(period)的主成交区内")
            priceText += isNearPointOfControl ? L10n.text("，且接近成交峰值。") : "。"
        }

        guard let cost, cost.isFinite, cost > 0 else {
            return Result(
                text: priceText,
                pricePosition: pricePosition,
                costPosition: .unavailable,
                isNearPointOfControl: isNearPointOfControl,
                costDifferencePercent: nil
            )
        }

        let differenceFraction = abs(cost - quote) / quote
        let differencePercent = differenceFraction * 100
        let costPosition: CostPosition
        let costText: String
        if differenceFraction <= costParityFraction {
            costPosition = .aligned
            costText = L10n.text("你的持仓成本与现价基本持平。")
        } else if cost < quote {
            costPosition = .belowCurrent
            costText = L10n.text("你的持仓成本低于现价\(percentageText(differencePercent))%，目前持仓处于盈利状态。")
        } else {
            costPosition = .aboveCurrent
            costText = L10n.text("你的持仓成本高于现价\(percentageText(differencePercent))%，当前持仓处于浮亏状态。")
        }

        return Result(
            text: "\(priceText)\(costText)",
            pricePosition: pricePosition,
            costPosition: costPosition,
            isNearPointOfControl: isNearPointOfControl,
            costDifferencePercent: differencePercent
        )
    }

    static func convertedPrice(
        _ value: Double,
        from sourceCurrency: String?,
        to targetCurrency: String?,
        usdRate: (String) -> Double?
    ) -> Double? {
        guard value.isFinite,
              value > 0,
              let source = normalizedCurrency(sourceCurrency),
              let target = normalizedCurrency(targetCurrency) else { return nil }
        guard source != target else { return value }
        guard let sourceRate = usdRate(source),
              let targetRate = usdRate(target),
              sourceRate.isFinite,
              targetRate.isFinite,
              sourceRate > 0,
              targetRate > 0 else { return nil }
        let converted = value * sourceRate / targetRate
        return converted.isFinite && converted > 0 ? converted : nil
    }

    private static func normalizedCurrency(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func percentageText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Shared VP/OI section chrome; each plot keeps its own financial semantics.
struct PriceDistributionSection<Plot: View, Footer: View>: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let subtitle: String
    @ViewBuilder let plot: () -> Plot
    @ViewBuilder let footer: () -> Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(LegacyType.medium(19, relativeTo: .headline))
                Spacer(minLength: 12)
                Text(subtitle).font(Typography.text(size: 15, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.50))
            }.frame(height: 23)
            plot().padding(.top, 24)
            footer().font(LegacyType.medium(15, relativeTo: .subheadline))
                .foregroundStyle(.secondary).padding(.top, 12)
        }.transaction { $0.animation = nil }
    }
}

private struct VolumePriceChart: View {
    @Environment(\.locale) private var appLocale
    let profile: VolumeProfile
    let holding: Holding
    let showsHoldingCost: Bool
    @State private var selectedPrice: Double?

    private var displayedValueArea: (low: Double, high: Double) {
        let positiveBins = (profile.bins ?? []).filter {
            $0.volume.isFinite && $0.volume > 0 && $0.priceHigh > $0.priceLow
        }
        let distributionLow = positiveBins.map(\.priceLow).min() ?? profile.valueAreaLow
        let distributionHigh = positiveBins.map(\.priceHigh).max() ?? profile.valueAreaHigh
        #if DEBUG
        let previewMode = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--volume-tail-preview=") }?
            .split(separator: "=", maxSplits: 1)
            .last
            .map(String.init)
        switch previewMode {
        case "none":
            return (distributionLow, distributionHigh)
        case "upper-only":
            return (distributionLow, profile.valueAreaHigh)
        case "lower-only":
            return (profile.valueAreaLow, distributionHigh)
        default:
            break
        }
        #endif
        return (profile.valueAreaLow, profile.valueAreaHigh)
    }

    private var currentPrice: Double? {
        VolumeProfileInterpretation.convertedPrice(
            holding.quotePrice,
            from: holding.quoteCurrency ?? profile.currency,
            to: profile.currency,
            usdRate: LocalPortfolioEngine.usdRate(for:)
        )
    }

    private var holdingCost: Double? {
        guard showsHoldingCost,
              holding.costCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              holding.quoteCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return VolumeProfileInterpretation.convertedPrice(
            holding.averageCost,
            from: holding.costCurrency,
            to: profile.currency,
            usdRate: LocalPortfolioEngine.usdRate(for:)
        )
    }

    private var domain: ClosedRange<Double> {
        let binValues = (profile.bins ?? []).flatMap { [$0.priceLow, $0.priceHigh] }
        var values = binValues + [
            displayedValueArea.low,
            displayedValueArea.high,
            profile.pointOfControl,
        ]
        if let currentPrice { values.append(currentPrice) }
        if let holdingCost { values.append(holdingCost) }
        values = values.filter { $0.isFinite && $0 > 0 }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.035, max(abs(high) * 0.005, 0.01))
        return max(0, low - padding)...(high + padding)
    }

    private var interpretation: VolumeProfileInterpretation.Result {
        VolumeProfileInterpretation.result(
            sessions: profile.sessions,
            quote: currentPrice ?? .nan,
            valueAreaLow: displayedValueArea.low,
            valueAreaHigh: displayedValueArea.high,
            pointOfControl: profile.pointOfControl,
            cost: holdingCost
        )
    }

    var body: some View {
        PriceDistributionSection(title: L10n.text("Volume Profile"), subtitle: L10n.text("\(profile.sessions) 个交易日")) {
            VolumeDistributionPlot(
                profile: profile,
                valueAreaLow: displayedValueArea.low,
                valueAreaHigh: displayedValueArea.high,
                currentPrice: currentPrice,
                holdingCost: holdingCost,
                domain: domain,
                selectedPrice: $selectedPrice,
                onSelectionChanged: updateSelection
            )
            .frame(height: 303)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(interpretation.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(interpretation.text)

                Text(profile.asOf)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func updateSelection(_ price: Double?) {
        guard let price else {
            selectedPrice = nil
            return
        }
        guard price != selectedPrice else { return }
        selectedPrice = price

    }
}

private struct VolumeLabelFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct VolumeDistributionPlot: View {
    @Environment(\.locale) private var appLocale
    let profile: VolumeProfile
    let valueAreaLow: Double
    let valueAreaHigh: Double
    let currentPrice: Double?
    let holdingCost: Double?
    let domain: ClosedRange<Double>
    @Binding var selectedPrice: Double?
    let onSelectionChanged: (Double?) -> Void
    /// The finger's x while a price is held; its readout goes on the far side.
    @State private var touchX: CGFloat?
    /// Where each price label and pill was drawn, so the rules can part
    /// around them rather than run through the figures.
    @State private var labelFrames: [String: CGRect] = [:]
    private static let plotSpace = "volume-plot-space"

    @Environment(\.colorScheme) private var colorScheme

    private let verticalPlotInset: CGFloat = 0

    private var sourceBins: [VolumeProfileBin] {
        let bins = (profile.bins ?? [])
            .filter {
                $0.volume.isFinite
                    && $0.volume >= 0
                    && $0.priceLow.isFinite
                    && $0.priceHigh.isFinite
                    && $0.priceHigh > $0.priceLow
            }
            .sorted { $0.midpoint < $1.midpoint }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--volume-narrow-bin-preview"),
           let anchor = bins.first(where: { $0.volume > 0 }) {
            let narrowHeight = max((domain.upperBound - domain.lowerBound) * 0.000_1, 0.000_001)
            return [
                VolumeProfileBin(
                    priceLow: anchor.midpoint - narrowHeight / 2,
                    priceHigh: anchor.midpoint + narrowHeight / 2,
                    volume: anchor.volume
                )
            ]
        }
        #endif
        return bins
    }

    private var positiveBins: [VolumeProfileBin] {
        sourceBins.filter { $0.volume > 0 }
    }

    private func drawableProfile(lowerBound: Double, upperBound: Double) -> [VolumeProfileBin] {
        VolumeProfileInterpretation.continuousSlices(
            bins: sourceBins.map { ($0.priceLow, $0.priceHigh, $0.volume) },
            lowerBound: lowerBound,
            upperBound: upperBound
        ).map {
            VolumeProfileBin(priceLow: $0.priceLow, priceHigh: $0.priceHigh, volume: $0.volume)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let plotWidth = max(120, size.width - 93)
            let maximumVolume = max(positiveBins.map(\.volume).max() ?? 1, 0.000_001)
            let peakMarkerWidth = min(
                126,
                max(72, markerLabelWidth(L10n.text("峰值"), price: profile.pointOfControl))
            )
            let edgeLabelLeading: CGFloat = 6
            let peakMarkerX = edgeLabelLeading + peakMarkerWidth / 2
            // Short titles (现价, 成本) keep the pills narrow; both share the
            // wider of the two so they line up when stacked.
            let markerLabelWidths = [
                currentPrice.map { markerLabelWidth(L10n.text("现价"), price: $0) },
                holdingCost.map { markerLabelWidth(L10n.text("成本"), price: $0) },
            ].compactMap { $0 }
            let markerWidth = min(
                size.width * 0.42,
                max(72, markerLabelWidths.max() ?? 72)
            )
            let markerGap: CGFloat = 6
            let hasValidValueArea = valueAreaLow.isFinite
                && valueAreaHigh.isFinite
                && valueAreaHigh > valueAreaLow
            let valueAreaHighY = hasValidValueArea
                ? yPosition(for: valueAreaHigh, height: size.height)
                : 0
            let valueAreaLowY = hasValidValueArea
                ? yPosition(for: valueAreaLow, height: size.height)
                : size.height
            let profileHigh = positiveBins.last?.priceHigh ?? valueAreaHigh
            let profileLow = positiveBins.first?.priceLow ?? valueAreaLow
            let profileTopY = yPosition(for: profileHigh, height: size.height)
            let profileBottomY = yPosition(for: profileLow, height: size.height)
            let currentY = currentPrice.map { yPosition(for: $0, height: size.height) }
            let costY = holdingCost.map { yPosition(for: $0, height: size.height) }
            let hasValidPeak = profile.pointOfControl.isFinite && profile.pointOfControl > 0
            let peakY = hasValidPeak ? yPosition(for: profile.pointOfControl, height: size.height) : 0
            let rightMarkerX = size.width - markerWidth / 2
            let markersWouldOverlap = currentY.flatMap { current in
                costY.map { abs(current - $0) < 28 }
            } ?? false
            let currentMarkerX = markersWouldOverlap
                ? rightMarkerX - markerWidth - markerGap
                : rightMarkerX
            let currentRuleEndX = currentMarkerX - markerWidth / 2 - markerGap
            let costRuleEndX = rightMarkerX - markerWidth / 2 - markerGap
            // Size the selection pill for the longest price in this chart. Keeping
            // the text at its semantic caption size avoids short integer values
            // looking larger than decimal values that previously had to shrink to
            // fit the fixed 58-point pill.
            let longestAxisPrice = max(
                money(domain.lowerBound, fractionDigits: 2).count,
                money(domain.upperBound, fractionDigits: 2).count
            )
            let axisPillWidth = min(
                size.width * 0.28,
                max(58, CGFloat(longestAxisPrice) * 7 + 18)
            )
            let axisPillX = size.width - axisPillWidth / 2

            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    let bins = drawableProfile(
                        lowerBound: domain.lowerBound,
                        upperBound: domain.upperBound
                    )
                    let silhouette = silhouettePath(
                        bins: bins,
                        maximumVolume: maximumVolume,
                        plotWidth: plotWidth,
                        height: canvasSize.height
                    )
                    let actualProfileRegion = Path(CGRect(
                        x: 0,
                        y: profileTopY,
                        width: plotWidth,
                        height: max(0, profileBottomY - profileTopY)
                    ))

                    // Prices outside the historical bins are a visual extension
                    // only. The weak fill keeps the price relationship legible;
                    // all profile calculations still use the original bins.
                    context.fill(silhouette, with: .color(volumeProfileExtensionBlue))
                    context.drawLayer { layer in
                        layer.clip(to: silhouette)
                        layer.fill(actualProfileRegion, with: .color(volumeProfileBlue))
                    }

                    if hasValidValueArea {
                        var tailRegions = Path()
                        tailRegions.addRect(CGRect(
                            x: 0,
                            y: 0,
                            width: plotWidth,
                            height: max(0, valueAreaHighY)
                        ))
                        tailRegions.addRect(CGRect(
                            x: 0,
                            y: valueAreaLowY,
                            width: plotWidth,
                            height: max(0, canvasSize.height - valueAreaLowY)
                        ))
                        context.drawLayer { layer in
                            layer.clip(to: silhouette)
                            layer.clip(to: actualProfileRegion)
                            layer.fill(tailRegions, with: .color(volumeProfileTailBlue))
                        }
                    }

                    var stripes = Path()
                    var x = -canvasSize.height
                    while x < plotWidth + canvasSize.height {
                        stripes.move(to: CGPoint(x: x, y: 0))
                        stripes.addLine(to: CGPoint(x: x + canvasSize.height, y: canvasSize.height))
                        x += 30
                    }
                    context.drawLayer { layer in
                        layer.clip(to: silhouette)
                        layer.stroke(stripes, with: .color(.white.opacity(0.12)), lineWidth: 11)
                    }
                    context.drawLayer { layer in
                        layer.clip(to: silhouette)
                        layer.clip(to: actualProfileRegion)
                        layer.stroke(stripes, with: .color(.white.opacity(0.20)), lineWidth: 11)
                    }
                }

                if let currentY {
                    segmentedRule(y: currentY, from: edgeLabelLeading, to: currentRuleEndX, color: currentPriceTint)
                        .zIndex(1)
                }

                if let costY {
                    segmentedRule(y: costY, from: edgeLabelLeading, to: costRuleEndX, color: volumeCostGreen)
                        .zIndex(1)
                }

                if hasValidValueArea {
                    edgePriceLabel(price: valueAreaHigh)
                        .background(labelFrameReader("value-area-high"))
                        .frame(width: 80, alignment: .leading)
                        .position(x: edgeLabelLeading + 40, y: valueAreaHighY + 14)
                }
                if hasValidValueArea {
                    edgePriceLabel(price: valueAreaLow)
                        .background(labelFrameReader("value-area-low"))
                        .frame(width: 80, alignment: .leading)
                        .position(x: edgeLabelLeading + 40, y: valueAreaLowY - 14)
                }

                if let currentPrice, let currentY {
                    markerPill(
                        title: L10n.text("现价"),
                        price: currentPrice,
                        foreground: currentPriceText,
                        background: currentPriceTint,
                        width: markerWidth
                    )
                    .background(labelFrameReader("current"))
                    .position(x: currentMarkerX, y: currentY)
                    .zIndex(2)
                }

                if hasValidPeak {
                    peakMarkerPill(
                        title: L10n.text("峰值"),
                        price: profile.pointOfControl,
                        width: peakMarkerWidth
                    )
                    .background(labelFrameReader("peak"))
                    .position(x: peakMarkerX, y: peakY)
                    .zIndex(2)
                }

                if let holdingCost, let costY {
                    markerPill(
                        title: L10n.text("成本"),
                        price: holdingCost,
                        foreground: volumeCostText,
                        background: volumeCostGreen,
                        width: markerWidth
                    )
                    .background(labelFrameReader("cost"))
                    .position(x: rightMarkerX, y: costY)
                    .shadow(color: volumeCostGreen.opacity(0.42), radius: 18)
                    .zIndex(2)
                }

                if let selectedPrice {
                    // The readout goes to the side the finger is not on.
                    let pillOnLeft = (touchX ?? 0) > size.width / 2
                    let pillX = pillOnLeft ? axisPillWidth / 2 : axisPillX
                    let selectedRuleStartX = pillOnLeft ? axisPillWidth + markerGap : edgeLabelLeading
                    let selectedRuleEndX = pillOnLeft
                        ? size.width - edgeLabelLeading
                        : axisPillX - axisPillWidth / 2 - markerGap
                    segmentedRule(y: yPosition(for: selectedPrice, height: size.height),
                                  from: selectedRuleStartX, to: selectedRuleEndX,
                                  color: volumeSelectionBlue, isInteractive: true)
                        .allowsHitTesting(false)
                        .zIndex(10)

                    axisPricePill(price: selectedPrice, width: axisPillWidth)
                        .position(x: pillX, y: yPosition(for: selectedPrice, height: size.height))
                        .zIndex(10)
                }

                ChartPointInteractionOverlay(
                    onLocationChanged: { location in
                        touchX = location.x
                        onSelectionChanged(price(at: location.y, height: size.height))
                    },
                    onInteractionEnded: { touchX = nil; onSelectionChanged(nil) }
                )
                .zIndex(20)
            }
            .coordinateSpace(name: Self.plotSpace)
            .onPreferenceChange(VolumeLabelFramesKey.self) { labelFrames = $0 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// A pill's width for its title and price at the marker size: CJK glyphs
    /// run about a full em, Latin letters and figures a little over half.
    private func markerLabelWidth(_ title: String, price: Double) -> CGFloat {
        let text = title + " " + money(price)
        return text.reduce(CGFloat(0)) { $0 + ($1.isASCII ? 7 : 11.5) } + 20
    }

    /// A marker rule from `start` to `end`, broken wherever a price label or
    /// pill sits on it: the line stops short of the figure and carries on
    /// beyond it rather than running through it.
    private func segmentedRule(y: CGFloat, from start: CGFloat, to end: CGFloat,
                               color: Color, isInteractive: Bool = false) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(ruleSegments(y: y, from: start, to: end).enumerated()), id: \.offset) { _, segment in
                glassRule(color: color, width: segment.upperBound - segment.lowerBound, isInteractive: isInteractive)
                    .position(x: (segment.lowerBound + segment.upperBound) / 2, y: y)
            }
        }
    }

    private func ruleSegments(y: CGFloat, from start: CGFloat, to end: CGFloat) -> [ClosedRange<CGFloat>] {
        guard end - start >= 8 else { return [] }
        let gap: CGFloat = 6
        var segments: [ClosedRange<CGFloat>] = [start...end]
        // A 5pt rule touches a label when its centre is within half its width.
        for frame in labelFrames.values where y >= frame.minY - 2.5 && y <= frame.maxY + 2.5 {
            let cut = (frame.minX - gap)...(frame.maxX + gap)
            segments = segments.flatMap { run -> [ClosedRange<CGFloat>] in
                guard cut.upperBound > run.lowerBound, cut.lowerBound < run.upperBound else { return [run] }
                var parts: [ClosedRange<CGFloat>] = []
                if cut.lowerBound - run.lowerBound >= 8 { parts.append(run.lowerBound...cut.lowerBound) }
                if run.upperBound - cut.upperBound >= 8 { parts.append(cut.upperBound...run.upperBound) }
                return parts
            }
        }
        return segments
    }

    private func labelFrameReader(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: VolumeLabelFramesKey.self, value: [id: proxy.frame(in: .named(Self.plotSpace))])
        }
    }

    private var accessibilityLabel: String {
        var parts = [L10n.text("成交量价格分布"), L10n.text("成交峰值 \(money(profile.pointOfControl))")]
        if let currentPrice { parts.insert(L10n.text("当前价格 \(money(currentPrice))"), at: 1) }
        if let holdingCost { parts.append(L10n.text("持仓成本 \(money(holdingCost))")) }
        return parts.joined(separator: "，")
    }

    private var volumeCostGreen: Color {
        Color(red: 96 / 255, green: 1, blue: 52 / 255).opacity(0.8)
    }

    private var currentPriceTint: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.05)
    }

    private var currentPriceText: Color {
        colorScheme == .dark ? .white : .black
    }

    private var volumeCostText: Color {
        colorScheme == .dark ? .black : Color(red: 28 / 255, green: 83 / 255, blue: 13 / 255)
    }

    private var volumeProfileBlue: Color {
        Color(red: 52 / 255, green: 117 / 255, blue: 1)
    }

    private var volumeProfileTailBlue: Color {
        colorScheme == .dark
            ? Color(red: 113 / 255, green: 151 / 255, blue: 224 / 255)
            : Color(red: 188 / 255, green: 211 / 255, blue: 1)
    }

    private var volumeProfileExtensionBlue: Color {
        volumeProfileTailBlue.opacity(colorScheme == .dark ? 0.30 : 0.42)
    }

    private var volumeSelectionBlue: Color {
        Color(red: 0, green: 47 / 255, blue: 1).opacity(0.8)
    }

    private func yPosition(for price: Double, height: CGFloat) -> CGFloat {
        let top = verticalPlotInset
        let bottom = height - verticalPlotInset
        let span = max(domain.upperBound - domain.lowerBound, 0.0001)
        let ratio = min(1, max(0, (price - domain.lowerBound) / span))
        return bottom - CGFloat(ratio) * (bottom - top)
    }

    private func price(at y: CGFloat, height: CGFloat) -> Double {
        let top = verticalPlotInset
        let bottom = height - verticalPlotInset
        let clamped = min(bottom, max(top, y))
        let ratio = Double((bottom - clamped) / max(bottom - top, 1))
        return domain.lowerBound + ratio * (domain.upperBound - domain.lowerBound)
    }

    private func silhouettePath(
        bins: [VolumeProfileBin],
        maximumVolume: Double,
        plotWidth: CGFloat,
        height: CGFloat
    ) -> Path {
        var path = Path()
        guard let first = bins.first, let last = bins.last else { return path }

        let widths = smoothedProfileWidths(
            bins: bins,
            maximumVolume: maximumVolume,
            plotWidth: plotWidth
        )
        let topY = yPosition(for: last.priceHigh, height: height)
        let bottomY = yPosition(for: first.priceLow, height: height)
        let topWidth = widths.last ?? plotWidth * 0.2
        let bottomWidth = widths.first ?? plotWidth * 0.2
        let profilePoints = zip(bins.reversed(), widths.reversed()).map { bin, width in
            CGPoint(x: width, y: yPosition(for: bin.midpoint, height: height))
        }

        let realHeight = max(0, bottomY - topY)
        let cornerRadius = CGFloat(
            VolumeProfileInterpretation.constrainedCornerRadius(
                height: Double(realHeight),
                topWidth: Double(topWidth),
                bottomWidth: Double(bottomWidth)
            )
        )
        let topRadius = min(cornerRadius, topWidth / 2)
        let bottomRadius = min(cornerRadius, bottomWidth / 2)

        path.move(to: CGPoint(x: 0, y: topY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: cornerRadius, y: topY),
            control: CGPoint(x: 0, y: topY)
        )
        path.addLine(to: CGPoint(x: max(cornerRadius, topWidth - topRadius), y: topY))
        addSmoothProfileEdge(
            to: &path,
            points: profilePoints,
            topY: topY,
            topWidth: topWidth,
            topRadius: topRadius,
            bottomY: bottomY,
            bottomWidth: bottomWidth,
            bottomRadius: bottomRadius
        )
        path.addLine(to: CGPoint(x: cornerRadius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: bottomY - cornerRadius),
            control: CGPoint(x: 0, y: bottomY)
        )
        path.closeSubpath()
        #if DEBUG
        let bounds = path.boundingRect
        let boundaryTolerance: CGFloat = 0.01
        assert(
            bounds.minY >= topY - boundaryTolerance
                && bounds.maxY <= bottomY + boundaryTolerance,
            "Volume profile curve escaped its real price band"
        )
        #endif
        return path
    }

    /// Draws the exposed edge as one continuous cubic curve. Using a shared
    /// derivative at every bin removes the small horizontal/vertical "feet"
    /// produced by giving each segment its own vertical tangent.
    private func addSmoothProfileEdge(
        to path: inout Path,
        points: [CGPoint],
        topY: CGFloat,
        topWidth: CGFloat,
        topRadius: CGFloat,
        bottomY: CGFloat,
        bottomWidth: CGFloat,
        bottomRadius: CGFloat
    ) {
        let edgePoints = points.filter { $0.y > topY && $0.y < bottomY }
        guard !edgePoints.isEmpty else {
            path.addCurve(
                to: CGPoint(x: max(0, bottomWidth - bottomRadius), y: bottomY),
                control1: CGPoint(x: topWidth, y: topY),
                control2: CGPoint(x: bottomWidth, y: bottomY)
            )
            return
        }

        let slopes = smoothEdgeSlopes(for: edgePoints)
        let first = edgePoints[0]
        let topVerticalHandle = CGFloat(
            VolumeProfileInterpretation.curveVerticalHandle(
                distance: Double(first.y - topY)
            )
        )
        path.addCurve(
            to: first,
            control1: CGPoint(x: topWidth, y: topY),
            control2: CGPoint(
                x: first.x - slopes[0] * topVerticalHandle,
                y: first.y - topVerticalHandle
            )
        )

        if edgePoints.count > 1 {
            for index in 0..<(edgePoints.count - 1) {
                let start = edgePoints[index]
                let end = edgePoints[index + 1]
                let verticalHandle = CGFloat(
                    VolumeProfileInterpretation.curveVerticalHandle(
                        distance: Double(end.y - start.y)
                    )
                )
                path.addCurve(
                    to: end,
                    control1: CGPoint(
                        x: start.x + slopes[index] * verticalHandle,
                        y: start.y + verticalHandle
                    ),
                    control2: CGPoint(
                        x: end.x - slopes[index + 1] * verticalHandle,
                        y: end.y - verticalHandle
                    )
                )
            }
        }

        let last = edgePoints[edgePoints.count - 1]
        let bottomVerticalHandle = CGFloat(
            VolumeProfileInterpretation.curveVerticalHandle(
                distance: Double(bottomY - last.y)
            )
        )
        path.addCurve(
            to: CGPoint(x: max(0, bottomWidth - bottomRadius), y: bottomY),
            control1: CGPoint(
                x: last.x + slopes[slopes.count - 1] * bottomVerticalHandle,
                y: last.y + bottomVerticalHandle
            ),
            control2: CGPoint(x: bottomWidth, y: bottomY)
        )
    }

    /// Monotone cubic slopes for x as a function of y. At local peaks and
    /// valleys the tangent settles to zero instead of overshooting, while all
    /// other joins retain one continuous direction.
    private func smoothEdgeSlopes(for points: [CGPoint]) -> [CGFloat] {
        guard points.count > 1 else { return [0] }

        let segmentSlopes = (0..<(points.count - 1)).map { index -> CGFloat in
            let deltaY = max(points[index + 1].y - points[index].y, 0.001)
            return (points[index + 1].x - points[index].x) / deltaY
        }
        var slopes = Array(repeating: CGFloat.zero, count: points.count)
        slopes[0] = segmentSlopes[0]
        slopes[points.count - 1] = segmentSlopes[segmentSlopes.count - 1]

        if points.count > 2 {
            for index in 1..<(points.count - 1) {
                let previous = segmentSlopes[index - 1]
                let next = segmentSlopes[index]
                guard previous * next > 0 else {
                    slopes[index] = 0
                    continue
                }
                slopes[index] = 2 * previous * next / (previous + next)
            }
        }
        return slopes
    }

    /// Keeps the profile faithful to the source bins while removing tiny visual spikes.
    /// The continuous values feed the cubic edge directly; quantising them would recreate
    /// the deliberate-looking ledges that the smoothing is meant to remove.
    private func smoothedProfileWidths(
        bins: [VolumeProfileBin],
        maximumVolume: Double,
        plotWidth: CGFloat
    ) -> [CGFloat] {
        guard !bins.isEmpty else { return [] }

        let safeMaximum = max(maximumVolume, 0.000_001)
        let normalized = bins.map { max(0, $0.volume / safeMaximum) }
        let kernel: [Double] = [1, 2, 3, 4, 3, 2, 1]
        let radius = kernel.count / 2
        let filtered = normalized.indices.map { index in
            var weightedValue = 0.0
            var totalWeight = 0.0
            for offset in -radius...radius {
                let neighbor = min(normalized.count - 1, max(0, index + offset))
                let weight = kernel[offset + radius]
                weightedValue += normalized[neighbor] * weight
                totalWeight += weight
            }
            return weightedValue / max(totalWeight, 1)
        }

        var displayValues = filtered
        if let peakIndex = bins.indices.max(by: { bins[$0].volume < bins[$1].volume }) {
            // Preserve the profile's true scale against the global maximum.
            displayValues[peakIndex] = normalized[peakIndex]
        }

        return displayValues.indices.map { index in
            if normalized[index] == 0 {
                // The smoothed value forms a narrow visual neck across empty
                // buckets. Four points is only a topology floor: it keeps the
                // silhouette visibly whole without suggesting material volume.
                return min(plotWidth, max(4, plotWidth * CGFloat(displayValues[index])))
            }
            return plotWidth * CGFloat(max(0, displayValues[index]))
        }
    }

    private func money(_ price: Double, fractionDigits: Int? = nil) -> String {
        DisplayFormat.money(
            price,
            currency: profile.currency,
            fractionDigits: fractionDigits
        )
    }

    private func markerPill(
        title: String,
        price: Double,
        foreground: Color,
        background: Color,
        width: CGFloat
    ) -> some View {
        tintedGlassPill(
            markerPillLabel(title: title, price: price, foreground: foreground)
                .frame(width: width),
            tint: background
        )
    }

    private func peakMarkerPill(title: String, price: Double, width: CGFloat) -> some View {
        tintedGlassPill(
            markerPillLabel(title: title, price: price, foreground: .white)
                .frame(width: width, alignment: .leading),
            tint: volumeSelectionBlue.opacity(0.45)
        )
    }

    private func markerPillLabel(
        title: String,
        price: Double,
        foreground: Color
    ) -> some View {
        (
            Text(title)
                .font(Typography.text(.micro, weight: .semibold))
            + Text(" \(money(price))")
                .font(Typography.number(.micro, weight: .bold))
        )
        .foregroundStyle(foreground)
        .lineLimit(1)
        .minimumScaleFactor(0.58)
        .allowsTightening(true)
        .padding(.horizontal, 8)
        .frame(height: 24)
    }

    private func edgePriceLabel(price: Double) -> some View {
        Text(money(price))
            .appNumber(.micro, weight: .semibold)
            .fontDesign(.rounded)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func axisPricePill(price: Double, width: CGFloat) -> some View {
        let label = Text(money(price, fractionDigits: 2))
            .appNumber(.micro, weight: .semibold)
            .fontDesign(.rounded)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: width, height: 26)

        return tintedGlassPill(label, tint: volumeSelectionBlue, isInteractive: true)
    }

    @ViewBuilder
    private func glassRule(
        color: Color,
        width: CGFloat,
        isInteractive: Bool = false
    ) -> some View {
        let rule = Color.clear
            .frame(width: width, height: 5)

        if #available(iOS 26.0, *) {
            rule.glassEffect(glass(tint: color, isInteractive: isInteractive), in: Capsule())
        } else {
            rule
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().fill(color.opacity(0.72)) }
                .overlay { Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5) }
        }
    }

    @ViewBuilder
    private func tintedGlassPill<Content: View>(
        _ content: Content,
        tint: Color,
        isInteractive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            // Label above the glass, not inside it, so dark ink stays true.
            content.hidden()
                .glassEffect(glass(tint: tint, isInteractive: isInteractive), in: Capsule())
                .overlay { content }
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(tint.opacity(0.62), in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.32), lineWidth: 0.5) }
        }
    }

    @available(iOS 26.0, *)
    private func glass(tint: Color, isInteractive: Bool) -> Glass {
        let material = Glass.clear.tint(tint)
        return isInteractive ? material.interactive() : material
    }

}

/// Read the button's window position only when tapped. No per-scroll geometry
/// observer or published state is attached to the expensive price section.
final class SecurityPaperSourceAnchor {
    weak var view: UIView?
    var frame: CGRect {
        guard let view, view.window != nil else { return .zero }
        view.window?.layoutIfNeeded()
        return view.convert(view.bounds, to: nil)
    }
}

private struct SecurityPaperSourceReader: UIViewRepresentable {
    let anchor: SecurityPaperSourceAnchor
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { anchor.view = view }
}

/// The origin and quote enter the modal atomically; a separate State value can
/// be stale in the fullScreenCover closure on its first presentation.
struct SecurityPaperRequest: Identifiable {
    let id = UUID()
    let context: SecurityPriceMoveContext
    let sourceFrame: CGRect
    init?(context: SecurityPriceMoveContext, sourceFrame: CGRect) {
        guard !sourceFrame.isEmpty,
              [sourceFrame.minX, sourceFrame.minY, sourceFrame.width, sourceFrame.height].allSatisfy({ $0.isFinite }) else { return nil }
        self.context = context
        self.sourceFrame = sourceFrame
    }
}
