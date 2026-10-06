import SwiftUI
import UIKit
import Observation

typealias HoldingDetailTypography = LegacyType


// MARK: - Card explanations


#if DEBUG
@MainActor enum SecurityCardInsightDemo { static var fired = false }
#endif


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

        let rawPeriod = sessions > 0 ? L10n.text("过去\(sessions)个交易日") : L10n.text("所选历史区间")
        let isEnglish = AppLanguage.currentIdentifier == "en"
        let period = isEnglish ? rawPeriod.prefix(1).lowercased() + String(rawPeriod.dropFirst()) : rawPeriod
        let sentenceSpace = isEnglish ? " " : ""
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
            priceText += isNearPointOfControl
                ? sentenceSpace + L10n.text("，且接近成交峰值。")
                : (isEnglish ? "." : "。")
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
            text: "\(priceText)\(sentenceSpace)\(costText)",
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

/// Shared VP/OI section chrome; each plot keeps its own financial semantics.
struct PriceDistributionSection<Plot: View, Footer: View>: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let subtitle: String
    var insightFacts: (() -> String?)? = nil
    @ViewBuilder let plot: () -> Plot
    @ViewBuilder let footer: () -> Footer
    var body: some View {
        HoldingDetailSectionCard(title: title, subtitle: subtitle, insightFacts: insightFacts) {
            VStack(alignment: .leading, spacing: 16) {
                plot()
                footer().font(LegacyType.medium(15, relativeTo: .subheadline))
                    .foregroundStyle(.secondary)
            }
        }
        .transaction { $0.animation = nil }
    }
}

struct VolumePriceChart: View {
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
        let previewMode = LaunchArguments.all
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

    /// Public figures only: the holding's cost stays out of it.
    private var insightFacts: String {
        var lines = [
            "Window: \(profile.sessions) trading sessions, as of \(profile.asOf)",
            "Point of control (price with the most volume): \(DisplayFormat.money(profile.pointOfControl, currency: profile.currency))",
            "Value area (about 70% of volume): \(DisplayFormat.money(displayedValueArea.low, currency: profile.currency)) – \(DisplayFormat.money(displayedValueArea.high, currency: profile.currency))",
        ]
        if let currentPrice {
            lines.append("Latest price: \(DisplayFormat.money(currentPrice, currency: profile.currency))")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        PriceDistributionSection(title: L10n.text("Volume Profile"), subtitle: L10n.text("\(profile.sessions) 个交易日"),
                                 insightFacts: { insightFacts }) {
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

/// Only labels move. Each marker's anchor remains the original price y so
/// a displaced label can be joined back to the correct value with a leader.
enum VolumeProfileMarkerLayout {
    struct Marker {
        let id: String
        let centerX: CGFloat
        let width: CGFloat
        let anchorY: CGFloat
    }

    static func frames(for markers: [Marker], height: CGFloat,
                       pillHeight: CGFloat = 24, gap: CGFloat = 6) -> [String: CGRect] {
        let half = pillHeight / 2
        let lower = half
        let upper = max(lower, height - half)
        func clamped(_ y: CGFloat) -> CGFloat { min(upper, max(lower, y)) }
        var result: [String: CGRect] = [:]
        for marker in markers {
            func frame(_ y: CGFloat) -> CGRect {
                CGRect(x: marker.centerX - marker.width / 2, y: y - half,
                       width: marker.width, height: pillHeight)
            }
            let occupied = Array(result.values)
            let candidates = [clamped(marker.anchorY), lower, upper] + occupied.flatMap {
                [clamped($0.minY - gap - half), clamped($0.maxY + gap + half)]
            }
            let available = candidates.filter { y in
                !occupied.contains { frame(y).intersects($0.insetBy(dx: -gap / 2, dy: -gap / 2)) }
            }
            let y = available.min {
                let left = abs($0 - marker.anchorY), right = abs($1 - marker.anchorY)
                return left == right ? $0 < $1 : left < right
            } ?? clamped(marker.anchorY)
            result[marker.id] = frame(y)
        }
        return result
    }

    /// Pick a clear vertical lane between the other pills, including the
    /// original price row. The dot must not disappear underneath another label.
    static func leaderX(for frame: CGRect, anchorY: CGFloat, width: CGFloat,
                        excluding otherFrames: [CGRect]) -> CGFloat {
        var lanes: [ClosedRange<CGFloat>] = [1...max(1, width - 1)]
        let top = min(anchorY, frame.midY), bottom = max(anchorY, frame.midY)
        for other in otherFrames where other.maxY >= top && other.minY <= bottom {
            let cut = (other.minX - 3)...(other.maxX + 3)
            lanes = lanes.flatMap { lane -> [ClosedRange<CGFloat>] in
                guard cut.upperBound > lane.lowerBound, cut.lowerBound < lane.upperBound else { return [lane] }
                var remaining: [ClosedRange<CGFloat>] = []
                if cut.lowerBound > lane.lowerBound { remaining.append(lane.lowerBound...cut.lowerBound) }
                if cut.upperBound < lane.upperBound { remaining.append(cut.upperBound...lane.upperBound) }
                return remaining
            }
        }
        return lanes.map { min($0.upperBound, max($0.lowerBound, frame.midX)) }
            .min { abs($0 - frame.midX) < abs($1 - frame.midX) } ?? min(width - 1, max(1, frame.midX))
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
        if LaunchArguments.contains("--volume-narrow-bin-preview"),
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
            let markerFrames = VolumeProfileMarkerLayout.frames(for: [
                hasValidPeak ? VolumeProfileMarkerLayout.Marker(id: "peak", centerX: peakMarkerX, width: peakMarkerWidth, anchorY: peakY) : nil,
                costY.map { .init(id: "cost", centerX: rightMarkerX, width: markerWidth, anchorY: $0) },
                currentY.map { .init(id: "current", centerX: currentMarkerX, width: markerWidth, anchorY: $0) },
            ].compactMap { $0 }, height: size.height)
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
                // The cost: a plain 1pt rule under the profile, read through
                // it rather than laid over it as the glass rules are.
                if let costY {
                    Rectangle()
                        .fill(volumeCostGreen)
                        .frame(width: max(0, costRuleEndX - edgeLabelLeading), height: 1)
                        .position(x: (edgeLabelLeading + costRuleEndX) / 2, y: costY)
                        .allowsHitTesting(false)
                }

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

                if let currentY, let frame = markerFrames["current"] {
                    markerLeader(id: "current", frame: frame, anchorY: currentY, width: size.width,
                                 frames: markerFrames, color: currentPriceText.opacity(0.65))
                        .zIndex(1)
                }
                if let costY, let frame = markerFrames["cost"] {
                    markerLeader(id: "cost", frame: frame, anchorY: costY, width: size.width,
                                 frames: markerFrames, color: volumeCostText)
                        .zIndex(1)
                }
                if hasValidPeak, let frame = markerFrames["peak"] {
                    markerLeader(id: "peak", frame: frame, anchorY: peakY, width: size.width,
                                 frames: markerFrames, color: volumeSelectionBlue)
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
                    .position(x: currentMarkerX, y: markerFrames["current"]?.midY ?? currentY)
                    .zIndex(2)
                }

                if hasValidPeak {
                    peakMarkerPill(
                        title: L10n.text("峰值"),
                        price: profile.pointOfControl,
                        width: peakMarkerWidth
                    )
                    .background(labelFrameReader("peak"))
                    .position(x: peakMarkerX, y: markerFrames["peak"]?.midY ?? peakY)
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
                    .position(x: rightMarkerX, y: markerFrames["cost"]?.midY ?? costY)
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

    @ViewBuilder
    private func markerLeader(id: String, frame: CGRect, anchorY: CGFloat, width: CGFloat,
                              frames: [String: CGRect], color: Color) -> some View {
        if abs(frame.midY - anchorY) > 0.5 {
            let others = frames.filter { $0.key != id }.map(\.value)
            let x = VolumeProfileMarkerLayout.leaderX(for: frame, anchorY: anchorY,
                                                     width: width, excluding: others)
            let meetsVerticalEdge = x < frame.minX || x > frame.maxX
            let target = meetsVerticalEdge
                ? CGPoint(x: min(frame.maxX, max(frame.minX, x)), y: frame.midY)
                : CGPoint(x: x, y: anchorY > frame.midY ? frame.maxY : frame.minY)
            Path { path in
                path.move(to: CGPoint(x: x, y: anchorY))
                path.addLine(to: CGPoint(x: x, y: target.y))
                path.addLine(to: target)
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
            Circle().fill(color).frame(width: 3, height: 3)
                .position(x: x, y: anchorY)
                .allowsHitTesting(false)
        }
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
        return parts.joined(separator: L10n.listSeparator)
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

struct SecurityPaperSourceReader: UIViewRepresentable {
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
