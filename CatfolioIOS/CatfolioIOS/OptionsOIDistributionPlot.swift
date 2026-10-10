import SwiftUI
import Charts
import CryptoKit

/// Mirrors the VolumeDistributionPlot's Canvas, diagonal grain and glass rules.
/// Reuses its native chart interaction recognizer (including cancellation/haptics).
struct OptionsOIDistributionPlot: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var appLocale
    @ScaledMetric(relativeTo: .caption2) private var markerFontSize = 11.0
    let distribution: OIDistribution
    let currentPrice: Double?
    let holdingCost: Double?
    @Binding var selectedStrike: Double?
    var range: OIPlotRange = .main
    /// Where every visible label pill was drawn, so the rules can part
    /// around them rather than run underneath the glass.
    @State private var pillFrames: [String: CGRect] = [:]
    /// The finger's x while a strike is held; its readout goes on the far side.
    @State private var touchX: CGFloat?
    private static let plotSpace = "options-oi-plot-space"

    private struct PillFramesKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private var putColor: Color { CatfolioTheme.loss(for: colorScheme) }
    private var callColor: Color { CatfolioTheme.gain(for: colorScheme) }
    private var selectionColor: Color { CatfolioTheme.accent }
    private var currentTint: Color { colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.05) }

    var body: some View {
        let geometry = OIPlotGeometry(distribution, range: range, currentPrice: currentPrice)
        VStack(spacing: 12) {
            GeometryReader { proxy in
                let size = proxy.size
                let center = size.width / 2
                let laneWidth = max(1, center - 10)
                let axisWidth = min(size.width * 0.46, max(72, CGFloat(max(priceText(geometry.domain.lowerBound).count,
                                                     priceText(geometry.domain.upperBound).count)) * 7 + 18))
                ZStack(alignment: .topLeading) {
                    Canvas { context, canvas in
                        context.clip(to: Path(CGRect(origin: .zero, size: canvas)))
                        for side in [OIPlotGeometry.Side.put, .call] {
                            let color = side == .put ? putColor : callColor
                            for segment in geometry.segments(for: side) {
                                let path = silhouette(segment, side: side, geometry: geometry, size: canvas)
                                context.fill(path, with: .color(color.opacity(0.84)))
                                if let range = distribution.concentration {
                                    let upper = y(range.upperBound, geometry, canvas.height)
                                    let lower = y(range.lowerBound, geometry, canvas.height)
                                    context.drawLayer { layer in
                                        layer.clip(to: path)
                                        layer.fill(Path(CGRect(x: 0, y: 0, width: canvas.width, height: upper)), with: .color(Color(uiColor: .systemBackground).opacity(0.35)))
                                        layer.fill(Path(CGRect(x: 0, y: lower, width: canvas.width, height: max(0, canvas.height - lower))), with: .color(Color(uiColor: .systemBackground).opacity(0.35)))
                                    }
                                }
                                var stripes = Path()
                                var x = -canvas.height
                                while x < canvas.width + canvas.height {
                                    stripes.move(to: CGPoint(x: x, y: 0))
                                    stripes.addLine(to: CGPoint(x: x + canvas.height, y: canvas.height))
                                    x += 30
                                }
                                context.drawLayer { layer in
                                    layer.clip(to: path)
                                    layer.stroke(stripes, with: .color(.white.opacity(0.20)), lineWidth: 11)
                                }
                            }
                        }
                        var axis = Path()
                        axis.move(to: CGPoint(x: center, y: 0))
                        axis.addLine(to: CGPoint(x: center, y: canvas.height))
                        context.stroke(axis, with: .color(.secondary.opacity(0.22)), lineWidth: 0.5)
                    }
                    // The walls step aside while a finger reads a strike, so
                    // the one line on the chart is the selection.
                    Group {
                        markerRules(geometry: geometry, size: size)
                        markerLane(call: false, geometry: geometry, size: size, width: laneWidth)
                        markerLane(call: true, geometry: geometry, size: size, width: laneWidth)
                    }
                    .opacity(selectedStrike == nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: selectedStrike == nil)
                    if let selectedStrike, let row = geometry.nearest(to: selectedStrike) {
                        let selectedY = y(row.strike, geometry, size.height)
                        // The readout goes to the side the finger is not on.
                        let onLeft = (touchX ?? 0) > size.width / 2
                        ForEach(Array(ruleSegments(y: selectedY,
                            from: onLeft ? axisWidth + 6 : 6,
                            to: onLeft ? size.width - 6 : size.width - axisWidth - 6,
                            only: "selection").enumerated()), id: \.offset) { _, segment in
                            glassRule(color: selectionColor, width: segment.upperBound - segment.lowerBound, interactive: true)
                                .position(x: (segment.lowerBound + segment.upperBound) / 2, y: selectedY)
                                .opacity(pillFrames["selection"] == nil ? 0 : 1)
                        }
                        pill(Text(priceText(row.strike)).appNumber(.micro, weight: .semibold)
                            .foregroundStyle(.white).lineLimit(1).padding(.horizontal, 8)
                            .frame(width: axisWidth, height: 26), tint: selectionColor, interactive: true)
                            .background(pillFrameReader("selection"))
                            .position(x: onLeft ? axisWidth / 2 : size.width - axisWidth / 2,
                                      y: min(size.height - 13, max(13, selectedY)))
                    }
                    ChartPointInteractionOverlay(onLocationChanged: { location in
                        touchX = location.x
                        let fraction = 1 - min(1, max(0, location.y / max(1, size.height)))
                        let price = geometry.domain.lowerBound + Double(fraction) * (geometry.domain.upperBound - geometry.domain.lowerBound)
                        selectedStrike = geometry.nearest(to: price)?.strike
                    }, onInteractionEnded: { selectedStrike = nil; touchX = nil })
                    .accessibilityIdentifier("options-oi-interaction")
                }
                .coordinateSpace(name: Self.plotSpace)
                .onPreferenceChange(PillFramesKey.self) { pillFrames = $0 }
                .onDisappear { selectedStrike = nil; touchX = nil }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("options-oi-plot")
                .accessibilityLabel(L10n.text("按行权价排列的 Call 与 Put 未平仓合约分布，下方提供峰值和集中区数值"))
                .accessibilityValue(selectionDescription(geometry))
                .accessibilityAdjustableAction { direction in
                    let index = geometry.visibleRows.firstIndex { $0.strike == selectedStrike } ?? geometry.visibleRows.count / 2
                    let next = direction == .increment ? index + 1 : index - 1
                    if !geometry.visibleRows.isEmpty { selectedStrike = geometry.visibleRows[min(geometry.visibleRows.count - 1, max(0, next))].strike }
                }
            }
            axisLabels(geometry)
        }
        // Inside the glass card the waves take nearly its full width; the axis
        // row stays 20pt in from each side as drawn.
        .padding(.horizontal, 2)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .transaction { $0.animation = nil }
    }

    /// At rest: the OI scale at each side and the strike span between them.
    /// While a strike is held: that strike's Put and Call OI either side of it.
    private func axisLabels(_ geometry: OIPlotGeometry) -> some View {
        let row = selectedStrike.flatMap { geometry.nearest(to: $0) }
        let scale = DisplayFormat.compact(geometry.maximum, precision: .whole)
        return HStack {
            Text(row.map { oiLabel($0.put, observed: $0.hasPut) } ?? scale)
                .foregroundStyle(row == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(putColor))
            Spacer(minLength: 8)
            Text(row.map { priceText($0.strike) }
                 ?? "\(priceText(geometry.domain.lowerBound)) - \(priceText(geometry.domain.upperBound))")
                .foregroundStyle(row == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Spacer(minLength: 8)
            Text(row.map { oiLabel($0.call, observed: $0.hasCall) } ?? scale)
                .foregroundStyle(row == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(callColor))
        }
        .appNumber(.caption, weight: .medium)
        .lineLimit(1)
        .padding(.horizontal, 18)
        .accessibilityHidden(true)
    }

    private func oiLabel(_ value: Double, observed: Bool) -> String {
        observed ? DisplayFormat.compact(value, precision: .whole) : "—"
    }

    private struct Marker: Identifiable {
        let id: String
        let title: String
        let prices: [Double]
        let color: Color
        let foreground: Color
        var anchor: Double { prices[0] }
    }

    private func markers(call: Bool, geometry: OIPlotGeometry) -> [Marker] {
        let walls = (call ? distribution.callWalls : distribution.putWalls).filter { geometry.domain.contains($0.strike) }
        let title = call ? "Call" : "Put"
        let color = call ? callColor : putColor
        // Dense tied walls get grouped labels; every true wall still has its own
        // rule, and the unabridged list/amounts remain immediately below the plot.
        let chunkSize = max(1, Int(ceil(Double(walls.count) / 4)))
        var result: [Marker] = stride(from: 0, to: walls.count, by: chunkSize).map { start in
            Marker(id: "wall-\(start)", title: title, prices: Array(walls[start..<min(walls.count, start + chunkSize)]).map(\.strike),
                   color: color, foreground: colorScheme == .dark ? .black : .white)
        }
        let reference = call ? holdingCost : currentPrice
        if let reference, reference.isFinite, reference > 0, geometry.domain.contains(reference) {
            result.append(Marker(id: "reference", title: L10n.text(call ? "成本" : "现价"),
                                 prices: [reference], color: call ? callColor.opacity(0.55) : currentTint, foreground: .primary))
        }
        return result.sorted { $0.anchor > $1.anchor }
    }

    private func markerLane(call: Bool, geometry: OIPlotGeometry, size: CGSize, width: CGFloat) -> some View {
        let markers = markers(call: call, geometry: geometry)
        let positions = OIPlotGeometry.labelPositions(markers.map { Double(y($0.anchor, geometry, size.height)) }, height: Double(size.height))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                let x = call ? width / 2 + 6 : size.width - width / 2 - 6
                let actualY = y(marker.anchor, geometry, size.height)
                let labelY = CGFloat(positions[index])
                let obscuredBySelection = selectedStrike.map { abs(y($0, geometry, size.height) - labelY) < 28 } ?? false
                if !obscuredBySelection && abs(labelY - actualY) > 1,
                   let frame = pillFrames["\(call)-\(marker.id)"] {
                    Path { path in
                        let edgeX = call ? CGFloat(4) : size.width - 4
                        let frames = Array(pillFrames.values)
                        for segment in OIPlotGeometry.uncoveredLineIntervals(from: actualY, to: labelY,
                            at: edgeX, vertical: true, excluding: frames) {
                            path.move(to: CGPoint(x: edgeX, y: segment.lowerBound))
                            path.addLine(to: CGPoint(x: edgeX, y: segment.upperBound))
                        }
                        for segment in OIPlotGeometry.uncoveredLineIntervals(from: edgeX, to: frame.midX,
                            at: labelY, excluding: frames) {
                            path.move(to: CGPoint(x: segment.lowerBound, y: labelY))
                            path.addLine(to: CGPoint(x: segment.upperBound, y: labelY))
                        }
                    }.stroke(marker.color.opacity(0.7), lineWidth: 1)
                }
                pill(markerLabel(marker)
                    .padding(.horizontal, 8)
                    .frame(minWidth: min(70, width), minHeight: 24), tint: marker.color)
                    .background { if !obscuredBySelection { pillFrameReader("\(call)-\(marker.id)") } }
                    .frame(maxWidth: width, alignment: call ? .leading : .trailing)
                    .position(x: x, y: labelY)
                    .opacity(obscuredBySelection ? 0 : 1)
            }
        }.allowsHitTesting(false)
    }

    /// Every wall and reference rule, from both lanes, in one layer under the
    /// pills. A rule stops short of any pill it would otherwise pass beneath,
    /// its own included, and carries on beyond it.
    private func markerRules(geometry: OIPlotGeometry, size: CGSize) -> some View {
        let rules = [false, true].flatMap { call in
            markers(call: call, geometry: geometry).flatMap { marker in
                marker.prices.map { (id: "\(call)-\(marker.id)-\($0)", y: y($0, geometry, size.height), color: marker.color) }
            }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(rules, id: \.id) { rule in
                ForEach(Array(ruleSegments(y: rule.y, from: 6, to: size.width - 6).enumerated()), id: \.offset) { _, segment in
                    glassRule(color: rule.color, width: segment.upperBound - segment.lowerBound)
                        .position(x: (segment.lowerBound + segment.upperBound) / 2, y: rule.y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// `only` names the one pill the rule must clear; otherwise it clears all.
    private func ruleSegments(y: CGFloat, from start: CGFloat, to end: CGFloat,
                              only: String? = nil) -> [ClosedRange<CGFloat>] {
        let frames = only.map { key in pillFrames[key].map { [$0] } ?? [] } ?? Array(pillFrames.values)
        guard end > start, !frames.isEmpty else { return [] }
        return OIPlotGeometry.uncoveredLineIntervals(from: start, to: end, at: y,
            excluding: frames, lineWidth: 5)
    }

    private func pillFrameReader(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PillFramesKey.self, value: [id: proxy.frame(in: .named(Self.plotSpace))])
        }
    }

    private func markerLabel(_ marker: Marker) -> some View {
        let value = marker.prices.count == 1 ? priceText(marker.anchor) : "×\(marker.prices.count)"
        let text = Text(marker.title + " ").font(Typography.text(size: markerFontSize, weight: .semibold))
            + Text(value).font(Typography.number(size: markerFontSize, weight: .bold))
        return ViewThatFits(in: .horizontal) {
            // Measure the complete localized label before constraining the bubble.
            text.fixedSize(horizontal: true, vertical: false)
            text.lineLimit(1).minimumScaleFactor(0.5)
        }
        .foregroundStyle(marker.foreground)
    }

    private func y(_ price: Double, _ geometry: OIPlotGeometry, _ height: CGFloat, clamped: Bool = true) -> CGFloat {
        let fraction = (price - geometry.domain.lowerBound) / (geometry.domain.upperBound - geometry.domain.lowerBound)
        return height * CGFloat(1 - (clamped ? min(1, max(0, fraction)) : fraction))
    }

    private func silhouette(_ vertices: [OIPlotGeometry.Vertex], side: OIPlotGeometry.Side,
                            geometry: OIPlotGeometry, size: CGSize) -> Path {
        let center = size.width / 2
        let sign: CGFloat = side == .put ? -1 : 1
        let ordered = Array(vertices.reversed())
        let slopes = Array(OIPlotGeometry.edgeSlopes(vertices).reversed())
        let points = ordered.map { vertex in
            CGPoint(x: center + sign * CGFloat(vertex.width) * (center - 2), y: y(vertex.strike, geometry, size.height, clamped: false))
        }
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        for index in 0..<(points.count - 1) {
            let start = ordered[index], end = ordered[index + 1]
            let gap = (end.strike - start.strike) / 3
            let control1 = CGPoint(x: center + sign * CGFloat(start.width + slopes[index] * gap) * (center - 2),
                                   y: y(start.strike + gap, geometry, size.height, clamped: false))
            let control2 = CGPoint(x: center + sign * CGFloat(end.width - slopes[index + 1] * gap) * (center - 2),
                                   y: y(end.strike - gap, geometry, size.height, clamped: false))
            path.addCurve(to: points[index + 1], control1: control1, control2: control2)
        }
        path.addLine(to: CGPoint(x: center, y: last.y))
        path.addLine(to: CGPoint(x: center, y: first.y))
        path.closeSubpath()
        return path
    }

    private func priceText(_ price: Double) -> String {
        OIPriceLabel.text(price, locale: appLocale)
    }

    private func selectionDescription(_ geometry: OIPlotGeometry) -> String {
        guard let selectedStrike, let row = geometry.nearest(to: selectedStrike) else { return "" }
        let call = row.hasCall ? row.call.formatted(.number.precision(.fractionLength(0)).locale(appLocale)) : "—"
        let put = row.hasPut ? row.put.formatted(.number.precision(.fractionLength(0)).locale(appLocale)) : "—"
        return L10n.text("\(priceText(row.strike)) · Call \(call) 张 · Put \(put) 张")
    }

    @ViewBuilder private func glassRule(color: Color, width: CGFloat, interactive: Bool = false) -> some View {
        let rule = Color.clear.frame(width: max(0, width), height: 5)
        if #available(iOS 26.0, *) {
            rule.glassEffect(glass(color, interactive), in: Capsule())
        } else {
            rule.background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().fill(color.opacity(0.72)) }
                .overlay { Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5) }
        }
    }

    @ViewBuilder private func pill<Content: View>(_ content: Content, tint: Color, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            // The label rides above the glass rather than inside it, where the
            // tinted material washes into the ink: black has to read as black.
            content.hidden()
                .glassEffect(glass(tint, interactive), in: Capsule())
                .overlay { content }
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .background(tint.opacity(0.62), in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.32), lineWidth: 0.5) }
        }
    }

    @available(iOS 26.0, *) private func glass(_ tint: Color, _ interactive: Bool) -> Glass {
        let glass = Glass.clear.tint(tint)
        return interactive ? glass.interactive() : glass
    }
}
