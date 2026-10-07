import SwiftUI
import UIKit
import Observation

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

struct FiftyTwoWeekRange: View {
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
    /// The year's move lights up tick by tick when the card appears, from
    /// where the year started to where the price is now.
    @State private var hasRevealedMove = false
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
        HoldingDetailSectionCard(title: L10n.text("52-Week Range"), insightFacts: { insightFacts }) {
            VStack(spacing: 10) {
                GeometryReader { geometry in
                    rangePlot(size: geometry.size)
                }
                .frame(height: currentTickHeight)
                FiftyTwoWeekRangeLabels(low: low, high: high, currency: currency)
                    .foregroundStyle(rangeLabelColor)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: selectedIndex)
        .sensoryFeedback(.selection, trigger: selectedIndex) { oldValue, newValue in
            hapticsEnabled && oldValue != nil && newValue != nil
        }
        .onChange(of: reduceMotion) { _, enabled in if enabled { edgePull = 0 } }
        .onDisappear { edgePull = 0; selectedIndex = nil; hasRevealedMove = false }
        // The card sits below the fold, so the sweep waits until it is
        // mostly on screen rather than playing out unseen when the page opens.
        .onScrollVisibilityChange(threshold: 0.6) { isVisible in
            guard isVisible, !hasRevealedMove else { return }
            hasRevealedMove = true
        }
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
                    // Steps from the year's first tick; today's tick is the last.
                    let revealOrder = abs(index - (startIndex ?? currentIndex))
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
                        isRevealed: hasRevealedMove || reduceMotion,
                        // Each tick takes its colour a little after the one
                        // before it, so the move reads as travelling rather
                        // than switching on; the whole run stays under ~0.9s.
                        revealDelay: Double(revealOrder) * min(0.026, 0.6 / Double(max(1, markerCount))),
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
        isRevealed: Bool,
        revealDelay: Double,
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
        let isLit = isHighlighted && isRevealed

        // The grey tick is always there; the colour fades in over it. Two
        // separate shapes swapped in and out would snap rather than animate.
        Capsule().fill(inactiveTickColor)
            .overlay {
                if isHighlighted {
                    Group {
                        if isCurrent {
                            Capsule().fill(performanceColor)
                        } else {
                            Capsule().fill(
                                LinearGradient(
                                    colors: highlightedGradientColors,
                                    startPoint: UnitPoint(x: localStartX, y: 0.5),
                                    endPoint: UnitPoint(x: localEndX, y: 0.5)
                                )
                            )
                        }
                    }
                    .opacity(isRevealed ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.26).delay(revealDelay),
                        value: isRevealed
                    )
                }
            }
            .frame(width: width, height: height)
            .shadow(
                color: usesVisibleGlow
                    ? (isLit ? performanceGlowColor : inactiveTickGlowColor)
                    : .clear,
                radius: usesVisibleGlow ? (isCurrent ? 8 : 5) : 0
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.26).delay(revealDelay),
                value: isRevealed
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
        return components.joined(separator: L10n.listSeparator)
    }

    private var insightFacts: String {
        var lines = [
            "52-week low: \(DisplayFormat.money(low, currency: currency))",
            "52-week high: \(DisplayFormat.money(high, currency: currency))",
            "Latest price: \(DisplayFormat.money(current, currency: currency))",
            "Position within the range: \(Int((normalized(current) * 100).rounded()))% of the way from low to high",
        ]
        if let periodStart {
            lines.append("Price 52 weeks ago: \(DisplayFormat.money(periodStart, currency: currency))")
        }
        if let changePercent {
            lines.append("Change over 52 weeks: \(DisplayFormat.percent(changePercent))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Keep ordinary prices at opposite ends of the scale. Large text or long
/// amounts get their own rows rather than losing the low/high distinction.
struct FiftyTwoWeekRangeLabels: View {
    @Environment(\.locale) private var appLocale
    let low: Double
    let high: Double
    let currency: String

    private var lowLabel: String { L10n.text("Lowest \(DisplayFormat.money(low, currency: currency))") }
    private var highLabel: String { L10n.text("\(DisplayFormat.money(high, currency: currency)) Highest") }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(lowLabel).fixedSize()
                Spacer(minLength: 0)
                Text(highLabel).fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(lowLabel)
                Text(highLabel)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appNumber(.callout)
        .accessibilityIdentifier("fifty-two-week-range-labels")
    }
}
