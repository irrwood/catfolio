import SwiftUI
import UIKit

private typealias PortfolioHomeTypography = LegacyType

private struct PortfolioHomeTopBackground: View {
    @Environment(\.locale) private var appLocale
    let colorScheme: ColorScheme

    var body: some View {
        LinearGradient(
            stops: colorScheme == .light
                ? [
                    // Figma 223:31122: #9ADCFF.
                    .init(color: Color(red: 154 / 255, green: 220 / 255, blue: 1), location: 0),
                    .init(color: .white, location: 1),
                ]
                : [
                    .init(color: .black, location: 0),
                    .init(color: Color(red: 0.192, green: 0.208, blue: 0.235), location: 1),
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct PortfolioHomePageBackdrop: View {
    @Environment(\.locale) private var appLocale
    let colorScheme: ColorScheme
    let scrollState: PortfolioHomeScrollState

    var body: some View {
        ZStack(alignment: .top) {
            (colorScheme == .light ? Color.white : Color.black)

            // Figma 223:31122 uses one uninterrupted viewport gradient from
            // #9ADCFF to the terminal page surface. Keeping it fixed behind
            // the native ScrollView also makes rubber-banding reveal the same
            // background instead of a separate pale-blue extension band.
            PortfolioHomeTopBackground(colorScheme: colorScheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(1 - scrollState.backdropProgress)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

private enum PortfolioContentSheetLayout {
    // Figma 165:6775 starts as a 378pt sheet inside a 402pt canvas.
    static let initialHorizontalInset: CGFloat = 12
    // By the halfway reference (223:29979) the sheet has travelled 263pt
    // and opened to the full canvas width.
    static let widthExpansionDistance: CGFloat = 263
    static let transitionHeight: CGFloat = 326
    // TODAY sits 30pt from the card top and is 17pt tall. Once it has left the
    // screen, use the card's remaining travel to finish the colour transition.
    static let backdropFadeDistance: CGFloat = transitionHeight - 47
    // Leaves the sheet at the screenshot's resting position: the account
    // summary remains visible while the chart is covered by Today.
    static let firstScrollDetent = PortfolioHeroChartLayout.sectionHeight - PortfolioHeroChartLayout.plotTop
    static let topRadius: CGFloat = 38

    static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: topRadius,
            style: .continuous
        )
    }
}

/// Only the small visual layers observe scroll samples. PortfolioView keeps
/// this reference without reading its properties while building financial
/// content, so a pixel of travel does not reconstruct the holdings or charts.
@MainActor @Observable
private final class PortfolioHomeScrollState {
    private(set) var heroOffset: CGFloat = 0
    private(set) var sheetProgress: CGFloat = 0
    private(set) var backdropProgress: CGFloat = 0
    private(set) var indicatorTopInset: CGFloat = 0
    private(set) var hasVisibleIndicatorTrack = false

    @ObservationIgnored private var offset: CGFloat = 0
    @ObservationIgnored private var pull: CGFloat = 0
    @ObservationIgnored private var titleExitOffset: CGFloat?
    @ObservationIgnored private var holdingsTop: CGFloat?
    @ObservationIgnored private var viewportHeight: CGFloat = 0

    func update(offset: CGFloat, pull: CGFloat) {
        self.offset = offset
        self.pull = pull
        if heroOffset != offset { heroOffset = offset }
        let progress = min(max(offset / PortfolioContentSheetLayout.widthExpansionDistance, 0), 1)
        if sheetProgress != progress { sheetProgress = progress }
        updateBackdrop()
        updateIndicator()
    }

    func titleMoved(to bottom: CGFloat) {
        guard pull < 0.5 else { return }
        let exit = offset + bottom
        guard titleExitOffset.map({ abs($0 - exit) > 0.5 }) ?? true else { return }
        titleExitOffset = exit
        updateBackdrop()
    }

    func holdingsMoved(to top: CGFloat) {
        holdingsTop = top
        updateIndicator()
    }

    func viewportChanged(to height: CGFloat) {
        viewportHeight = height
        updateIndicator()
    }

    private func updateBackdrop() {
        guard let start = titleExitOffset else { return }
        let linear = min(max((offset - start) / PortfolioContentSheetLayout.backdropFadeDistance, 0), 1)
        let progress = linear * linear * (3 - 2 * linear)
        if backdropProgress != progress { backdropProgress = progress }
    }

    private func updateIndicator() {
        let inset = max(0, (holdingsTop ?? 0) - offset)
        if indicatorTopInset != inset { indicatorTopInset = inset }
        let visible = holdingsTop != nil && viewportHeight - inset > 32
        if hasVisibleIndicatorTrack != visible { hasVisibleIndicatorTrack = visible }
    }
}

private struct PortfolioPinnedHero: ViewModifier {
    let scrollState: PortfolioHomeScrollState

    func body(content: Content) -> some View {
        content.offset(y: scrollState.heroOffset)
    }
}

private struct PortfolioHomeScrollIndicators: ViewModifier {
    let scrollState: PortfolioHomeScrollState
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, scrollState.indicatorTopInset, for: .scrollIndicators)
            .scrollIndicators(enabled && scrollState.hasVisibleIndicatorTrack ? .automatic : .hidden, axes: .vertical)
            .onGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom)
            } action: { _, height in
                scrollState.viewportChanged(to: height)
            }
    }
}

private struct PortfolioContentSheet<Content: View>: View {
    @Environment(\.locale) private var appLocale
    let scrollState: PortfolioHomeScrollState
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(scrollState: PortfolioHomeScrollState, @ViewBuilder content: () -> Content) {
        self.scrollState = scrollState
        self.content = content()
    }

    private var widthProgress: CGFloat {
        scrollState.sheetProgress
    }

    private var horizontalInset: CGFloat {
        PortfolioContentSheetLayout.initialHorizontalInset * (1 - widthProgress)
    }

    private var settlingProgress: CGFloat {
        widthProgress
    }

    private var sheetShape: UnevenRoundedRectangle {
        PortfolioContentSheetLayout.shape
    }

    var body: some View {
        content
            .background {
                PortfolioContentSheetBackground(
                    colorScheme: colorScheme,
                    settlingProgress: settlingProgress
                )
                .allowsHitTesting(false)
            }
            .clipShape(sheetShape)
            .padding(.horizontal, horizontalInset)
            .accessibilityElement(children: .contain)
    }
}

private struct PortfolioContentSheetBackground: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let colorScheme: ColorScheme
    let settlingProgress: CGFloat

    private var terminalColor: Color {
        colorScheme == .light ? .white : .black
    }

    private var sheetShape: UnevenRoundedRectangle {
        PortfolioContentSheetLayout.shape
    }

    @ViewBuilder
    private var liquidGlassLayer: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.clear, in: sheetShape)
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // The card retains its own glass surface. No separate blur
                // band extends beyond its rounded edge.
                if !reduceTransparency, settlingProgress < 1 {
                    liquidGlassLayer
                }

                LinearGradient(
                    stops: [
                        .init(color: terminalColor.opacity(0.10), location: 0),
                        .init(color: terminalColor.opacity(0.54), location: 0.42),
                        .init(color: terminalColor, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Passive glass avoids a full-card press highlight. Fade to
                // the opaque page colour as the card finishes expanding.
                terminalColor.opacity(reduceTransparency ? 1 : pow(settlingProgress, 3))
            }
            .frame(height: PortfolioContentSheetLayout.transitionHeight)

            terminalColor
        }
    }
}

struct PortfolioView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var selectedHolding: Holding?
    @State private var showsTodayDetail = false
    @State private var homeScrollState = PortfolioHomeScrollState()
    @State private var homeScrollController = PortfolioHomeScrollController()
    @State private var isHomeScrolling = false
    // One namespace per origin. A security shown both in the Today bars and
    // in the holdings list would otherwise publish two sources under the same
    // id, and the transition has no way to know which one it grew from.
    @Namespace private var holdingsRowZoom
    @Namespace private var todayBarZoom
    @Namespace private var holdingPresentationZoom
    @State private var holdingZoomState = SecurityDetailZoomState()

    private var previewsLoading: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--show-portfolio-loading")
        #else
        false
        #endif
    }

    private var isHomeReadyForRipple: Bool {
        !previewsLoading && model.overview != nil && model.portfolioChart != nil
            && !model.holdings.isEmpty && model.portfolioError == nil
            && !model.isPortfolioLoading && !model.isPortfolioChartLoading
            && !model.isHoldingDailyChangesLoading
    }

    var body: some View {
        // RootTabView owns this tab's stack, just as it does for the other tabs.
        Group {
            ScrollViewReader { scrollProxy in
                ZStack {
                    PortfolioHomePageBackdrop(
                        colorScheme: colorScheme,
                        scrollState: homeScrollState
                    )

                    ScrollView {
                        // The hero is visually pinned with an offset while the
                        // foreground sheet scrolls over it. A LazyVStack judges
                        // visibility from the hero's untransformed layout frame,
                        // so it used to recycle the entire chart exactly when the
                        // range picker crossed the sheet edge. There are only two
                        // structural children here; keep them resident and let the
                        // long content inside them own any useful laziness.
                        VStack(spacing: 0) {
                            PortfolioRefreshTimestamp(
                                date: model.localUpdatedAt,
                                cachedAt: model.portfolioCachedAt,
                                isRefreshing: model.isPortfolioLoading
                            )

                            if previewsLoading {
                                PortfolioLoadingView(scrollState: homeScrollState)
                            } else if model.holdings.isEmpty, model.overview != nil {
                                if model.isPublicInvestorMode && !model.isPortfolioLoading {
                                    ContentUnavailableView(L10n.text("暂无持仓数据"), systemImage: "person.crop.circle", description: Text(L10n.text("请在设置中选择账户。")))
                                } else {
                                    PortfolioLoadingView(isAnimating: model.isPortfolioLoading, scrollState: homeScrollState)
                                }
                            } else if let overview = model.overview, let chart = model.portfolioChart {
                                CostMarketCard(
                                    overview: overview,
                                    response: chart,
                                    isAwaitingEnrichedHistory: model.isPortfolioChartLoading
                                )
                                    // Account changes start a new chart; quote and
                                    // history revisions update the existing one.
                                    .id(model.selectedAccountKeys.sorted())
                                    // Keep the hero visually fixed in its original
                                    // scroll slot. The foreground sheet below moves
                                    // normally and therefore covers it as it rises.
                                    .modifier(PortfolioPinnedHero(scrollState: homeScrollState))
                                    .zIndex(0)

                                PortfolioContentSheet(scrollState: homeScrollState) {
                                    VStack(spacing: 0) {
                                        TodayContributionCard(
                                            holdings: model.holdings,
                                            dailyChanges: model.holdingDailyChanges,
                                            benchmarkChange: model.benchmarkDailyChange,
                                            isLoading: model.isHoldingDailyChangesLoading,
                                            onOpenDetail: { showsTodayDetail = true },
                                            onTitleBottomPositionChange: { titleBottomY in
                                                homeScrollState.titleMoved(to: titleBottomY)
                                            },
                                            zoomNamespace: todayBarZoom
                                        ) { holding in
                                            openHolding(holding, from: todayBarZoom)
                                        }
                                        .id("today-contribution")

                                        PortfolioDetailsCard(
                                            holdings: model.holdings,
                                            onSelect: { holding in
                                                openHolding(holding, from: holdingsRowZoom)
                                            },
                                            zoomNamespace: holdingsRowZoom,
                                            floatsFilter: true
                                        )
                                        .id("portfolio-details")
                                        .onGeometryChange(for: CGFloat.self) { geometry in
                                            geometry.frame(in: .named("portfolio-home-content")).minY
                                        } action: { _, top in
                                            homeScrollState.holdingsMoved(to: top)
                                        }
                                    }
                                }
                                .zIndex(1)
                            } else if model.isPortfolioLoading {
                                PortfolioLoadingView(scrollState: homeScrollState)
                            } else if let error = model.portfolioError {
                                ContentUnavailableView {
                                    Label(L10n.text("暂时无法加载"), systemImage: "wifi.exclamationmark")
                                } description: {
                                    Text(error)
                                } actions: {
                                    Button(L10n.text("重试")) { Task { await model.refreshPortfolio() } }
                                }
                                .frame(minHeight: 420)
                            } else {
                                PortfolioLoadingView(scrollState: homeScrollState)
                            }
                        }
                        // Leave a deliberate scroll tail above the floating
                        // custom tab bar so the final portfolio content can
                        // settle fully in view instead of ending beneath it.
                        .padding(.bottom, 96)
                        .coordinateSpace(name: "portfolio-home-content")
                        .background {
                            PortfolioHomeScrollBridge(
                                controller: homeScrollController,
                                detent: PortfolioContentSheetLayout.firstScrollDetent,
                                reduceMotion: reduceMotion,
                                onOffset: { offset, pull in
                                    homeScrollState.update(offset: offset, pull: pull)
                                },
                                refresh: { await model.refreshPortfolio() }
                            )
                        }
                    }
                    .background(Color.clear)
                    .onScrollPhaseChange { _, phase in
                        isHomeScrolling = phase != .idle
                    }
                    // Keep the native indicator track beside the holdings only;
                    // changing indicator margins leaves content and detents intact.
                    .modifier(PortfolioHomeScrollIndicators(
                        scrollState: homeScrollState,
                        enabled: !previewsLoading && !model.holdings.isEmpty
                    ))
                    .tracksRootTabBarScroll()
                    // One native rubber-band and refresh control, armed only
                    // by a new touch at the completely settled lower stop.
                    .scrollBounceBehavior(.always, axes: .vertical)
                    .accessibilityIdentifier("portfolio-scroll")
                    .task {
                        if model.overview == nil && !model.isPortfolioLoading {
                            await model.refreshPortfolio()
                        }
                        let arguments = ProcessInfo.processInfo.arguments
                        if arguments.contains("--show-volume"), selectedHolding == nil {
                            let requestedTicker = arguments
                                .first(where: { $0.hasPrefix("--show-volume-ticker=") })?
                                .split(separator: "=", maxSplits: 1)
                                .last
                                .map { String($0).uppercased() }
                            selectedHolding = requestedTicker.flatMap { ticker in
                                model.holdings.first { $0.ticker.uppercased() == ticker }
                            } ?? model.holdings.first
                        }
                        if arguments.contains("--show-today-contribution") {
                            try? await Task.sleep(for: .milliseconds(250))
                            scrollProxy.scrollTo("today-contribution", anchor: .top)
                        }
                    }
                }
                .modifier(PortfolioLoadRipple(
                    isReady: isHomeReadyForRipple,
                    isScrolling: isHomeScrolling
                ))
                .modifier(PortfolioFloatingFilterOverlay())
                .securityDetailZoomHost(holdingZoomState, in: holdingPresentationZoom)
                .sheet(item: $selectedHolding, onDismiss: { holdingZoomState.didDismiss() }) { holding in
                    HoldingDetailView(holding: holding, onClose: { selectedHolding = nil })
                        .environment(model)
                        .securityDetailSheet()
                        .securityDetailZoomTransition(holdingZoomState.activeSource, in: holdingPresentationZoom)
                }
                .securityDetailOpenFeedback(trigger: selectedHolding?.ticker, enabled: hapticsEnabled)
                .navigationDestination(isPresented: $showsTodayDetail) {
                    TodayDetailView(
                        holdings: model.holdings,
                        dailyChanges: model.holdingDailyChanges,
                        benchmarkChange: model.benchmarkDailyChange
                    )
                }
            }
            // Inside the stack, so it hides the bar for this screen only.
            // Applied to the stack itself it becomes a stack-wide preference
            // that every pushed screen inherits and none of them can override
            // — which left the Today detail with a title and a back button
            // over no background at all.
            .toolbar(.hidden, for: .navigationBar)
        }
        .accessibilityIdentifier("page.portfolio")
    }

    private func openHolding(_ holding: Holding, from namespace: Namespace.ID) {
        guard selectedHolding == nil, holdingZoomState.activeSource == nil,
              !homeScrollController.touchCaughtMotion else { return }
        holdingZoomState.prepare(id: holding.ticker, namespace: namespace) {
            selectedHolding = holding
        }
    }

}

private struct PortfolioRefreshTimestamp: View {
    @Environment(\.locale) private var appLocale
    let date: Date?
    let cachedAt: Date?
    let isRefreshing: Bool

    var body: some View {
        Group {
            if let cachedAt {
                Text(L10n.text("上次显示于 \(cachedAt.formatted(.dateTime.month().day().hour().minute().locale(appLocale)))"))
                    .appNumber(.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let date {
                Text(L10n.text("更新于 \(date.formatted(.dateTime.hour().minute()))"))
                    .appNumber(.micro)
                    .foregroundStyle(Color.primary.opacity(0.44))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cachedAt != nil ? 20 : 0)
        .offset(y: cachedAt != nil ? 0 : -16)
        .opacity(isRefreshing || cachedAt != nil ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isRefreshing)
        .accessibilityHidden(!isRefreshing && cachedAt == nil)
        .accessibilityLabel(cachedAt.map { L10n.text("上次显示于 \($0.formatted(.dateTime.month().day().hour().minute().locale(appLocale)))") }
            ?? date.map { L10n.text("数据更新于 \($0.formatted(.dateTime.hour().minute()))") } ?? "")
    }
}

private struct TodayContributionCard: View {
    @Environment(\.locale) private var appLocale
    private enum Direction: Hashable {
        case gains
        case losses
    }

    private struct Contribution: Identifiable {
        let holding: Holding
        let changePercent: Double
        let amount: Double

        var id: String { holding.ticker }
    }

    private static let launchDirection: Direction = ProcessInfo.processInfo.arguments.contains("--show-today-losses")
        ? .losses
        : .gains

    let holdings: [Holding]
    let dailyChanges: [String: Double]
    let benchmarkChange: Double?
    let isLoading: Bool
    var onOpenDetail: (() -> Void)? = nil
    var onTitleBottomPositionChange: ((CGFloat) -> Void)? = nil
    let onSelect: (Holding) -> Void
    let zoomNamespace: Namespace.ID?

    /// Derived once per view value rather than on every `body` pass.
    ///
    /// `body` reads this about ten times per evaluation — directly, and through
    /// `totalAmount`, `totalPercent`, `isAwaitingContributions`, `barAnimationKey`
    /// and `visibleContributions` — and it re-evaluates on every frame of the
    /// bar-reveal animation. Each pass uppercased a ticker and hashed it into
    /// `dailyChanges` for every holding. It depends only on `holdings` and
    /// `dailyChanges`, never on `@State`, so SwiftUI rebuilds it exactly when
    /// those inputs change.
    private let contributions: [Contribution]

    @State private var direction: Direction = TodayContributionCard.launchDirection
    @State private var barRevealProgress: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("catfolio.haptics") private var hapticsEnabled = true

    init(
        holdings: [Holding],
        dailyChanges: [String: Double],
        benchmarkChange: Double?,
        isLoading: Bool,
        onOpenDetail: (() -> Void)? = nil,
        onTitleBottomPositionChange: ((CGFloat) -> Void)? = nil,
        zoomNamespace: Namespace.ID? = nil,
        onSelect: @escaping (Holding) -> Void
    ) {
        self.holdings = holdings
        self.dailyChanges = dailyChanges
        self.benchmarkChange = benchmarkChange
        self.isLoading = isLoading
        self.onOpenDetail = onOpenDetail
        self.onTitleBottomPositionChange = onTitleBottomPositionChange
        self.zoomNamespace = zoomNamespace
        self.onSelect = onSelect
        self.contributions = Self.makeContributions(holdings: holdings, dailyChanges: dailyChanges)
    }

    private static func makeContributions(
        holdings: [Holding],
        dailyChanges: [String: Double]
    ) -> [Contribution] {
        holdings.compactMap { holding in
            let key = holding.ticker.uppercased()
            guard let change = dailyChanges[key] ?? holding.todayChangePercent,
                  change.isFinite,
                  holding.marketValue.isFinite else { return nil }
            let factor = 1 + change / 100
            guard factor > 0 else { return nil }
            return Contribution(
                holding: holding,
                changePercent: change,
                amount: holding.marketValue - holding.marketValue / factor
            )
        }
    }

    private var totalAmount: Double {
        guard !holdings.contains(where: { $0.publicDisclosure != nil }) else { return .nan }
        return contributions.reduce(0) { $0 + $1.amount }
    }

    private var totalPercent: Double {
        guard totalAmount.isFinite else { return .nan }
        let currentValue = holdings.reduce(0) { $0 + $1.marketValue }
        let previousValue = currentValue - totalAmount
        guard previousValue > 0 else { return 0 }
        return totalAmount / previousValue * 100
    }

    private var isAwaitingContributions: Bool {
        isLoading && contributions.isEmpty
    }

    private var visibleContributions: [Contribution] {
        let filtered = contributions.filter { contribution in
            direction == .gains ? contribution.amount > 0 : contribution.amount < 0
        }
        return Array(filtered.sorted { lhs, rhs in
            direction == .gains ? lhs.amount > rhs.amount : lhs.amount < rhs.amount
        }.prefix(5))
    }

    private var barAnimationKey: String {
        let directionKey = direction == .gains ? "gains" : "losses"
        return ([directionKey] + visibleContributions.map(\.id)).joined(separator: "|")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            todayBackground
                .allowsHitTesting(false)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(L10n.text("TODAY"))
                            .appCaps(.caption, weight: .semibold)
                            .foregroundStyle(.primary)
                        if onOpenDetail != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 17, alignment: .topLeading)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .global).maxY
                    } action: { _, newValue in
                        onTitleBottomPositionChange?(newValue)
                    }
                    .accessibilityAddTraits(onOpenDetail == nil ? [] : .isButton)
                    .accessibilityLabel(L10n.text("今日盈亏详情"))

                    Group {
                        if contributions.isEmpty {
                            HomeSkeletonBlock(width: 133, height: 22, color: HomeSkeletonStyle.color(for: colorScheme))
                                .accessibilityLabel(L10n.text("正在计算今日贡献"))
                        } else {
                            CatfolioDisplayAmountText(
                                text: DisplayFormat.money(totalAmount, signed: true, fractionDigits: 2),
                                color: .primary
                            )
                            .contentTransition(.numericText(value: totalAmount))
                        }
                    }
                    .frame(height: 39, alignment: .leading)

                    HStack(spacing: 5) {
                        if contributions.isEmpty {
                            if isAwaitingContributions {
                                HomeSkeletonBlock(width: 168, height: 11, color: HomeSkeletonStyle.color(for: colorScheme))
                            } else {
                                Text(L10n.text("行情暂不可用"))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(DisplayFormat.percent(totalPercent))
                                .foregroundStyle(.primary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            benchmarkSummary
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                    }
                    .appNumber(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(height: 20, alignment: .bottomLeading)
                }
                // The title, the amount and the line under it all open the
                // day's detail, up to the direction picker.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onOpenDetail?() }

                directionPicker
            }
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            .padding(.top, 30)
            .frame(height: 106, alignment: .top)

            Group {
                if contributions.isEmpty {
                    TodayContributionLoadingBars(isAnimating: isAwaitingContributions)
                        .frame(height: 167, alignment: .top)
                } else if visibleContributions.isEmpty {
                    ContentUnavailableView(
                        direction == .gains ? L10n.text("今天暂无上涨持仓") : L10n.text("今天暂无下跌持仓"),
                        systemImage: direction == .gains ? "arrow.up.right" : "arrow.down.right"
                    )
                    .frame(maxWidth: .infinity, minHeight: 167)
                } else {
                    contributionBars
                        .frame(height: 167)
                }
            }
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            .offset(y: 139)
        }
        .frame(height: 326)
        .task(id: barAnimationKey) {
            var resetTransaction = Transaction(animation: nil)
            resetTransaction.disablesAnimations = true
            withTransaction(resetTransaction) {
                barRevealProgress = reduceMotion ? 1 : 0
            }

            guard !reduceMotion, !visibleContributions.isEmpty else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(TodayContributionAnimation.reveal) {
                barRevealProgress = 1
            }
        }
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced {
                barRevealProgress = 1
            }
        }
        .sensoryFeedback(.selection, trigger: direction) { _, _ in hapticsEnabled }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var benchmarkSummary: some View {
        if let benchmarkChange, benchmarkChange.isFinite {
            let difference = totalPercent - benchmarkChange
            Text("\(difference >= 0 ? "+" : "-")SPY \(DisplayFormat.percent(abs(difference), signed: false))")
        } else {
            Text(L10n.text("SPY 暂无数据"))
        }
    }

    @ViewBuilder
    private var todayBackground: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 38,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 38,
            style: .continuous
        )
        if colorScheme == .light {
            // The shared content sheet owns the light glass-to-white surface.
            // Keep this card clear so the hero chart can show through its top.
            shape.fill(Color.clear)
        } else {
            let showsGains = direction == .gains
            let baseColor = showsGains
                ? Color(red: 0, green: 0.255, blue: 0)
                : Color(red: 0.22, green: 0.031, blue: 0.02)
            let glowColor = showsGains
                ? CatfolioPalette.contributionGreen
                : CatfolioPalette.contributionRedGlow

            shape
                .fill(
                    LinearGradient(
                        colors: [baseColor, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(glowColor.opacity(showsGains ? 0.45 : 0.40))
                        .frame(width: 205, height: 205)
                        .blur(radius: 50)
                        .offset(x: 220, y: -92)
                }
                .clipShape(shape)
                .animation(.easeOut(duration: 0.18), value: direction)
        }
    }

    private var contributionBars: some View {
        let values = visibleContributions
        let rankHeights: [Double] = [1, 0.50, 0.28, 0.16, 0]

        return HStack(alignment: .top, spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                Group {
                    if index < values.count {
                        let contribution = values[index]
                        TodayContributionBar(
                            holding: contribution.holding,
                            amount: contribution.amount,
                            relativeHeight: rankHeights[index],
                            isGain: direction == .gains,
                            growth: barRevealProgress,
                            zoomNamespace: zoomNamespace
                        ) {
                            onSelect(contribution.holding)
                        }
                        // The five visual slots are reused during the direction
                        // animation. Give their contents a security identity so
                        // a newly ranked company cannot retain the previous
                        // slot's logo or other view-local state.
                        .id(contribution.id)
                    } else {
                        Color.clear
                            .frame(height: 167)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var directionPicker: some View {
        directionPickerContent
            .background(Color.white.opacity(0.40), in: Capsule())
    }

    private var directionPickerContent: some View {
        HStack(spacing: 2) {
            directionButton(.gains, systemImage: "arrow.up")
            directionButton(.losses, systemImage: "arrow.down")
        }
        .padding(3)
        .frame(width: 97, height: 47)
    }

    private func directionButton(_ value: Direction, systemImage: String) -> some View {
        Button {
            switchDirection(to: value)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255))
                .frame(width: 44, height: 41)
                .background {
                    if direction == value {
                        Capsule()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.10), radius: 2, y: 2)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == .gains ? L10n.text("上涨贡献") : L10n.text("下跌贡献"))
        .accessibilityAddTraits(direction == value ? .isSelected : [])
    }

    private func switchDirection(to value: Direction) {
        guard value != direction else { return }
        // Reset the one shared progress value in the same transaction that
        // swaps the ranking. The incoming five bars therefore never render a
        // stale fully-grown frame before their common reveal begins.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            barRevealProgress = reduceMotion ? 1 : 0
            direction = value
        }
    }
}

private enum TodayContributionAnimation {
    static var reveal: Animation {
        .timingCurve(0.16, 1, 0.30, 1, duration: 0.34)
    }
}

private struct TodayContributionBar: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let amount: Double
    let relativeHeight: Double
    let isGain: Bool
    let growth: CGFloat
    var zoomNamespace: Namespace.ID?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var resolvedBrandColor: Color?
    @State private var isHovering = false

    private var accent: Color {
        isGain
            ? CatfolioPalette.contributionGreen
            : CatfolioPalette.contributionRed
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [accent, colorScheme == .light ? .white : .black],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // Retained while the legacy glass helpers below remain source-compatible;
    // the current Figma treatment no longer renders this colour mix.
    private var brandAccent: Color {
        resolvedBrandColor ?? AssetBrandColor.fallback(for: holding.logoSymbol ?? holding.ticker)
    }

    private var barHeight: CGFloat {
        66 + CGFloat(min(max(relativeHeight, 0), 1)) * 80
    }

    private var renderedBarHeight: CGFloat {
        max(0, barHeight * growth)
    }

    private var renderedCornerRadius: CGFloat {
        min(12, renderedBarHeight / 2)
    }

    var body: some View {
        let fillShape = RoundedRectangle(cornerRadius: renderedCornerRadius, style: .continuous)

        Button(action: action) {
            ZStack(alignment: .top) {
                ZStack(alignment: .bottom) {
                    ZStack(alignment: .top) {
                        // Keep the gradient and texture in one isolated blend
                        // group. The stripe source stays pure black; `.overlay`
                        // derives its visible colour from the green underneath.
                        // Opacity is applied after blending rather than baked
                        // into the source colour, which otherwise reads as a
                        // separate pale-green decoration on device.
                        fillShape
                            .fill(barGradient)
                            .overlay {
                                ContributionStripePattern(color: .black)
                                    .blendMode(.overlay)
                                    // Figma uses a pure-black stripe group at
                                    // 40% opacity. The base green-to-white
                                    // gradient makes the texture fade naturally;
                                    // an additional opacity mask darkens the
                                    // middle of the bar and must not be added.
                                    .opacity(0.40)
                            }
                            .compositingGroup()
                            .opacity(growth)

                        // Full figure while it fits, abbreviated when it does
                        // not. A bar's width is whatever is left after the
                        // others take theirs, so the same number fits on a
                        // two-bar day and not on a six-bar one — which is why
                        // this asks the layout rather than guessing from the
                        // magnitude. Shrinking to fit was the previous
                        // answer, and at a nine-figure total it produced a
                        // truncated string with no decimal point in it.
                        ViewThatFits(in: .horizontal) {
                            barAmountLabel(amountText)
                            barAmountLabel(compactAmountText)
                            barAmountLabel(compactAmountText)
                                .minimumScaleFactor(0.62)
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                        .opacity(growth)
                    }
                    .frame(height: renderedBarHeight)
                    .clipShape(fillShape, style: FillStyle(antialiased: true))
                    // The page grows out of the green bar itself, not the
                    // 167pt slot around it: landing on the slot, the zoom
                    // ended on a tall green card and then dropped to the
                    // shorter bar under it.
                    .holdingZoomSource(holding.ticker, in: zoomNamespace)
                }
                .frame(maxWidth: .infinity, minHeight: 146, maxHeight: 146, alignment: .bottom)

                contributionLogo
                    .scaleEffect(0.76 + growth * 0.24)
                    .opacity(growth)
                    .offset(y: 131)
            }
            .frame(maxWidth: .infinity, minHeight: 167, maxHeight: 167, alignment: .top)
        }
        .buttonStyle(ContributionBarButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .accessibilityLabel(L10n.text("\(holding.shortName)，今日贡献 \(DisplayFormat.money(amount, signed: true, fractionDigits: 2))"))
        .accessibilityHint(L10n.text("打开个股详情"))
    }

    private var contributionLogo: some View {
        AssetLogo(
            ticker: holding.ticker,
            logoSymbol: holding.logoSymbol,
            size: 36,
            onBrandColorResolved: { resolvedBrandColor = $0 }
        )
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var amountText: String {
        DisplayCurrency.current.fromUSD(abs(amount)).formatted(
            .number.precision(.fractionLength(2))
        )
    }

    /// The same amount, abbreviated. Pence are noise at this magnitude, so
    /// the compact form drops them rather than carrying two decimals into a
    /// space that could not hold the digits.
    ///
    private var compactAmountText: String {
        DisplayFormat.compact(DisplayCurrency.current.fromUSD(abs(amount)))
    }

    private func barAmountLabel(_ text: String) -> some View {
        Text(text)
            .appNumber(.caption, weight: .semibold)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private var amountBubble: some View {
        Text(
            DisplayCurrency.current.fromUSD(abs(amount)).formatted(
                .number.precision(.fractionLength(2))
            )
        )
            .appNumber(.micro, weight: .bold)
            .foregroundStyle(colorScheme == .dark ? Color.white : accent)
            .lineLimit(1)
            .minimumScaleFactor(0.48)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 25)
            .background {
                ContributionGlassSurface(
                    shape: Capsule(),
                    tint: accent,
                    secondaryTint: brandAccent,
                    tintOpacity: colorScheme == .dark ? 0.09 : 0.055
                )
            }
            .padding(.horizontal, 3)
    }

    private var liquidGlassBar: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return ZStack {
            ContributionGlassSurface(
                shape: shape,
                tint: accent,
                secondaryTint: brandAccent,
                tintOpacity: colorScheme == .dark ? 0.12 : 0.085
            )

            ZStack {
                // The colour lives inside the shell. Its opacity is constant for
                // every bar; only the bar height communicates magnitude.
                shape
                    .fill(accent.opacity(colorScheme == .dark ? 0.46 : 0.36))

                shape
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: brandAccent.opacity(colorScheme == .dark ? 0.88 : 0.78), location: 0),
                                .init(color: brandAccent.opacity(colorScheme == .dark ? 0.52 : 0.44), location: 0.42),
                                .init(color: .clear, location: 1),
                            ],
                            center: UnitPoint(x: 0.30, y: 0.30),
                            startRadius: 0,
                            endRadius: 52
                        )
                    )
                    .blendMode(.color)

                shape
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: accent.opacity(colorScheme == .dark ? 0.80 : 0.68), location: 0),
                                .init(color: accent.opacity(colorScheme == .dark ? 0.42 : 0.32), location: 0.50),
                                .init(color: .clear, location: 1),
                            ],
                            center: UnitPoint(x: 0.64, y: 0.72),
                            startRadius: 0,
                            endRadius: 72
                        )
                    )

                // Keep the semantic colour dominant across the data body while
                // anchoring a saturated, logo-adjacent brand zone at the base.
                // This avoids muddy RGB interpolation between complementary hues.
                shape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.48),
                                .init(color: brandAccent.opacity(0.16), location: 0.62),
                                .init(color: brandAccent.opacity(0.76), location: 0.84),
                                .init(color: brandAccent.opacity(0.88), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                shape
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(colorScheme == .dark ? 0.12 : 0.25), location: 0),
                                .init(color: Color.white.opacity(0.035), location: 0.24),
                                .init(color: .clear, location: 0.58),
                                .init(color: accent.opacity(0.08), location: 1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .clipShape(shape)

            shape
                .inset(by: 0.45)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.54 : 0.90),
                            Color.white.opacity(colorScheme == .dark ? 0.16 : 0.34),
                            Color.primary.opacity(0.055),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .allowsHitTesting(false)
        }
        .contentShape(shape)
    }
}


/// A neutral, refractive shell shared by the contribution bar, value capsule,
/// and raised logo lens. Accent colour is intentionally restrained: the light
/// source is rendered behind/inside the shell rather than painted onto it.
private struct ContributionGlassSurface<S: InsettableShape>: View {
    @Environment(\.locale) private var appLocale
    let shape: S
    let tint: Color
    let secondaryTint: Color
    let tintOpacity: Double
    var strokeWidth: CGFloat = 0.8

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Material supplies transparency/refraction without the automatic
            // cast shadow added by the system Liquid Glass renderer.
            shape
                .fill(.ultraThinMaterial)

            shape
                .fill(Color.white.opacity(colorScheme == .dark ? 0.018 : 0.055))

            shape
                .fill(tint.opacity(tintOpacity))

            shape
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: secondaryTint.opacity(tintOpacity * 2.4), location: 0),
                            .init(color: secondaryTint.opacity(tintOpacity * 0.82), location: 0.38),
                            .init(color: .clear, location: 1),
                        ],
                        center: UnitPoint(x: 0.26, y: 0.24),
                        startRadius: 0,
                        endRadius: 44
                    )
                )
                .blendMode(.color)

            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(colorScheme == .dark ? 0.18 : 0.42), location: 0),
                            .init(color: Color.white.opacity(0.055), location: 0.28),
                            .init(color: .clear, location: 0.62),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            shape
                .inset(by: 0.45)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(colorScheme == .dark ? 0.52 : 0.84), location: 0),
                            .init(color: Color.white.opacity(colorScheme == .dark ? 0.18 : 0.36), location: 0.42),
                            .init(color: Color.primary.opacity(0.065), location: 1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: strokeWidth
                )
        }
        .allowsHitTesting(false)
    }
}

private struct ContributionBarButtonStyle: ButtonStyle {
    let isHovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let isActive = configuration.isPressed || isHovering
        configuration.label
            // Keep the response restrained: a pointer gently lifts the column,
            // while a touch compresses it like a physical control. Brightness
            // and saturation provide the faint highlight without adding the
            // permanent shadow that was removed from the bar treatment.
            .scaleEffect(
                reduceMotion ? 1 : (configuration.isPressed ? 0.985 : (isHovering ? 1.012 : 1)),
                anchor: .bottom
            )
            .brightness(isActive ? 0.035 : 0)
            .saturation(isActive ? 1.06 : 1)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isHovering)
    }
}

private enum PortfolioHeroChartLayout {
    static let sectionHeight: CGFloat = 461
    static let plotTop: CGFloat = 118
    // Keep the UIKit-backed chart's frame entirely above the range picker.
    // A visual overlap can still intercept taps even when the chart's own
    // gesture overlay is inset, particularly with iOS 26 dark rendering.
    static let plotHeight: CGFloat = 280
    // Keep UIKit's long-press capture view away from the range buttons. The
    // chart still draws at full height; only its interactive surface is inset.
    static let chartInteractionBottomInset: CGFloat = 24
    static let pickerTop: CGFloat = 398
    static let pickerHeight: CGFloat = 62
}

private struct CostMarketCard: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model

    let overview: PortfolioOverview
    let warning: String?
    let response: PortfolioChartResponse
    let isAwaitingEnrichedHistory: Bool
    @State private var prepared: CostMarketPreparedData?
    @State private var isPreparing = true
    @State private var hasPreparedAllRanges = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var range = ChartTimeRange.yearToDate
    @State private var selectedDate: Date?
    @State private var measuredRange: ChartDateRange?
    @State private var showsNetDeposit = true
    @State private var showsAccountBasis = false
    @Environment(\.colorScheme) private var colorScheme

    private var forcesChartLoadingState: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-chart-loading-state")
    }

    private var isChartLoading: Bool {
        forcesChartLoadingState || (prepared == nil && (isPreparing || isAwaitingEnrichedHistory))
    }

    init(
        overview: PortfolioOverview,
        response: PortfolioChartResponse,
        isAwaitingEnrichedHistory: Bool
    ) {
        self.overview = overview
        self.warning = response.warning
        self.response = response
        self.isAwaitingEnrichedHistory = isAwaitingEnrichedHistory
    }

    private var rangeData: CostMarketRangeData {
        prepared?.data(for: range) ?? .empty
    }

    private var selectedPoint: CostMarketPlotPoint? {
        if let measuredRange {
            return rangeData.nearest(to: measuredRange.end)
        }
        guard let selectedDate else { return rangeData.rows.last }
        return rangeData.nearest(to: selectedDate)
    }

    private var measuredPoints: (start: CostMarketPlotPoint, end: CostMarketPlotPoint)? {
        guard let measuredRange,
              let start = rangeData.nearest(to: measuredRange.start),
              let end = rangeData.nearest(to: measuredRange.end) else { return nil }
        return (start, end)
    }

    private var displayedMarketValue: Double {
        if response.accountNAV != nil { return selectedPoint?.marketValue ?? response.currentPoint.marketValue }
        return selectedPoint?.marketValue ?? overview.summary.marketValue
    }

    private var displayedCost: Double {
        if response.accountNAV != nil { return selectedPoint?.cost ?? response.currentPoint.cost }
        return selectedPoint?.cost ?? overview.summary.totalCost
    }

    private var displayedProfit: Double {
        displayedMarketValue - displayedCost
    }

    private var rangePerformance: (amount: Double, percentage: Double) {
        if response.accountNAV != nil {
            if let measurement = measuredPoints {
                return response.accountPerformance(from: measurement.start.dateText, to: measurement.end.dateText)
            }
            guard let first = rangeData.rows.first, let end = selectedPoint,
                  let index = response.positionHistory.rows.firstIndex(where: { $0.dateText == first.dateText }) else { return (.nan, .nan) }
            let opening = response.positionHistory.rows[max(0, index - 1)].dateText
            return response.accountPerformance(from: opening, to: end.dateText)
        }
        if let measurement = measuredPoints {
            return costMarketChange(from: measurement.start, to: measurement.end)
        }
        guard range != .maximum,
              let start = rangeData.rows.first,
              let end = selectedPoint,
              start.id != end.id else {
            let percentage = displayedCost == 0 ? 0 : displayedProfit / displayedCost * 100
            return (displayedProfit, percentage)
        }

        // The market-value line can jump when cash is added or removed. Offset
        // that movement with the matching change in the cost/deposit line so
        // the header describes investment performance for the visible window,
        // rather than mistaking a contribution for a gain.
        return costMarketChange(from: start, to: end)
    }

    private var displayedPrimaryAmount: Double {
        displayedMarketValue
    }

    private var financialAccent: Color {
        if !rangePerformance.amount.isFinite { return .secondary }
        return CatfolioTheme.heroPerformance(for: rangePerformance.amount, scheme: colorScheme)
    }

    /// Nil while the reader is looking at their own portfolio.
    private var portfolioOwnerName: String? {
        PublicInvestorNaming.title(
            selection: model.publicInvestorSelection,
            isDemo: model.isFakeDataMode,
            isInvestorMode: model.isPublicInvestorMode
        )
    }

    var body: some View {
        let data = rangeData
        ZStack(alignment: .topLeading) {
            HStack(spacing: 4) {
                // Whose portfolio this is. Left as "CATFOLIO" the header
                // labels someone else's holdings with the reader's own app
                // name, which is exactly the wrong thing to say above a
                // total that is not theirs.
                if let owner = portfolioOwnerName {
                    Text(owner)
                        .appText(.caption, weight: .semibold)
                } else {
                    Text("CATFOLIO")
                        .appCaps(.caption, weight: .semibold)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                if response.accountNAV != nil {
                    Button { showsAccountBasis = true } label: {
                        Image(systemName: "info.circle").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("账户资产与收益口径"))
                }
            }
            .lineLimit(1)
            .foregroundStyle(.primary)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 15)

            CatfolioDisplayAmountText(
                text: model.publicDisclosureSummary?.amountLabel ?? DisplayFormat.money(
                    displayedPrimaryAmount,
                    signed: false,
                    fractionDigits: 2
                ),
                size: 40,
                symbolSize: 25.8,
                color: .primary
            )
            .contentTransition(.numericText(value: displayedPrimaryAmount))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: displayedPrimaryAmount)
            .frame(height: 44, alignment: .leading)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 32)

            HStack(spacing: 4) {
                let summaryAccent = financialAccent
                Group {
                    Text(DisplayFormat.money(rangePerformance.amount, signed: true))
                        .foregroundStyle(summaryAccent)
                        .contentTransition(.numericText(value: rangePerformance.amount))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: rangePerformance.amount)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text((response.accountNAV != nil ? "TWR " : "") + (rangePerformance.percentage.isFinite ? DisplayFormat.percent(rangePerformance.percentage, signed: false) : "—"))
                        .foregroundStyle(summaryAccent)
                        .contentTransition(.numericText(value: rangePerformance.percentage))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: rangePerformance.percentage)

                    Text("·")
                        .foregroundStyle(.tertiary)
                }

                Button {
                    showsNetDeposit.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.text("NET DEPOSIT"))
                            .appCaps(.footnote)
                        Text(DisplayFormat.money(displayedCost))
                            .numericTransition(displayedCost)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showsNetDeposit ? 1 : 0.45)
                .accessibilityLabel(L10n.text("净入金线"))
                .accessibilityValue(showsNetDeposit ? L10n.text("显示") : L10n.text("隐藏"))
                .accessibilityHint(L10n.text("轻点切换显示或隐藏"))
                .foregroundStyle(Color.primary.opacity(colorScheme == .light ? 0.30 : 0.50))
            }
            .appNumber(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 82)

            chartContent(data: data)
                .frame(height: PortfolioHeroChartLayout.plotHeight)
                .clipped()
                .offset(y: PortfolioHeroChartLayout.plotTop)
                .zIndex(0)

            if !isChartLoading, data.rows.count > 1 {
                chartAxisLabels(data: data)
                    .frame(height: PortfolioHeroChartLayout.plotHeight)
                    .offset(y: PortfolioHeroChartLayout.plotTop)
            }

            ChartTimeRangePicker(
                selection: $range,
                isDisabled: isChartLoading || !hasPreparedAllRanges,
                usesBrightSelectedBackground: true
            )
            .frame(height: PortfolioHeroChartLayout.pickerHeight)
            .contentShape(Rectangle())
            .offset(y: PortfolioHeroChartLayout.pickerTop)
            .zIndex(2)
            .accessibilityLabel(response.accountNAV != nil ? L10n.text("账户资产与净入金时间范围") : L10n.text("成本与市值时间范围"))
        }
        .frame(height: PortfolioHeroChartLayout.sectionHeight, alignment: .topLeading)
        .preference(key: PortfolioHeroReadyPreference.self, value: !isChartLoading && hasPreparedAllRanges)
        .alert(L10n.text("账户资产与收益口径"), isPresented: $showsAccountBasis) {
            Button(L10n.text("知道了"), role: .cancel) { }
        } message: {
            // Paragraph by paragraph, so each is found in the catalogue.
            Text(warning.map { $0.components(separatedBy: "\n\n").map { L10n.label($0) }.joined(separator: "\n\n") }
                 ?? L10n.text("账户历史暂不可用。"))
        }
        .task(id: "\(model.portfolioChartRevision)-\(isAwaitingEnrichedHistory)") {
            // Keep the last prepared curve mounted during background refresh.
            // Interim snapshot-only responses must not replace enriched history.
            guard !isAwaitingEnrichedHistory else { return }
            let response = response
            let initialRange = range
            let initialRanges: [ChartTimeRange] = initialRange == .maximum
                ? [.maximum]
                : [initialRange, .maximum]
            let source = await Task.detached(priority: .userInitiated) {
                CostMarketPreparedSource(response: response)
            }.value
            guard !Task.isCancelled else { return }
            if !hasPreparedAllRanges {
                let initial = await Task.detached(priority: .userInitiated) {
                    CostMarketPreparedData(source: source, requestedRanges: initialRanges)
                }.value
                guard !Task.isCancelled else { return }
                self.prepared = initial
                if initial.data(for: range).rows.count <= 1,
                   initial.data(for: .maximum).rows.count > 1 {
                    range = .maximum
                }
                isPreparing = false
                applyLaunchSelectionIfNeeded()
            }

            // The first visible plot should not wait for every alternate
            // range. Fill those caches at lower priority after the default
            // range is already on screen; the picker stays disabled until the
            // complete set is ready, so it can never select an empty cache.
            // On refresh, keep the existing complete cache interactive until
            // its replacement is ready; never dim the picker for background work.
            let complete = await Task.detached(priority: .utility) {
                CostMarketPreparedData(source: source)
            }.value
            guard !Task.isCancelled else { return }
            self.prepared = complete
            hasPreparedAllRanges = true
            if complete.data(for: range).rows.count <= 1,
               let availableRange = ChartTimeRange.allCases.first(where: {
                   complete.data(for: $0).rows.count > 1
               }) {
                range = availableRange
            }
        }
        .onChange(of: range) { _, _ in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedDate = nil
                measuredRange = nil
            }
        }
    }

    @ViewBuilder
    private func chartContent(data: CostMarketRangeData) -> some View {
        if forcesChartLoadingState || isChartLoading {
            StandardLineChartSkeleton(
                axisWidth: 0,
                topInset: 0,
                trailingEndpointInset: 21,
                seriesCount: 2,
                lineWidths: [2.5],
                appearanceID: "portfolio-assets"
            )
                .accessibilityElement()
                .accessibilityLabel(L10n.text("正在准备历史数据"))

        } else if data.rows.count > 1 {
            FastCostMarketPlot(
                data: data,
                showsNetDeposit: showsNetDeposit,
                transitionKey: range.rawValue,
                showsLatestPoint: range != .oneDay,
                selectedPoint: selectedDate == nil && measuredRange == nil ? nil : selectedPoint,
                measuredRange: measuredRange,
                selectionIndicatorLabel: selectionIndicatorLabel,
                compactDates: [.oneDay, .oneWeek, .oneMonth, .twoMonths].contains(range),
                onSelect: {
                    guard measuredRange != nil || selectedDate != $0 else { return }
                    measuredRange = nil
                    selectedDate = $0
                },
                onMeasure: {
                    guard measuredRange != $0 else { return }
                    measuredRange = $0
                    selectedDate = $0.end
                },
                onInteractionEnded: { _ in
                    selectedDate = nil
                    measuredRange = nil
                }
            )
            .accessibilityLabel(response.accountNAV != nil ? L10n.text("账户资产与净入金对比图，长按查看单日，双指测量区间") : L10n.text("成本与市值对比图，长按后单指拖动查看单日，保持第一指并加入第二指测量区间"))
        } else {
            StandardLineChartPlaceholder(
                title: L10n.text("历史数据不足"),
                message: warning ?? L10n.text("该时间范围内没有足够的成本与市值记录。"),
                isLoading: false
            )
        }
    }

    private func chartAxisLabels(data: CostMarketRangeData) -> some View {
        let values = [
            data.domain.upperBound,
            (data.domain.lowerBound + data.domain.upperBound) / 2,
            data.domain.lowerBound,
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text(compactAxisValue(value))
                    .appNumber(.footnote)
                if index < values.count - 1 { Spacer() }
            }
        }
        .foregroundStyle(Color.white.opacity(colorScheme == .light ? 0.16 : 0.08))
        .padding(.leading, CatfolioStyle.pageHorizontalInset)
        .padding(.vertical, 13)
        .allowsHitTesting(false)
    }

    /// An axis label. This stopped at M, so a portfolio past a billion drew
    /// `1234M` where the ladder now gives `1B`.
    private func compactAxisValue(_ value: Double) -> String {
        DisplayFormat.compact(value, precision: .whole)
    }

    private func rangeDateText(from start: Date, to end: Date) -> String {
        "\(start.formatted(.dateTime.year().month(.abbreviated).day())) – \(end.formatted(.dateTime.year().month(.abbreviated).day()))"
    }

    private var selectionIndicatorLabel: String? {
        if let measurement = measuredPoints {
            return rangeDateText(from: measurement.start.date, to: measurement.end.date)
        }
        guard selectedDate != nil, let selectedPoint else { return nil }
        if range == .oneDay && response.accountNAV == nil {
            return selectedPoint.date.formatted(.dateTime.hour().minute())
        }
        return selectedPoint.date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private func applyLaunchSelectionIfNeeded() {
        let data = rangeData
        let arguments = ProcessInfo.processInfo.arguments
        guard data.rows.count > 1 else { return }
        if arguments.contains("--show-chart-selection"), selectedDate == nil {
            selectedDate = data.rows[data.rows.count / 3].date
        } else if arguments.contains("--show-chart-range"), measuredRange == nil {
            measuredRange = ChartDateRange(
                data.rows[data.rows.count / 3].date,
                data.rows[(data.rows.count * 2) / 3].date
            )
        }
    }
}

/// Canvas keeps a range switch to one draw pass instead of rebuilding hundreds
/// of Swift Charts marks. Filtering and domains are cached once; every range
/// keeps the original daily vertices so viewport zooms preserve the same curve.
private struct FastCostMarketPlot: View {
    @Environment(\.locale) private var appLocale
    let data: CostMarketRangeData
    let showsNetDeposit: Bool
    let transitionKey: String
    let showsLatestPoint: Bool
    let selectedPoint: CostMarketPlotPoint?
    let measuredRange: ChartDateRange?
    let selectionIndicatorLabel: String?
    let compactDates: Bool
    let onSelect: (Date) -> Void
    let onMeasure: (ChartDateRange) -> Void
    let onInteractionEnded: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme
    private let bottomHeight: CGFloat = 0

    var body: some View {
        let marketSeries = StandardLineChartSeries(
            id: "market",
            points: data.plottedRows.map {
                StandardLineChartPoint(id: $0.id, date: $0.date, value: $0.marketValue)
            },
            color: colorScheme == .light
                ? Color.white
                : CatfolioTheme.gain(for: .dark),
            lineWidth: 2.5,
            latestPointRadius: showsLatestPoint ? 5 : 0,
            latestPointColor: colorScheme == .light ? .black : nil,
            latestPointUsesGlass: false
        )
        let costSeries = StandardLineChartSeries(
            id: "cost",
            points: data.plottedRows.map {
                StandardLineChartPoint(id: "cost|\($0.id)", date: $0.date, value: $0.cost)
            },
            color: Color(red: 0.204, green: 0.459, blue: 1),
            lineWidth: 2.5,
            latestPointRadius: showsLatestPoint ? 5 : 0,
            latestPointUsesGlass: false
        )
        StandardLineChart(
            // Canvas paints later series above earlier ones. Keep the blue
            // net-deposit line underneath the adaptive white/green market
            // line so their crossings preserve the portfolio-value signal.
            series: showsNetDeposit ? [costSeries, marketSeries] : [marketSeries],
            interactionDates: data.rows.map(\.date),
            domain: data.domain,
            yTicks: (0..<5).map { index in
                let fraction = Double(index) / 4
                return data.domain.upperBound
                    - (data.domain.upperBound - data.domain.lowerBound) * fraction
            },
            axisWidth: 0,
            topInset: 0,
            bottomHeight: bottomHeight,
            interactionBottomInset: PortfolioHeroChartLayout.chartInteractionBottomInset,
            leadingLineOverflow: 0,
            trailingEndpointInset: 21,
            gridOpacity: 0,
            transitionKey: "\(transitionKey)-\(colorScheme == .light ? "light" : "dark")",
            appearanceID: "portfolio-assets",
            dataTransition: .viewportZoom,
            animatesInitialAppearance: true,
            selectedDate: selectedPoint?.date,
            measuredRange: measuredRange,
            selectionIndicatorLabel: selectionIndicatorLabel,
            selectionSeriesIDs: showsNetDeposit ? ["market", "cost"] : ["market"],
            rangeSeriesIDs: showsNetDeposit ? ["market", "cost"] : ["market"],
            rangePrimarySeriesID: "market",
            dimsFutureDuringSelection: true,
            yAxisLabel: { _ in "" },
            xAxisLabel: shortDate,
            onSelect: onSelect,
            onMeasure: onMeasure,
            onInteractionEnded: onInteractionEnded
        )
    }

    private func shortDate(_ date: Date) -> String {
        compactDates
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated))
    }
}

private final class CostMarketPreparedSource: @unchecked Sendable {
    let points: [CostMarketPlotPoint]
    let lastDate: Date?
    let previousTradingDate: Date?

    init(response: PortfolioChartResponse) {
        let source = response.positionHistory.rows.isEmpty
            ? [response.currentPoint]
            : response.positionHistory.rows
        points = source.compactMap { row -> CostMarketPlotPoint? in
            guard row.marketValue.isFinite, row.cost.isFinite,
                  let date = DayDateCodec.date(from: row.dateText) else { return nil }
            return CostMarketPlotPoint(
                dateText: row.dateText,
                date: date,
                marketValue: row.marketValue,
                cost: row.cost
            )
        }.sorted { $0.date < $1.date }
        lastDate = points.last?.date
        previousTradingDate = points.dropLast().last?.date
    }
}

private final class CostMarketPreparedData: @unchecked Sendable {
    private let ranges: [ChartTimeRange: CostMarketRangeData]

    init(
        source: CostMarketPreparedSource,
        requestedRanges: [ChartTimeRange] = ChartTimeRange.allCases
    ) {
        let points = source.points

        guard let last = source.lastDate else {
            ranges = [:]
            return
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        ranges = Dictionary(uniqueKeysWithValues: requestedRanges.map { range in
            // Portfolio history is daily rather than intraday. Use the latest
            // two trading snapshots so 1D still shows the day-over-day move
            // instead of collapsing to an unhelpful single point.
            let filtered = points.filter {
                range.includes(
                    $0.date,
                    through: last,
                    previousTradingDate: source.previousTradingDate,
                    calendar: calendar
                )
            }
            return (range, Self.prepare(filtered))
        })
    }

    func data(for range: ChartTimeRange) -> CostMarketRangeData {
        ranges[range] ?? ranges[.maximum] ?? .empty
    }

    private static func prepare(_ points: [CostMarketPlotPoint]) -> CostMarketRangeData {
        guard !points.isEmpty else { return .empty }
        // Range-dependent decimation changes the curve at shared dates. Keep
        // every daily vertex so the transition's union and the resting path
        // have identical geometry inside the final viewport.

        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        for point in points {
            minimum = min(minimum, point.marketValue, point.cost)
            maximum = max(maximum, point.marketValue, point.cost)
        }
        let span = max(maximum - minimum, max(abs(minimum), abs(maximum)) * 0.02, 1)
        let padding = span * 0.12
        return CostMarketRangeData(
            rows: points,
            plottedRows: points,
            domain: (minimum < 0 ? minimum - padding : max(0, minimum - padding))...(maximum + padding)
        )
    }
}

private struct CostMarketRangeData {
    let rows: [CostMarketPlotPoint]
    let plottedRows: [CostMarketPlotPoint]
    let domain: ClosedRange<Double>

    static let empty = CostMarketRangeData(rows: [], plottedRows: [], domain: 0...1)

    func nearest(to date: Date) -> CostMarketPlotPoint? {
        guard !rows.isEmpty else { return nil }
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].date < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return rows[0] }
        guard lower < rows.count else { return rows[rows.count - 1] }
        let before = rows[lower - 1]
        let after = rows[lower]
        return abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
    }
}

/// Change in the chart's cost-adjusted value, not a ledger-backed TWR/IRR.
/// Inputs share the chart's reporting currency; do not convert either endpoint twice.
private func costMarketChange(
    from start: CostMarketPlotPoint, to end: CostMarketPlotPoint
) -> (amount: Double, percentage: Double) {
    let amount = (end.marketValue - start.marketValue) - (end.cost - start.cost)
    return (amount, start.marketValue == 0 ? 0 : amount / start.marketValue * 100)
}

private struct CostMarketPlotPoint: Identifiable {
    let dateText: String
    let date: Date
    let marketValue: Double
    let cost: Double

    var id: String { dateText }
}

/// Marks a row as the thing the security page grows out of.
///
/// The namespace is optional because this card is also built in places that
/// present the page without a zoom, and a source without a matching
/// destination animates from nowhere.
extension View {
    @ViewBuilder
    func holdingZoomSource(_ ticker: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            catfolioZoomSource(ticker, in: namespace)
        } else {
            self
        }
    }
}

struct PortfolioDetailsCard: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let holdings: [Holding]
    let onSelect: (Holding) -> Void
    let showsHeatmap: Bool
    let zoomNamespace: Namespace.ID?
    /// Set on the Performance tab: the heatmap is drawn as the isometric hero
    /// rather than inside a card.
    let hero: HeatmapHeroState?
    let floatsFilter: Bool

    @State private var tableMode: String

    init(
        holdings: [Holding],
        onSelect: @escaping (Holding) -> Void,
        showsHeatmap: Bool = false,
        zoomNamespace: Namespace.ID? = nil,
        hero: HeatmapHeroState? = nil,
        floatsFilter: Bool = false
    ) {
        self.holdings = holdings
        self.onSelect = onSelect
        self.showsHeatmap = showsHeatmap
        self.zoomNamespace = zoomNamespace
        self.hero = hero
        self.floatsFilter = floatsFilter
        _tableMode = State(initialValue: showsHeatmap ? "热力图"
            : ProcessInfo.processInfo.arguments.contains("--show-etf") ? "ETF 穿透" : "持仓")
    }
    @State private var etfResponse: ETFLookThroughResponse?
    @State private var etfError: String?
    @State private var isLoadingETF = false
    @State private var etfLoadGeneration = 0
    @State private var loadedETFHoldingsKey = ""
    @State private var etfConstituentDailyChanges: [String: Double] = [:]
    @State private var loadedETFConstituentChangesKey = ""
    @State private var isLoadingETFConstituentChanges = false
    @State private var etfVisibleLimit = 20
    @State private var etfSortField = ETFExposureSortField.totalExposure
    @State private var etfSortAscending = false
    @State private var headerUsesGlass = false
    @AppStorage("portfolio.holdings.sortField") private var holdingSortFieldRawValue = HoldingSortField.marketValue.rawValue
    @AppStorage("portfolio.holdings.sortAscending") private var holdingSortAscending = false
    @State private var holdingPerformancePeriod: HoldingPerformancePeriod = .holdingPeriod
    @State private var heatmapPerformancePeriod: HoldingPerformancePeriod = .today
    @State private var heatmapGroupsBySector = ProcessInfo.processInfo.arguments
        .contains("--group-heatmap-by-sector")
    @State private var heatmapLooksThroughETF = ProcessInfo.processInfo.arguments
        .contains("--look-through-heatmap-etf")

    var body: some View {
        Group {
            if showsHeatmap, let hero {
                PerformanceHeatmapHero(
                    state: hero,
                    renderKey: heatmapRenderKey,
                    header: { headerRow },
                    heatmap: { heatmapView(isSnapshot: $0) }
                )
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    headerRow

                    Group {
                        if tableMode == "持仓" {
                            holdingsTable
                        } else if tableMode == "热力图" {
                            heatmapView(isSnapshot: false)
                        } else {
                            etfTable
                        }
                    }
                }
                .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                .padding(.top, 24)
                .padding(.bottom, 18)
                .background(colorScheme == .light ? Color.white : Color(red: 0, green: 0.008, blue: 0))
            }
        }
        // Local exposure preparation must not wait for network quotes.
        .environment(\.securityDetailZoomOrigin, zoomNamespace)
        .task(id: "\(tableMode)-\(etfHoldingsKey)-\(heatmapLooksThroughETF)") {
            guard tableMode == "ETF 穿透" || (tableMode == "热力图" && heatmapLooksThroughETF),
                  etfResponse == nil || loadedETFHoldingsKey != etfHoldingsKey else { return }
            await loadETF()
        }
        .task(id: "heatmap-daily-\(tableMode)-\(etfHoldingsKey)-\(heatmapPerformancePeriod.rawValue)") {
            guard tableMode == "热力图", heatmapPerformancePeriod == .today else { return }
            await model.refreshHoldingDailyChanges()
        }
        .task(id: "heatmap-constituents-\(tableMode)-\(loadedETFHoldingsKey)-\(heatmapLooksThroughETF)-\(heatmapPerformancePeriod.rawValue)") {
            guard tableMode == "热力图", heatmapLooksThroughETF,
                  heatmapPerformancePeriod == .today else { return }
            await loadETFConstituentDailyChanges()
        }
        .onChange(of: etfSortField) { _, _ in etfVisibleLimit = 20 }
        .onChange(of: etfSortAscending) { _, _ in etfVisibleLimit = 20 }
    }

    private func heatmapView(isSnapshot: Bool) -> HoldingsHeatmapView {
        HoldingsHeatmapView(
            holdings: holdings,
            dailyChanges: model.holdingDailyChanges,
            isLoading: !isSnapshot && ((heatmapLooksThroughETF && isLoadingETF)
                || (heatmapPerformancePeriod == .today
                    && (model.isHoldingDailyChangesLoading || isLoadingETFConstituentChanges))),
            performancePeriod: heatmapPerformancePeriod,
            groupsBySector: heatmapGroupsBySector,
            usesETFLookThrough: heatmapLooksThroughETF,
            lookThroughRows: loadedETFHoldingsKey == etfHoldingsKey
                ? etfResponse?.rows
                : nil,
            lookThroughDailyChanges: etfConstituentDailyChanges,
            screenInset: hero == nil ? CatfolioStyle.pageHorizontalInset : SettingsTemplate.pageInset,
            isInteractive: !isSnapshot,
            onSelect: onSelect
        )
    }

    /// Everything that changes how the heatmap draws, so the hero re-renders
    /// its textures only when one of them does.
    private var heatmapRenderKey: Int {
        var hasher = Hasher()
        for holding in holdings {
            hasher.combine(holding.ticker)
            hasher.combine(holding.logoSymbol)
            hasher.combine(holding.marketValue)
            hasher.combine(holding.todayChangePercent)
            hasher.combine(holding.unrealizedPercent)
        }
        for (ticker, change) in model.holdingDailyChanges.sorted(by: { $0.key < $1.key }) {
            hasher.combine(ticker)
            hasher.combine(change)
        }
        hasher.combine(heatmapPerformancePeriod.rawValue)
        hasher.combine(heatmapGroupsBySector)
        hasher.combine(heatmapLooksThroughETF)
        hasher.combine(loadedETFHoldingsKey == etfHoldingsKey ? etfResponse?.rows.count ?? -1 : -1)
        hasher.combine(etfConstituentDailyChanges.count)
        return hasher.finalize()
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsHeatmap {
                Text(L10n.text("持仓热力图"))
                    .font(.title2.weight(.semibold))
            } else {
            Menu {
                Button {
                    tableMode = "持仓"
                } label: {
                    Label(L10n.text("持仓明细"), systemImage: tableMode == "持仓" ? "checkmark" : "list.bullet")
                }
                Button {
                    tableMode = "ETF 穿透"
                } label: {
                    Label(L10n.text("ETF 穿透"), systemImage: tableMode == "ETF 穿透" ? "checkmark" : "square.3.layers.3d")
                }
            } label: {
                HStack(spacing: 0) {
                    Text(tableTitle)
                    Image("PortfolioHeaderDisclosure")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
                .font(Typography.number(size: colorScheme == .light ? 28 : 32))
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            }

            Spacer()
            filterMenu(floating: false)
                .accessibilityIdentifier("portfolio-inline-filter")
                .anchorPreference(key: PortfolioFloatingFilterPreference.self, value: .bounds) { anchor in
                    floatsFilter ? PortfolioFloatingFilterSource(bounds: anchor,
                        menu: AnyView(filterMenu(floating: true))) : nil
                }
        }
        .onGeometryChange(for: Bool.self) { geometry in
            guard #available(iOS 26.0, *) else { return false }
            // Only publish the threshold crossing, not every global position.
            let threshold = UIScreen.main.bounds.midY + (headerUsesGlass ? 28 : 0)
            return geometry.frame(in: .global).midY <= threshold
        } action: { _, usesGlass in
            guard usesGlass != headerUsesGlass else { return }
            withAnimation(.easeOut(duration: 0.18)) { headerUsesGlass = usesGlass }
        }
    }

    @ViewBuilder
    private func filterMenu(floating: Bool) -> some View {
        if tableMode == "持仓" {
            HoldingSortMenu(
                field: Binding(get: { holdingSortField }, set: { holdingSortFieldRawValue = $0.rawValue }),
                ascending: $holdingSortAscending,
                performancePeriod: $holdingPerformancePeriod,
                iconOnly: true,
                usesGlass: floating || headerUsesGlass,
                showsFilterTitle: floating
            )
        } else if tableMode == "ETF 穿透" {
            ETFExposureSortMenu(field: $etfSortField, ascending: $etfSortAscending, showsFilterTitle: floating)
        } else {
            HeatmapPerformancePeriodMenu(period: $heatmapPerformancePeriod,
                groupsBySector: $heatmapGroupsBySector, looksThroughETF: $heatmapLooksThroughETF,
                usesGlass: floating || headerUsesGlass, showsFilterTitle: floating)
        }
    }

    private var itemCount: String {
        switch tableMode {
        case "ETF 穿透": L10n.text("All \(etfResponse?.rows.count ?? 0)")
        default: L10n.text("All \(holdings.count)")
        }
    }

    private var tableTitle: String {
        switch tableMode {
        case "ETF 穿透": L10n.text("ETF 穿透")
        case "热力图": L10n.text("持仓热力图")
        default: "Catfolio"
        }
    }

    private var holdingsTable: some View {
        LazyVStack(spacing: 4) {
            ForEach(sortedHoldings) { holding in
                Button {
                    onSelect(holding)
                } label: {
                    HoldingRow(
                        holding: holding,
                        performancePeriod: holdingPerformancePeriod,
                        dailyChangePercent: dailyChangePercent(for: holding)
                    )
                }
                .buttonStyle(HoldingPressButtonStyle())
                .holdingDetailPreview(holding) { onSelect(holding) }
                .holdingZoomSource(holding.ticker, in: zoomNamespace)
            }
        }
    }

    private var holdingSortField: HoldingSortField {
        HoldingSortField(rawValue: holdingSortFieldRawValue) ?? .marketValue
    }

    private struct HoldingSortEntry {
        let holding: Holding
        let value: Double?
    }

    /// Decorate-sort-undecorate.
    ///
    /// `sorted(by:)` takes a comparator, so anything derived inside it runs
    /// O(n log n) times — twice per comparison here. `performanceValues` uppercases
    /// the ticker and hashes it into the daily-change dictionary, so deriving the
    /// sort key once per holding drops that from ~2n log n allocations to n.
    ///
    /// `compareOptional` delegates to `compare` whenever both sides are present, and
    /// `.marketValue` always is, so routing all three numeric fields through it
    /// keeps the ordering identical to the previous per-case comparators.
    private var sortedHoldings: [Holding] {
        let field = holdingSortField
        let entries = holdings.map { holding in
            switch field {
            case .marketValue:
                HoldingSortEntry(holding: holding, value: holding.marketValue)
            case .unrealized:
                HoldingSortEntry(holding: holding, value: performanceValues(for: holding)?.amount)
            case .unrealizedPercent:
                HoldingSortEntry(holding: holding, value: performanceValues(for: holding)?.percent)
            case .name:
                HoldingSortEntry(holding: holding, value: nil)
            }
        }
        return entries.sorted { left, right in
            guard field != .name else {
                let comparison = left.holding.shortName.localizedStandardCompare(right.holding.shortName)
                if comparison == .orderedSame {
                    let tickerComparison = left.holding.ticker.localizedStandardCompare(right.holding.ticker)
                    return holdingSortAscending
                        ? tickerComparison == .orderedAscending
                        : tickerComparison == .orderedDescending
                }
                return holdingSortAscending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
            return compareOptional(
                left.value,
                right.value,
                leftTicker: left.holding.ticker,
                rightTicker: right.holding.ticker
            )
        }.map(\.holding)
    }

    private func compare(
        _ left: Double,
        _ right: Double,
        leftTicker: String,
        rightTicker: String
    ) -> Bool {
        if left.isFinite != right.isFinite { return left.isFinite }
        if left == right || (!left.isFinite && !right.isFinite) {
            let comparison = leftTicker.localizedStandardCompare(rightTicker)
            return holdingSortAscending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
        return holdingSortAscending ? left < right : left > right
    }

    private func compareOptional(
        _ left: Double?,
        _ right: Double?,
        leftTicker: String,
        rightTicker: String
    ) -> Bool {
        switch (left, right) {
        case let (.some(leftValue), .some(rightValue)):
            return compare(leftValue, rightValue, leftTicker: leftTicker, rightTicker: rightTicker)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return compare(0, 0, leftTicker: leftTicker, rightTicker: rightTicker)
        }
    }

    private func dailyChangePercent(for holding: Holding) -> Double? {
        model.holdingDailyChanges[holding.ticker.uppercased()] ?? holding.todayChangePercent
    }

    private func performanceValues(for holding: Holding) -> HoldingPerformanceValues? {
        holding.performanceValues(
            for: holdingPerformancePeriod,
            dailyChangePercent: dailyChangePercent(for: holding)
        )
    }

    @ViewBuilder
    private var etfTable: some View {
        if isLoadingETF, etfResponse == nil {
            HStack(spacing: 10) {
                ProgressView()
                Text(L10n.text("正在计算 ETF 底层持仓…"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.subheadline)
            .frame(minHeight: 90)
        } else if let etfError {
            Label(etfError, systemImage: "square.3.layers.3d.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        } else if let response = etfResponse {
            HStack(spacing: 12) {
                ETFSummaryMetric(title: L10n.text("ETF 市值"), value: DisplayFormat.money(response.etfTotalUSD))
                ETFSummaryMetric(title: L10n.text("底层证券"), value: L10n.text("\(response.constituentCount) 项"))
                ETFSummaryMetric(
                    title: L10n.text("成分覆盖"),
                    value: DisplayFormat.percent(response.coveredWeightPercent, signed: false)
                )
            }
            .padding(.vertical, 10)

            Text(L10n.text("\(response.etfTickers.joined(separator: " · ")) 按当前市值和基金权重拆开，再与相同股票的直接持仓合并。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(visibleETFRows) { row in
                    ETFExposureRow(
                        row: row,
                        directHolding: directHolding(for: row.ticker),
                        portfolioTotal: etfPortfolioTotal
                    )
                }
            }

            if visibleETFRows.count < sortedETFRows.count {
                Button {
                    etfVisibleLimit += 20
                } label: {
                    HStack {
                        Text(L10n.text("显示更多"))
                        Spacer()
                        Text("\(visibleETFRows.count) / \(sortedETFRows.count)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.text("再显示 20 项 ETF 底层持仓"))
            }
        }
    }

    private var etfHoldingsKey: String {
        model.selectedAccountKeys.sorted().joined(separator: ",") + "|" + holdings.map {
            "\($0.ticker):\($0.shares):\($0.quotePrice):\($0.averageCost):\($0.costCurrency ?? ""):\($0.marketValue)"
        }.joined(separator: "|")
    }

    private var sortedETFRows: [ETFLookThroughRow] {
        guard let rows = etfResponse?.rows else { return [] }
        return rows.sorted { left, right in
            let ordered: Bool
            switch etfSortField {
            case .totalExposure:
                ordered = compareETF(left.totalUSD, right.totalUSD, left: left.ticker, right: right.ticker)
            case .indirectExposure:
                ordered = compareETF(left.fromETFUSD, right.fromETFUSD, left: left.ticker, right: right.ticker)
            case .directExposure:
                ordered = compareETF(left.directUSD, right.directUSD, left: left.ticker, right: right.ticker)
            case .name:
                let leftName = CompanyNameCatalog.displayName(ticker: left.ticker, fallback: left.name)
                let rightName = CompanyNameCatalog.displayName(ticker: right.ticker, fallback: right.name)
                let result = leftName.localizedStandardCompare(rightName)
                if result == .orderedSame {
                    ordered = etfSortAscending ? left.ticker < right.ticker : left.ticker > right.ticker
                } else {
                    ordered = etfSortAscending ? result == .orderedAscending : result == .orderedDescending
                }
            }
            return ordered
        }
    }

    private var visibleETFRows: [ETFLookThroughRow] {
        Array(sortedETFRows.prefix(etfVisibleLimit))
    }

    private var etfPortfolioTotal: Double {
        etfResponse?.rows.reduce(0) { $0 + $1.totalUSD } ?? 0
    }

    private func directHolding(for ticker: String) -> Holding? {
        holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    private func compareETF(_ leftValue: Double, _ rightValue: Double, left: String, right: String) -> Bool {
        if leftValue == rightValue {
            return etfSortAscending ? left < right : left > right
        }
        return etfSortAscending ? leftValue < rightValue : leftValue > rightValue
    }

    private func loadETF() async {
        etfLoadGeneration &+= 1
        let generation = etfLoadGeneration
        let requestedKey = etfHoldingsKey
        isLoadingETF = true
        etfError = nil
        defer {
            if generation == etfLoadGeneration { isLoadingETF = false }
        }
        do {
            let response = try await model.loadETFLookThrough(basis: .market)
            guard !Task.isCancelled, generation == etfLoadGeneration,
                  requestedKey == etfHoldingsKey else { return }
            etfResponse = response
            let activeTickers = Set(response.rows.map { $0.ticker.uppercased() })
            etfConstituentDailyChanges = etfConstituentDailyChanges.filter { activeTickers.contains($0.key) }
            loadedETFConstituentChangesKey = ""
            loadedETFHoldingsKey = requestedKey
            etfVisibleLimit = 20
        } catch {
            guard !Task.isCancelled, generation == etfLoadGeneration,
                  requestedKey == etfHoldingsKey else { return }
            etfResponse = nil
            etfError = error.localizedDescription
        }
    }

    private func loadETFConstituentDailyChanges() async {
        guard let rows = etfResponse?.rows,
              loadedETFHoldingsKey == etfHoldingsKey else { return }
        let tickers = rows
            .filter { $0.totalUSD.isFinite && $0.totalUSD > 0 && $0.ticker != "ETF 其他" }
            .sorted { $0.totalUSD > $1.totalUSD }
            .map(\.ticker)
        let signature = "\(etfHoldingsKey)|\(tickers.map { $0.uppercased() }.joined(separator: ","))"
        guard signature != loadedETFConstituentChangesKey else { return }

        isLoadingETFConstituentChanges = true
        defer { isLoadingETFConstituentChanges = false }
        let holdingsKey = etfHoldingsKey
        let client = LocalMarketDataClient()
        // Populate the leading tiles first, then the tail needed for aggregate
        // P&L. Each batch reuses the quote cache and bounded request concurrency.
        let batchSize = HoldingsHeatmapView.maximumLookThroughTiles
        for start in stride(from: 0, to: tickers.count, by: batchSize) {
            guard !Task.isCancelled, loadedETFHoldingsKey == holdingsKey else { return }
            let batch = Array(tickers[start..<min(start + batchSize, tickers.count)])
            let changes = await client.dailyChanges(tickers: batch)
            guard !Task.isCancelled, loadedETFHoldingsKey == holdingsKey else { return }
            etfConstituentDailyChanges.merge(changes) { _, fresh in fresh }
            // Later batches fill the summaries without blocking the whole map.
            isLoadingETFConstituentChanges = false
        }
        loadedETFConstituentChangesKey = signature
    }
}

private enum HoldingSortField: String, CaseIterable, Identifiable {
    case marketValue
    case unrealized
    case unrealizedPercent
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .marketValue: L10n.text("市值")
        case .unrealized: L10n.text("盈利")
        case .unrealizedPercent: L10n.text("收益率")
        case .name: L10n.text("名称")
        }
    }

    var compactTitle: String {
        switch self {
        case .marketValue: L10n.text("Mkt Cap")
        case .unrealized: L10n.text("P&L")
        case .unrealizedPercent: L10n.text("Return")
        case .name: L10n.text("Name")
        }
    }
}

enum HoldingPerformancePeriod: String, CaseIterable, Identifiable {
    case today
    case holdingPeriod

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: L10n.text("今日")
        case .holdingPeriod: L10n.text("持有期")
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .holdingPeriod: "calendar.badge.clock"
        }
    }
}

private struct HeatmapPerformancePeriodMenu: View {
    @Environment(\.locale) private var appLocale
    @Binding var period: HoldingPerformancePeriod
    @Binding var groupsBySector: Bool
    @Binding var looksThroughETF: Bool
    var usesGlass = false
    var showsFilterTitle = false

    var body: some View {
        Menu {
            Section(L10n.text("收益时间")) {
                ForEach(HoldingPerformancePeriod.allCases) { option in
                    Button {
                        period = option
                    } label: {
                        Label(
                            option.title,
                            systemImage: period == option ? "checkmark" : option.systemImage
                        )
                    }
                }
            }

            Divider()

            Section(L10n.text("布局")) {
                Toggle(L10n.text("按板块分组"), isOn: $groupsBySector)
                Toggle(L10n.text("穿透 ETF"), isOn: $looksThroughETF)
            }
        } label: {
            PortfolioFilterLabel(showsTitle: showsFilterTitle, usesGlass: usesGlass)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .menuOrder(.fixed)
        .accessibilityLabel(
            L10n.text("热力图筛选：\(period.title)，\(groupsBySector ? "按板块分组" : "不分组")，")
                + (looksThroughETF ? L10n.text("已穿透 ETF") : L10n.text("未穿透 ETF"))
        )
    }
}

private enum ETFExposureSortField: String, CaseIterable, Identifiable {
    case totalExposure
    case indirectExposure
    case directExposure
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .totalExposure: L10n.text("总暴露")
        case .indirectExposure: L10n.text("ETF 间接")
        case .directExposure: L10n.text("直接持仓")
        case .name: L10n.text("名称")
        }
    }
}

private struct HoldingSortMenu: View {
    @Environment(\.locale) private var appLocale
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @Binding var field: HoldingSortField
    @Binding var ascending: Bool
    @Binding var performancePeriod: HoldingPerformancePeriod
    var iconOnly = false
    var usesGlass = false
    var showsFilterTitle = false

    var body: some View {
        menu
        .buttonStyle(.plain)
        .appText(.footnote, weight: .medium)
        .foregroundStyle(.secondary)
        .sensoryFeedback(.selection, trigger: performancePeriod) { _, _ in hapticsEnabled }
        .accessibilityLabel(L10n.text("筛选：\(performancePeriod.title)；排序：\(field.title)，\(ascending ? "升序" : "降序")"))
    }

    private var menu: some View {
        Menu {
            Section(L10n.text("收益时间")) {
                ForEach(HoldingPerformancePeriod.allCases) { period in
                    Button {
                        performancePeriod = period
                    } label: {
                        Label(
                            period.title,
                            systemImage: performancePeriod == period ? "checkmark" : period.systemImage
                        )
                    }
                }
            }

            Divider()

            Section(L10n.text("排序方式")) {
                ForEach(HoldingSortField.allCases) { option in
                    Button {
                        field = option
                    } label: {
                        if field == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }

            Divider()

            Button {
                ascending.toggle()
            } label: {
                Label(
                    ascending ? L10n.text("改为降序") : L10n.text("改为升序"),
                    systemImage: ascending ? "arrow.down" : "arrow.up"
                )
            }
        } label: {
            Group {
                if iconOnly {
                    PortfolioFilterLabel(showsTitle: showsFilterTitle, usesGlass: usesGlass)
                } else {
                    HStack(spacing: 3) {
                        Text(field.compactTitle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
            }
        }
        .menuOrder(.fixed)
    }
}

private struct PortfolioFilterLabel: View {
    let showsTitle: Bool
    let usesGlass: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image("PortfolioHeaderSort")
                .renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24)
            if showsTitle { Text(L10n.text("筛选")).appText(.footnote, weight: .medium) }
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 44)
        .fixedSize()
        .modifier(PortfolioHeaderMaterialControl(usesGlass: usesGlass))
    }
}

private struct PortfolioFloatingFilterSource {
    let bounds: Anchor<CGRect>
    // The bindings still belong to the details card, including its transient
    // performance period and ETF sort. Both presentations operate on that state.
    let menu: AnyView
}

private struct PortfolioFloatingFilterPreference: PreferenceKey {
    static var defaultValue: PortfolioFloatingFilterSource? { nil }
    static func reduce(value: inout PortfolioFloatingFilterSource?, nextValue: () -> PortfolioFloatingFilterSource?) {
        value = nextValue() ?? value
    }
}

struct PortfolioFloatingFilterOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(PortfolioFloatingFilterPreference.self) { source in
            GeometryReader { geometry in
                if let source, Self.shouldFloat(sourceFrame: geometry[source.bounds]) {
                    source.menu
                        .accessibilityIdentifier("portfolio-floating-filter")
                        .padding(.top, 10)
                        .padding(.trailing, CatfolioStyle.pageHorizontalInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
    }

    static func shouldFloat(sourceFrame: CGRect) -> Bool {
        sourceFrame.height > 0 && sourceFrame.maxY.isFinite && sourceFrame.maxY <= 0
    }
}

private struct PortfolioHeaderMaterialControl: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let usesGlass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), usesGlass {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(
                    colorScheme == .light
                        ? Color(red: 244 / 255, green: 244 / 255, blue: 244 / 255)
                        : Color.white.opacity(0.12),
                    in: Capsule()
                )
        }
    }
}

private struct ETFExposureSortMenu: View {
    @Environment(\.locale) private var appLocale
    @Binding var field: ETFExposureSortField
    @Binding var ascending: Bool
    var showsFilterTitle = false

    var body: some View {
        menu
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityLabel(L10n.text("ETF 穿透排序：\(field.title)，\(ascending ? "升序" : "降序")"))
    }

    private var menu: some View {
        Menu {
            Section(L10n.text("排序方式")) {
                ForEach(ETFExposureSortField.allCases) { option in
                    Button {
                        field = option
                    } label: {
                        if field == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
            Divider()
            Button {
                ascending.toggle()
            } label: {
                Label(
                    ascending ? L10n.text("改为降序") : L10n.text("改为升序"),
                    systemImage: ascending ? "arrow.down" : "arrow.up"
                )
            }
        } label: {
            if showsFilterTitle {
                PortfolioFilterLabel(showsTitle: true, usesGlass: true)
            } else {
                HStack(spacing: 5) {
                    Text(field.title)
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .menuOrder(.fixed)
    }
}

private struct ETFSummaryMetric: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .appNumber(.callout, weight: .bold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ETFExposureRow: View {
    @Environment(\.locale) private var appLocale
    let row: ETFLookThroughRow
    let directHolding: Holding?
    let portfolioTotal: Double

    private var portfolioWeight: Double {
        guard portfolioTotal > 0 else { return 0 }
        return row.totalUSD / portfolioTotal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AssetLogo(ticker: row.ticker, logoSymbol: row.logoSymbol)

                VStack(alignment: .leading, spacing: 3) {
                    Text(CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name))
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(row.ticker)
                        if let directHolding {
                            Text("·")
                            Text(L10n.text("\(formattedShares(directHolding.shares)) 股"))
                        }
                    }
                    .appNumber(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(DisplayFormat.money(row.totalUSD, fractionDigits: 2))
                        .appNumber(.callout, weight: .bold)
                    Text(DisplayFormat.percent(portfolioWeight * 100, signed: false))
                        .appNumber(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .layoutPriority(2)
            }

            HStack(spacing: 12) {
                exposureLabel(L10n.text("直接"), value: row.directUSD, color: CatfolioPalette.blue500)
                exposureLabel("ETF", value: row.fromETFUSD, color: CatfolioPalette.green500)
                Spacer(minLength: 4)
                if row.directUSD > 0, row.fromETFUSD > 0 {
                    Text(L10n.text("重叠持仓"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.1), in: Capsule())
                }
            }

            if let directHolding {
                HStack(spacing: 6) {
                    Text(L10n.text("现价 \(DisplayFormat.money(directHolding.quotePrice, currency: directHolding.quoteCurrency))"))
                    Text("·")
                    Text(
                        L10n.text("盈亏 \(DisplayFormat.money(directHolding.unrealized, signed: true, fractionDigits: 2)) ")
                            + "(\(DisplayFormat.percent(directHolding.unrealizedPercent)))"
                    )
                    .foregroundStyle(directHolding.unrealized >= 0 ? CatfolioPalette.green500 : CatfolioPalette.rose500)
                }
                .appNumber(.micro, weight: .semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: 76)
        .accessibilityElement(children: .combine)
    }

    private func exposureLabel(_ title: String, value: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(DisplayFormat.money(value))")
                .appNumber(.micro, weight: .semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func formattedShares(_ value: Double) -> String {
        DisplayFormat.shares(value)
    }
}

private struct HoldingPerformanceValues {
    let amount: Double
    let percent: Double
}

private extension Holding {
    func performanceValues(
        for period: HoldingPerformancePeriod,
        dailyChangePercent: Double?
    ) -> HoldingPerformanceValues? {
        switch period {
        case .holdingPeriod:
            guard unrealized.isFinite, unrealizedPercent.isFinite else { return nil }
            return HoldingPerformanceValues(amount: unrealized, percent: unrealizedPercent)
        case .today:
            guard let dailyChangePercent, dailyChangePercent.isFinite else { return nil }
            let factor = 1 + dailyChangePercent / 100
            guard factor > 0 else { return nil }
            return HoldingPerformanceValues(
                amount: marketValue - marketValue / factor,
                percent: dailyChangePercent
            )
        }
    }
}

private struct HoldingRow: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let performancePeriod: HoldingPerformancePeriod
    let dailyChangePercent: Double?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var performance: HoldingPerformanceValues? {
        holding.performanceValues(
            for: performancePeriod,
            dailyChangePercent: dailyChangePercent
        )
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 40)
                        HoldingIdentity(holding: holding, compact: false)
                    }
                    HoldingMetrics(
                        holding: holding,
                        performance: performance,
                        period: performancePeriod,
                        alignment: .leading,
                        compact: false
                    )
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 40)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(holding.shortName)
                                .appText(.body, weight: .medium)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)

                            Spacer(minLength: 4)

                            Text(holding.displayedMarketValue)
                                .appNumber(.body)
                                .numericTransition(holding.marketValue)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            HStack(spacing: 2) {
                                Text(DisplayFormat.shares(holding.shares))
                                    .appNumber(.caption, monospaced: false)
                                Text(holding.ticker)
                                    .appText(.caption, weight: .medium)
                            }
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(0)

                            Spacer(minLength: 2)

                            performanceLabel
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.text("\(holding.shortName)，\(formattedShares) 股 \(holding.ticker)，市值 \(DisplayFormat.money(holding.marketValue))，\(performancePeriod.title)盈亏 \(profitDescription)")
        )
    }

    private var formattedShares: String {
        DisplayFormat.shares(holding.shares)
    }

    private var profitDescription: String {
        guard let performance else { return L10n.text("暂无数据") }
        return "\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) · \(DisplayFormat.percent(performance.percent))"
    }

    @ViewBuilder
    private var performanceLabel: some View {
        if let performance {
            HStack(spacing: 2) {
                Text(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2))
                    .numericTransition(performance.amount)
                Circle()
                    .fill(.secondary)
                    .frame(width: 2, height: 2)
                    .accessibilityHidden(true)
                Text(DisplayFormat.percent(performance.percent))
                    .numericTransition(performance.percent)
            }
            .appNumber(.caption, weight: .medium)
            .foregroundStyle(rowAccent)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        } else {
            Text(L10n.text("暂无数据"))
                .font(PortfolioHomeTypography.medium(12, relativeTo: .caption))
                .foregroundStyle(rowAccent)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
    }

    private var rowAccent: Color {
        if (performance?.amount ?? 0) >= 0 {
            return CatfolioTheme.gainDefault
        }
        return CatfolioPalette.rose500
    }
}

private struct HoldingIdentity: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(holding.shortName)
                .appText(.body, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(compact ? 1 : nil)

            HStack(spacing: 2) {
                Text(DisplayFormat.shares(holding.shares))
                    .appNumber(.caption, monospaced: false)
                Text(holding.ticker)
                    .appText(.caption, weight: .medium)
            }
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 1 : nil)
        }
    }
}

private struct HoldingMetrics: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let performance: HoldingPerformanceValues?
    let period: HoldingPerformancePeriod
    let alignment: HorizontalAlignment
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(holding.displayedMarketValue)
                .appNumber(.body)
                .lineLimit(compact ? 1 : nil)
            // The separator is punctuation, not data. Carrying the gain or
            // loss colour it reads as part of the figure, and a row of red
            // dots between red numbers is noise the eye has to filter.
            Group {
                if let performance {
                    Text(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2))
                        .foregroundStyle(performanceColor)
                    + Text(" · ").foregroundStyle(.secondary)
                    + Text(DisplayFormat.percent(performance.percent))
                        .foregroundStyle(performanceColor)
                } else {
                    Text(performanceText).foregroundStyle(.secondary)
                }
            }
            .appNumber(.caption, weight: .medium)
            .lineLimit(compact ? 1 : nil)
        }
    }

    private var performanceColor: Color {
        (performance?.amount ?? 0) >= 0
            ? (colorScheme == .light
                ? CatfolioTheme.gain(for: .light)
                : CatfolioTheme.gain(for: .dark))
            : CatfolioPalette.rose500
    }

    private var performanceText: String {
        guard let performance else { return L10n.text("\(period.title)暂无数据") }
        return "\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) "
            + "· \(DisplayFormat.percent(performance.percent))"
    }
}

private enum HomeSkeletonStyle {
    static func color(for scheme: ColorScheme) -> Color {
        CatfolioTheme.skeletonFill
    }
}

private struct HomeSkeletonBlock: View {
    @Environment(\.locale) private var appLocale
    let width: CGFloat
    let height: CGFloat
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: width, height: height)
    }
}

private struct TodayContributionLoadingBars: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(0..<5, id: \.self) { _ in
                VStack(spacing: -13) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(
                            colors: [HomeSkeletonStyle.color(for: colorScheme), Color(uiColor: .systemBackground)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .overlay {
                            ContributionStripePattern(color: Color(uiColor: .systemBackground))
                                .opacity(0.45)
                                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                        }
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(height: 140)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(HomeSkeletonStyle.color(for: colorScheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                        }
                        .frame(width: 30, height: 30)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct TodayLoadingHeader: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true

    var body: some View {
        let color = HomeSkeletonStyle.color(for: colorScheme)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HomeSkeletonBlock(width: 52, height: 10, color: color)
                    .frame(height: 17, alignment: .top)
                HomeSkeletonBlock(width: 180, height: 32, color: color)
                    .frame(height: 39, alignment: .leading)
                HStack(spacing: 4) {
                    HomeSkeletonBlock(width: 46, height: 11, color: color)
                    HomeSkeletonBlock(width: 71, height: 11, color: color)
                    HomeSkeletonBlock(width: 39, height: 11, color: color)
                }
                .frame(height: 20, alignment: .bottom)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .frame(width: 44, height: 38)
                    .background(Color(uiColor: .systemBackground), in: Capsule())
                Image(systemName: "arrow.down")
                    .frame(width: 44, height: 38)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.10))
            .padding(3)
            .background(color, in: Capsule())
        }
    }
}

private struct PortfolioLoadingView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true
    let scrollState: PortfolioHomeScrollState

    var body: some View {
        let color = HomeSkeletonStyle.color(for: colorScheme)
        VStack(spacing: 0) {
            PortfolioChartLoadingPlaceholder(isAnimating: isAnimating)
                .frame(height: PortfolioHeroChartLayout.sectionHeight)
                .modifier(PortfolioPinnedHero(scrollState: scrollState))

            PortfolioContentSheet(scrollState: scrollState) {
            VStack(spacing: 0) {
            ZStack(alignment: .top) {
                TodayLoadingHeader(isAnimating: isAnimating)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                    .padding(.top, 30)
                TodayContributionLoadingBars(isAnimating: isAnimating)
                    .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                    .frame(height: 167, alignment: .top)
                    .offset(y: 139)
            }
            .frame(height: 326, alignment: .top)

            VStack(spacing: 18) {
                HStack {
                    HomeSkeletonBlock(width: 118, height: 22, color: color)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.10))
                    Spacer()
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.primary.opacity(0.10))
                        .frame(width: 58, height: 44)
                        .background(color, in: Capsule())
                }
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 10) {
                        HomeSkeletonBlock(width: 63, height: 14, color: color)
                        HStack(spacing: 8) {
                            HomeSkeletonBlock(width: 59, height: 10, color: color)
                            HomeSkeletonBlock(width: 40, height: 10, color: color)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 10) {
                        HomeSkeletonBlock(width: 94, height: 14, color: color)
                        HStack(spacing: 4) {
                            HomeSkeletonBlock(width: 79, height: 10, color: color)
                            HomeSkeletonBlock(width: 45, height: 10, color: color)
                        }
                    }
                }
                .frame(height: 64)
            }
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)
            }
            }
            .zIndex(1)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isAnimating ? L10n.text("正在读取投资组合") : L10n.text("暂无持仓数据"))
    }
}

private struct PortfolioChartLoadingPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true

    var body: some View {
        let color = Color.primary.opacity(colorScheme == .light ? 0.08 : 0.14)
        ZStack(alignment: .topLeading) {
            HomeSkeletonBlock(width: 88, height: 10, color: color)
                .offset(x: CatfolioStyle.pageHorizontalInset, y: 15)
            HomeSkeletonBlock(width: 240, height: 44, color: color)
                .offset(x: CatfolioStyle.pageHorizontalInset, y: 32)
            HStack(spacing: 8) {
                HomeSkeletonBlock(width: 72, height: 13, color: color)
                HomeSkeletonBlock(width: 42, height: 13, color: color)
                HomeSkeletonBlock(width: 124, height: 13, color: color)
            }
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 82)

            // Match the current quiet chart-loading state, not the old mock
            // asset curves, which briefly looked like a different portfolio.
            Color.clear
                .frame(height: PortfolioHeroChartLayout.plotHeight)
                .offset(y: PortfolioHeroChartLayout.plotTop)

            ChartTimeRangePickerSkeleton()
                .frame(height: PortfolioHeroChartLayout.pickerHeight)
                .offset(y: PortfolioHeroChartLayout.pickerTop)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: PortfolioHeroChartLayout.sectionHeight, alignment: .topLeading)
    }
}
