import SwiftUI

struct FastReturnsPlot: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    let data: ReturnsDisplayData
    let transitionKey: String
    let rangeTransitionKey: String
    let selectedDate: Date?
    let measuredRange: ChartDateRange?
    let mode: ReturnsChartMode
    let highlightedSeries: String?
    let onSelect: (Date) -> Void
    let onMeasure: (ChartDateRange) -> Void
    let onInteractionEnded: (Int) -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var seriesCache = ReturnsPlotSeriesCache()

    private let axisWidth: CGFloat = 33
    private let bottomHeight: CGFloat = 0
    private let endpointInset: CGFloat = 9

    private var grouped: [String: [ReturnsSeriesPoint]] { data.grouped }
    private var domain: ClosedRange<Double> { data.domain }

    var body: some View {
        let prepared = seriesCache.prepared(for: data, differentiateWithoutColor: differentiateWithoutColor,
                                            highlighted: highlightedSeries)
        StandardLineChart(
            series: prepared.series,
            interactionDates: prepared.interactionDates,
            domain: domain,
            yTicks: prepared.yTicks,
            axisWidth: axisWidth,
            topInset: 0,
            bottomHeight: bottomHeight,
            // Keep the range's actual baseline visible and reachable by touch.
            leadingLineOverflow: 0,
            trailingEndpointInset: endpointInset,
            gridOpacity: 0,
            transitionKey: transitionKey,
            rangeTransitionKey: rangeTransitionKey,
            appearanceID: "returns-comparison",
            dataTransition: .viewportZoom,
            animatesInitialAppearance: true,
            selectedDate: selectedDate,
            measuredRange: measuredRange,
            // The day being read, as on the home chart. A measured range
            // names its dates in the summary card instead.
            selectionIndicatorLabel: measuredRange == nil
                ? selectedDate?.formatted(.dateTime.year().month(.abbreviated).day().locale(appLocale))
                : nil,
            rangeSeriesIDs: [ReturnsSeriesStyle.portfolio],
            rangePrimarySeriesID: ReturnsSeriesStyle.portfolio,
            yAxisFont: .system(size: 14, weight: .regular, design: .rounded).italic(),
            yAxisColor: .primary.opacity(0.20),
            yAxisLabel: { _ in "" },
            xAxisLabel: shortDate,
            onSelect: onSelect,
            onMeasure: onMeasure,
            onInteractionEnded: onInteractionEnded
        )
        .overlay {
            // Each line ends in its ring; the labels stand apart in the axis
            // column, shifted vertically to keep neighbouring tickers apart.
            GeometryReader { geometry in
                let span = max(domain.upperBound - domain.lowerBound, 0.000001)
                let zeroY = CGFloat(domain.upperBound / span) * geometry.size.height
                Color.clear.preference(key: ComparisonZeroPositionKey.self,
                    value: geometry.frame(in: .named("comparison-page")).minY + zeroY)
                let zeroIndex = prepared.yTicks.indices.min {
                    abs(prepared.yTicks[$0]) < abs(prepared.yTicks[$1])
                }
                ForEach(prepared.yTicks.indices, id: \.self) { index in
                    let value = domain.contains(0) && index == zeroIndex ? 0 : prepared.yTicks[index]
                    FinancialText(axisLabel(value))
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(Color.white.opacity(0.3))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 50, alignment: .leading)
                        .position(x: 45, y: min(geometry.size.height - 8, max(8,
                            CGFloat((domain.upperBound - value) / span) * geometry.size.height)))
                }
                ForEach(endpointLayouts(height: geometry.size.height)) { endpoint in
                    // Set back behind a highlighted line, a label darkens
                    // but stays solid: see-through, the lines behind it
                    // showed through the capsule.
                    let isDimmed = highlightedSeries != nil && highlightedSeries != endpoint.id
                    let badgeColor = isDimmed
                        ? endpoint.color.mix(with: colorScheme == .dark ? .black : .white, by: 0.68)
                        : endpoint.color
                    ReturnsChartBadge(text: endpoint.text, color: badgeColor,
                                      width: axisWidth, height: 18, fontSize: 10)
                        .zIndex(highlightedSeries == endpoint.id ? 1 : 0)
                        .position(
                            x: geometry.size.width - axisWidth / 2,
                            y: endpoint.y
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func endpointLayouts(height: CGFloat) -> [ReturnsEndpointLabelLayout] {
        let span = max(domain.upperBound - domain.lowerBound, 0.000_001)
        let halfHeight: CGFloat = 9
        let minimumSpacing: CGFloat = 19
        var result = ReturnsSeriesStyle.displayOrder.compactMap { series -> ReturnsEndpointLabelLayout? in
            guard let point = grouped[series]?.last else { return nil }
            let normalized = (domain.upperBound - point.value) / span
            let rawY = CGFloat(normalized) * height
            return ReturnsEndpointLabelLayout(
                id: series,
                text: ReturnsSeriesStyle.title(for: series),
                color: ReturnsSeriesStyle.color(for: series),
                y: min(max(rawY, halfHeight), max(halfHeight, height - halfHeight))
            )
        }
        .sorted { $0.y < $1.y }

        guard !result.isEmpty else { return [] }
        for index in result.indices.dropFirst() {
            result[index].y = max(result[index].y, result[index - 1].y + minimumSpacing)
        }

        let overflow = max(0, (result.last?.y ?? 0) - (height - halfHeight))
        if overflow > 0 {
            for index in result.indices {
                result[index].y -= overflow
            }
            if result.count > 1 {
                for index in stride(from: result.count - 2, through: 0, by: -1) {
                    result[index].y = min(result[index].y, result[index + 1].y - minimumSpacing)
                }
            }
        }

        let underflow = max(0, halfHeight - (result.first?.y ?? halfHeight))
        if underflow > 0 {
            for index in result.indices {
                result[index].y += underflow
            }
        }
        return result
    }

    private func axisLabel(_ value: Double) -> String {
        if mode == .cashFlowMatched {
            let converted = DisplayCurrency.current.fromUSD(value)
            return (converted / cashFlowAxisDivisor).formatted(
                .number
                    .grouping(.never)
                    .precision(.fractionLength(0))
            )
        }
        return ReturnsAxisLabels.percent(value, step: (domain.upperBound - domain.lowerBound) / 5, locale: appLocale)
    }

    private var cashFlowAxisDivisor: Double {
        let displayCurrency = DisplayCurrency.current
        let maximumMagnitude = max(
            abs(displayCurrency.fromUSD(domain.lowerBound)),
            abs(displayCurrency.fromUSD(domain.upperBound))
        )

        switch maximumMagnitude {
        case 1_000_000_000...: return 1_000_000_000
        case 1_000_000...: return 1_000_000
        case 1_000...: return 1_000
        default: return 1
        }
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A selection changes only the crosshair and readouts. Keep line geometry
/// until the prepared mode/range/visible series or accessibility style changes.
@MainActor
final class ReturnsPlotSeriesCache {
    struct Prepared {
        let series: [StandardLineChartSeries]
        let interactionDates: [Date]
        let yTicks: [Double]
    }

    /// How far the other lines fade while one is highlighted.
    static let fadedOpacity = 0.18

    private var cachedDataID: UUID?
    private var cachedDifferentiatesWithoutColor = false
    private var cachedHighlight: String?
    private var cachedValue: Prepared?

    func prepared(for data: ReturnsDisplayData, differentiateWithoutColor: Bool, highlighted: String?) -> Prepared {
        if cachedDataID == data.id,
           cachedDifferentiatesWithoutColor == differentiateWithoutColor,
           cachedHighlight == highlighted,
           let cachedValue { return cachedValue }

        let order = ReturnsSeriesStyle.order
        // The highlighted line is drawn last, so nothing crosses over it.
        let drawOrder = order.filter { $0 != highlighted } + order.filter { $0 == highlighted }
        let series = drawOrder.compactMap { name -> StandardLineChartSeries? in
            guard let values = data.grouped[name], !values.isEmpty else { return nil }
            let isFaded = highlighted != nil && highlighted != name
            return StandardLineChartSeries(
                id: name,
                points: values.map {
                    StandardLineChartPoint(id: "\(name)|\($0.id)", date: $0.date, value: $0.value)
                },
                color: ReturnsSeriesStyle.color(for: name).opacity(isFaded ? Self.fadedOpacity : 1),
                lineWidth: 2,
                dash: Self.dashPattern(for: name, in: order, enabled: differentiateWithoutColor),
                selectionRadius: name == ReturnsSeriesStyle.portfolio ? 3.6 : 2.8,
                latestPointRadius: name == ReturnsSeriesStyle.portfolio ? 5 : 4,
                latestPointUsesGlass: false
            )
        }
        let ticks = (0..<6).map { index in
            let fraction = Double(index) / 5
            return data.domain.upperBound - (data.domain.upperBound - data.domain.lowerBound) * fraction
        }
        let value = Prepared(series: series, interactionDates: data.dates, yTicks: ticks)
        cachedDataID = data.id
        cachedDifferentiatesWithoutColor = differentiateWithoutColor
        cachedHighlight = highlighted
        cachedValue = value
        return value
    }

    private static func dashPattern(for series: String, in order: [String], enabled: Bool) -> [CGFloat] {
        guard enabled, series != ReturnsSeriesStyle.portfolio,
              let index = order.firstIndex(of: series) else { return [] }
        let patterns: [[CGFloat]] = [
            [8, 4], [2, 3], [10, 3, 2, 3], [5, 3],
            [12, 4], [3, 2, 1, 2], [7, 2], [1, 3],
        ]
        return patterns[(index - 1) % patterns.count]
    }
}

struct ReturnsEndpointLabelLayout: Identifiable {
    let id: String
    let text: String
    let color: Color
    var y: CGFloat
}
