import SwiftUI
import UIKit

typealias PortfolioHomeTypography = LegacyType


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
    @State private var refreshNotice: PortfolioRefreshResult?
    @State private var refreshNoticeToken = UUID()
    // One namespace per origin. A security shown both in the Today bars and
    // in the holdings list would otherwise publish two sources under the same
    // id, and the transition has no way to know which one it grew from.
    @Namespace private var holdingsRowZoom
    @Namespace private var todayBarZoom
    private var previewsLoading: Bool {
        #if DEBUG
        LaunchArguments.contains("--show-portfolio-loading")
        #else
        false
        #endif
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
                                            isRefreshingBehindCache: model.isHomeRefreshingBehindCache,
                                            onOpenDetail: { showsTodayDetail = true },
                                            onTitleBottomPositionChange: { titleBottomY in
                                                homeScrollState.titleMoved(to: titleBottomY)
                                            },
                                            zoomNamespace: todayBarZoom,
                                            onRefresh: { Task { await model.refreshHoldingDailyChanges(forceRefresh: true) } }
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
                                    Text(L10n.message(error))
                                } actions: {
                                    Button(L10n.text("重试")) { Task { await refreshFromUser() } }
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
                                refresh: { await refreshFromUser() }
                            )
                        }
                    }
                    .background(Color.clear)
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
                        let arguments = LaunchArguments.all
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
                .overlay(alignment: .top) {
                    if let refreshNotice {
                        PortfolioRefreshNotice(result: refreshNotice)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                            .zIndex(10)
                    }
                }
                .modifier(PortfolioFloatingFilterOverlay())
                .fullScreenCover(item: $selectedHolding) { holding in
                    HoldingDetailView(holding: holding, onClose: { selectedHolding = nil })
                        .environment(model)
                        .securityDetailFullScreen()
                }
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
        #if DEBUG
        SecurityDetailLiveZoom.note("row tapped \(holding.ticker) selected=\(selectedHolding?.ticker ?? "nil") caughtMotion=\(homeScrollController.touchCaughtMotion)")
        #endif
        // A page flying back does not block the tap: the next one opens at once.
        guard selectedHolding == nil, !SecurityDetailLiveZoom.shared.isShowingPage,
              !homeScrollController.touchCaughtMotion else { return }
        HoldingDetailContentView.prefetch(holding, model: model)
        let opened = SecurityDetailLiveZoom.shared.open(
            id: holding.ticker, namespace: namespace,
            page: { close in
                AnyView(HoldingDetailView(holding: holding, onClose: close)
                    .environment(model)
                    .environment(\.locale, appLocale)
                    .environment(\.isAppModal, false)
                    .fontDesign(.rounded)
                    .tint(CatfolioTheme.accent))
            },
            didEnd: {})
        openFeedback()
        if !opened { selectedHolding = holding }
    }

    /// The click is the tap's, in the same run-loop turn: tied to the page's
    /// presentation it came only once the card had landed.
    private func openFeedback() {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8)
    }

    @MainActor private func refreshFromUser() async {
        let token = UUID()
        refreshNoticeToken = token
        refreshNotice = nil
        guard let result = await model.refreshPortfolioReportingResult(), !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            refreshNotice = result
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: result.noticeText)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard refreshNoticeToken == token else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                refreshNotice = nil
            }
        }
    }
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

extension PortfolioRefreshResult {
    var noticeText: String {
        switch self {
        case .quotesUpdated: L10n.text("已获取新报价，持仓数据已更新")
        case .portfolioLoaded: L10n.text("持仓数据已载入")
        case .portfolioLoadedWithoutNewQuotes: L10n.text("持仓已载入；暂无新报价")
        case .unchangedQuotes: L10n.text("未获取新报价，继续显示已有数据")
        case .unchangedContent: L10n.text("已检查，暂无新内容")
        case .noHeldQuotes: L10n.text("当前没有持仓报价可刷新")
        case .failed(let retainsData): retainsData
            ? L10n.text("刷新失败，继续显示已有数据")
            : L10n.text("刷新失败，请稍后重试")
        }
    }

    var noticeSymbol: String {
        switch self {
        case .quotesUpdated, .portfolioLoaded: "checkmark.circle.fill"
        case .portfolioLoadedWithoutNewQuotes, .unchangedQuotes, .unchangedContent, .noHeldQuotes: "info.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    var noticeTint: Color {
        switch self {
        case .quotesUpdated, .portfolioLoaded: CatfolioTheme.positive
        case .portfolioLoadedWithoutNewQuotes, .unchangedQuotes, .unchangedContent, .noHeldQuotes: CatfolioTheme.warning
        case .failed: CatfolioTheme.danger
        }
    }
}

struct PortfolioRefreshNotice: View {
    let result: PortfolioRefreshResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.noticeSymbol)
                .foregroundStyle(result.noticeTint)
                .padding(.top, 3)
            Text(result.noticeText)
                .appText(.footnote, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("portfolio-refresh-result")
        .allowsHitTesting(false)
    }
}
