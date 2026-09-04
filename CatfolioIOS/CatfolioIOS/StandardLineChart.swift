import SwiftUI
import UIKit

struct StandardLineChartPoint: Identifiable {
    let id: String
    let date: Date
    let value: Double

    init(id: String? = nil, date: Date, value: Double) {
        self.id = id ?? "\(date.timeIntervalSinceReferenceDate)|\(value)"
        self.date = date
        self.value = value
    }
}

struct StandardLineChartSeries: Identifiable {
    let id: String
    let points: [StandardLineChartPoint]
    let color: Color
    let lineWidth: CGFloat
    let dash: [CGFloat]
    let areaFill: Color?
    let areaBaseline: Double?
    let areaStripeColor: Color?
    let areaStripeSpacing: CGFloat
    let selectionRadius: CGFloat
    let latestPointRadius: CGFloat?
    let latestPointColor: Color?
    let latestPointUsesGlass: Bool
    let isLoadingPlaceholder: Bool

    init(
        id: String,
        points: [StandardLineChartPoint],
        color: Color,
        lineWidth: CGFloat = 2.25,
        dash: [CGFloat] = [],
        areaFill: Color? = nil,
        areaBaseline: Double? = nil,
        areaStripeColor: Color? = nil,
        areaStripeSpacing: CGFloat = 12,
        selectionRadius: CGFloat = 3.5,
        latestPointRadius: CGFloat? = 5.5,
        latestPointColor: Color? = nil,
        latestPointUsesGlass: Bool = true,
        isLoadingPlaceholder: Bool = false
    ) {
        self.id = id
        self.points = points.sorted { $0.date < $1.date }
        self.color = color
        self.lineWidth = lineWidth
        self.dash = dash
        self.areaFill = areaFill
        self.areaBaseline = areaBaseline
        self.areaStripeColor = areaStripeColor
        self.areaStripeSpacing = areaStripeSpacing
        self.selectionRadius = selectionRadius
        self.latestPointRadius = latestPointRadius
        self.latestPointColor = latestPointColor
        self.latestPointUsesGlass = latestPointUsesGlass
        self.isLoadingPlaceholder = isLoadingPlaceholder
    }
}

private enum StandardLineChartLoadingTemplate {
    static let xFractions: [CGFloat] = [-0.08, 0.08, 0.20, 0.31, 0.58, 1]

    static func yFractions(seriesIndex: Int, seriesCount: Int) -> [CGFloat] {
        let visibleCount = max(1, min(seriesCount, 8))
        let visibleIndex = seriesIndex % visibleCount
        let offset = CGFloat(visibleIndex) * 0.055
        let endsLow = visibleIndex == visibleCount - 1 && visibleCount > 2
        return [
            0.72 + offset,
            0.60 + offset * 0.5,
            0.22 + offset,
            0.27 + offset,
            0.50 + offset * 0.75,
            endsLow ? 0.91 : 0.50 + offset * 0.75,
        ]
    }

    static func color(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.09) : Color(white: 0.957)
    }

    static let adaptiveColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.09)
            : UIColor(white: 0.957, alpha: 1)
    })
}

struct StandardLineChartMarker: Identifiable {
    enum Style {
        case solid
        case ring
    }

    let id: String
    let point: StandardLineChartPoint
    let color: Color
    let radius: CGFloat
    let outlineColor: Color?
    let outlineWidth: CGFloat
    let style: Style

    init(
        id: String,
        point: StandardLineChartPoint,
        color: Color,
        radius: CGFloat = 4.5,
        outlineColor: Color? = Color(uiColor: .systemBackground),
        outlineWidth: CGFloat = 1.5,
        style: Style = .solid
    ) {
        self.id = id
        self.point = point
        self.color = color
        self.radius = radius
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
        self.style = style
    }
}

/// A value that remains visually anchored to the chart while every consumer
/// continues to share the same plot geometry, interaction and dimming rules.
/// The line is rendered as material instead of being faked by a dashed series.
struct StandardLineChartReferenceLine: Identifiable {
    let id: String
    let value: Double
    let color: Color
    let label: String
    let lineWidth: CGFloat
    let minimumAxisLabelSpacing: CGFloat

    init(
        id: String,
        value: Double,
        color: Color,
        label: String,
        lineWidth: CGFloat = 2,
        minimumAxisLabelSpacing: CGFloat = 18
    ) {
        self.id = id
        self.value = value
        self.color = color
        self.label = label
        self.lineWidth = lineWidth
        self.minimumAxisLabelSpacing = minimumAxisLabelSpacing
    }
}

enum StandardLineChartAxisSide: Equatable {
    case leading
    case trailing
}

private struct StandardLineChartRevision: Equatable {
    let transitionKey: String
    let contentFingerprint: String
}

private struct StandardLineChartTransitionDriver<Content: View>: View, Animatable {
    var progress: CGFloat
    let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    init(
        progress: CGFloat,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) {
        self.progress = progress
        self.content = content
    }

    var body: some View {
        content(progress)
    }
}

private final class StandardLineChartHapticDriver {
    private let generator = UISelectionFeedbackGenerator()

    func prepare() {
        generator.prepare()
    }

    func selectionChanged() {
        generator.selectionChanged()
        generator.prepare()
    }
}

/// Shared Canvas renderer for every time-series line chart in Catfolio.
///
/// It owns the common grid, axes, edge-to-edge range transition, one/two-finger
/// inspection, haptic-friendly selection callbacks, range measurement, area
/// fills and event markers. Feature-specific views only prepare data and labels.
struct StandardLineChart: View {
    let series: [StandardLineChartSeries]
    let interactionDates: [Date]
    let domain: ClosedRange<Double>
    let yTicks: [Double]
    let yAxisSide: StandardLineChartAxisSide
    let axisWidth: CGFloat
    let topInset: CGFloat
    let bottomHeight: CGFloat
    let plotTrailingInset: CGFloat
    let interactionBottomInset: CGFloat
    let leadingLineOverflow: CGFloat
    let trailingEndpointInset: CGFloat
    let gridDash: [CGFloat]
    let gridOpacity: Double
    let transitionKey: String
    let markers: [StandardLineChartMarker]
    let referenceLines: [StandardLineChartReferenceLine]
    let selectedDate: Date?
    let measuredRange: ChartDateRange?
    let selectionIndicatorLabel: String?
    let selectionSeriesIDs: Set<String>
    let rangeSeriesIDs: Set<String>
    let rangePrimarySeriesID: String?
    let dimsFutureDuringSelection: Bool
    let yAxisFont: Font
    let yAxisTracking: CGFloat
    let yAxisColor: Color
    let referenceAxisFont: Font
    let referenceAxisTracking: CGFloat
    let yAxisLabel: (Double) -> String
    let xAxisLabel: (Date) -> String
    let onSelect: ((Date) -> Void)?
    let onMeasure: ((ChartDateRange) -> Void)?
    let onInteractionEnded: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedSeries: [StandardLineChartSeries]
    @State private var outgoingSeries: [StandardLineChartSeries] = []
    @State private var presentedMarkers: [StandardLineChartMarker]
    @State private var outgoingMarkers: [StandardLineChartMarker] = []
    @State private var presentedDates: [Date]
    @State private var outgoingDates: [Date] = []
    @State private var presentedDomain: ClosedRange<Double>
    @State private var outgoingDomain: ClosedRange<Double>
    @State private var transitionProgress: CGFloat = 1
    @State private var transitionGeneration = 0
    @State private var needsInitialTransition: Bool
    @State private var lastHapticDates: [Date] = []
    @State private var lastSelectionHapticTime: TimeInterval = 0
    @State private var selectionHapticDriver = StandardLineChartHapticDriver()

    init(
        series: [StandardLineChartSeries],
        interactionDates: [Date],
        domain: ClosedRange<Double>,
        yTicks: [Double],
        yAxisSide: StandardLineChartAxisSide = .trailing,
        axisWidth: CGFloat = 52,
        topInset: CGFloat = 8,
        bottomHeight: CGFloat = 24,
        plotTrailingInset: CGFloat = 0,
        interactionBottomInset: CGFloat = 0,
        leadingLineOverflow: CGFloat = 16,
        trailingEndpointInset: CGFloat = 9,
        gridDash: [CGFloat] = [],
        gridOpacity: Double = 0.12,
        transitionKey: String,
        markers: [StandardLineChartMarker] = [],
        referenceLines: [StandardLineChartReferenceLine] = [],
        selectedDate: Date? = nil,
        measuredRange: ChartDateRange? = nil,
        selectionIndicatorLabel: String? = nil,
        selectionSeriesIDs: Set<String> = [],
        rangeSeriesIDs: Set<String> = [],
        rangePrimarySeriesID: String? = nil,
        dimsFutureDuringSelection: Bool = false,
        yAxisFont: Font = .caption2.weight(.medium).monospacedDigit(),
        yAxisTracking: CGFloat = 0,
        yAxisColor: Color = .secondary,
        referenceAxisFont: Font = .caption2.weight(.semibold).monospacedDigit(),
        referenceAxisTracking: CGFloat = 0,
        yAxisLabel: @escaping (Double) -> String,
        xAxisLabel: @escaping (Date) -> String,
        onSelect: ((Date) -> Void)? = nil,
        onMeasure: ((ChartDateRange) -> Void)? = nil,
        onInteractionEnded: @escaping (Int) -> Void = { _ in }
    ) {
        self.series = series
        self.interactionDates = interactionDates.sorted()
        self.domain = domain
        self.yTicks = yTicks
        self.yAxisSide = yAxisSide
        self.axisWidth = axisWidth
        self.topInset = topInset
        self.bottomHeight = bottomHeight
        self.plotTrailingInset = plotTrailingInset
        self.interactionBottomInset = interactionBottomInset
        self.leadingLineOverflow = leadingLineOverflow
        self.trailingEndpointInset = trailingEndpointInset
        self.gridDash = gridDash
        self.gridOpacity = gridOpacity
        self.transitionKey = transitionKey
        self.markers = markers
        self.referenceLines = referenceLines
        self.selectedDate = selectedDate
        self.measuredRange = measuredRange
        self.selectionIndicatorLabel = selectionIndicatorLabel
        self.selectionSeriesIDs = selectionSeriesIDs
        self.rangeSeriesIDs = rangeSeriesIDs
        self.rangePrimarySeriesID = rangePrimarySeriesID
        self.dimsFutureDuringSelection = dimsFutureDuringSelection
        self.yAxisFont = yAxisFont
        self.yAxisTracking = yAxisTracking
        self.yAxisColor = yAxisColor
        self.referenceAxisFont = referenceAxisFont
        self.referenceAxisTracking = referenceAxisTracking
        self.yAxisLabel = yAxisLabel
        self.xAxisLabel = xAxisLabel
        self.onSelect = onSelect
        self.onMeasure = onMeasure
        self.onInteractionEnded = onInteractionEnded
        let sortedDates = interactionDates.sorted()
        let loadingSeries = Self.loadingSeries(
            matching: series,
            dates: sortedDates,
            domain: domain
        )
        let startsFromLoading = !loadingSeries.isEmpty
        _presentedSeries = State(initialValue: startsFromLoading ? loadingSeries : series)
        _presentedMarkers = State(initialValue: startsFromLoading ? [] : markers)
        _presentedDates = State(initialValue: sortedDates)
        _presentedDomain = State(initialValue: domain)
        _outgoingDomain = State(initialValue: domain)
        _needsInitialTransition = State(initialValue: startsFromLoading)
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = plotRect(in: geometry.size)
            let lineLayerBleed = yAxisSide == .trailing ? leadingLineOverflow : 0
            let selectedRangeX = measuredRange.map {
                interactionX(for: $0.start, in: plot)...interactionX(for: $0.end, in: plot)
            }
            let selectedX = selectedDate.map { interactionX(for: $0, in: plot) }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawGrid(context: &context, plot: plot)
                }
                .allowsHitTesting(false)

                ZStack(alignment: .topLeading) {
                    StandardLineChartTransitionDriver(progress: transitionProgress) { progress in
                        Canvas { context, _ in
                            var lineContext = context
                            lineContext.translateBy(x: lineLayerBleed, y: 0)
                            lineContext.clip(to: Path(CGRect(
                                x: plot.minX - lineLayerBleed,
                                y: plot.minY,
                                width: plot.width + lineLayerBleed,
                                height: plot.height
                            )))
                            if !outgoingSeries.isEmpty, progress < 1 {
                                drawMorphedBase(
                                    progress: progress,
                                    context: &lineContext,
                                    plot: plot
                                )
                            } else {
                                drawBase(
                                    series: presentedSeries,
                                    markers: presentedMarkers,
                                    dates: presentedDates,
                                    valueDomain: presentedDomain,
                                    xOffset: 0,
                                    opacity: 1,
                                    context: &lineContext,
                                    plot: plot
                                )
                            }
                        }
                    }
                    .frame(width: geometry.size.width + lineLayerBleed)
                    .offset(x: -lineLayerBleed)

                    StandardLineChartTransitionDriver(progress: transitionProgress) { progress in
                        endpointLayer(plot: plot, progress: progress)
                    }

                    referenceLineLayer(plot: plot)
                }
                // Plain endpoints punch their centre through the complete
                // series layer before drawing the coloured ring. This reveals
                // the real plot background (including gradients) instead of
                // approximating it with a solid fill colour.
                .compositingGroup()
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .chartSeriesInteractionMask(
                    selectedRange: selectedRangeX,
                    selectedX: selectedX,
                    dimsAfterSingleSelection: dimsFutureDuringSelection
                )
                .allowsHitTesting(false)

                selectionOverlay(plot: plot)
                .allowsHitTesting(false)

                yAxisLabels(plot: plot)
                referenceAxisLabels(plot: plot)
                xAxisLabels(plot: plot)

                if let selectionIndicatorLabel,
                   measuredRange != nil || selectedDate != nil {
                    selectionIndicator(selectionIndicatorLabel, plot: plot)
                        .allowsHitTesting(false)
                }

                if onSelect != nil || onMeasure != nil {
                    ChartInteractionOverlay(
                        onValueChanged: { value in
                            // The UIKit bridge is deliberately constrained to
                            // the plot area below. Translate its local touch
                            // coordinates back into chart coordinates before
                            // resolving the selected date.
                            let locations = value.horizontalSelectionLocations.map { location in
                                CGPoint(
                                    x: location.x + plot.minX,
                                    y: location.y + plot.minY
                                )
                            }
                            updateSelection(from: locations, plot: plot)
                        },
                        onInteractionEnded: { touchCount in
                            lastHapticDates = []
                            lastSelectionHapticTime = 0
                            onInteractionEnded(touchCount)
                        }
                    )
                    .frame(
                        width: plot.width,
                        height: max(1, plot.height - interactionBottomInset)
                    )
                    .offset(x: plot.minX, y: plot.minY)
                    .clipped()
                }
            }
        }
        .onChange(of: revision) { previous, latest in
            if previous.contentFingerprint != latest.contentFingerprint
                || previous.transitionKey != latest.transitionKey {
                transitionToLatestData()
            }
        }
        .onAppear {
            startInitialTransitionIfNeeded()
        }
    }

    private var revision: StandardLineChartRevision {
        let seriesParts = series.map { item in
            let first = item.points.first
            let last = item.points.last
            let sampleStep = max(1, item.points.count / 8)
            let samples = item.points.indices.compactMap { index -> String? in
                guard index.isMultiple(of: sampleStep) || index == item.points.index(before: item.points.endIndex) else {
                    return nil
                }
                let point = item.points[index]
                return "\(point.id):\(point.value)"
            }
            return "\(item.id):\(item.points.count):\(first?.id ?? "-"):\(last?.id ?? "-"):\(samples.joined(separator: ","))"
        }
        let markerParts = markers.map { "\($0.id):\($0.point.id):\($0.point.value)" }
        let scalePart = "\(interactionDates.count):\(interactionDates.first?.timeIntervalSinceReferenceDate ?? 0):\(interactionDates.last?.timeIntervalSinceReferenceDate ?? 0):\(domain.lowerBound):\(domain.upperBound)"
        return StandardLineChartRevision(
            transitionKey: transitionKey,
            contentFingerprint: ([scalePart] + seriesParts + markerParts).joined(separator: "|")
        )
    }

    private func plotRect(in size: CGSize) -> CGRect {
        let leadingInset = yAxisSide == .leading ? axisWidth : 0
        let trailingAxisInset = yAxisSide == .trailing ? axisWidth : 0
        return CGRect(
            x: leadingInset,
            y: topInset,
            width: max(1, size.width - leadingInset - trailingAxisInset - plotTrailingInset),
            height: max(1, size.height - bottomHeight - topInset)
        )
    }

    private func transitionToLatestData() {
        needsInitialTransition = false
        guard !reduceMotion else {
            syncLatestData()
            return
        }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        outgoingSeries = presentedSeries
        outgoingMarkers = presentedMarkers
        outgoingDates = presentedDates
        outgoingDomain = presentedDomain
        presentedSeries = series
        presentedMarkers = markers
        presentedDates = interactionDates
        presentedDomain = domain

        var resetTransaction = Transaction(animation: nil)
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            transitionProgress = 0
        }

        Task { @MainActor in
            await Task.yield()
            guard generation == transitionGeneration else { return }
            withAnimation(.smooth(duration: 0.42)) {
                transitionProgress = 1
            }
        }
    }

    private func startInitialTransitionIfNeeded() {
        guard needsInitialTransition else { return }
        transitionToLatestData()
    }

    private func syncLatestData() {
        needsInitialTransition = false
        transitionGeneration &+= 1
        presentedSeries = series
        presentedMarkers = markers
        presentedDates = interactionDates
        presentedDomain = domain
        outgoingSeries = []
        outgoingMarkers = []
        outgoingDates = []
        transitionProgress = 1
    }

    /// Builds the same quiet loading curve for every line-chart consumer.
    /// Keeping the placeholder in the renderer gives us a genuine path morph
    /// instead of replacing one unrelated view with another when data arrives.
    private static func loadingSeries(
        matching targetSeries: [StandardLineChartSeries],
        dates: [Date],
        domain: ClosedRange<Double>
    ) -> [StandardLineChartSeries] {
        guard dates.count > 1,
              let startDate = dates.first,
              let endDate = dates.last,
              endDate > startDate,
              domain.upperBound > domain.lowerBound,
              !targetSeries.isEmpty else { return [] }

        let dateSpan = endDate.timeIntervalSince(startDate)
        let valueSpan = domain.upperBound - domain.lowerBound
        return targetSeries.enumerated().map { index, target in
            let yFractions = StandardLineChartLoadingTemplate.yFractions(
                seriesIndex: index,
                seriesCount: targetSeries.count
            )
            let points = zip(StandardLineChartLoadingTemplate.xFractions, yFractions)
                .enumerated()
                .map { pointIndex, fractions in
                    StandardLineChartPoint(
                        id: "loading|\(target.id)|\(pointIndex)",
                        date: startDate.addingTimeInterval(dateSpan * Double(fractions.0)),
                        value: domain.upperBound - valueSpan * Double(fractions.1)
                    )
                }
            return StandardLineChartSeries(
                id: target.id,
                points: points,
                color: StandardLineChartLoadingTemplate.adaptiveColor,
                lineWidth: 1.2,
                dash: [],
                selectionRadius: target.selectionRadius,
                latestPointRadius: target.latestPointRadius == nil ? nil : 3,
                latestPointColor: StandardLineChartLoadingTemplate.adaptiveColor,
                latestPointUsesGlass: false,
                isLoadingPlaceholder: true
            )
        }
    }

    private func drawGrid(context: inout GraphicsContext, plot: CGRect) {
        for value in yTicks {
            let y = y(for: value, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(
                line,
                with: .color(Color.secondary.opacity(gridOpacity)),
                style: StrokeStyle(lineWidth: 0.7, dash: gridDash)
            )
        }
    }

    private func drawBase(
        series: [StandardLineChartSeries],
        markers: [StandardLineChartMarker],
        dates: [Date],
        valueDomain: ClosedRange<Double>,
        xOffset: CGFloat,
        opacity: Double,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        var layer = context
        layer.translateBy(x: xOffset, y: 0)
        layer.opacity = opacity
        drawBaseContent(
            series: series,
            markers: markers,
            dates: dates,
            valueDomain: valueDomain,
            context: &layer,
            plot: plot
        )
    }

    private func drawBaseContent(
        series: [StandardLineChartSeries],
        markers: [StandardLineChartMarker],
        dates: [Date],
        valueDomain: ClosedRange<Double>,
        context: inout GraphicsContext,
        plot: CGRect
    ) {

        for item in series {
            guard !item.points.isEmpty else { continue }
            if let fill = item.areaFill, let baseline = item.areaBaseline {
                drawArea(
                    item,
                    fill: fill,
                    baseline: baseline,
                    dates: dates,
                    valueDomain: valueDomain,
                    context: &context,
                    plot: plot
                )
            }
            if item.points.count == 1,
               item.latestPointRadius == nil,
               let point = item.points.first {
                drawPoint(
                    at: CGPoint(x: plot.midX, y: y(for: point.value, in: plot, domain: valueDomain)),
                    color: item.color,
                    radius: item.latestPointRadius ?? max(3.5, item.selectionRadius),
                    context: &context
                )
            } else {
                drawPath(
                    item.points,
                    series: item,
                    opacity: 1,
                    dates: dates,
                    valueDomain: valueDomain,
                    context: &context,
                    plot: plot
                )
            }

        }

        for marker in markers {
            let center = CGPoint(
                x: x(for: marker.point.date, in: plot, dates: dates),
                y: y(for: marker.point.value, in: plot, domain: valueDomain)
            )
            drawMarker(marker, at: center, context: &context)
        }
    }

    private func drawMorphedBase(
        progress: CGFloat,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        let outgoingByID = Dictionary(uniqueKeysWithValues: outgoingSeries.map { ($0.id, $0) })
        let presentedIDs = Set(presentedSeries.map(\.id))

        for incoming in presentedSeries where !incoming.points.isEmpty {
            if let outgoing = outgoingByID[incoming.id], !outgoing.points.isEmpty {
                drawMorphedSeries(
                    from: outgoing,
                    to: incoming,
                    progress: progress,
                    context: &context,
                    plot: plot
                )
            } else {
                drawBase(
                    series: [incoming],
                    markers: [],
                    dates: presentedDates,
                    valueDomain: presentedDomain,
                    xOffset: 0,
                    opacity: Double(progress),
                    context: &context,
                    plot: plot
                )
            }
        }

        for outgoing in outgoingSeries where !presentedIDs.contains(outgoing.id) {
            drawBase(
                series: [outgoing],
                markers: [],
                dates: outgoingDates,
                valueDomain: outgoingDomain,
                xOffset: 0,
                opacity: 1 - Double(progress),
                context: &context,
                plot: plot
            )
        }

        drawMorphedMarkers(progress: progress, context: &context, plot: plot)
    }

    private func drawMorphedSeries(
        from outgoing: StandardLineChartSeries,
        to incoming: StandardLineChartSeries,
        progress: CGFloat,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        let pathProgresses = mergedMorphProgresses(
            outgoing.points,
            incoming.points
        )
        let pairedSamples = pathProgresses.compactMap { pathProgress -> (CGPoint, CGPoint)? in
            guard let old = normalizedSample(
                for: outgoing,
                dates: outgoingDates,
                domain: outgoingDomain,
                pathProgress: pathProgress
            ), let new = normalizedSample(
                for: incoming,
                dates: presentedDates,
                domain: presentedDomain,
                pathProgress: pathProgress
            ) else { return nil }
            return (old, new)
        }
        guard !pairedSamples.isEmpty else { return }

        let samples = pairedSamples.map { old, new in
            CGPoint(
                x: old.x + (new.x - old.x) * progress,
                y: old.y + (new.y - old.y) * progress
            )
        }
        let points = samples.map { point(in: plot, normalized: $0) }
        guard let first = points.first else { return }

        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }

        if let fill = incoming.areaFill,
           let incomingBaseline = incoming.areaBaseline {
            let outgoingBaseline = outgoing.areaBaseline ?? incomingBaseline
            let oldBaseline = normalizedValue(outgoingBaseline, domain: outgoingDomain)
            let newBaseline = normalizedValue(incomingBaseline, domain: presentedDomain)
            let baseline = oldBaseline + (newBaseline - oldBaseline) * progress
            var area = path
            area.addLine(to: CGPoint(x: points.last?.x ?? first.x, y: y(in: plot, normalized: baseline)))
            area.addLine(to: CGPoint(x: first.x, y: y(in: plot, normalized: baseline)))
            area.closeSubpath()
            var fillContext = context
            fillContext.opacity = outgoing.isLoadingPlaceholder ? Double(progress) : 1
            fillContext.fill(area, with: .color(fill))
            drawAreaStripes(
                in: area,
                color: incoming.areaStripeColor,
                spacing: incoming.areaStripeSpacing,
                context: &fillContext,
                plot: plot
            )
        }

        if outgoing.isLoadingPlaceholder {
            // Both strokes follow the same interpolated geometry. Crossfading
            // them here makes loading grey become the semantic series colour
            // while the curve itself continuously reshapes.
            stroke(
                path,
                series: outgoing,
                opacity: 1 - Double(progress),
                context: &context
            )
            stroke(
                path,
                series: incoming,
                opacity: Double(progress),
                context: &context
            )
        } else {
            stroke(path, series: incoming, opacity: 1, context: &context)
        }
    }

    /// Uses every real vertex from both paths as an interpolation stop. Extra
    /// stops remain collinear on the opposite path, so progress 0 and 1 match
    /// the original paths exactly instead of snapping on the final frame.
    private func mergedMorphProgresses(
        _ outgoing: [StandardLineChartPoint],
        _ incoming: [StandardLineChartPoint]
    ) -> [Double] {
        let combined = morphProgresses(for: outgoing)
            + morphProgresses(for: incoming)
            + [0, 1]
        let sorted = combined
            .map { min(1, max(0, $0)) }
            .sorted()

        return sorted.reduce(into: [Double]()) { result, value in
            guard result.last.map({ abs($0 - value) > 0.000_000_1 }) ?? true else { return }
            result.append(value)
        }
    }

    private func morphProgresses(
        for points: [StandardLineChartPoint]
    ) -> [Double] {
        guard let first = points.first?.date,
              let last = points.last?.date else { return [] }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return [0, 1] }
        return points.map { $0.date.timeIntervalSince(first) / span }
    }

    private func normalizedSample(
        for series: StandardLineChartSeries,
        dates: [Date],
        domain: ClosedRange<Double>,
        pathProgress: Double
    ) -> CGPoint? {
        guard let chartStart = dates.first,
              let chartEnd = dates.last,
              let seriesStart = series.points.first?.date,
              let seriesEnd = series.points.last?.date,
              !series.points.isEmpty else { return nil }

        let chartSpan = max(chartEnd.timeIntervalSince(chartStart), 1)
        let seriesSpan = max(seriesEnd.timeIntervalSince(seriesStart), 0)
        let clampedProgress = min(1, max(0, pathProgress))
        let date = seriesStart.addingTimeInterval(seriesSpan * clampedProgress)
        let value = interpolatedValue(at: date, in: series.points)
        return CGPoint(
            x: CGFloat(date.timeIntervalSince(chartStart) / chartSpan),
            y: normalizedValue(value, domain: domain)
        )
    }

    private func interpolatedValue(
        at date: Date,
        in points: [StandardLineChartPoint]
    ) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        guard date > first.date else { return first.value }
        guard date < last.date else { return last.value }

        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0, lower < points.count else { return points[min(lower, points.count - 1)].value }
        let before = points[lower - 1]
        let after = points[lower]
        let span = max(after.date.timeIntervalSince(before.date), 0.000_001)
        let progress = date.timeIntervalSince(before.date) / span
        return before.value + (after.value - before.value) * progress
    }

    private func normalizedValue(
        _ value: Double,
        domain: ClosedRange<Double>
    ) -> CGFloat {
        let span = max(domain.upperBound - domain.lowerBound, 0.000_001)
        return CGFloat((value - domain.lowerBound) / span)
    }

    private func point(in plot: CGRect, normalized: CGPoint) -> CGPoint {
        let startX = plot.minX - leadingLineOverflow
        let endX = plot.maxX - trailingEndpointInset
        return CGPoint(
            x: startX + (endX - startX) * normalized.x,
            y: y(in: plot, normalized: normalized.y)
        )
    }

    private func y(in plot: CGRect, normalized: CGFloat) -> CGFloat {
        plot.maxY - plot.height * normalized
    }

    private func drawMorphedMarkers(
        progress: CGFloat,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        // Trade markers should not slide across the graph while the time scale
        // changes. Collapse every old marker in place, then let the markers for
        // the new range grow at their final coordinates.
        let outgoingScale = markerScale(1 - progress / 0.45)
        let incomingScale = markerScale((progress - 0.55) / 0.45)

        for outgoing in outgoingMarkers {
            let position = normalizedPosition(
                for: outgoing.point,
                dates: outgoingDates,
                domain: outgoingDomain
            )
            drawMarker(
                outgoing,
                at: point(in: plot, normalized: position),
                scale: outgoingScale,
                context: &context
            )
        }

        for incoming in presentedMarkers {
            let position = normalizedPosition(
                for: incoming.point,
                dates: presentedDates,
                domain: presentedDomain
            )
            drawMarker(
                incoming,
                at: point(in: plot, normalized: position),
                scale: incomingScale,
                context: &context
            )
        }
    }

    private func markerScale(_ progress: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, progress))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func normalizedPosition(
        for point: StandardLineChartPoint,
        dates: [Date],
        domain: ClosedRange<Double>
    ) -> CGPoint {
        guard let first = dates.first, let last = dates.last else {
            return CGPoint(x: 0.5, y: normalizedValue(point.value, domain: domain))
        }
        let span = max(last.timeIntervalSince(first), 1)
        return CGPoint(
            x: CGFloat(point.date.timeIntervalSince(first) / span),
            y: normalizedValue(point.value, domain: domain)
        )
    }

    private func drawMarker(
        _ marker: StandardLineChartMarker,
        at center: CGPoint,
        scale: CGFloat = 1,
        context: inout GraphicsContext
    ) {
        guard scale > 0.001 else { return }
        let radius = marker.radius * scale
        var layer = context
        layer.opacity = Double(min(1, scale * 1.6))
        let ellipse = Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        if marker.style == .ring {
            // Punch through the complete series layer so the line cannot show
            // through the centre of a buy/sell marker. The actual chart
            // background remains visible in both appearance modes.
            var cutout = layer
            cutout.blendMode = .destinationOut
            cutout.fill(ellipse, with: .color(.black))
            layer.stroke(
                ellipse,
                with: .color(marker.color),
                lineWidth: max(1, marker.outlineWidth * scale)
            )
        } else {
            drawPoint(at: center, color: marker.color, radius: radius, context: &layer)
        }
        if marker.style == .solid,
           let outlineColor = marker.outlineColor,
           marker.outlineWidth > 0 {
            layer.stroke(
                ellipse,
                with: .color(outlineColor),
                lineWidth: marker.outlineWidth * scale
            )
        }
    }

    private func drawPath(
        _ points: [StandardLineChartPoint],
        series: StandardLineChartSeries,
        opacity: Double,
        dates: [Date],
        valueDomain: ClosedRange<Double>,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        guard points.count > 1 else { return }
        var path = Path()
        for (index, point) in points.enumerated() {
            let location = CGPoint(
                x: x(for: point.date, in: plot, dates: dates),
                y: y(for: point.value, in: plot, domain: valueDomain)
            )
            index == 0 ? path.move(to: location) : path.addLine(to: location)
        }
        stroke(path, series: series, opacity: opacity, context: &context)
    }

    private func stroke(
        _ path: Path,
        series: StandardLineChartSeries,
        opacity: Double,
        context: inout GraphicsContext
    ) {
        context.stroke(
            path,
            with: .color(series.color.opacity(opacity)),
            style: StrokeStyle(
                lineWidth: series.lineWidth,
                lineCap: .round,
                lineJoin: .round,
                dash: series.dash
            )
        )
    }

    @ViewBuilder
    private func endpointLayer(plot: CGRect, progress: CGFloat) -> some View {
        let outgoingByID = Dictionary(uniqueKeysWithValues: outgoingSeries.map { ($0.id, $0) })
        let presentedIDs = Set(presentedSeries.map(\.id))
        ZStack(alignment: .topLeading) {
            ForEach(presentedSeries) { item in
                if progress < 1, let outgoing = outgoingByID[item.id] {
                    morphedEndpoint(
                        from: outgoing,
                        to: item,
                        progress: progress,
                        plot: plot
                    )
                } else {
                    endpoint(
                        for: item,
                        dates: presentedDates,
                        valueDomain: presentedDomain,
                        plot: plot
                    )
                    .opacity(progress < 1 ? progress : 1)
                }
            }

            ForEach(outgoingSeries.filter { !presentedIDs.contains($0.id) }) { item in
                endpoint(
                    for: item,
                    dates: outgoingDates,
                    valueDomain: outgoingDomain,
                    plot: plot
                )
                .opacity(1 - progress)
            }
        }
    }

    @ViewBuilder
    private func morphedEndpoint(
        from outgoing: StandardLineChartSeries,
        to incoming: StandardLineChartSeries,
        progress: CGFloat,
        plot: CGRect
    ) -> some View {
        if let oldPoint = outgoing.points.last,
           let newPoint = incoming.points.last,
           let newRadius = incoming.latestPointRadius {
            let oldPosition = normalizedPosition(
                for: oldPoint,
                dates: outgoingDates,
                domain: outgoingDomain
            )
            let newPosition = normalizedPosition(
                for: newPoint,
                dates: presentedDates,
                domain: presentedDomain
            )
            let position = point(
                in: plot,
                normalized: CGPoint(
                    x: oldPosition.x + (newPosition.x - oldPosition.x) * progress,
                    y: oldPosition.y + (newPosition.y - oldPosition.y) * progress
                )
            )
            if outgoing.isLoadingPlaceholder {
                ZStack {
                    StandardLineChartPlainEndpoint(
                        color: outgoing.latestPointColor ?? outgoing.color,
                        radius: outgoing.latestPointRadius ?? 3
                    )
                    .opacity(1 - progress)

                    if incoming.latestPointUsesGlass {
                        StandardLineChartGlassEndpoint(
                            color: incoming.latestPointColor ?? incoming.color,
                            radius: newRadius
                        )
                        .opacity(progress)
                    } else {
                        StandardLineChartPlainEndpoint(
                            color: incoming.latestPointColor ?? incoming.color,
                            radius: newRadius
                        )
                        .opacity(progress)
                    }
                }
                .position(position)
            } else if incoming.latestPointUsesGlass {
                StandardLineChartGlassEndpoint(
                    color: incoming.latestPointColor ?? incoming.color,
                    radius: newRadius
                )
                .position(position)
            } else {
                StandardLineChartPlainEndpoint(
                    color: incoming.latestPointColor ?? incoming.color,
                    radius: newRadius
                )
                .position(position)
            }
        }
    }

    @ViewBuilder
    private func endpoint(
        for item: StandardLineChartSeries,
        dates: [Date],
        valueDomain: ClosedRange<Double>,
        plot: CGRect
    ) -> some View {
        if let point = item.points.last,
           let radius = item.latestPointRadius {
            if item.latestPointUsesGlass {
                StandardLineChartGlassEndpoint(
                    color: item.latestPointColor ?? item.color,
                    radius: radius
                )
                .position(
                    x: x(for: point.date, in: plot, dates: dates),
                    y: y(for: point.value, in: plot, domain: valueDomain)
                )
            } else {
                StandardLineChartPlainEndpoint(
                    color: item.latestPointColor ?? item.color,
                    radius: radius
                )
                .position(
                    x: x(for: point.date, in: plot, dates: dates),
                    y: y(for: point.value, in: plot, domain: valueDomain)
                )
            }
        }
    }

    private func drawArea(
        _ series: StandardLineChartSeries,
        fill: Color,
        baseline: Double,
        dates: [Date],
        valueDomain: ClosedRange<Double>,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        guard series.points.count > 1 else { return }
        var area = Path()
        for (index, point) in series.points.enumerated() {
            let location = CGPoint(
                x: x(for: point.date, in: plot, dates: dates),
                y: y(for: point.value, in: plot, domain: valueDomain)
            )
            index == 0 ? area.move(to: location) : area.addLine(to: location)
        }
        if let first = series.points.first, let last = series.points.last {
            let baselineY = y(for: baseline, in: plot, domain: valueDomain)
            area.addLine(to: CGPoint(x: x(for: last.date, in: plot, dates: dates), y: baselineY))
            area.addLine(to: CGPoint(x: x(for: first.date, in: plot, dates: dates), y: baselineY))
            area.closeSubpath()
            context.fill(area, with: .color(fill))
            drawAreaStripes(
                in: area,
                color: series.areaStripeColor,
                spacing: series.areaStripeSpacing,
                context: &context,
                plot: plot
            )
        }
    }

    private func drawAreaStripes(
        in area: Path,
        color: Color?,
        spacing: CGFloat,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        guard let color else { return }
        var stripeContext = context
        stripeContext.clip(to: area)
        var stripes = Path()
        let safeSpacing = max(6, spacing)
        var x = plot.minX - plot.height
        while x <= plot.maxX {
            stripes.move(to: CGPoint(x: x, y: plot.maxY))
            stripes.addLine(to: CGPoint(x: x + plot.height, y: plot.minY))
            x += safeSpacing
        }
        stripeContext.stroke(stripes, with: .color(color), lineWidth: 0.75)
    }

    @ViewBuilder
    private func selectionOverlay(plot: CGRect) -> some View {
        if let measuredRange {
            let allowed = rangeSeriesIDs.isEmpty ? Set(series.map(\.id)) : rangeSeriesIDs
            ForEach([measuredRange.start, measuredRange.end], id: \.self) { date in
                glassSelection(
                    at: date,
                    allowedSeriesIDs: allowed,
                    ruleTint: .white,
                    guideTop: plot.minY,
                    plot: plot
                )
            }
        } else if let selectedDate {
            let allowed = selectionSeriesIDs.isEmpty ? Set(series.map(\.id)) : selectionSeriesIDs
            let bubbleBottom = max(14, plot.minY / 2) + 14
            glassSelection(
                at: selectedDate,
                allowedSeriesIDs: allowed,
                ruleTint: .white,
                guideTop: selectionIndicatorLabel == nil ? plot.minY : max(plot.minY, bubbleBottom),
                plot: plot
            )
        }
    }

    private func glassSelection(
        at date: Date,
        allowedSeriesIDs: Set<String>,
        ruleTint: Color,
        guideTop: CGFloat,
        plot: CGRect
    ) -> some View {
        let selectedX = interactionX(for: date, in: plot)
        let guideHeight = max(0, plot.maxY - guideTop)
        return ZStack(alignment: .topLeading) {
            StandardLineChartGlassGuide(tint: ruleTint)
                .frame(width: 2, height: guideHeight)
                .position(x: selectedX, y: guideTop + guideHeight / 2)

            ForEach(series.filter { allowedSeriesIDs.contains($0.id) }) { item in
                if let point = nearestPoint(to: date, in: item.points) {
                    StandardLineChartGlassSelectionPoint(
                        color: item.color,
                        diameter: max(12, item.selectionRadius * 2)
                    )
                    .position(
                        x: selectedX,
                        y: y(for: point.value, in: plot)
                    )
                }
            }
        }
    }

    private func selectionIndicator(_ label: String, plot: CGRect) -> some View {
        let rawX: CGFloat
        if let measuredRange {
            rawX = (interactionX(for: measuredRange.start, in: plot)
                + interactionX(for: measuredRange.end, in: plot)) / 2
        } else if let selectedDate {
            rawX = interactionX(for: selectedDate, in: plot)
        } else {
            rawX = plot.midX
        }

        return StandardLineChartDateBubble(label: label)
            .fixedSize()
            .position(
                x: min(plot.maxX - 58, max(plot.minX + 58, rawX)),
                y: max(14, plot.minY / 2)
            )
    }

    private func drawPoint(
        at center: CGPoint,
        color: Color,
        radius: CGFloat,
        context: inout GraphicsContext
    ) {
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )),
            with: .color(color)
        )
    }

    @ViewBuilder
    private func yAxisLabels(plot: CGRect) -> some View {
        ForEach(Array(yTicks.enumerated()), id: \.offset) { entry in
            if shouldShowAxisTick(entry.element, plot: plot) {
                Text(yAxisLabel(entry.element))
                    .font(yAxisFont)
                    .tracking(yAxisTracking)
                    .foregroundStyle(yAxisColor)
                    .position(
                        x: yAxisSide == .leading ? axisWidth / 2 : plot.maxX + axisWidth / 2,
                        y: y(for: entry.element, in: plot)
                    )
            }
        }
    }

    private func shouldShowAxisTick(_ value: Double, plot: CGRect) -> Bool {
        referenceLines.allSatisfy { reference in
            abs(y(for: value, in: plot) - y(for: reference.value, in: plot))
                >= reference.minimumAxisLabelSpacing
        }
    }

    @ViewBuilder
    private func referenceLineLayer(plot: CGRect) -> some View {
        ForEach(referenceLines) { reference in
            StandardLineChartGlassReferenceLine(tint: reference.color)
                .frame(width: plot.width, height: reference.lineWidth)
                .position(x: plot.midX, y: y(for: reference.value, in: plot))
        }
    }

    @ViewBuilder
    private func referenceAxisLabels(plot: CGRect) -> some View {
        ForEach(referenceLines) { reference in
            Text(reference.label)
                .font(referenceAxisFont)
                .tracking(referenceAxisTracking)
                .foregroundStyle(reference.color)
                .position(
                    x: yAxisSide == .leading ? axisWidth / 2 : plot.maxX + axisWidth / 2,
                    y: y(for: reference.value, in: plot)
                )
        }
    }

    @ViewBuilder
    private func xAxisLabels(plot: CGRect) -> some View {
        if bottomHeight > 0, let first = interactionDates.first, let last = interactionDates.last {
            HStack {
                Text(xAxisLabel(first))
                Spacer()
                Text(xAxisLabel(last))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: plot.width)
            .offset(x: plot.minX, y: plot.maxY + 6)
        }
    }

    private func updateSelection(from locations: [CGPoint], plot: CGRect) {
        let dates = locations.compactMap { date(at: $0.x, plot: plot) }
        updateSelectionHaptic(for: dates)
        if dates.count >= 2, let onMeasure {
            onMeasure(ChartDateRange(dates[0], dates[1]))
        } else if let date = dates.first {
            onSelect?(date)
        }
    }

    private func updateSelectionHaptic(for dates: [Date]) {
        guard !dates.isEmpty else { return }

        if lastHapticDates.isEmpty {
            // The long-press recognizer already emits the activation impact.
            // Seed the snapped dates without doubling that first feedback.
            lastHapticDates = dates
            selectionHapticDriver.prepare()
            return
        }

        guard dates != lastHapticDates else { return }
        lastHapticDates = dates

        let defaults = UserDefaults.standard
        let hapticsEnabled = defaults.object(forKey: ChartInteractionStyle.hapticsPreferenceKey) as? Bool ?? true
        guard hapticsEnabled else { return }

        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSelectionHapticTime >= ChartInteractionStyle.selectionHapticMinimumInterval else { return }
        lastSelectionHapticTime = now

        selectionHapticDriver.selectionChanged()
    }

    private func date(at locationX: CGFloat, plot: CGRect) -> Date? {
        guard !interactionDates.isEmpty, plot.width > 0 else { return nil }
        let clampedX = min(max(locationX, plot.minX), plot.maxX)
        let startX = plot.minX - leadingLineOverflow
        let endX = plot.maxX - trailingEndpointInset
        let ratio = min(1, max(0, Double((clampedX - startX) / max(endX - startX, 1))))
        let first = interactionDates[0]
        let last = interactionDates[interactionDates.count - 1]
        let candidate = first.addingTimeInterval(last.timeIntervalSince(first) * ratio)
        return nearestDate(to: candidate)
    }

    private func nearestDate(to target: Date) -> Date? {
        guard !interactionDates.isEmpty else { return nil }
        var lower = 0
        var upper = interactionDates.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if interactionDates[middle] < target { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return interactionDates[0] }
        guard lower < interactionDates.count else { return interactionDates[interactionDates.count - 1] }
        let before = interactionDates[lower - 1]
        let after = interactionDates[lower]
        return abs(before.timeIntervalSince(target)) <= abs(after.timeIntervalSince(target)) ? before : after
    }

    private func nearestPoint(
        to target: Date,
        in points: [StandardLineChartPoint]
    ) -> StandardLineChartPoint? {
        guard !points.isEmpty else { return nil }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].date < target { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return points[0] }
        guard lower < points.count else { return points[points.count - 1] }
        let before = points[lower - 1]
        let after = points[lower]
        return abs(before.date.timeIntervalSince(target)) <= abs(after.date.timeIntervalSince(target)) ? before : after
    }

    private func x(for date: Date, in plot: CGRect) -> CGFloat {
        x(for: date, in: plot, dates: interactionDates)
    }

    private func interactionX(for date: Date, in plot: CGRect) -> CGFloat {
        min(plot.maxX, max(plot.minX, x(for: date, in: plot)))
    }

    private func x(for date: Date, in plot: CGRect, dates: [Date]) -> CGFloat {
        guard let first = dates.first, let last = dates.last else { return plot.midX }
        let span = max(last.timeIntervalSince(first), 1)
        let startX = plot.minX - leadingLineOverflow
        let endX = plot.maxX - trailingEndpointInset
        return startX + (endX - startX) * CGFloat(date.timeIntervalSince(first) / span)
    }

    private func y(for value: Double, in plot: CGRect) -> CGFloat {
        y(for: value, in: plot, domain: domain)
    }

    private func y(
        for value: Double,
        in plot: CGRect,
        domain valueDomain: ClosedRange<Double>
    ) -> CGFloat {
        let span = max(valueDomain.upperBound - valueDomain.lowerBound, 0.000_001)
        return plot.maxY - plot.height * CGFloat((value - valueDomain.lowerBound) / span)
    }
}

private struct StandardLineChartGlassGuide: View {
    let tint: Color

    @ViewBuilder
    var body: some View {
        let shape = Capsule()
        let guide = Color.clear

        if #available(iOS 26.0, *) {
            guide
                .glassEffect(.clear.tint(tint.opacity(0.34)), in: shape)
                .overlay {
                    shape
                        .fill(Color.white.opacity(0.05))
                }
        } else {
            guide
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .fill(tint.opacity(0.16))
                }
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.35)
                }
        }
    }
}

private struct StandardLineChartGlassReferenceLine: View {
    let tint: Color

    @ViewBuilder
    var body: some View {
        let shape = Capsule()
        let line = Color.clear

        if #available(iOS 26.0, *) {
            line
                .glassEffect(.clear.tint(tint.opacity(0.22)), in: shape)
                .overlay {
                    shape
                        .fill(Color.white.opacity(0.045))
                }
        } else {
            line
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .fill(tint.opacity(0.12))
                }
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.35)
                }
        }
    }
}

private struct StandardLineChartGlassSelectionPoint: View {
    let color: Color
    let diameter: CGFloat

    @ViewBuilder
    var body: some View {
        let shape = Circle()
        let point = shape
            .fill(color.opacity(0.12))
            .frame(width: diameter, height: diameter)

        if #available(iOS 26.0, *) {
            point
                .glassEffect(.clear.tint(color.opacity(0.30)), in: shape)
                .overlay {
                    shape
                        .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.5)
                        .padding(0.5)
                }
        } else {
            point
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .fill(color.opacity(0.18))
                }
                .overlay {
                    shape
                        .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.55)
                }
        }
    }
}

private struct StandardLineChartDateBubble: View {
    let label: String

    var body: some View {
        let content = Text(label)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)

        if #available(iOS 26.0, *) {
            content
                .glassEffect(.clear, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}

private struct StandardLineChartPlainEndpoint: View {
    let color: Color
    let radius: CGFloat

    var body: some View {
        let ringWidth = max(2.2, radius * 0.44)
        ZStack {
            Circle()
                .fill(Color.black)
                .blendMode(.destinationOut)

            Circle()
                .strokeBorder(color, lineWidth: ringWidth)
        }
        .frame(width: radius * 2, height: radius * 2)
        .accessibilityHidden(true)
    }
}

private struct StandardLineChartGlassEndpoint: View {
    let color: Color
    let radius: CGFloat
    var isDimmed = false

    @ViewBuilder
    var body: some View {
        let shape = Circle()
        let diameter = radius * 2
        let ringWidth = max(2.1, radius * 0.42)

        if isDimmed {
            shape
                .strokeBorder(color.opacity(0.30), lineWidth: 1.35)
                .frame(width: diameter, height: diameter)
        } else {
            ZStack {
                shape
                    .stroke(color.opacity(0.28), lineWidth: ringWidth + 2.5)
                    .blur(radius: radius * 0.55)

                shape
                    .fill(Color(uiColor: .systemBackground))

                shape
                    .strokeBorder(color, lineWidth: ringWidth)

                shape
                    .strokeBorder(Color.white.opacity(0.34), lineWidth: 0.65)
                    .padding(ringWidth * 0.34)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: color.opacity(0.22), radius: radius * 0.9)
        }
    }
}

/// Geometry-compatible loading state for every shared time-series chart. It
/// keeps the plot, trailing axis and endpoint space stable while data loads,
/// so the real chart can replace it without a vertical or horizontal jump.
struct StandardLineChartSkeleton: View {
    @Environment(\.colorScheme) private var colorScheme

    var axisWidth: CGFloat = 49
    var topInset: CGFloat = 34
    var bottomHeight: CGFloat = 0
    var leadingLineOverflow: CGFloat = 0
    var trailingEndpointInset: CGFloat = 0
    var seriesCount: Int = 1
    var showsEndpointLabels = false

    private var skeletonColor: Color {
        StandardLineChartLoadingTemplate.color(for: colorScheme)
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 0,
                y: topInset,
                width: max(1, geometry.size.width - axisWidth),
                height: max(1, geometry.size.height - topInset - bottomHeight)
            )
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let count = max(1, min(seriesCount, 8))
                    for seriesIndex in 0..<count {
                        let yFractions = StandardLineChartLoadingTemplate.yFractions(
                            seriesIndex: seriesIndex,
                            seriesCount: count
                        )
                        let fractions = Array(zip(
                            StandardLineChartLoadingTemplate.xFractions,
                            yFractions
                        ))
                        var path = Path()
                        let lineStartX = plot.minX - leadingLineOverflow
                        let lineEndX = plot.maxX - trailingEndpointInset
                        for (index, fraction) in fractions.enumerated() {
                            let point = CGPoint(
                                x: lineStartX + (lineEndX - lineStartX) * fraction.0,
                                y: min(
                                    plot.maxY,
                                    max(plot.minY, plot.minY + plot.height * fraction.1)
                                )
                            )
                            index == 0 ? path.move(to: point) : path.addLine(to: point)
                        }
                        context.stroke(
                            path,
                            with: .color(skeletonColor.opacity(0.92 - Double(seriesIndex) * 0.07)),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                        )

                        let endYFraction = yFractions.last ?? 0.5
                        let endpoint = CGRect(
                            x: lineEndX - 3,
                            y: plot.minY + plot.height * endYFraction - 3,
                            width: 6,
                            height: 6
                        )
                        context.stroke(
                            Path(ellipseIn: endpoint),
                            with: .color(skeletonColor),
                            lineWidth: 1.2
                        )
                    }
                }

                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(skeletonColor)
                        .frame(width: 28 - CGFloat(index % 2) * 3, height: 11)
                        .position(
                            x: plot.maxX + axisWidth / 2,
                            y: plot.minY + plot.height * CGFloat(index) / 4
                        )
                }

                if showsEndpointLabels {
                    ForEach(0..<max(1, min(seriesCount, 8)), id: \.self) { index in
                        let yFraction = StandardLineChartLoadingTemplate.yFractions(
                            seriesIndex: index,
                            seriesCount: seriesCount
                        ).last ?? 0.5
                        Capsule()
                            .fill(skeletonColor.opacity(0.88))
                            .frame(width: 25, height: 11)
                            .position(
                                x: plot.maxX + axisWidth / 2,
                                y: plot.minY + plot.height * yFraction
                            )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct StandardLineChartPlaceholder: View {
    let title: String
    let message: String
    let isLoading: Bool
    var maximumLines = 3

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.055))
            VStack(spacing: 9) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(maximumLines)
                    .padding(.horizontal, 24)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(message)")
    }
}
