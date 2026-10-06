import SwiftUI
import UIKit

/// Presentation history outlives individual pages, just like the in-memory
/// chart cache. A range, theme or language change does not create a new chart.
@MainActor
enum ChartAppearanceHistory {
    private static var displayed: Set<String> = []

    static func hasDisplayed(_ id: String) -> Bool { displayed.contains(id) }

    @discardableResult
    static func record(_ id: String) -> Bool { displayed.insert(id).inserted }
}

/// A soft travelling highlight, masked by the placeholder itself. It never
/// adds an outline or changes the width of the loading stroke.
private struct ChartLoadingShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let active: Bool
    let appearanceID: String?

    func body(content: Content) -> some View {
        let animates = active && !reduceMotion
            && !(appearanceID.map { ChartAppearanceHistory.hasDisplayed($0) } ?? false)
        content.overlay {
            if animates {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    GeometryReader { geometry in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 2.2) / 2.2
                        LinearGradient(
                            colors: [.clear, .white.opacity(colorScheme == .dark ? 0.32 : 0.85), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.7)
                        .offset(x: geometry.size.width * (phase * 1.7 - 0.7))
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func chartLoadingShimmer(active: Bool = true, appearanceID: String? = nil) -> some View {
        modifier(ChartLoadingShimmer(active: active, appearanceID: appearanceID))
    }
}

struct ChartSkeletonShape: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 5

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(CatfolioTheme.skeletonFill)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

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
    /// How far the area's fill washes out towards the bottom of its own
    /// shape: 0 keeps the flat colour, 0.4 mixes 40% white into the bottom
    /// edge. The gradient spans the shape's own bounds, so a band reads as
    /// its pure colour where it starts and pales where it ends.
    let cornerRadius: CGFloat
    let areaFillWash: Double
    /// Optional design-specified gradient endpoint; other charts retain their wash.
    let areaFillEndColor: Color?
    let areaBaseline: Double?
    let areaStripeColor: Color?
    let areaStripeSpacing: CGFloat
    let areaStripeWidth: CGFloat
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
        cornerRadius: CGFloat = 0,
        areaFillWash: Double = 0,
        areaFillEndColor: Color? = nil,
        areaBaseline: Double? = nil,
        areaStripeColor: Color? = nil,
        areaStripeSpacing: CGFloat = 12,
        areaStripeWidth: CGFloat = 0.75,
        selectionRadius: CGFloat = 3.5,
        latestPointRadius: CGFloat? = 5.5,
        latestPointColor: Color? = nil,
        latestPointUsesGlass: Bool = true,
        isLoadingPlaceholder: Bool = false
    ) {
        self.id = id
        self.cornerRadius = max(0, cornerRadius)
        self.points = points.sorted { $0.date < $1.date }
        self.color = color
        self.lineWidth = lineWidth
        self.dash = dash
        self.areaFill = areaFill
        self.areaFillWash = areaFillWash
        self.areaFillEndColor = areaFillEndColor
        self.areaBaseline = areaBaseline
        self.areaStripeColor = areaStripeColor
        self.areaStripeSpacing = areaStripeSpacing
        self.areaStripeWidth = areaStripeWidth
        self.selectionRadius = selectionRadius
        self.latestPointRadius = latestPointRadius
        self.latestPointColor = latestPointColor
        self.latestPointUsesGlass = latestPointUsesGlass
        self.isLoadingPlaceholder = isLoadingPlaceholder
    }
}

enum StandardLineChartLoadingTemplate {
    // Borrow the reference's rising line and quiet, level finish. Normalized
    // geometry adapts to today's plots; these are not financial observations.
    static let xFractions: [CGFloat] = (0...64).map { -0.08 + 1.08 * CGFloat($0) / 64 }

    static func yFractions(seriesIndex: Int, seriesCount: Int) -> [CGFloat] {
        xFractions.map { yFraction(at: $0, seriesIndex: seriesIndex, seriesCount: seriesCount) }
    }

    private static func yFraction(at x: CGFloat, seriesIndex: Int, seriesCount: Int) -> CGFloat {
        let visibleCount = max(1, min(seriesCount, 8))
        let visibleIndex = seriesIndex % visibleCount
        let offset = CGFloat(visibleIndex / 2) * 0.045
        if visibleIndex.isMultiple(of: 2) {
            return 0.93 - 1.9 * (x + 0.08)
                + 1.32 * roundedHinge(x, at: 0.13, radius: 0.035)
                + 0.80 * roundedHinge(x, at: 0.78, radius: 0.035) + offset
        }
        return 0.96 - 0.72 * (x + 0.08)
            + 0.72 * roundedHinge(x, at: 0.38, radius: 0.045) + offset
    }

    /// A quadratic knee joins straight runs without sharp corners or overshoot.
    private static func roundedHinge(_ x: CGFloat, at center: CGFloat, radius: CGFloat) -> CGFloat {
        let distance = x - center
        if distance <= -radius { return 0 }
        if distance >= radius { return distance }
        return (distance + radius) * (distance + radius) / (4 * radius)
    }

    static func color(for colorScheme: ColorScheme) -> Color {
        CatfolioTheme.skeletonFill
    }

    static let adaptiveColor = CatfolioTheme.skeletonFill

    static func value(at fraction: Double, domain: ClosedRange<Double>, seriesIndex: Int = 0, seriesCount: Int = 1) -> Double {
        let x = CGFloat(min(1, max(Double(xFractions[0]), fraction)))
        let y = Double(yFraction(at: x, seriesIndex: seriesIndex, seriesCount: seriesCount))
        return domain.upperBound - (domain.upperBound - domain.lowerBound) * y
    }
}

/// Swift Charts consumers keep their native marks, missing-data segments,
/// bands, axes and selection. Only their displayed Y values use the same
/// entrance template as Canvas; their underlying observations stay untouched.
struct StandardLineChartEntrance<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat
    @State private var appeared = false
    let appearanceID: String
    let content: (StandardLineChartEntrancePhase) -> Content

    init(appearanceID: String = #fileID, @ViewBuilder content: @escaping (StandardLineChartEntrancePhase) -> Content) {
        self.appearanceID = appearanceID
        self.content = content
        _progress = State(initialValue: ChartAppearanceHistory.hasDisplayed(appearanceID) ? 1 : 0)
    }

    var body: some View {
        StandardLineChartTransitionDriver(progress: reduceMotion ? 1 : progress) { value in
            content(StandardLineChartEntrancePhase(progress: min(1, max(0, value))))
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            let firstAppearance = ChartAppearanceHistory.record(appearanceID)
            if reduceMotion || !firstAppearance {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { progress = 1 }
            }
            else { withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.45)) { progress = 1 } }
        }
        .onChange(of: reduceMotion) { _, enabled in
            guard enabled else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { progress = 1 }
        }
    }
}

struct StandardLineChartEntrancePhase {
    let progress: CGFloat

    func value(_ actual: Double, fraction: Double, domain: ClosedRange<Double>, seriesIndex: Int = 0, seriesCount: Int = 1) -> Double {
        let from = StandardLineChartLoadingTemplate.value(at: fraction, domain: domain, seriesIndex: seriesIndex, seriesCount: seriesCount)
        return from + (actual - from) * Double(progress)
    }

    static func domain(_ values: [Double]) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        let low = finite.min() ?? 0, high = finite.max() ?? 1
        let padding = max(high - low, max(abs(high) * 0.01, 0.01)) * 0.05
        return (low - padding)...(high + padding)
    }
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
    /// The rendered series this annotation belongs to (not a trade price).
    let seriesID: String?

    init(
        id: String,
        point: StandardLineChartPoint,
        color: Color,
        radius: CGFloat = 4.5,
        outlineColor: Color? = Color(uiColor: .systemBackground),
        outlineWidth: CGFloat = 1.5,
        style: Style = .solid,
        seriesID: String? = nil
    ) {
        self.id = id
        self.point = point
        self.color = color
        self.radius = radius
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
        self.style = style
        self.seriesID = seriesID
    }
}

/// One value per date, never a splice of two differently rebased histories.
/// Build correspondence once per update, not once per animation frame.
struct StandardLineChartViewportPath {
    let dates: [Date]
    let oldValues: [Double]
    let newValues: [Double]
    let oldPoints: [StandardLineChartPoint]
    let newPoints: [StandardLineChartPoint]

    init(from old: [StandardLineChartPoint], to new: [StandardLineChartPoint]) {
        oldPoints = old
        newPoints = new
        dates = Array(Set(old.map(\.date) + new.map(\.date))).sorted()
        oldValues = dates.map { Self.value(at: $0, in: old) }
        newValues = dates.map { Self.value(at: $0, in: new) }
    }

    func samples(progress raw: CGFloat) -> [StandardLineChartPoint] {
        guard let oldFirst = oldPoints.first, let oldLast = oldPoints.last,
              let newFirst = newPoints.first, let newLast = newPoints.last else { return [] }
        let t = Double(min(1, max(0, raw)))
        if t == 0 { return oldPoints }
        if t == 1 { return newPoints }
        let first = oldFirst.date.addingTimeInterval(newFirst.date.timeIntervalSince(oldFirst.date) * t)
        let last = oldLast.date.addingTimeInterval(newLast.date.timeIntervalSince(oldLast.date) * t)
        func boundary(_ date: Date) -> StandardLineChartPoint {
            let old = Self.value(at: date, in: oldPoints)
            let new = Self.value(at: date, in: newPoints)
            return StandardLineChartPoint(date: date, value: old + (new - old) * t)
        }
        var result = [boundary(first)]
        for index in dates.indices where dates[index] > first && dates[index] < last {
            result.append(StandardLineChartPoint(date: dates[index],
                value: oldValues[index] + (newValues[index] - oldValues[index]) * t))
        }
        if last > first { result.append(boundary(last)) }
        return result
    }

    static func value(at date: Date, in points: [StandardLineChartPoint]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if date <= first.date { return first.value }
        if date >= last.date { return last.value }
        var low = 0
        var high = points.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if points[middle].date <= date { low = middle } else { high = middle }
        }
        let before = points[low], after = points[high]
        let fraction = date.timeIntervalSince(before.date) / max(after.date.timeIntervalSince(before.date), 0.000_001)
        return before.value + (after.value - before.value) * fraction
    }
}

/// Non-observable presentation state: recording a drawn frame must not publish
/// a SwiftUI update or invalidate the chart's parent while a finger is moving.
private final class StandardLineChartPresentationProgress {
    var value: CGFloat = 1
}

/// A value that remains visually anchored to the chart while every consumer
/// continues to share the same plot geometry, interaction and dimming rules.
/// The line is rendered behind the price series as a plain color.
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

/// An axis figure that counts through a chart's own zoom. A chart draws its
/// bands through `StandardLineChart`, which interpolates the domain over
/// `StandardLineChartTransition.zoom`; a label placed in an overlay is outside
/// that and would otherwise snap to its new number while the bands are still
/// moving.
struct AnimatedChartValue<Label: View>: View, Animatable {
    var value: Double
    @ViewBuilder var label: (Double) -> Label

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { label(value) }
}

enum StandardLineChartTransition {
    /// The curve and length `StandardLineChart` moves its own data with.
    static let zoom = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.45)
}

enum StandardLineChartDataTransition: Equatable {
    case morph
    /// Interpolate the visible date/value viewport while drawing the union of
    /// the old and new samples. With a shared latest date this behaves like a
    /// trailing-anchored camera zoom instead of reshaping the curve in place.
    case viewportZoom
}

private struct StandardLineChartRevision: Equatable {
    let transitionKey: String
    let rangeTransitionKey: String?
    let contentFingerprint: Int
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
/// Small screen-space attraction for optional chart markers. A two-point
/// release margin prevents jitter without holding the cursor far from a trade.
enum ChartMarkerMagnet {
    static func date(at x: CGFloat, targets: [(date: Date, x: CGFloat)],
                     currentDate: Date?, radius: CGFloat) -> Date? {
        guard x.isFinite, radius.isFinite, radius > 0 else { return nil }
        let valid = targets.filter { $0.x.isFinite }
        if let nearest = valid.min(by: {
            let left = abs($0.x - x), right = abs($1.x - x)
            return left == right ? $0.date < $1.date : left < right
        }), abs(nearest.x - x) <= radius {
            return nearest.date
        }
        if let currentDate, let held = valid.first(where: { $0.date == currentDate }),
           abs(held.x - x) <= radius + 2 {
            return held.date
        }
        return nil
    }
}

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
    /// Identifies a selected time window independently of theme and line visibility.
    let rangeTransitionKey: String?
    let appearanceID: String
    let dataTransition: StandardLineChartDataTransition
    /// Optional vertical travel for a series entering or leaving this chart.
    /// Only the portfolio's net-deposit toggle uses it; range zooms stay put.
    let seriesChangeBounce: CGFloat
    let animatesInitialAppearance: Bool
    let revealsInitialAppearance: Bool
    let markers: [StandardLineChartMarker]
    let markerMagnetRadius: CGFloat
    let referenceLines: [StandardLineChartReferenceLine]
    let selectedDate: Date?
    let measuredRange: ChartDateRange?
    let selectionIndicatorLabel: String?
    let selectionSeriesIDs: Set<String>
    let rangeSeriesIDs: Set<String>
    let rangePrimarySeriesID: String?
    let dimsFutureDuringSelection: Bool
    let yAxisFont: Font
    let yAxisColor: Color
    let referenceAxisFont: Font
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
    @State private var bouncesSeriesChange = false
    @State private var usesRangeHistory = false
    @State private var unchangedSeriesDuringBounce: Set<String> = []
    @State private var transitionGeneration = 0
    @State private var viewportPaths: [String: StandardLineChartViewportPath] = [:]
    @State private var rangeHistories: [String: StandardLineChartRangeHistory] = [:]
    @State private var morphPairs: [String: [(CGPoint, CGPoint)]] = [:]
    @State private var presentationProgress = StandardLineChartPresentationProgress()
    @State private var needsInitialTransition: Bool
    @State private var initialRevealProgress: CGFloat
    @State private var needsInitialReveal: Bool
    @State private var initialRevealCancelled = false
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
        rangeTransitionKey: String? = nil,
        appearanceID: String = #fileID,
        dataTransition: StandardLineChartDataTransition = .morph,
        seriesChangeBounce: CGFloat = 0,
        animatesInitialAppearance: Bool = true,
        revealsInitialAppearance: Bool = false,
        markers: [StandardLineChartMarker] = [],
        markerMagnetRadius: CGFloat = 0,
        referenceLines: [StandardLineChartReferenceLine] = [],
        selectedDate: Date? = nil,
        measuredRange: ChartDateRange? = nil,
        selectionIndicatorLabel: String? = nil,
        selectionSeriesIDs: Set<String> = [],
        rangeSeriesIDs: Set<String> = [],
        rangePrimarySeriesID: String? = nil,
        dimsFutureDuringSelection: Bool = false,
        yAxisFont: Font = Typography.number(.nano),
        yAxisColor: Color = .secondary,
        referenceAxisFont: Font = Typography.number(.nano, weight: .semibold),
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
        self.rangeTransitionKey = rangeTransitionKey
        self.appearanceID = appearanceID
        self.dataTransition = dataTransition
        self.seriesChangeBounce = seriesChangeBounce
        self.animatesInitialAppearance = animatesInitialAppearance
        self.revealsInitialAppearance = revealsInitialAppearance
        self.markers = markers
        self.markerMagnetRadius = markerMagnetRadius
        self.referenceLines = referenceLines
        self.selectedDate = selectedDate
        self.measuredRange = measuredRange
        self.selectionIndicatorLabel = selectionIndicatorLabel
        self.selectionSeriesIDs = selectionSeriesIDs
        self.rangeSeriesIDs = rangeSeriesIDs
        self.rangePrimarySeriesID = rangePrimarySeriesID
        self.dimsFutureDuringSelection = dimsFutureDuringSelection
        self.yAxisFont = yAxisFont
        self.yAxisColor = yAxisColor
        self.referenceAxisFont = referenceAxisFont
        self.yAxisLabel = yAxisLabel
        self.xAxisLabel = xAxisLabel
        self.onSelect = onSelect
        self.onMeasure = onMeasure
        self.onInteractionEnded = onInteractionEnded
        // Prepared plots already provide chronological dates. Keep their
        // shared array instead of sorting a full history on every crosshair
        // update; still accept unordered dates from other chart consumers.
        let datesAreSorted = zip(interactionDates, interactionDates.dropFirst())
            .allSatisfy { $0.0 <= $0.1 }
        let sortedDates = datesAreSorted ? interactionDates : interactionDates.sorted()
        let firstAppearance = !ChartAppearanceHistory.hasDisplayed(appearanceID)
        // Once a chart has appeared, its loading geometry is discarded. Avoid
        // rebuilding those placeholder series on every selection update.
        let needsLoadingSeries = firstAppearance && animatesInitialAppearance && !revealsInitialAppearance
        let loadingSeries = needsLoadingSeries
            ? Self.loadingSeries(matching: series, dates: sortedDates, domain: domain)
            : []
        let startsFromLoading = firstAppearance && animatesInitialAppearance && !revealsInitialAppearance && !loadingSeries.isEmpty
        _presentedSeries = State(initialValue: startsFromLoading ? loadingSeries : series)
        _presentedMarkers = State(initialValue: startsFromLoading ? [] : markers)
        _presentedDates = State(initialValue: sortedDates)
        _presentedDomain = State(initialValue: domain)
        _outgoingDomain = State(initialValue: domain)
        _needsInitialTransition = State(initialValue: startsFromLoading)
        _initialRevealProgress = State(initialValue: firstAppearance && revealsInitialAppearance ? 0 : 1)
        _needsInitialReveal = State(initialValue: firstAppearance && revealsInitialAppearance)
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

                StandardLineChartTransitionDriver(progress: initialRevealProgress) { rawReveal in
                    let reveal = reduceMotion || initialRevealCancelled ? CGFloat(1) : Self.easeOutQuart(rawReveal)
                    ZStack(alignment: .topLeading) {
                        StandardLineChartTransitionDriver(progress: transitionProgress) { progress in
                            referenceLineLayer(plot: plot, progress: min(1, max(0, progress)))
                        }
                        StandardLineChartTransitionDriver(progress: transitionProgress) { progress in
                            Canvas { context, _ in
                                let settledProgress = min(1, max(0, progress))
                                let viewportProgress = settledProgress
                                presentationProgress.value = viewportProgress
                                var lineContext = context
                                lineContext.translateBy(x: lineLayerBleed, y: 0)
                                lineContext.clip(to: Path(CGRect(
                                    x: plot.minX - lineLayerBleed,
                                    y: plot.minY,
                                    width: plot.width + lineLayerBleed,
                                    height: plot.height
                                )))
                                if reveal < 1 {
                                    lineContext.clip(to: Path(CGRect(
                                        x: plot.minX - lineLayerBleed,
                                        y: plot.minY,
                                        width: max(0, (plot.width - trailingEndpointInset) * reveal + lineLayerBleed),
                                        height: plot.height
                                    )))
                                }
                                if !outgoingSeries.isEmpty,
                                   settledProgress < 1 || (bouncesSeriesChange && progress > 1) {
                                    drawMorphedBase(
                                        progress: settledProgress,
                                        viewportProgress: viewportProgress,
                                        bounceProgress: progress,
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
                            if reveal < 1 {
                                revealingEndpoints(plot: plot, progress: reveal)
                            } else {
                                endpointLayer(plot: plot, progress: min(1, max(0, progress)),
                                              viewportProgress: min(1, max(0, progress)),
                                              bounceProgress: progress)
                            }
                        }
                    }
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
                StandardLineChartTransitionDriver(progress: transitionProgress) { progress in
                    referenceAxisLabels(plot: plot, progress: min(1, max(0, progress)))
                }
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
            if previous.transitionKey != latest.transitionKey {
                transitionToLatestData(rangeChanged: previous.rangeTransitionKey != nil
                    && previous.rangeTransitionKey != latest.rangeTransitionKey)
            } else if previous.contentFingerprint != latest.contentFingerprint {
                // Background refreshes replace data without replaying loading.
                syncWithoutAnimation()
            }
        }
        .onAppear {
            guard series.contains(where: { !$0.isLoadingPlaceholder && $0.points.count > 1 }) else { return }
            guard ChartAppearanceHistory.record(appearanceID) else {
                syncWithoutAnimation()
                return
            }
            startInitialRevealIfNeeded()
            startInitialTransitionIfNeeded()
        }
        .onChange(of: reduceMotion) { _, enabled in
            guard enabled else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { syncLatestData() }
        }
    }

    /// Evaluated on every update, a crosshair drag's included, so it hashes
    /// rather than formatting: the earlier string built every series' colour
    /// and sampled values into text on each frame of a drag.
    private var revision: StandardLineChartRevision {
        var hasher = Hasher()
        hasher.combine(interactionDates.count)
        hasher.combine(interactionDates.first)
        hasher.combine(interactionDates.last)
        hasher.combine(domain.lowerBound)
        hasher.combine(domain.upperBound)
        for item in series {
            hasher.combine(item.id)
            hasher.combine(item.points.count)
            hasher.combine(item.points.first?.id)
            hasher.combine(item.points.last?.id)
            // The paint too: a band set back behind a highlighted one keeps
            // its points and must still redraw.
            hasher.combine(item.color)
            hasher.combine(item.areaFill)
            hasher.combine(item.lineWidth)
            let sampleStep = max(1, item.points.count / 8)
            for index in stride(from: 0, to: item.points.count, by: sampleStep) {
                hasher.combine(item.points[index].id)
                hasher.combine(item.points[index].value)
            }
            if let last = item.points.last { hasher.combine(last.value) }
        }
        for marker in markers {
            hasher.combine(marker.id)
            hasher.combine(marker.point.id)
            hasher.combine(marker.point.value)
        }
        return StandardLineChartRevision(
            transitionKey: transitionKey,
            rangeTransitionKey: rangeTransitionKey,
            contentFingerprint: hasher.finalize()
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

    private func transitionToLatestData(rangeChanged: Bool = false) {
        if revealsInitialAppearance {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                needsInitialReveal = false
                initialRevealCancelled = true
                initialRevealProgress = 1
            }
        }
        needsInitialTransition = false
        guard !reduceMotion else {
            syncLatestData()
            return
        }
        // Interrupt from the last actually drawn shape, not the previous
        // target (which may still be 400 ms away during rapid range taps).
        let current = currentPresentation(progress: presentationProgress.value)
        let changesSeries = Set(current.series.map(\.id)) != Set(series.map(\.id))
        let shouldBounce = seriesChangeBounce > 0 && changesSeries && !rangeChanged
        let shouldUseRangeHistory = rangeChanged && dataTransition == .viewportZoom
            && current.dates != interactionDates
        let unchangedIDs = shouldBounce && current.dates == interactionDates && current.domain == domain
            ? Set(series.compactMap { incoming -> String? in
                guard let previous = current.series.first(where: { $0.id == incoming.id }),
                      previous.points.count == incoming.points.count,
                      zip(previous.points, incoming.points).allSatisfy({ pair in
                          pair.0.date == pair.1.date && pair.0.value == pair.1.value
                      }) else { return nil }
                return incoming.id
            }) : []
        var resetTransaction = Transaction(animation: nil)
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            transitionGeneration &+= 1
            bouncesSeriesChange = shouldBounce
            usesRangeHistory = shouldUseRangeHistory
            unchangedSeriesDuringBounce = unchangedIDs
            outgoingSeries = current.series
            outgoingMarkers = current.markers
            outgoingDates = current.dates
            outgoingDomain = current.domain
            presentedSeries = series
            presentedMarkers = markers
            presentedDates = interactionDates
            presentedDomain = domain
            viewportPaths = shouldUseRangeHistory ? [:]
                : Dictionary(uniqueKeysWithValues: series.compactMap { incoming in
                    guard !unchangedIDs.contains(incoming.id) else { return nil }
                    guard let old = outgoingSeries.first(where: { $0.id == incoming.id }) else { return nil }
                    return (incoming.id, StandardLineChartViewportPath(from: old.points, to: incoming.points))
                })
            rangeHistories = shouldUseRangeHistory
                ? Dictionary(uniqueKeysWithValues: series.compactMap { incoming in
                    guard let old = outgoingSeries.first(where: { $0.id == incoming.id }) else { return nil }
                    return (incoming.id, StandardLineChartRangeHistory(from: old.points, to: incoming.points))
                }) : [:]
            morphPairs = shouldUseRangeHistory ? [:]
                : Dictionary(uniqueKeysWithValues: series.compactMap { incoming in
                    guard !unchangedIDs.contains(incoming.id) else { return nil }
                    guard let old = outgoingSeries.first(where: { $0.id == incoming.id }) else { return nil }
                    return (incoming.id, pairedMorphSamples(from: old, to: incoming))
                })
            presentationProgress.value = 0
            transitionProgress = 0
        }
        let generation = transitionGeneration
        Task { @MainActor in
            await Task.yield()
            guard generation == transitionGeneration else { return }
            let animation: Animation = shouldBounce
                ? .spring(response: 0.42, dampingFraction: 0.58)
                : StandardLineChartTransition.zoom
            withAnimation(animation) {
                transitionProgress = 1
            }
        }
    }

    private func startInitialTransitionIfNeeded() {
        guard needsInitialTransition else { return }
        transitionToLatestData()
    }

    private static func easeOutQuart(_ progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        return 1 - pow(1 - t, 4)
    }

    private func startInitialRevealIfNeeded() {
        guard needsInitialReveal else { return }
        needsInitialReveal = false
        guard !reduceMotion else {
            initialRevealProgress = 1
            return
        }
        // Ease in the renderer so the sweep and its endpoint share the exact
        // quartic curve, rather than a cubic Bezier approximation.
        withAnimation(.linear(duration: 0.9)) {
            initialRevealProgress = 1
        }
    }

    @ViewBuilder
    private func revealingEndpoints(plot: CGRect, progress: CGFloat) -> some View {
        if let start = presentedDates.first, let end = presentedDates.last {
            let date = interpolatedDate(from: start, to: end, progress: progress)
            ForEach(presentedSeries) { item in
                if let first = item.points.first, date >= first.date,
                   let last = item.points.last, let radius = item.latestPointRadius {
                    let headDate = min(date, last.date)
                    let position = CGPoint(
                        x: x(for: headDate, in: plot, dates: presentedDates),
                        y: y(for: interpolatedValue(at: headDate, in: item.points), in: plot, domain: presentedDomain)
                    )
                    if item.latestPointUsesGlass {
                        StandardLineChartGlassEndpoint(color: item.latestPointColor ?? item.color, radius: radius)
                            .position(position)
                    } else {
                        StandardLineChartPlainEndpoint(color: item.latestPointColor ?? item.color, radius: radius)
                            .position(position)
                    }
                }
            }
        }
    }

    private func syncLatestData() {
        needsInitialTransition = false
        needsInitialReveal = false
        initialRevealProgress = 1
        initialRevealCancelled = true
        transitionGeneration &+= 1
        presentedSeries = series
        presentedMarkers = markers
        presentedDates = interactionDates
        presentedDomain = domain
        outgoingSeries = []
        outgoingMarkers = []
        outgoingDates = []
        viewportPaths = [:]
        rangeHistories = [:]
        morphPairs = [:]
        bouncesSeriesChange = false
        usesRangeHistory = false
        unchangedSeriesDuringBounce = []
        presentationProgress.value = 1
        transitionProgress = 1
    }

    private func syncWithoutAnimation() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { syncLatestData() }
    }

    private func copySeries(_ source: StandardLineChartSeries,
                            points: [StandardLineChartPoint]) -> StandardLineChartSeries {
        StandardLineChartSeries(id: source.id, points: points, color: source.color,
            lineWidth: source.lineWidth, dash: source.dash, areaFill: source.areaFill,
            areaFillWash: source.areaFillWash,
            areaFillEndColor: source.areaFillEndColor,
            areaBaseline: source.areaBaseline, areaStripeColor: source.areaStripeColor,
            areaStripeSpacing: source.areaStripeSpacing, areaStripeWidth: source.areaStripeWidth, selectionRadius: source.selectionRadius,
            latestPointRadius: source.latestPointRadius, latestPointColor: source.latestPointColor,
            latestPointUsesGlass: source.latestPointUsesGlass)
    }

    private func transitionDates(_ raw: CGFloat) -> [Date] {
        guard let oldFirst = outgoingDates.first, let oldLast = outgoingDates.last,
              let newFirst = presentedDates.first, let newLast = presentedDates.last else { return presentedDates }
        let progress = min(1, max(0, raw))
        return [interpolatedDate(from: oldFirst, to: newFirst, progress: progress),
                interpolatedDate(from: oldLast, to: newLast, progress: progress)]
    }

    private func currentPresentation(progress raw: CGFloat) -> (
        series: [StandardLineChartSeries], markers: [StandardLineChartMarker],
        dates: [Date], domain: ClosedRange<Double>
    ) {
        let progress = min(1, max(0, raw))
        guard progress < 1, !outgoingSeries.isEmpty else {
            return (presentedSeries, presentedMarkers, presentedDates, presentedDomain)
        }
        let dates = transitionDates(progress)
        let domain = interpolatedDomain(from: outgoingDomain, to: presentedDomain, progress: progress)
        guard let first = dates.first, let last = dates.last else {
            return (presentedSeries, presentedMarkers, presentedDates, presentedDomain)
        }
        func dataPoint(_ position: CGPoint, id: String? = nil) -> StandardLineChartPoint {
            StandardLineChartPoint(id: id,
                date: first.addingTimeInterval(last.timeIntervalSince(first) * Double(position.x)),
                value: domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double(position.y))
        }
        let visible = presentedSeries.map { incoming in
            guard let old = outgoingSeries.first(where: { $0.id == incoming.id }) else { return incoming }
            if usesRangeHistory, let history = rangeHistories[incoming.id] {
                return copySeries(incoming, points: history.samples(from: first, to: last))
            }
            if dataTransition == .viewportZoom && !old.isLoadingPlaceholder,
               let path = viewportPaths[incoming.id] {
                return copySeries(incoming, points: path.samples(progress: progress))
            }
            return copySeries(incoming, points: morphedSamples(from: old, to: incoming, progress: progress).map { dataPoint($0) })
        }
        let visibleMarkers = animatedMarkers(progress: progress).compactMap { item -> StandardLineChartMarker? in
            guard item.scale > 0.01 else { return nil }
            let marker = item.marker
            return StandardLineChartMarker(id: marker.id, point: dataPoint(item.position, id: marker.point.id),
                color: marker.color, radius: marker.radius, outlineColor: marker.outlineColor,
                outlineWidth: marker.outlineWidth, style: marker.style, seriesID: marker.seriesID)
        }
        return (visible, visibleMarkers, dates, domain)
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
                lineWidth: target.lineWidth,
                dash: target.dash,
                selectionRadius: target.selectionRadius,
                latestPointRadius: target.latestPointRadius,
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
        yOffset: CGFloat = 0,
        opacity: Double,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        var layer = context
        layer.translateBy(x: xOffset, y: yOffset)
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
        viewportProgress: CGFloat,
        bounceProgress: CGFloat,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        let outgoingByID = Dictionary(uniqueKeysWithValues: outgoingSeries.map { ($0.id, $0) })
        let presentedIDs = Set(presentedSeries.map(\.id))

        for incoming in presentedSeries where !incoming.points.isEmpty {
            if let outgoing = outgoingByID[incoming.id],
               !outgoing.points.isEmpty {
                if unchangedSeriesDuringBounce.contains(incoming.id) {
                    drawBase(
                        series: [incoming], markers: [], dates: presentedDates,
                        valueDomain: presentedDomain, xOffset: 0, opacity: 1,
                        context: &context, plot: plot
                    )
                } else if dataTransition == .viewportZoom && !outgoing.isLoadingPlaceholder {
                    drawViewportZoomedSeries(
                        from: outgoing,
                        to: incoming,
                        progress: viewportProgress,
                        context: &context,
                        plot: plot
                    )
                } else {
                    drawMorphedSeries(
                        from: outgoing,
                        to: incoming,
                        progress: progress,
                        context: &context,
                        plot: plot
                    )
                }
            } else {
                drawBase(
                    series: [incoming],
                    markers: [],
                    dates: presentedDates,
                    valueDomain: presentedDomain,
                    xOffset: 0,
                    yOffset: seriesBounceOffset(entering: true, progress: bounceProgress),
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
                yOffset: seriesBounceOffset(entering: false, progress: bounceProgress),
                opacity: 1 - Double(progress),
                context: &context,
                plot: plot
            )
        }

        drawMorphedMarkers(progress: progress, context: &context, plot: plot)
    }

    private func seriesBounceOffset(entering: Bool, progress: CGFloat) -> CGFloat {
        guard bouncesSeriesChange else { return 0 }
        return entering ? seriesChangeBounce * (1 - progress) : -seriesChangeBounce * progress
    }

    private func drawViewportZoomedSeries(
        from outgoing: StandardLineChartSeries,
        to incoming: StandardLineChartSeries,
        progress: CGFloat,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        guard let oldStart = outgoingDates.first,
              let oldEnd = outgoingDates.last,
              let newStart = presentedDates.first,
              let newEnd = presentedDates.last else { return }

        let dates = usesRangeHistory
            ? transitionDates(progress)
            : [interpolatedDate(from: oldStart, to: newStart, progress: progress),
               interpolatedDate(from: oldEnd, to: newEnd, progress: progress)]
        guard let visibleStart = dates.first, let visibleEnd = dates.last else { return }
        guard visibleEnd > visibleStart else { return }

        let visibleDomain = interpolatedDomain(
            from: outgoingDomain,
            to: presentedDomain,
            progress: min(1, max(0, progress))
        )
        let samples: [StandardLineChartPoint]
        if usesRangeHistory, let history = rangeHistories[incoming.id] {
            samples = history.samples(from: visibleStart, to: visibleEnd)
        } else {
            samples = viewportPaths[incoming.id]?.samples(progress: progress)
                ?? StandardLineChartViewportPath(from: outgoing.points, to: incoming.points)
                    .samples(progress: progress)
        }

        drawPath(
            samples,
            series: incoming,
            opacity: 1,
            dates: [visibleStart, visibleEnd],
            valueDomain: visibleDomain,
            context: &context,
            plot: plot
        )
    }

    private func interpolatedDate(
        from start: Date,
        to end: Date,
        progress: CGFloat
    ) -> Date {
        Date(timeIntervalSinceReferenceDate:
            start.timeIntervalSinceReferenceDate
                + (end.timeIntervalSinceReferenceDate - start.timeIntervalSinceReferenceDate)
                * Double(progress)
        )
    }

    private func interpolatedDomain(
        from start: ClosedRange<Double>,
        to end: ClosedRange<Double>,
        progress: CGFloat
    ) -> ClosedRange<Double> {
        let progress = Double(progress)
        let lower = start.lowerBound + (end.lowerBound - start.lowerBound) * progress
        let upper = start.upperBound + (end.upperBound - start.upperBound) * progress
        return lower...max(lower + 0.000_001, upper)
    }

    private func drawMorphedSeries(
        from outgoing: StandardLineChartSeries,
        to incoming: StandardLineChartSeries,
        progress: CGFloat,
        context: inout GraphicsContext,
        plot: CGRect
    ) {
        let samples = morphedSamples(from: outgoing, to: incoming, progress: progress)
        let points = samples.map { point(in: plot, normalized: $0) }
        guard let first = points.first else { return }

        let path = StandardLineChartRoundedPath.make(points, radius: incoming.cornerRadius)

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
            fillContext.fill(area, with: areaShading(incoming, fill: fill, bounds: area.boundingRect))
            drawAreaStripes(in: area, color: incoming.areaStripeColor,
                spacing: incoming.areaStripeSpacing, width: incoming.areaStripeWidth, context: &fillContext, plot: plot)
        }

        if outgoing.isLoadingPlaceholder {
            // Paint one interpolated colour, not two translucent copies of
            // the same stroke (which darken their overlapping edges).
            stroke(path, series: incoming, opacity: 1,
                color: outgoing.color.mix(with: incoming.color, by: Double(progress)), context: &context)
        } else {
            stroke(path, series: incoming, opacity: 1, context: &context)
        }
    }

    private func morphedSamples(from outgoing: StandardLineChartSeries,
                                to incoming: StandardLineChartSeries, progress: CGFloat) -> [CGPoint] {
        let pairs = morphPairs[incoming.id] ?? pairedMorphSamples(from: outgoing, to: incoming)
        return pairs.map { old, new in
            CGPoint(x: old.x + (new.x - old.x) * progress, y: old.y + (new.y - old.y) * progress)
        }
    }

    private func pairedMorphSamples(from outgoing: StandardLineChartSeries,
                                    to incoming: StandardLineChartSeries) -> [(CGPoint, CGPoint)] {
        mergedMorphProgresses(outgoing.points, incoming.points).compactMap { pathProgress -> (CGPoint, CGPoint)? in
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
        for item in animatedMarkers(progress: progress) {
            drawMarker(item.marker, at: point(in: plot, normalized: item.position),
                       scale: item.scale, context: &context)
        }
    }

    private func animatedMarkers(progress: CGFloat) -> [(marker: StandardLineChartMarker, position: CGPoint, scale: CGFloat)] {
        let oldByID = Dictionary(uniqueKeysWithValues: outgoingMarkers.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: presentedMarkers.map { ($0.id, $0) })
        let ids = presentedMarkers.map(\.id) + outgoingMarkers.filter { newByID[$0.id] == nil }.map(\.id)
        let dates = transitionDates(progress)
        let domain = interpolatedDomain(from: outgoingDomain, to: presentedDomain, progress: progress)
        let paths = viewportPaths.mapValues { $0.samples(progress: progress) }
        return ids.compactMap { id in
            guard let marker = newByID[id] ?? oldByID[id] else { return nil }
            let oldMarker = oldByID[id], newMarker = newByID[id]
            let scale = oldMarker == nil ? markerScale(progress)
                : newMarker == nil ? markerScale(1 - progress) : 1
            let oldPoint = oldMarker?.point ?? marker.point
            let newPoint = newMarker?.point ?? marker.point
            let position: CGPoint
            if let seriesID = marker.seriesID,
               let old = outgoingSeries.first(where: { $0.id == seriesID }),
               let new = presentedSeries.first(where: { $0.id == seriesID }) {
                if dataTransition == .viewportZoom && !old.isLoadingPlaceholder,
                   let samples = paths[seriesID] {
                    let date = interpolatedDate(from: oldPoint.date, to: newPoint.date, progress: progress)
                    position = normalizedPosition(for: StandardLineChartPoint(date: date,
                        value: StandardLineChartViewportPath.value(at: date, in: samples)), dates: dates, domain: domain)
                } else {
                    // A marker rides the same correspondence as its series.
                    // Its path fraction moves between its two real date anchors.
                    func fraction(_ point: StandardLineChartPoint, _ series: StandardLineChartSeries) -> Double {
                        guard let first = series.points.first, let last = series.points.last else { return 0 }
                        return min(1, max(0, point.date.timeIntervalSince(first.date) / max(last.date.timeIntervalSince(first.date), 1)))
                    }
                    let end = fraction(newPoint, new)
                    let start = old.isLoadingPlaceholder ? end : fraction(oldPoint, old)
                    let fraction = start + (end - start) * Double(progress)
                    guard let a = normalizedSample(for: old, dates: outgoingDates, domain: outgoingDomain, pathProgress: fraction),
                          let b = normalizedSample(for: new, dates: presentedDates, domain: presentedDomain, pathProgress: fraction) else { return nil }
                    position = CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
                }
            } else {
                let a = normalizedPosition(for: oldPoint, dates: outgoingDates, domain: outgoingDomain)
                let b = normalizedPosition(for: newPoint, dates: presentedDates, domain: presentedDomain)
                position = CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
            }
            return (marker, position, scale)
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
        var locations: [CGPoint] = []
        for point in points {
            let location = CGPoint(
                x: x(for: point.date, in: plot, dates: dates),
                y: y(for: point.value, in: plot, domain: valueDomain)
            )
            locations.append(location)
        }
        // The viewport-zoom transition draws through here. Without this, a
        // filled series lost its area for the length of every range change.
        let path = StandardLineChartRoundedPath.make(locations, radius: series.cornerRadius)
        if let fill = series.areaFill, let baseline = series.areaBaseline,
           let first = locations.first, let last = locations.last {
            let baseY = y(for: baseline, in: plot, domain: valueDomain)
            var area = path
            area.addLine(to: CGPoint(x: last.x, y: baseY))
            area.addLine(to: CGPoint(x: first.x, y: baseY))
            area.closeSubpath()
            var fillContext = context
            fillContext.opacity = opacity
            fillContext.fill(area, with: areaShading(series, fill: fill, bounds: area.boundingRect))
            drawAreaStripes(in: area, color: series.areaStripeColor,
                            spacing: series.areaStripeSpacing, width: series.areaStripeWidth, context: &fillContext, plot: plot)
        }
        stroke(path, series: series, opacity: opacity, context: &context)
    }

    private func stroke(
        _ path: Path,
        series: StandardLineChartSeries,
        opacity: Double,
        color: Color? = nil,
        context: inout GraphicsContext
    ) {
        // An area-only series (the stacked source bands) has no line. Core
        // Graphics strokes a zero width as a one-pixel hairline, which left
        // a thread of each band's colour along the axis wherever it was flat.
        guard series.lineWidth > 0 else { return }
        var strokeContext = context
        if let endpoint = path.currentPoint, let radius = series.latestPointRadius {
            // Geometry, not the ring's opacity, hides the line head. This
            // remains hollow during shimmer, fades and on gradient surfaces.
            strokeContext.clip(to: Path(ellipseIn: CGRect(
                x: endpoint.x - radius, y: endpoint.y - radius,
                width: radius * 2, height: radius * 2
            )), options: .inverse)
        }
        strokeContext.stroke(
            path,
            with: .color((color ?? series.color).opacity(opacity)),
            style: StrokeStyle(
                lineWidth: series.lineWidth,
                lineCap: .round,
                lineJoin: .round,
                dash: series.dash
            )
        )
    }

    @ViewBuilder
    private func endpointLayer(
        plot: CGRect, progress: CGFloat, viewportProgress: CGFloat, bounceProgress: CGFloat
    ) -> some View {
        let outgoingByID = Dictionary(uniqueKeysWithValues: outgoingSeries.map { ($0.id, $0) })
        let presentedIDs = Set(presentedSeries.map(\.id))
        ZStack(alignment: .topLeading) {
            ForEach(presentedSeries.filter { $0.latestPointRadius != nil }) { item in
                if unchangedSeriesDuringBounce.contains(item.id) {
                    endpoint(for: item, dates: presentedDates,
                             valueDomain: presentedDomain, plot: plot)
                } else if progress < 1,
                          let outgoing = outgoingByID[item.id] {
                    if dataTransition == .viewportZoom,
                       !outgoing.isLoadingPlaceholder {
                        // The stroke projects values through the animated
                        // domain. Interpolating screen positions instead takes
                        // a different path as the domain's span changes.
                        let endpointSeries = usesRangeHistory ? item : copySeries(item,
                            points: viewportPaths[item.id]?.samples(progress: viewportProgress) ?? item.points)
                        endpoint(
                            for: endpointSeries,
                            dates: transitionDates(viewportProgress),
                            valueDomain: interpolatedDomain(
                                from: outgoingDomain,
                                to: presentedDomain,
                                progress: progress
                            ),
                            plot: plot
                        )
                    } else {
                        morphedEndpoint(
                            from: outgoing,
                            to: item,
                            progress: progress,
                            plot: plot
                        )
                    }
                } else {
                    endpoint(
                        for: item,
                        dates: presentedDates,
                        valueDomain: presentedDomain,
                        plot: plot
                    )
                    .offset(y: outgoingByID[item.id] == nil
                        ? seriesBounceOffset(entering: true, progress: bounceProgress) : 0)
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
                .offset(y: seriesBounceOffset(entering: false, progress: bounceProgress))
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
                    // Clear the endpoint once at full coverage before either
                    // ring fades. Fading the cutout itself exposes the line.
                    Circle()
                        .fill(Color.black)
                        .blendMode(.destinationOut)
                        .frame(width: newRadius * 2, height: newRadius * 2)

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


    /// Flat colour, or the design's wash from the shape's top to its bottom.
    private func areaShading(_ series: StandardLineChartSeries, fill: Color,
                             bounds: CGRect) -> GraphicsContext.Shading {
        guard series.areaFillWash > 0 || series.areaFillEndColor != nil, bounds.height > 1 else { return .color(fill) }
        return .linearGradient(
            Gradient(colors: [fill, series.areaFillEndColor ?? fill.mix(with: .white, by: series.areaFillWash)]),
            startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
            endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)
        )
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
        let locations = series.points.map { point in
            let location = CGPoint(
                x: x(for: point.date, in: plot, dates: dates),
                y: y(for: point.value, in: plot, domain: valueDomain)
            )
            return location
        }
        var area = StandardLineChartRoundedPath.make(locations, radius: series.cornerRadius)
        if let first = series.points.first, let last = series.points.last {
            let baselineY = y(for: baseline, in: plot, domain: valueDomain)
            area.addLine(to: CGPoint(x: x(for: last.date, in: plot, dates: dates), y: baselineY))
            area.addLine(to: CGPoint(x: x(for: first.date, in: plot, dates: dates), y: baselineY))
            area.closeSubpath()
            context.fill(area, with: areaShading(series, fill: fill, bounds: area.boundingRect))
            drawAreaStripes(
                in: area,
                color: series.areaStripeColor,
                spacing: series.areaStripeSpacing,
                width: series.areaStripeWidth,
                context: &context,
                plot: plot
            )
        }
    }

    private func drawAreaStripes(
        in area: Path,
        color: Color?,
        spacing: CGFloat,
        width: CGFloat,
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
        stripeContext.stroke(stripes, with: .color(color), lineWidth: width)
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
    private func referenceLineLayer(plot: CGRect, progress: CGFloat) -> some View {
        ForEach(referenceLines) { reference in
            Capsule().fill(reference.color)
                .frame(width: plot.width, height: reference.lineWidth)
                .position(x: plot.midX, y: referenceY(reference.value, plot: plot, progress: progress))
        }
    }

    @ViewBuilder
    private func referenceAxisLabels(plot: CGRect, progress: CGFloat) -> some View {
        ForEach(referenceLines) { reference in
            Text(reference.label)
                .font(referenceAxisFont)
                .foregroundStyle(reference.color)
                .position(
                    x: yAxisSide == .leading ? axisWidth / 2 : plot.maxX + axisWidth / 2,
                    y: referenceY(reference.value, plot: plot, progress: progress)
                )
        }
    }

    private func referenceY(_ value: Double, plot: CGRect, progress: CGFloat) -> CGFloat {
        let activeDomain = outgoingSeries.isEmpty ? presentedDomain
            : interpolatedDomain(from: outgoingDomain, to: presentedDomain, progress: progress)
        return y(for: value, in: plot, domain: activeDomain)
    }

    @ViewBuilder
    private func xAxisLabels(plot: CGRect) -> some View {
        if bottomHeight > 0, let first = interactionDates.first, let last = interactionDates.last {
            HStack {
                Text(xAxisLabel(first))
                Spacer()
                Text(xAxisLabel(last))
            }
            .font(Typography.text(.micro))
            .foregroundStyle(.secondary)
            .frame(width: plot.width)
            .offset(x: plot.minX, y: plot.maxY + 6)
        }
    }

    private func updateSelection(from locations: [CGPoint], plot: CGRect) {
        let dates = locations.compactMap {
            date(at: $0.x, plot: plot, attractsMarkers: locations.count == 1)
        }
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

    private func date(at locationX: CGFloat, plot: CGRect, attractsMarkers: Bool) -> Date? {
        guard !interactionDates.isEmpty, plot.width > 0 else { return nil }
        let clampedX = min(max(locationX, plot.minX), plot.maxX)
        let startX = plot.minX - leadingLineOverflow
        let endX = plot.maxX - trailingEndpointInset
        let ratio = min(1, max(0, Double((clampedX - startX) / max(endX - startX, 1))))
        let first = interactionDates[0]
        let last = interactionDates[interactionDates.count - 1]
        if attractsMarkers, markerMagnetRadius > 0 {
            let targets = markers.compactMap { marker -> (date: Date, x: CGFloat)? in
                guard marker.point.date >= first, marker.point.date <= last else { return nil }
                return (marker.point.date, interactionX(for: marker.point.date, in: plot))
            }
            if let attracted = ChartMarkerMagnet.date(at: clampedX, targets: targets,
                currentDate: selectedDate, radius: markerMagnetRadius) {
                return attracted
            }
        }
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
            .font(Typography.number(.caption, weight: .semibold))
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
    var showsSeries = true
    var showsEndpointLabels = false
    var lineWidths: [CGFloat] = [2.25]
    var appearanceID: String? = nil
    /// Whether to draw the axis label bars. Off, the plot keeps the same
    /// geometry — only the line is drawn.
    var showsAxis = true

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
                    guard showsSeries else { return }
                    let count = max(1, min(seriesCount, 8))
                    var silhouette = Path()
                    var endpointHoles = Path()
                    let lineStartX = plot.minX - leadingLineOverflow
                    let lineEndX = plot.maxX - trailingEndpointInset

                    for seriesIndex in 0..<count {
                        let lineWidth = lineWidths.isEmpty ? 2.25 : lineWidths[min(seriesIndex, lineWidths.count - 1)]
                        let yFractions = StandardLineChartLoadingTemplate.yFractions(
                            seriesIndex: seriesIndex, seriesCount: count
                        )
                        let points = zip(StandardLineChartLoadingTemplate.xFractions, yFractions).map { x, y in
                            CGPoint(x: lineStartX + (lineEndX - lineStartX) * x,
                                    y: min(plot.maxY, max(plot.minY, plot.minY + plot.height * y)))
                        }
                        var path = Path()
                        path.addLines(points)
                        let stroke = path.strokedPath(StrokeStyle(
                            lineWidth: lineWidth, lineCap: .round, lineJoin: .round
                        ))
                        silhouette = silhouette.union(stroke)

                        if let endpoint = points.last {
                            let radius = max(4.5, lineWidth * 1.6)
                            let outer = CGRect(x: endpoint.x - radius, y: endpoint.y - radius,
                                               width: radius * 2, height: radius * 2)
                            silhouette = silhouette.union(Path(ellipseIn: outer))
                            endpointHoles.addEllipse(in: outer.insetBy(dx: lineWidth, dy: lineWidth))
                        }
                    }
                    // Resolve overlaps before applying the translucent fill.
                    // Every ring is genuinely hollow, including where another
                    // series passes behind it; shimmer uses this same silhouette.
                    context.fill(silhouette.subtracting(endpointHoles), with: .color(skeletonColor))
                }

                if axisWidth > 0, showsAxis {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule()
                            .fill(skeletonColor)
                            .frame(width: 28 - CGFloat(index % 2) * 3, height: 11)
                            .position(
                                x: plot.maxX + axisWidth / 2,
                                y: plot.minY + plot.height * CGFloat(index) / 4
                            )
                    }
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
        .chartLoadingShimmer(appearanceID: appearanceID)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct StandardLineChartPlaceholder: View {
    let title: String
    let message: String
    let isLoading: Bool
    var maximumLines = 3
    var lineWidths: [CGFloat] = [2.25]
    var appearanceID: String? = nil
    /// What the reader can do about it, one quiet line under the message.
    var hint: String? = nil

    @ViewBuilder
    var body: some View {
        if isLoading {
            StandardLineChartSkeleton(seriesCount: lineWidths.count, lineWidths: lineWidths, appearanceID: appearanceID)
        } else {
            ZStack {
                // The chart's own resting line, very faint. The page keeps the
                // shape it will have once there is something to draw, rather
                // than turning into a grey box with an icon in it.
                restingLine
                    .allowsHitTesting(false)

                VStack(spacing: 5) {
                    Text(title)
                        .appText(.subheading, weight: .semibold)
                        .foregroundStyle(CatfolioTheme.primaryText)
                    Text(L10n.message(message))
                        .appText(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(maximumLines)
                    if let hint {
                        Text(hint)
                            .appText(.micro)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
                .padding(.horizontal, 24)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel([title, message, hint].compactMap { $0 }.map { L10n.message($0) }.joined(separator: L10n.listSeparator))
        }
    }

    private var restingLine: some View {
        Canvas { context, size in
            // A low, shallow curve: a horizon under the words rather than a
            // line through them.
            let plot = CGRect(x: 0, y: size.height * 0.62,
                              width: max(1, size.width), height: max(1, size.height * 0.26))
            let fractions = StandardLineChartLoadingTemplate.yFractions(seriesIndex: 0, seriesCount: 1)
            let points = zip(StandardLineChartLoadingTemplate.xFractions, fractions).map { x, y in
                CGPoint(x: plot.minX + plot.width * x,
                        y: min(plot.maxY, max(plot.minY, plot.minY + plot.height * y)))
            }
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(CatfolioTheme.skeletonFill),
                           style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
        }
        .opacity(0.5)
        .mask(LinearGradient(colors: [.black.opacity(0), .black, .black, .black.opacity(0)],
                             startPoint: .leading, endPoint: .trailing))
    }
}

/// Non-line plots keep their own geometry while their data is unavailable.
struct ChartShapeSkeleton: View {
    enum Layout { case columns, horizontalBars, bubbles }
    let layout: Layout
    var appearanceID: String? = nil

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(x: 12, y: 18, width: max(1, geometry.size.width - 52),
                              height: max(1, geometry.size.height - 46))
            Canvas { context, _ in
                let fill = GraphicsContext.Shading.color(CatfolioTheme.skeletonFill)
                switch layout {
                case .columns:
                    let step = plot.width / 8
                    for index in 0..<8 {
                        let height = plot.height * [0.36, 0.49, 0.44, 0.65, 0.56, 0.74, 0.66, 0.85][index]
                        for column in 0..<2 {
                            let barHeight = height * (column == 0 ? 0.82 : 1)
                            let rect = CGRect(x: plot.minX + CGFloat(index) * step + CGFloat(column) * step * 0.35,
                                              y: plot.maxY - barHeight, width: step * 0.28, height: barHeight)
                            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: fill)
                        }
                    }
                case .horizontalBars:
                    let step = plot.height / 18
                    for index in 0..<18 {
                        let width = plot.width * (0.22 + 0.30 * (1 + sin(Double(index) * 1.3)) / 2)
                        let rect = CGRect(x: plot.midX - width / 2, y: plot.minY + CGFloat(index) * step,
                                          width: width, height: step * 0.6)
                        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: fill)
                    }
                case .bubbles:
                    for index in 0..<12 {
                        let diameter: CGFloat = 14 + CGFloat(index % 4) * 7
                        let x = plot.minX + plot.width * CGFloat((index * 7) % 13) / 13
                        let y = plot.minY + plot.height * CGFloat((index * 5) % 13) / 13
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)), with: fill)
                    }
                }
                for index in 0..<5 {
                    let label = CGRect(x: plot.maxX + 8, y: plot.minY + plot.height * CGFloat(index) / 4,
                                       width: 25, height: 10)
                    context.fill(Path(roundedRect: label, cornerRadius: 4), with: fill)
                }
                for index in 0..<4 {
                    let label = CGRect(x: plot.minX + plot.width * CGFloat(index) / 4,
                                       y: plot.maxY + 12, width: 28, height: 10)
                    context.fill(Path(roundedRect: label, cornerRadius: 4), with: fill)
                }
            }
        }
        .chartLoadingShimmer(appearanceID: appearanceID)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Quadratic fillets with a shared horizontal radius keep stacked boundaries
/// ordered: all layers use the same positive interpolation weights and dates.
/// Rounding is opt-in and does not change source values or the selection readout.
enum StandardLineChartRoundedPath {
    static func make(_ points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard radius > 0, points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1], vertex = points[index], next = points[index + 1]
            let left = vertex.x - previous.x, right = next.x - vertex.x
            guard left > 0, right > 0 else { path.addLine(to: vertex); continue }
            let width = min(radius, min(left, right) / 2)
            let entry = CGPoint(x: vertex.x - width,
                                y: vertex.y + (previous.y - vertex.y) * width / left)
            let exit = CGPoint(x: vertex.x + width,
                               y: vertex.y + (next.y - vertex.y) * width / right)
            path.addLine(to: entry)
            path.addQuadCurve(to: exit, control: vertex)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
