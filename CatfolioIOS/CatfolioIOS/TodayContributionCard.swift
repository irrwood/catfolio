import SwiftUI
import UIKit

struct TodayContributionCard: View {
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

    private static let launchDirection: Direction = LaunchArguments.contains("--show-today-losses")
        ? .losses
        : .gains

    let holdings: [Holding]
    let dailyChanges: [String: Double]
    let benchmarkChange: Double?
    let isLoading: Bool
    /// Cached contributions are on screen while fresh quotes arrive.
    let isRefreshingBehindCache: Bool
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
        isRefreshingBehindCache: Bool = false,
        onOpenDetail: (() -> Void)? = nil,
        onTitleBottomPositionChange: ((CGFloat) -> Void)? = nil,
        zoomNamespace: Namespace.ID? = nil,
        onSelect: @escaping (Holding) -> Void
    ) {
        self.holdings = holdings
        self.dailyChanges = dailyChanges
        self.benchmarkChange = benchmarkChange
        self.isLoading = isLoading
        self.isRefreshingBehindCache = isRefreshingBehindCache
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
                  let amount = PortfolioMath.dayContribution(
                      marketValue: holding.marketValue, changePercent: change) else { return nil }
            return Contribution(holding: holding, changePercent: change, amount: amount)
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
                            .refreshGlow(isActive: isRefreshingBehindCache)
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

enum TodayContributionAnimation {
    static var reveal: Animation {
        .timingCurve(0.16, 1, 0.30, 1, duration: 0.34)
    }
}

struct TodayContributionBar: View {
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
struct ContributionGlassSurface<S: InsettableShape>: View {
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

struct ContributionBarButtonStyle: ButtonStyle {
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

struct TodayContributionLoadingBars: View {
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

struct TodayLoadingHeader: View {
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
