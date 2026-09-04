import SwiftUI

private enum PortfolioHomeTypography {
    static func regular(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Montserrat-Regular", size: size, relativeTo: style)
    }

    static func medium(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Montserrat-Medium", size: size, relativeTo: style)
    }

    static func semibold(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Montserrat-SemiBold", size: size, relativeTo: style)
    }

    static func italic(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Montserrat-Italic", size: size, relativeTo: style)
    }
}

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
        VStack(spacing: 0) {
            PortfolioHomeTopBackground(colorScheme: colorScheme)
                .frame(height: 520)

            // Keep the terminal colour of the hero behind the chart while the
            // scroll view is being rubber-banded. The opaque sections below
            // cover this extension in the resting state.
            (colorScheme == .light
                ? Color(red: 0.886, green: 0.941, blue: 0.969)
                : Color(red: 0.192, green: 0.208, blue: 0.235))
                .frame(height: 180)

            colorScheme == .light
                ? Color.white
                : Color.black
        }
        .ignoresSafeArea()
    }
}

struct PortfolioView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedHolding: Holding?

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        PortfolioRefreshTimestamp(
                            date: model.localUpdatedAt,
                            isRefreshing: model.isPortfolioLoading
                        )

                        if let overview = model.overview, let chart = model.portfolioChart {
                            CostMarketCard(overview: overview, response: chart)
                                .id(model.portfolioChartRevision)

                            TodayContributionCard(
                                holdings: model.holdings,
                                dailyChanges: model.holdingDailyChanges,
                                benchmarkChange: model.benchmarkDailyChange,
                                isLoading: model.isHoldingDailyChangesLoading
                            ) { holding in
                                selectedHolding = holding
                            }
                            .id("today-contribution")

                            PortfolioDetailsCard(holdings: model.holdings) { holding in
                                selectedHolding = holding
                            }
                            .id("portfolio-details")
                        } else if model.isPortfolioLoading {
                            PortfolioLoadingView()
                        } else if let error = model.portfolioError {
                            ContentUnavailableView("还没有本机持仓", systemImage: "iphone.gen3.slash", description: Text(error))
                                .frame(minHeight: 420)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .background {
                    PortfolioHomePageBackdrop(colorScheme: colorScheme)
                }
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
                .sheet(item: $selectedHolding) { holding in
                    HoldingDetailView(holding: holding)
                        .environment(model)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.hidden)
                        .presentationBackground(Color(uiColor: .systemBackground))
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
                    .font(PortfolioHomeTypography.medium(11, relativeTo: .caption2))
                    .foregroundStyle(Color.primary.opacity(0.44))
                    .monospacedDigit()
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
    let onSelect: (Holding) -> Void

    @State private var direction: Direction = TodayContributionCard.launchDirection
    @State private var displayedDirection: Direction = TodayContributionCard.launchDirection
    @State private var logoSwitchScale: CGFloat = 1
    @State private var barHeightFactor: CGFloat = 1
    @State private var isDirectionSwitching = false
    @State private var directionSwitchTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("catfolio.haptics") private var hapticsEnabled = true

    private var contributions: [Contribution] {
        holdings.compactMap { holding in
            let key = holding.ticker.uppercased()
            guard let change = holding.todayChangePercent ?? dailyChanges[key],
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
            displayedDirection == .gains ? contribution.amount > 0 : contribution.amount < 0
        }
        return Array(filtered.sorted { lhs, rhs in
            displayedDirection == .gains ? lhs.amount > rhs.amount : lhs.amount < rhs.amount
        }.prefix(5))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            todayBackground

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("TODAY")
                        .font(PortfolioHomeTypography.semibold(12, relativeTo: .caption))
                        .tracking(2)
                        .foregroundStyle(.primary)
                        .frame(height: 17, alignment: .topLeading)

                    Group {
                        if isAwaitingContributions {
                            Text("—")
                                .font(PortfolioHomeTypography.medium(32, relativeTo: .largeTitle))
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
                        if isAwaitingContributions {
                            Text("正在更新今日数据")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(DisplayFormat.percent(totalPercent))
                                .foregroundStyle(.primary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            benchmarkSummary
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                    }
                    .font(PortfolioHomeTypography.medium(14, relativeTo: .subheadline).monospacedDigit())
                    .tracking(0.65)
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
                if isLoading && contributions.isEmpty {
                    ProgressView("正在计算今日贡献")
                        .frame(maxWidth: .infinity, minHeight: 167)
                } else if visibleContributions.isEmpty {
                    ContentUnavailableView(
                        displayedDirection == .gains ? "今天暂无上涨持仓" : "今天暂无下跌持仓",
                        systemImage: displayedDirection == .gains ? "arrow.up.right" : "arrow.down.right"
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
        .sensoryFeedback(.selection, trigger: direction) { _, _ in hapticsEnabled }
        .accessibilityElement(children: .contain)
        .onDisappear {
            directionSwitchTask?.cancel()
        }
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
            let showsGains = displayedDirection == .gains
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
                .animation(.easeOut(duration: 0.18), value: displayedDirection)
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
                            isGain: displayedDirection == .gains,
                            animationDelay: Double(index) * 0.045,
                            logoSwitchScale: logoSwitchScale,
                            heightFactor: barHeightFactor,
                            isDirectionSwitching: isDirectionSwitching
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

        directionSwitchTask?.cancel()
        direction = value

        guard !reduceMotion else {
            displayedDirection = value
            logoSwitchScale = 1
            barHeightFactor = 1
            isDirectionSwitching = false
            return
        }

        // A quick reversal before the midpoint keeps the currently displayed
        // content and simply restores its logo to full size.
        guard value != displayedDirection else {
            isDirectionSwitching = false
            withAnimation(.timingCurve(0.12, 0.72, 0.22, 1, duration: 0.16)) {
                logoSwitchScale = 1
                barHeightFactor = 1
            }
            return
        }

        isDirectionSwitching = true
        withAnimation(.timingCurve(0.55, 0, 0.88, 0.32, duration: 0.16)) {
            logoSwitchScale = 0.001
            barHeightFactor = 0.35
        }

        directionSwitchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }

            // Swap the data and logo only while the old logo is at its minimum.
            displayedDirection = value
            logoSwitchScale = 0.001
            barHeightFactor = 0.35

            // One continuous curve now handles rebound, restrained overshoot,
            // and settling. The previous separate 1.02 -> 1 transaction was
            // short enough to read as an extra kick on the final frame.
            withAnimation(.timingCurve(0.16, 0.72, 0.24, 1.04, duration: 0.33)) {
                logoSwitchScale = 1
                barHeightFactor = 1
            }

            try? await Task.sleep(for: .milliseconds(330))
            guard !Task.isCancelled else { return }
            isDirectionSwitching = false
        }
    }
}

private struct TodayContributionBar: View {
    let holding: Holding
    let amount: Double
    let relativeHeight: Double
    let isGain: Bool
    let animationDelay: Double
    let logoSwitchScale: CGFloat
    let heightFactor: CGFloat
    let isDirectionSwitching: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var growth: CGFloat = 0
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
        // Keep one continuous height expression throughout the transition.
        // Switching formulas when `isDirectionSwitching` became false could
        // replace the final presentation frame a fraction early and look like
        // a small jump at the end of the rebound.
        max(24, barHeight * growth * heightFactor)
    }

    private var renderedCornerRadius: CGFloat {
        min(12, renderedBarHeight / 2)
    }

    private var switchContentOpacity: CGFloat {
        guard isDirectionSwitching else { return 1 }
        return min(max((heightFactor - 0.35) / 0.22, 0), 1)
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
                            .opacity(growth * switchContentOpacity)

                        Text(amountText)
                            .font(PortfolioHomeTypography.semibold(12, relativeTo: .caption).monospacedDigit())
                            .tracking(1.25)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                            .padding(.horizontal, 4)
                            .padding(.top, 14)
                            .opacity(growth * switchContentOpacity)
                    }
                    .frame(height: renderedBarHeight)
                    .clipShape(fillShape, style: FillStyle(antialiased: true))
                }
                .frame(maxWidth: .infinity, minHeight: 146, maxHeight: 146, alignment: .bottom)

                contributionLogo
                    .scaleEffect((0.76 + growth * 0.24) * logoSwitchScale)
                    .opacity(growth)
                    .offset(y: 131)
            }
            .frame(maxWidth: .infinity, minHeight: 167, maxHeight: 167, alignment: .top)
        }
        .buttonStyle(ContributionBarButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(holding.shortName)，今日贡献 \(DisplayFormat.money(amount, signed: true, fractionDigits: 2))")
        .accessibilityHint("打开个股详情")
        .onAppear {
            if isDirectionSwitching {
                growth = 1
                return
            }

            guard !reduceMotion else {
                growth = 1
                return
            }

            growth = 0
            withAnimation(.spring(duration: 0.46, bounce: 0.16).delay(animationDelay)) {
                growth = 1
            }
        }
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced {
                growth = 1
            }
        }
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
            .font(.caption2.weight(.bold).monospacedDigit())
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
    static let plotHeight: CGFloat = 299
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
        let marketMovement = end.marketValue - start.marketValue
        let contributionMovement = end.cost - start.cost
        let amount = marketMovement - contributionMovement
        let percentage = start.marketValue == 0 ? 0 : amount / start.marketValue * 100
        return (amount, percentage)
    }

    private var measuredChange: Double? {
        measuredPoints.map { $0.end.marketValue - $0.start.marketValue }
    }

    private var measuredChangePercentage: Double? {
        guard let measurement = measuredPoints,
              measurement.start.marketValue != 0 else { return measuredPoints == nil ? nil : 0 }
        return (measurement.end.marketValue - measurement.start.marketValue)
            / measurement.start.marketValue * 100
    }

    private var displayedPrimaryAmount: Double {
        measuredChange ?? displayedMarketValue
    }

    private var financialAccent: Color {
        let value = measuredChange ?? rangePerformance.amount
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
                    .font(PortfolioHomeTypography.semibold(12, relativeTo: .caption))
                    .tracking(1.2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(.primary)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 15)

            CatfolioDisplayAmountText(
                text: DisplayFormat.money(
                    displayedPrimaryAmount,
                    signed: measuredChange != nil,
                    fractionDigits: 2
                ),
                color: measuredChange == nil ? .primary : financialAccent
            )
            .contentTransition(.numericText(value: displayedPrimaryAmount))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: displayedPrimaryAmount)
            .frame(height: 38, alignment: .leading)
            .offset(x: CatfolioStyle.pageHorizontalInset, y: 32)

            HStack(spacing: 4) {
                let summaryAccent = colorScheme == .light ? Color.primary : financialAccent
                if measuredChange != nil, let measuredChangePercentage {
                    Text(DisplayFormat.percent(abs(measuredChangePercentage), signed: false))
                        .foregroundStyle(summaryAccent)
                        .contentTransition(.numericText(value: measuredChangePercentage))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: measuredChangePercentage)

                    Text("·")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(DisplayFormat.money(rangePerformance.amount, signed: true))
                        .foregroundStyle(summaryAccent)
                        .contentTransition(.numericText(value: rangePerformance.amount))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: rangePerformance.amount)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(DisplayFormat.percent(abs(rangePerformance.percentage), signed: false))
                        .foregroundStyle(summaryAccent)
                        .contentTransition(.numericText(value: rangePerformance.percentage))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: rangePerformance.percentage)

                    Text("·")
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 4) {
                    Text(measuredChange == nil ? "NET DEPOSIT" : "ENDING VALUE")
                    Text(DisplayFormat.money(measuredChange == nil ? displayedCost : displayedMarketValue))
                }
                .foregroundStyle(Color.primary.opacity(colorScheme == .light ? 0.30 : 0.50))
            }
            .font(PortfolioHomeTypography.medium(14, relativeTo: .subheadline).monospacedDigit())
            .tracking(1.45)
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
                    .font(PortfolioHomeTypography.italic(14, relativeTo: .caption).monospacedDigit())
                    .tracking(1.4)
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
            series: [marketSeries, costSeries],
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
            interactionBottomInset: 20,
            leadingLineOverflow: 0,
            trailingEndpointInset: 21,
            gridOpacity: 0,
            transitionKey: "\(transitionKey)-\(colorScheme == .light ? "light" : "dark")",
            selectedDate: selectedPoint?.date,
            measuredRange: measuredRange,
            selectionIndicatorLabel: selectionIndicatorLabel,
            selectionSeriesIDs: ["market", "cost"],
            rangeSeriesIDs: ["market", "cost"],
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
    @State private var etfVisibleLimit = 20
    @State private var etfSortField = ETFExposureSortField.totalExposure
    @State private var etfSortAscending = false
    @State private var headerUsesGlass = false
    @AppStorage("portfolio.holdings.sortField") private var holdingSortFieldRawValue = HoldingSortField.marketValue.rawValue
    @AppStorage("portfolio.holdings.sortAscending") private var holdingSortAscending = false
    @State private var holdingPerformancePeriod: HoldingPerformancePeriod = .holdingPeriod

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
                    .font(PortfolioHomeTypography.medium(colorScheme == .light ? 28 : 32, relativeTo: .largeTitle))
                    .tracking(colorScheme == .light ? 1.4 : 1.6)
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
                    HStack(spacing: 6) {
                        if model.isHoldingDailyChangesLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("今日")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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
                        isLoading: model.isHoldingDailyChangesLoading,
                        onSelect: onSelect,
                        onShowAll: { tableMode = "持仓" }
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
        .task(id: "\(tableMode)-\(etfHoldingsKey)") {
            if tableMode == "ETF 穿透" {
                guard etfResponse == nil || loadedETFHoldingsKey != etfHoldingsKey else { return }
                await loadETF()
            } else if tableMode == "热力图" {
                await model.refreshHoldingDailyChanges()
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
            etfVisibleLimit = 20
        } catch {
            etfResponse = nil
            etfError = error.localizedDescription
        }
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

private enum HoldingPerformancePeriod: String, CaseIterable, Identifiable {
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
        .font(PortfolioHomeTypography.medium(14, relativeTo: .subheadline))
        .tracking(0.7)
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
                .font(.subheadline.weight(.bold).monospacedDigit())
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
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(DisplayFormat.money(row.totalUSD, fractionDigits: 2))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                    Text(DisplayFormat.percent(portfolioWeight * 100, signed: false))
                        .font(.caption.weight(.semibold).monospacedDigit())
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
                .font(.caption2.weight(.semibold).monospacedDigit())
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
                .font(.caption2.weight(.semibold).monospacedDigit())
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
                HStack(alignment: .center, spacing: 10) {
                    AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 40)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(holding.shortName)
                                .font(PortfolioHomeTypography.medium(17, relativeTo: .headline))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)

                            Spacer(minLength: 4)

                            Text(DisplayFormat.money(holding.marketValue, fractionDigits: 2))
                                .font(PortfolioHomeTypography.medium(17, relativeTo: .headline).monospacedDigit())
                                .tracking(1.36)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(DisplayFormat.shares(holding.shares))
                                Text(holding.ticker)
                            }
                                .font(PortfolioHomeTypography.medium(13, relativeTo: .caption).monospacedDigit())
                                .tracking(1.04)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(0)

                            Spacer(minLength: 2)

                            Text(profitDescription)
                                .font(PortfolioHomeTypography.medium(13, relativeTo: .caption).monospacedDigit())
                                .tracking(1.04)
                                .foregroundStyle(rowAccent)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(2)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(holding.shortName)
                .font(PortfolioHomeTypography.semibold(17, relativeTo: .headline))
                .foregroundStyle(.primary)
                .lineLimit(compact ? 1 : nil)
            Text("\(DisplayFormat.shares(holding.shares)) \(holding.ticker)")
                .font(PortfolioHomeTypography.semibold(13, relativeTo: .caption).monospacedDigit())
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
        VStack(alignment: alignment, spacing: 3) {
            Text(DisplayFormat.money(holding.marketValue, fractionDigits: 2))
                .font(PortfolioHomeTypography.semibold(17, relativeTo: .headline).monospacedDigit())
                .lineLimit(compact ? 1 : nil)
            Text(performanceText)
            .font(PortfolioHomeTypography.semibold(13, relativeTo: .caption).monospacedDigit())
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

private struct PortfolioLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            PortfolioChartLoadingPlaceholder()
                .frame(height: PortfolioHeroChartLayout.sectionHeight)

            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 38,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 38,
                    style: .continuous
                )
                .fill(colorScheme == .light ? Color.white : Color.black)

                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(Color.primary.opacity(0.10)).frame(width: 54, height: 10)
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 180, height: 30)
                    Capsule().fill(Color.primary.opacity(0.08)).frame(width: 210, height: 12)
                }
                .padding(.top, 30)
                .padding(.horizontal, CatfolioStyle.pageHorizontalInset)

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach([140.0, 102.0, 85.0, 76.0, 64.0], id: \.self) { height in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CatfolioPalette.contributionGreen.opacity(0.16))
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                    }
                }
                .frame(height: 140, alignment: .bottom)
                .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                .offset(y: 139)
            }
            .frame(height: 326)

            VStack(alignment: .leading, spacing: 4) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 170, height: 28)
                    .padding(.bottom, 14)
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 13) {
                        RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule().fill(Color.secondary.opacity(0.12)).frame(width: 120, height: 14)
                            Capsule().fill(Color.secondary.opacity(0.09)).frame(width: 90, height: 11)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 7) {
                            Capsule().fill(Color.secondary.opacity(0.12)).frame(width: 88, height: 14)
                            Capsule().fill(Color.secondary.opacity(0.09)).frame(width: 105, height: 11)
                        }
                    }
                    .frame(height: 64)
                }
            }
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            .padding(.top, 24)
            .background(colorScheme == .light ? Color.white : Color.black)
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("正在读取投资组合")
    }
}

private struct PortfolioChartLoadingPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            PortfolioHomeTopBackground(colorScheme: colorScheme)
            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 76, height: 10)
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 190, height: 30)
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: 265, height: 12)
            }
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            .padding(.top, 15)

            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height * 0.76))
                path.addCurve(
                    to: CGPoint(x: size.width, y: size.height * 0.28),
                    control1: CGPoint(x: size.width * 0.30, y: size.height * 0.30),
                    control2: CGPoint(x: size.width * 0.68, y: size.height * 0.58)
                )
                context.stroke(path, with: .color(Color.white.opacity(0.22)), lineWidth: 3)
            }
            .frame(height: PortfolioHeroChartLayout.plotHeight)
            .offset(y: PortfolioHeroChartLayout.plotTop)

            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(index == 3 ? Color.primary.opacity(0.09) : Color.clear)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 30)
            .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
            .offset(y: PortfolioHeroChartLayout.pickerTop + 16)
        }
    }
}
