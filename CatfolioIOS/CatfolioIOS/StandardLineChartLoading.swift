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
struct ChartLoadingShimmer: ViewModifier {
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
