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
final class StandardLineChartPresentationProgress {
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

struct StandardLineChartRevision: Equatable {
    let transitionKey: String
    let rangeTransitionKey: String?
    let contentFingerprint: Int
}

struct StandardLineChartTransitionDriver<Content: View>: View, Animatable {
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

final class StandardLineChartHapticDriver {
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
