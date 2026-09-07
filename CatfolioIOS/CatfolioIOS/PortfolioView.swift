import SwiftUI

private typealias PortfolioHomeTypography = LegacyType

private struct PortfolioHomeTopBackground: View {
    let colorScheme: ColorScheme

    var body: some View {
        LinearGradient(
            stops: colorScheme == .light
                ? [
                    .init(color: Color(red: 0.541, green: 0.788, blue: 0.918), location: 0),
                    .init(color: Color(red: 0.886, green: 0.941, blue: 0.969), location: 1),
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
    let colorScheme: ColorScheme

    var body: some View {
        ZStack(alignment: .top) {
            // This explicit terminal fill is independent of the scroll
            // content's height, so bottom rubber-banding can never expose the
            // NavigationStack or TabView background.
            (colorScheme == .light ? Color.white : Color.black)

            VStack(spacing: 0) {
                PortfolioHomeTopBackground(colorScheme: colorScheme)
                    .frame(height: 520)

                // Extend the hero's terminal colour beneath its opaque card.
                // It remains visible only during top-edge rubber-banding.
                (colorScheme == .light
                    ? Color(red: 0.886, green: 0.941, blue: 0.969)
                    : Color(red: 0.192, green: 0.208, blue: 0.235))
                    .frame(height: 180)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

struct PortfolioView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedHolding: Holding?
    @State private var showsTodayDetail = false
    @Namespace private var todayZoom

    private var previewsLoading: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--show-portfolio-loading")
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ZStack {
                    PortfolioHomePageBackdrop(colorScheme: colorScheme)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            PortfolioRefreshTimestamp(
                                date: model.localUpdatedAt,
                                isRefreshing: model.isPortfolioLoading
                            )

                            if previewsLoading {
                                PortfolioLoadingView()
                            } else if model.holdings.isEmpty, model.overview != nil {
                                PortfolioLoadingView(isAnimating: model.isPortfolioLoading)
                            } else if let overview = model.overview, let chart = model.portfolioChart {
                                CostMarketCard(overview: overview, response: chart)
                                    .id(model.portfolioChartRevision)

                                TodayContributionCard(
                                    holdings: model.holdings,
                                    dailyChanges: model.holdingDailyChanges,
                                    benchmarkChange: model.benchmarkDailyChange,
                                    isLoading: model.isHoldingDailyChangesLoading,
                                    onOpenDetail: { showsTodayDetail = true }
                                ) { holding in
                                    selectedHolding = holding
                                }
                                .id("today-contribution")
                                .matchedTransitionSource(id: "today-detail", in: todayZoom)

                                PortfolioDetailsCard(holdings: model.holdings) { holding in
                                    selectedHolding = holding
                                }
                                .id("portfolio-details")
                            } else if model.isPortfolioLoading {
                                PortfolioLoadingView()
                            } else if let error = model.portfolioError {
                                ContentUnavailableView {
                                    Label("暂时无法加载", systemImage: "wifi.exclamationmark")
                                } description: {
                                    Text(error)
                                } actions: {
                                    Button("重试") { Task { await model.refreshPortfolio() } }
                                }
                                .frame(minHeight: 420)
                            } else {
                                PortfolioLoadingView()
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .background(Color.clear)
                    // Keep native rubber-banding intact: UIRefreshControl relies on
                    // the full pull distance and release transition to trigger.
                    .scrollBounceBehavior(.always, axes: .vertical)
                    .refreshable { await model.refreshPortfolio() }
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
                        if arguments.contains("--show-heatmap") {
                            try? await Task.sleep(for: .milliseconds(250))
                            scrollProxy.scrollTo("portfolio-details", anchor: .top)
                        } else if arguments.contains("--show-today-contribution") {
                            try? await Task.sleep(for: .milliseconds(250))
                            scrollProxy.scrollTo("today-contribution", anchor: .top)
                        }
                    }
                }
                .sheet(item: $selectedHolding) { holding in
                    HoldingDetailView(holding: holding)
                        .environment(model)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.hidden)
                        .presentationBackground(Color(uiColor: .systemBackground))
                }
                .navigationDestination(isPresented: $showsTodayDetail) {
                    TodayDetailView(
                        holdings: model.holdings,
                        dailyChanges: model.holdingDailyChanges,
                        benchmarkChange: model.benchmarkDailyChange
                    )
                    .navigationTransition(.zoom(sourceID: "today-detail", in: todayZoom))
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct PortfolioRefreshTimestamp: View {
    let date: Date?
    let isRefreshing: Bool

    var body: some View {
        Group {
            if let date {
                Text("更新于 \(date.formatted(.dateTime.hour().minute()))")
                    .appNumber(.micro)
                    .foregroundStyle(Color.primary.opacity(0.44))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 0)
        .offset(y: -16)
        .opacity(isRefreshing ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isRefreshing)
        .accessibilityHidden(!isRefreshing)
        .accessibilityLabel(date.map { "数据更新于 \($0.formatted(.dateTime.hour().minute()))" } ?? "")
    }
}

private struct TodayContributionCard: View {
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
    let onSelect: (Holding) -> Void

    @State private var direction: Direction = TodayContributionCard.launchDirection
    @State private var barRevealProgress: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("catfolio.haptics") private var hapticsEnabled = true

    private var contributions: [Contribution] {
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
        contributions.reduce(0) { $0 + $1.amount }
    }

    private var totalPercent: Double {
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

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text("TODAY")
                            .appCaps(.caption, weight: .semibold)
                            .foregroundStyle(.primary)
                        if onOpenDetail != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 17, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenDetail?() }
                    .accessibilityAddTraits(onOpenDetail == nil ? [] : .isButton)
                    .accessibilityLabel("今日盈亏详情")

                    Group {
                        if contributions.isEmpty {
                            HomeSkeletonBlock(width: 133, height: 22, color: HomeSkeletonStyle.color(for: colorScheme))
                                .accessibilityLabel("正在计算今日贡献")
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
                                Text("行情暂不可用")
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

                Spacer(minLength: 0)
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
                        direction == .gains ? "今天暂无上涨持仓" : "今天暂无下跌持仓",
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
            Text("\(difference >= 0 ? "+" : "-")S&P 500 \(DisplayFormat.percent(abs(difference), signed: false))")
        } else {
            Text("S&P 500 暂无数据")
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
            shape.fill(Color.white)
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
                            growth: barRevealProgress
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
        HStack(spacing: 2) {
            directionButton(.gains, systemImage: "arrow.up")
            directionButton(.losses, systemImage: "arrow.down")
        }
        .padding(3)
        .frame(width: 96, height: 44)
        .background(
            colorScheme == .light ? Color(red: 0.957, green: 0.957, blue: 0.957) : Color.white.opacity(0.16),
            in: Capsule()
        )
    }

    private func directionButton(_ value: Direction, systemImage: String) -> some View {
        Button {
            switchDirection(to: value)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(direction == value ? Color.black : Color.primary)
                .frame(width: 44, height: 38)
                .background(direction == value ? Color.white : Color.clear, in: Capsule())
                .shadow(color: direction == value ? Color.black.opacity(0.10) : .clear, radius: 1, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == .gains ? "上涨贡献" : "下跌贡献")
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
    let holding: Holding
    let amount: Double
    let relativeHeight: Double
    let isGain: Bool
    let growth: CGFloat
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

                        Text(amountText)
                            .appNumber(.caption, weight: .semibold)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                            .padding(.horizontal, 4)
                            .padding(.top, 14)
                            .opacity(growth)
                    }
                    .frame(height: renderedBarHeight)
                    .clipShape(fillShape, style: FillStyle(antialiased: true))
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
        .accessibilityLabel("\(holding.shortName)，今日贡献 \(DisplayFormat.money(amount, signed: true, fractionDigits: 2))")
        .accessibilityHint("打开个股详情")
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

private struct ContributionStripePattern: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var stripes = Path()
            // Match the exported Figma stripe asset: 13pt strokes on a
            // 35.5pt cadence. The previous 18pt bands covered almost half of
            // each bar and made the whole gradient read much darker.
            let bandWidth: CGFloat = 13
            let spacing: CGFloat = 35.5
            // Start and end every diagonal band outside the rendered bounds.
            // If a stroke begins at y = 0 its cap remains visible just inside
            // the rounded mask, which reads as a short line head at the top.
            let overscan = bandWidth * 2
            var x = -size.height - overscan
            while x < size.width + size.height {
                stripes.move(to: CGPoint(x: x - overscan, y: -overscan))
                stripes.addLine(to: CGPoint(
                    x: x + size.height + overscan,
                    y: size.height + overscan
                ))
                x += spacing
            }
            context.stroke(stripes, with: .color(color), lineWidth: bandWidth)
        }
        .allowsHitTesting(false)
    }
}

/// A neutral, refractive shell shared by the contribution bar, value capsule,
/// and raised logo lens. Accent colour is intentionally restrained: the light
/// source is rendered behind/inside the shell rather than painted onto it.
private struct ContributionGlassSurface<S: InsettableShape>: View {
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
    static let pickerTop: CGFloat = 398
    static let pickerHeight: CGFloat = 62
}

private struct CostMarketCard: View {

    let overview: PortfolioOverview
    let warning: String?
    let response: PortfolioChartResponse
    @State private var prepared: CostMarketPreparedData?
    @State private var isPreparing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var range = "3M"
    @State private var selectedDate: Date?
    @State private var measuredRange: ChartDateRange?
    @State private var showsNetDeposit = true
    @Environment(\.colorScheme) private var colorScheme

    private let choices = ["1D", "1W", "1M", "3M", "YTD", "1Y", "MAX"]

    private var forcesChartLoadingState: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-chart-loading-state")
    }

    private var isChartLoading: Bool {
        isPreparing || forcesChartLoadingState
    }

    init(overview: PortfolioOverview, response: PortfolioChartResponse) {
        self.overview = overview
        self.warning = response.warning
        self.response = response
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
        selectedPoint?.marketValue ?? overview.summary.marketValue
    }

    private var displayedCost: Double {
        selectedPoint?.cost ?? overview.summary.totalCost
    }

    private var displayedProfit: Double {
        displayedMarketValue - displayedCost
    }

    private var rangePerformance: (amount: Double, percentage: Double) {
        if let measurement = measuredPoints {
            return costMarketChange(from: measurement.start, to: measurement.end)
        }
        guard range != "MAX",
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
        let value = rangePerformance.amount
        if value >= 0 {
            return colorScheme == .light
                ? Color(red: 0, green: 0.53, blue: 0.14)
                : Color(red: 0.204, green: 0.780, blue: 0.349)
        }
        return CatfolioPalette.rose500
    }

    var body: some View {
        let data = rangeData
        ZStack(alignment: .topLeading) {
            HStack(spacing: 4) {
                Text("CATFOLIO")
                    .appCaps(.caption, weight: .semibold)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(.primary)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 15)

            CatfolioDisplayAmountText(
                text: DisplayFormat.money(
                    displayedPrimaryAmount,
                    signed: false,
                    fractionDigits: 2
                ),
                color: .primary
            )
            .contentTransition(.numericText(value: displayedPrimaryAmount))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: displayedPrimaryAmount)
            .frame(height: 38, alignment: .leading)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 32)

            HStack(spacing: 4) {
                let summaryAccent = colorScheme == .light ? Color.primary : financialAccent
                Group {
                    Text(DisplayFormat.money(rangePerformance.amount, signed: true))
                        .foregroundStyle(summaryAccent)
                        .contentTransition(.numericText(value: rangePerformance.amount))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: rangePerformance.amount)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(DisplayFormat.percent(rangePerformance.percentage, signed: false))
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
                        Text("NET DEPOSIT")
                            .appCaps(.footnote)
                        Text(DisplayFormat.money(displayedCost))
                            .numericTransition(displayedCost)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showsNetDeposit ? 1 : 0.45)
                .accessibilityLabel("净入金线")
                .accessibilityValue(showsNetDeposit ? "显示" : "隐藏")
                .accessibilityHint("轻点切换显示或隐藏")
                .foregroundStyle(Color.primary.opacity(colorScheme == .light ? 0.30 : 0.50))
            }
            .appNumber(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 75)

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
                choices: choices,
                selection: $range,
                isDisabled: isChartLoading,
                usesBrightSelectedBackground: true,
                title: { $0 }
            )
            .frame(height: PortfolioHeroChartLayout.pickerHeight)
            .contentShape(Rectangle())
            .offset(y: PortfolioHeroChartLayout.pickerTop)
            .zIndex(2)
            .accessibilityLabel("成本与市值时间范围")
        }
        .frame(height: PortfolioHeroChartLayout.sectionHeight, alignment: .topLeading)
        .task {
            let response = response
            let prepared = await Task.detached(priority: .userInitiated) {
                CostMarketPreparedData(response: response)
            }.value
            guard !Task.isCancelled else { return }
            self.prepared = prepared
            if prepared.data(for: range).rows.count <= 1,
               let availableRange = choices.first(where: { prepared.data(for: $0).rows.count > 1 }) {
                // A sparse history can contain one old point plus today. Do
                // not leave the default 3M filter on a single point.
                range = availableRange
            }
            isPreparing = false
            applyLaunchSelectionIfNeeded()
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
        if isChartLoading {
            StandardLineChartSkeleton(
                axisWidth: 0,
                topInset: 0,
                trailingEndpointInset: 21,
                seriesCount: 2
            )
                .accessibilityElement()
                .accessibilityLabel("正在准备历史数据")
        } else if data.rows.count > 1 {
            FastCostMarketPlot(
                data: data,
                showsNetDeposit: showsNetDeposit,
                transitionKey: range,
                selectedPoint: selectedDate == nil && measuredRange == nil ? nil : selectedPoint,
                measuredRange: measuredRange,
                selectionIndicatorLabel: selectionIndicatorLabel,
                compactDates: range == "1D" || range == "1W" || range == "1M",
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
            .accessibilityLabel("成本与市值对比图，长按后单指拖动查看单日，保持第一指并加入第二指测量区间")
        } else {
            StandardLineChartPlaceholder(
                title: "历史数据不足",
                message: warning ?? "该时间范围内没有足够的成本与市值记录。",
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

    private func compactAxisValue(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000 {
            return "\((value / 1_000_000).formatted(.number.precision(.fractionLength(0))))M"
        }
        if magnitude >= 1_000 {
            return "\((value / 1_000).formatted(.number.precision(.fractionLength(0))))K"
        }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    private func rangeDateText(from start: Date, to end: Date) -> String {
        "\(start.formatted(.dateTime.year().month(.abbreviated).day())) – \(end.formatted(.dateTime.year().month(.abbreviated).day()))"
    }

    private var selectionIndicatorLabel: String? {
        if let measurement = measuredPoints {
            return rangeDateText(from: measurement.start.date, to: measurement.end.date)
        }
        guard selectedDate != nil, let selectedPoint else { return nil }
        if range == "1D" {
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
/// of Swift Charts marks. All filtering, sampling and domains are cached once.
private struct FastCostMarketPlot: View {
    let data: CostMarketRangeData
    let showsNetDeposit: Bool
    let transitionKey: String
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
                : Color(red: 0.204, green: 0.780, blue: 0.349),
            lineWidth: 3,
            latestPointRadius: 5,
            latestPointColor: colorScheme == .light ? .black : nil,
            latestPointUsesGlass: false
        )
        let costSeries = StandardLineChartSeries(
            id: "cost",
            points: data.plottedRows.map {
                StandardLineChartPoint(id: "cost|\($0.id)", date: $0.date, value: $0.cost)
            },
            color: Color(red: 0.204, green: 0.459, blue: 1),
            lineWidth: 3,
            latestPointRadius: 5,
            latestPointUsesGlass: false
        )
        StandardLineChart(
            series: showsNetDeposit ? [marketSeries, costSeries] : [marketSeries],
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
            leadingLineOverflow: 0,
            trailingEndpointInset: 21,
            gridOpacity: 0,
            transitionKey: "\(transitionKey)-\(colorScheme == .light ? "light" : "dark")",
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

private final class CostMarketPreparedData: @unchecked Sendable {
    private let ranges: [String: CostMarketRangeData]

    init(response: PortfolioChartResponse) {
        let source = response.positionHistory.rows.isEmpty
            ? [response.currentPoint]
            : response.positionHistory.rows
        let points = source.compactMap { row -> CostMarketPlotPoint? in
            guard let date = DayDateCodec.date(from: row.dateText) else { return nil }
            return CostMarketPlotPoint(
                dateText: row.dateText,
                date: date,
                marketValue: row.marketValue,
                cost: row.cost
            )
        }.sorted { $0.date < $1.date }

        guard let last = points.last?.date else {
            ranges = [:]
            return
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let oneWeek = calendar.date(byAdding: .day, value: -7, to: last) ?? .distantPast
        let oneMonth = calendar.date(byAdding: .month, value: -1, to: last) ?? .distantPast
        let threeMonths = calendar.date(byAdding: .month, value: -3, to: last) ?? .distantPast
        let oneYear = calendar.date(byAdding: .year, value: -1, to: last) ?? .distantPast
        let lastYear = calendar.component(.year, from: last)

        ranges = [
            // Portfolio history is daily rather than intraday. Use the latest
            // two trading snapshots so 1D still shows the day-over-day move
            // instead of collapsing to an unhelpful single point.
            "1D": Self.prepare(Array(points.suffix(2))),
            "1W": Self.prepare(points.filter { $0.date >= oneWeek }),
            "1M": Self.prepare(points.filter { $0.date >= oneMonth }),
            "3M": Self.prepare(points.filter { $0.date >= threeMonths }),
            "YTD": Self.prepare(points.filter { calendar.component(.year, from: $0.date) == lastYear }),
            "1Y": Self.prepare(points.filter { $0.date >= oneYear }),
            "MAX": Self.prepare(points)
        ]
    }

    func data(for range: String) -> CostMarketRangeData {
        ranges[range] ?? ranges["MAX"] ?? .empty
    }

    private static func prepare(_ points: [CostMarketPlotPoint]) -> CostMarketRangeData {
        guard !points.isEmpty else { return .empty }
        let step = max(1, Int(ceil(Double(points.count) / 90)))
        var sampled = Array(stride(from: 0, to: points.count, by: step)).map { points[$0] }
        if sampled.last?.id != points.last?.id, let last = points.last { sampled.append(last) }

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
            plottedRows: sampled,
            domain: max(0, minimum - padding)...(maximum + padding)
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

private struct PortfolioDetailsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let holdings: [Holding]
    let onSelect: (Holding) -> Void

    @State private var tableMode: String = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-etf") { return "ETF 穿透" }
        if arguments.contains("--show-heatmap") { return "热力图" }
        return "持仓"
    }()
    @State private var etfResponse: ETFLookThroughResponse?
    @State private var etfError: String?
    @State private var isLoadingETF = false
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 10) {
                Menu {
                    Button {
                        tableMode = "持仓"
                    } label: {
                        Label("持仓明细", systemImage: tableMode == "持仓" ? "checkmark" : "list.bullet")
                    }
                    Button {
                        tableMode = "热力图"
                    } label: {
                        Label("持仓热力图", systemImage: tableMode == "热力图" ? "checkmark" : "rectangle.3.group")
                    }
                    Button {
                        tableMode = "ETF 穿透"
                    } label: {
                        Label("ETF 穿透", systemImage: tableMode == "ETF 穿透" ? "checkmark" : "square.3.layers.3d")
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
                    .font(.system(
                        size: colorScheme == .light ? 28 : 32,
                        weight: .medium,
                        design: .rounded
                    ).monospacedDigit())
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Spacer()
                HStack(spacing: 12) {
                if tableMode == "持仓" {
                    HoldingSortMenu(
                        field: Binding(
                            get: { holdingSortField },
                            set: { holdingSortFieldRawValue = $0.rawValue }
                        ),
                        ascending: $holdingSortAscending,
                        performancePeriod: $holdingPerformancePeriod,
                        iconOnly: true,
                        usesGlass: headerUsesGlass
                    )
                } else if tableMode == "ETF 穿透" {
                    ETFExposureSortMenu(field: $etfSortField, ascending: $etfSortAscending)
                } else {
                    HeatmapPerformancePeriodMenu(
                        period: $heatmapPerformancePeriod,
                        groupsBySector: $heatmapGroupsBySector,
                        looksThroughETF: $heatmapLooksThroughETF,
                        usesGlass: headerUsesGlass
                    )
                }
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PortfolioHeaderMidYPreferenceKey.self,
                        value: geometry.frame(in: .global).midY
                    )
                }
            }
            .onPreferenceChange(PortfolioHeaderMidYPreferenceKey.self) { midY in
                updateHeaderMaterial(for: midY)
            }

            Group {
                if tableMode == "持仓" {
                    holdingsTable
                } else if tableMode == "热力图" {
                    HoldingsHeatmapView(
                        holdings: holdings,
                        dailyChanges: model.holdingDailyChanges,
                        isLoading: model.isHoldingDailyChangesLoading
                            || (heatmapLooksThroughETF
                                && (isLoadingETF || isLoadingETFConstituentChanges)),
                        performancePeriod: heatmapPerformancePeriod,
                        groupsBySector: heatmapGroupsBySector,
                        usesETFLookThrough: heatmapLooksThroughETF,
                        lookThroughRows: loadedETFHoldingsKey == etfHoldingsKey
                            ? etfResponse?.rows
                            : nil,
                        lookThroughDailyChanges: etfConstituentDailyChanges,
                        onSelect: onSelect
                    )
                } else {
                    etfTable
                }
            }
        }
        .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background(colorScheme == .light ? Color.white : Color(red: 0, green: 0.008, blue: 0))
        .task(id: "\(tableMode)-\(etfHoldingsKey)-\(heatmapLooksThroughETF)") {
            if tableMode == "ETF 穿透" {
                guard etfResponse == nil || loadedETFHoldingsKey != etfHoldingsKey else { return }
                await loadETF()
            } else if tableMode == "热力图" {
                await model.refreshHoldingDailyChanges()
                if heatmapLooksThroughETF {
                    if etfResponse == nil || loadedETFHoldingsKey != etfHoldingsKey {
                        await loadETF()
                    }
                    await loadETFConstituentDailyChanges()
                }
            }
        }
        .onChange(of: etfSortField) { _, _ in etfVisibleLimit = 20 }
        .onChange(of: etfSortAscending) { _, _ in etfVisibleLimit = 20 }
    }

    private var itemCount: String {
        switch tableMode {
        case "ETF 穿透": "All \(etfResponse?.rows.count ?? 0)"
        default: "All \(holdings.count)"
        }
    }

    private func updateHeaderMaterial(for midY: CGFloat) {
        guard #available(iOS 26.0, *) else {
            headerUsesGlass = false
            return
        }

        let screenMidY = UIScreen.main.bounds.midY
        // Once glass is active, keep it until the header has moved a little
        // below the centre again. This prevents material flicker around the
        // threshold during slow scrolling and rubber-banding.
        let threshold = headerUsesGlass ? screenMidY + 28 : screenMidY
        let shouldUseGlass = midY <= threshold
        guard shouldUseGlass != headerUsesGlass else { return }

        withAnimation(.easeOut(duration: 0.18)) {
            headerUsesGlass = shouldUseGlass
        }
    }

    private var tableTitle: String {
        switch tableMode {
        case "ETF 穿透": "ETF 穿透"
        case "热力图": "持仓热力图"
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
                .buttonStyle(.plain)
                .accessibilityHint("打开成交量分析")
            }
        }
    }

    private var holdingSortField: HoldingSortField {
        HoldingSortField(rawValue: holdingSortFieldRawValue) ?? .marketValue
    }

    private var sortedHoldings: [Holding] {
        holdings.sorted { left, right in
            switch holdingSortField {
            case .marketValue:
                return compare(left.marketValue, right.marketValue, leftTicker: left.ticker, rightTicker: right.ticker)
            case .unrealized:
                return compareOptional(
                    performanceValues(for: left)?.amount,
                    performanceValues(for: right)?.amount,
                    leftTicker: left.ticker,
                    rightTicker: right.ticker
                )
            case .unrealizedPercent:
                return compareOptional(
                    performanceValues(for: left)?.percent,
                    performanceValues(for: right)?.percent,
                    leftTicker: left.ticker,
                    rightTicker: right.ticker
                )
            case .name:
                let comparison = left.shortName.localizedStandardCompare(right.shortName)
                if comparison == .orderedSame {
                    let tickerComparison = left.ticker.localizedStandardCompare(right.ticker)
                    return holdingSortAscending
                        ? tickerComparison == .orderedAscending
                        : tickerComparison == .orderedDescending
                }
                return holdingSortAscending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
        }
    }

    private func compare(
        _ left: Double,
        _ right: Double,
        leftTicker: String,
        rightTicker: String
    ) -> Bool {
        if left == right {
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
        holding.todayChangePercent ?? model.holdingDailyChanges[holding.ticker.uppercased()]
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
                Text("正在计算 ETF 底层持仓…")
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
                ETFSummaryMetric(title: "ETF 市值", value: DisplayFormat.money(response.etfTotalUSD))
                ETFSummaryMetric(title: "底层证券", value: "\(response.constituentCount) 项")
                ETFSummaryMetric(
                    title: "成分覆盖",
                    value: DisplayFormat.percent(response.coveredWeightPercent, signed: false)
                )
            }
            .padding(.vertical, 10)

            Text("\(response.etfTickers.joined(separator: " · ")) 按当前市值和基金权重拆开，再与相同股票的直接持仓合并。")
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
                        Text("显示更多")
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
                .accessibilityHint("再显示 20 项 ETF 底层持仓")
            }
        }
    }

    private var etfHoldingsKey: String {
        holdings.map { "\($0.ticker):\($0.shares):\($0.quotePrice)" }.joined(separator: "|")
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
        isLoadingETF = true
        etfError = nil
        defer { isLoadingETF = false }
        do {
            etfResponse = try await model.loadETFLookThrough(basis: .market)
            loadedETFHoldingsKey = etfHoldingsKey
            etfConstituentDailyChanges = [:]
            loadedETFConstituentChangesKey = ""
            etfVisibleLimit = 20
        } catch {
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
            .prefix(HoldingsHeatmapView.maximumLookThroughTiles)
            .map(\.ticker)
        let signature = "\(etfHoldingsKey)|\(tickers.map { $0.uppercased() }.joined(separator: ","))"
        guard signature != loadedETFConstituentChangesKey else { return }

        isLoadingETFConstituentChanges = true
        defer { isLoadingETFConstituentChanges = false }
        let changes = await LocalMarketDataClient().dailyChanges(tickers: tickers)
        guard !Task.isCancelled, loadedETFHoldingsKey == etfHoldingsKey else { return }
        etfConstituentDailyChanges = changes
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
        case .marketValue: "市值"
        case .unrealized: "盈利"
        case .unrealizedPercent: "收益率"
        case .name: "名称"
        }
    }

    var compactTitle: String {
        switch self {
        case .marketValue: "Mkt Cap"
        case .unrealized: "P&L"
        case .unrealizedPercent: "Return"
        case .name: "Name"
        }
    }
}

enum HoldingPerformancePeriod: String, CaseIterable, Identifiable {
    case today
    case holdingPeriod

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今日"
        case .holdingPeriod: "持有期"
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
    @Binding var period: HoldingPerformancePeriod
    @Binding var groupsBySector: Bool
    @Binding var looksThroughETF: Bool
    var usesGlass = false

    var body: some View {
        Menu {
            Section("收益时间") {
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

            Section("布局") {
                Toggle("按板块分组", isOn: $groupsBySector)
                Toggle("穿透 ETF", isOn: $looksThroughETF)
            }
        } label: {
            Image("PortfolioHeaderSort")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .frame(width: 58, height: 44)
                .modifier(PortfolioHeaderMaterialControl(usesGlass: usesGlass))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .menuOrder(.fixed)
        .accessibilityLabel(
            "热力图筛选：\(period.title)，\(groupsBySector ? "按板块分组" : "不分组")，"
                + (looksThroughETF ? "已穿透 ETF" : "未穿透 ETF")
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
        case .totalExposure: "总暴露"
        case .indirectExposure: "ETF 间接"
        case .directExposure: "直接持仓"
        case .name: "名称"
        }
    }
}

private struct HoldingSortMenu: View {
    @Binding var field: HoldingSortField
    @Binding var ascending: Bool
    @Binding var performancePeriod: HoldingPerformancePeriod
    var iconOnly = false
    var usesGlass = false

    var body: some View {
        menu
        .buttonStyle(.plain)
        .appText(.footnote, weight: .medium)
        .foregroundStyle(.secondary)
        .accessibilityLabel("筛选：\(performancePeriod.title)；排序：\(field.title)，\(ascending ? "升序" : "降序")")
    }

    private var menu: some View {
        Menu {
            Section("收益时间") {
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

            Section("排序方式") {
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
                    ascending ? "改为降序" : "改为升序",
                    systemImage: ascending ? "arrow.down" : "arrow.up"
                )
            }
        } label: {
            Group {
                if iconOnly {
                    Image("PortfolioHeaderSort")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .frame(width: 58, height: 44)
                        .modifier(PortfolioHeaderMaterialControl(usesGlass: usesGlass))
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

private struct PortfolioHeaderMidYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ETFExposureSortMenu: View {
    @Binding var field: ETFExposureSortField
    @Binding var ascending: Bool

    var body: some View {
        menu
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityLabel("ETF 穿透排序：\(field.title)，\(ascending ? "升序" : "降序")")
    }

    private var menu: some View {
        Menu {
            Section("排序方式") {
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
                    ascending ? "改为降序" : "改为升序",
                    systemImage: ascending ? "arrow.down" : "arrow.up"
                )
            }
        } label: {
            HStack(spacing: 5) {
                Text(field.title)
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .menuOrder(.fixed)
    }
}

private struct ETFSummaryMetric: View {
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
                            Text("\(formattedShares(directHolding.shares)) 股")
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
                exposureLabel("直接", value: row.directUSD, color: CatfolioPalette.blue500)
                exposureLabel("ETF", value: row.fromETFUSD, color: CatfolioPalette.green500)
                Spacer(minLength: 4)
                if row.directUSD > 0, row.fromETFUSD > 0 {
                    Text("重叠持仓")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.1), in: Capsule())
                }
            }

            if let directHolding {
                HStack(spacing: 6) {
                    Text("现价 \(DisplayFormat.money(directHolding.quotePrice, currency: directHolding.quoteCurrency))")
                    Text("·")
                    Text(
                        "盈亏 \(DisplayFormat.money(directHolding.unrealized, signed: true, fractionDigits: 2)) "
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

                            Text(DisplayFormat.money(holding.marketValue, fractionDigits: 2))
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
            "\(holding.shortName)，\(formattedShares) 股 \(holding.ticker)，市值 \(DisplayFormat.money(holding.marketValue))，\(performancePeriod.title)盈亏 \(profitDescription)"
        )
    }

    private var formattedShares: String {
        DisplayFormat.shares(holding.shares)
    }

    private var profitDescription: String {
        guard let performance else { return "暂无数据" }
        return "\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) · \(DisplayFormat.percent(performance.percent))"
    }

    @ViewBuilder
    private var performanceLabel: some View {
        if let performance {
            HStack(spacing: 2) {
                Text(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2))
                    .numericTransition(performance.amount)
                Circle()
                    .fill(rowAccent)
                    .frame(width: 2, height: 2)
                    .accessibilityHidden(true)
                Text(DisplayFormat.percent(performance.percent))
                    .numericTransition(performance.percent)
            }
            .appNumber(.caption)
            .foregroundStyle(rowAccent)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        } else {
            Text("暂无数据")
                .font(PortfolioHomeTypography.medium(12, relativeTo: .caption))
                .foregroundStyle(rowAccent)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
    }

    private var rowAccent: Color {
        if (performance?.amount ?? 0) >= 0 {
            return Color(red: 1 / 255, green: 184 / 255, blue: 1 / 255)
        }
        return CatfolioPalette.rose500
    }
}

private struct HoldingIdentity: View {
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
    let holding: Holding
    let performance: HoldingPerformanceValues?
    let period: HoldingPerformancePeriod
    let alignment: HorizontalAlignment
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(DisplayFormat.money(holding.marketValue, fractionDigits: 2))
                .appNumber(.body)
                .lineLimit(compact ? 1 : nil)
            Text(performanceText)
            .appNumber(.caption)
            .foregroundStyle(
                (performance?.amount ?? 0) >= 0
                    ? (colorScheme == .light
                        ? Color(red: 0, green: 0.80, blue: 0.25)
                        : Color(red: 0.188, green: 0.820, blue: 0.345))
                    : CatfolioPalette.rose500
            )
            .lineLimit(compact ? 1 : nil)
        }
    }

    private var performanceText: String {
        guard let performance else { return "\(period.title)暂无数据" }
        return "\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) "
            + "· \(DisplayFormat.percent(performance.percent))"
    }
}

private enum HomeSkeletonStyle {
    static func color(for scheme: ColorScheme) -> Color {
        scheme == .light ? Color(white: 244.0 / 255.0) : Color(white: 0.12)
    }
}

private struct HomeSkeletonBlock: View {
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
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true

    var body: some View {
        let color = HomeSkeletonStyle.color(for: colorScheme)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HomeSkeletonBlock(width: 52, height: 10, color: color)
                HomeSkeletonBlock(width: 133, height: 22, color: color)
                HStack(spacing: 4) {
                    HomeSkeletonBlock(width: 46, height: 11, color: color)
                    HomeSkeletonBlock(width: 71, height: 11, color: color)
                    HomeSkeletonBlock(width: 39, height: 11, color: color)
                }
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
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true

    var body: some View {
        let color = HomeSkeletonStyle.color(for: colorScheme)
        VStack(spacing: 0) {
            PortfolioChartLoadingPlaceholder(isAnimating: isAnimating)
                .frame(height: PortfolioHeroChartLayout.sectionHeight)

            VStack(spacing: 33) {
                TodayLoadingHeader(isAnimating: isAnimating)
                TodayContributionLoadingBars(isAnimating: isAnimating)
            }
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            .padding(.vertical, 30)
            .frame(height: 326, alignment: .top)
            .background(
                Color(uiColor: .systemBackground),
                in: UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38)
            )

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
            .background(Color(uiColor: .systemBackground))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isAnimating ? "正在读取投资组合" : "暂无持仓数据")
    }
}

private struct PortfolioChartLoadingPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    var isAnimating = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 12) {
                HomeSkeletonBlock(width: 72, height: 10, color: .white)
                HomeSkeletonBlock(width: 172, height: 22, color: .white)
                HStack(spacing: 4) {
                    HomeSkeletonBlock(width: 65, height: 11, color: .white)
                    HomeSkeletonBlock(width: 38, height: 11, color: .white)
                    HomeSkeletonBlock(width: 104, height: 11, color: .white)
                    HomeSkeletonBlock(width: 68, height: 11, color: .white)
                }
            }
            .opacity(colorScheme == .light ? 0.5 : 0.15)
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            .padding(.top, 15)

            GeometryReader { geometry in
                Image("HomeSkeletonLineOne")
                    .resizable()
                    .frame(width: geometry.size.width * 407.169 / 402,
                           height: geometry.size.height * 187.016 / 226)
                    .offset(x: -geometry.size.width * 24 / 402)
                Image("HomeSkeletonLineTwo")
                    .resizable()
                    .frame(width: geometry.size.width * 416 / 402,
                           height: geometry.size.height * 155 / 226)
                    .offset(x: -geometry.size.width * 34 / 402,
                            y: geometry.size.height * 72 / 226)
            }
            .frame(height: PortfolioHeroChartLayout.plotHeight)
            .opacity(colorScheme == .light ? 1 : 0.22)
            .offset(y: PortfolioHeroChartLayout.plotTop)

            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    HomeSkeletonBlock(
                        width: [12.0, 15, 14, 17, 20, 12, 23][index],
                        height: 11, color: .white
                    )
                    .frame(width: 44, height: 30)
                    .background(index == 3 ? Color.white.opacity(0.5) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: PortfolioHeroChartLayout.pickerHeight)
            .opacity(colorScheme == .light ? 1 : 0.22)
            .padding(.horizontal, 16)
            .offset(y: PortfolioHeroChartLayout.pickerTop)
        }
        .frame(height: PortfolioHeroChartLayout.sectionHeight, alignment: .topLeading)
    }
}
