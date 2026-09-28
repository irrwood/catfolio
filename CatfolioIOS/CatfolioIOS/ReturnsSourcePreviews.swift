import SwiftUI

/// The gain-sources and loss-analysis charts, cut down to what fits on the
/// entry card: the latest headline and recent band shapes. Gains preview the
/// last two months; losses preview a year, using the detail pages' stacks.
struct ReturnsSourcePreview: Codable, Equatable {
    struct Band: Codable, Equatable {
        /// The holding's place in the palette; nil for the others.
        let colour: Int?
        /// One height per sampled day, never below nothing.
        let values: [Double]
    }

    /// Gains: the gain in the range's last day. Losses: that day's total loss.
    let headline: Double
    /// Losses only: how many holdings were below their cost that day.
    let losingCount: Int
    /// Stacked from the axis outward.
    let bands: [Band]

    /// No more points than the card is wide enough to show.
    static let samples = 48

    static func sampled(_ values: [Double], count: Int = samples) -> [Double] {
        guard values.count > count, count > 1 else { return values }
        let step = Double(values.count - 1) / Double(count - 1)
        return (0..<count).map { values[Int((Double($0) * step).rounded())] }
    }

    /// What the card draws: the three holdings that carried the most over the
    /// range, largest first, each as the running total of those before it —
    /// the first layer is the largest source alone, the last all three. The
    /// others band is left out: it is not a source the card can name.
    func sourceLayers(limit: Int = 3) -> [[Double]] {
        let ranked = bands
            .filter { $0.colour != nil }
            .map { band in (band.values, band.values.reduce(0) { $0 + max(0, $1) }) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        var layers: [[Double]] = []
        for (values, _) in ranked {
            let below = layers.last ?? Array(repeating: 0, count: values.count)
            guard below.count == values.count else { continue }
            layers.append(zip(below, values).map { $0 + max(0, $1) })
        }
        return layers
    }

    /// The gains alone, without the principal under them: on a card that
    /// short the principal would flatten every gain into a line.
    static func gains(history: HoldingValueHistory, holdings: [Holding]) -> ReturnsSourcePreview? {
        let stack = HoldingContributionStack(history: history, holdings: holdings)
        let rows = stack.window(for: .twoMonths).rows
        guard rows.count > 1, let last = rows.last else { return nil }
        let bands: [Band] = stack.bands.indices.compactMap { index in
            let colour: Int?
            switch stack.bands[index].kind {
            case .principal: return nil
            case .others: colour = nil
            case let .holding(value): colour = value
            }
            return Band(colour: colour, values: sampled(rows.map { $0.bands[index] }))
        }
        return ReturnsSourcePreview(headline: last.total - last.principal, losingCount: 0, bands: bands)
    }

    static func losses(history: HoldingValueHistory, holdings: [Holding]) -> ReturnsSourcePreview? {
        let stack = HoldingLossStack(history: history, holdings: holdings, range: .oneYear)
        guard stack.rows.count > 1, let last = stack.rows.last else { return nil }
        let bands: [Band] = stack.bands.indices.map { index in
            let colour: Int?
            switch stack.bands[index].kind {
            case .others: colour = nil
            case let .holding(value): colour = value
            }
            return Band(colour: colour, values: sampled(stack.rows.map { $0.bands[index] }))
        }
        return ReturnsSourcePreview(headline: last.totalLoss, losingCount: last.losingCount, bands: bands)
    }
}

/// Keeps the two previews and where they came from.
///
/// The cards open on what was last shown for these accounts, kept on disk, so
/// a cold launch has them at once instead of a blank card. The saved prices
/// then redraw them. Network prices are needed only when these accounts have
/// no usable saved previews or history.
@MainActor @Observable
final class ReturnsSourcePreviewStore {
    private(set) var gains: ReturnsSourcePreview?
    private(set) var losses: ReturnsSourcePreview?
    /// Figures are up and fresh prices are still coming in.
    private(set) var isRefreshing = false
    /// Nothing to show and nothing coming: no saved prices and the fetch failed.
    private(set) var isUnavailable = false

    private var shownScope: String?
    private var generation = 0

    private struct Snapshot: Codable {
        var gains: ReturnsSourcePreview?
        var losses: ReturnsSourcePreview?
    }

    private struct Saved: Codable {
        /// The scope last drawn, for the moment after launch when the
        /// accounts are not known yet.
        var latest: String?
        var scopes: [String: Snapshot] = [:]
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("returns-source-previews.json")
    }

    /// - Parameters:
    ///   - scope: the accounts and holdings the previews describe; what the
    ///     disk copy is kept under.
    ///   - revision: identifies the portfolio revision requested by the caller.
    ///   - isPortfolioLoaded: false in the moment after launch, before the
    ///     accounts and holdings are known.
    func load(scope: String, revision: String, holdings: [Holding], isPortfolioLoaded: Bool,
              fetch: (Bool) async throws -> HoldingValueHistory) async {
        generation &+= 1
        let request = generation
        isUnavailable = false
        isRefreshing = false

        // Before the portfolio has loaded, neither the accounts nor the
        // holdings are known: show what was last drawn, and run again when
        // they arrive.
        let isLoaded = isPortfolioLoaded
        if shownScope != scope {
            let saved = Self.read()
            if let snapshot = saved.scopes[scope] ?? (isLoaded ? nil : saved.latest.flatMap { saved.scopes[$0] }) {
                gains = snapshot.gains
                losses = snapshot.losses
            } else if isLoaded || shownScope != nil {
                gains = nil
                losses = nil
            }
            if isLoaded { shownScope = scope }
        }
        guard isLoaded, !holdings.isEmpty else { return }

        if let cached = try? await fetch(true), !Task.isCancelled, request == generation {
            publish(cached, holdings: holdings, scope: scope)
        }
        guard !Task.isCancelled, request == generation else { return }
        if gains != nil && losses != nil { return }

        isRefreshing = true
        defer { if request == generation { isRefreshing = false } }
        do {
            let fresh = try await fetch(false)
            guard !Task.isCancelled, request == generation else { return }
            publish(fresh, holdings: holdings, scope: scope)
        } catch {
            guard !Task.isCancelled, request == generation else { return }
            if gains == nil && losses == nil { isUnavailable = true }
        }
    }

    private func publish(_ history: HoldingValueHistory, holdings: [Holding], scope: String) {
        guard history.rows.count > 1 else { return }
        let nextGains = ReturnsSourcePreview.gains(history: history, holdings: holdings)
        let nextLosses = ReturnsSourcePreview.losses(history: history, holdings: holdings)
        guard nextGains != gains || nextLosses != losses else { return }
        withAnimation(.smooth(duration: 0.35)) {
            gains = nextGains
            losses = nextLosses
        }
        var saved = Self.read()
        saved.scopes[scope] = Snapshot(gains: nextGains, losses: nextLosses)
        saved.latest = scope
        // A handful of account selections is plenty; drop the rest.
        if saved.scopes.count > 6 { saved.scopes = saved.scopes.filter { $0.key == scope } }
        Self.write(saved)
    }

    private static func read() -> Saved {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return Saved() }
        return (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved()
    }

    private static func write(_ value: Saved) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The two entry cards, side by side, each opening its chart page.
struct ReturnsSourceCards: View {
    @Environment(AppModel.self) private var model
    let store: ReturnsSourcePreviewStore

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            NavigationLink { ReturnsChartPage(chart: .contributors) } label: {
                ReturnsSourceCard(chart: .contributors, preview: store.gains,
                                  isRefreshing: store.isRefreshing, isUnavailable: store.isUnavailable)
            }
            .accessibilityIdentifier("performance.chart.contributors")
            NavigationLink { ReturnsChartPage(chart: .losses) } label: {
                ReturnsSourceCard(chart: .losses, preview: store.losses,
                                  isRefreshing: store.isRefreshing, isUnavailable: store.isUnavailable)
            }
            .accessibilityIdentifier("performance.chart.losses")
        }
        .buttonStyle(.plain)
    }
}

/// Figma 487:5328 (dark) and 487:5331 (light): one tile per chart, the
/// icon and chevron on top, the title over the amount at the foot, and a
/// blur that deepens toward the foot so the text reads over the curves. Gains are blue and rise
/// from the bottom edge; losses are purple and hang from the top edge. Each
/// has a blurred glow set in the design's own place, over liquid glass.
private struct ReturnsSourceCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let chart: ReturnsChartDestination
    let preview: ReturnsSourcePreview?
    let isRefreshing: Bool
    let isUnavailable: Bool

    static let height: CGFloat = 173
    static let radius: CGFloat = 24
    /// How far below the card's top edge the gains may rise — clear of the
    /// label — and, mirrored, how far above the bottom edge losses may hang.
    static let chartInset: CGFloat = 38

    private var isLosses: Bool { chart == .losses }
    private var palette: ReturnsSourcePalette { ReturnsSourcePalette(isLosses: isLosses, scheme: colorScheme) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let clearPoint = SIMD2<Float>(isLosses ? (colorScheme == .light ? 0.382 : 0.575) : 0.364,
                                      isLosses ? (colorScheme == .light ? 0.439 : 0.503) : 0.587)
        let blurredPoint = SIMD2<Float>(isLosses ? (colorScheme == .light ? 0.139 : 0.176) : 0.147,
                                        isLosses && colorScheme == .dark ? 1.032 : 1)
        VStack(alignment: .leading, spacing: 0) {
            topRow
            Spacer(minLength: 0)
            // Figma's 12pt is measured between trimmed text boxes (cap
            // height to baseline); SwiftUI's line boxes add about 8pt of
            // their own between the two, and 4pt under the figure.
            VStack(alignment: .leading, spacing: 4) {
                Text(chart.title)
                    .font(Typography.text(size: 14, weight: .bold))
                    .tracking(0.56)
                    .textCase(.uppercase)
                    .foregroundStyle(palette.title)
                    .opacity(colorScheme == .dark ? (isLosses ? 0.8 : 0.4) : 1)
                    .blendMode(colorScheme == .dark ? .plusLighter : .normal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                headline
            }
        }
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .background {
            ZStack(alignment: .topLeading) {
                palette.fill
                artwork
            }
            .drawingGroup()
            .visualEffect { content, proxy in
                content.layerEffect(
                    Shader(function: ShaderFunction(library: .default, name: "returnsProgressiveBlur"), arguments: [
                        .float2(proxy.size),
                        .float2(clearPoint.x, clearPoint.y),
                        .float2(blurredPoint.x, blurredPoint.y),
                        .float(18.1)
                    ]),
                    maxSampleOffset: CGSize(width: 18.1, height: 18.1)
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(shape)
        .modifier(ReturnsSourceGlass(shape: shape))
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    private var artwork: some View {
        ZStack(alignment: .topLeading) {
            glows(abovePlot: false)
            ReturnsSourceMiniChart(preview: preview, hangsDown: isLosses, palette: palette)
                .padding(isLosses ? .bottom : .top, Self.chartInset)
        }
    }

    /// Blurred ellipses at the design's own offsets from the card's corner.
    private func glows(abovePlot: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(palette.glows.filter { $0.abovePlot == abovePlot }.enumerated()), id: \.offset) { _, glow in
                Ellipse()
                    .fill(glow.color)
                    .frame(width: glow.frame.width, height: glow.frame.height)
                    .blur(radius: 33)
                    .offset(x: glow.frame.minX, y: glow.frame.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            icon
            Spacer(minLength: 4)
            Image("SettingsChevron")
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(height: 24)
    }

    /// The Figma frame's own glyphs, in white: a mug for gains, a rounded
    /// down-triangle for losses.
    private var icon: some View {
        Image(isLosses ? "ReturnsLossAnalysis" : "ReturnsGainSources")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: isLosses ? 14.3 : 18, height: isLosses ? 12.2 : 16)
            .frame(width: isLosses ? 17 : 18, height: 16)
    }

    @ViewBuilder
    private var headline: some View {
        if let preview {
            // Signed, as in the dark frame: a loss reads as money lost.
            let amount = isLosses ? -abs(preview.headline) : preview.headline
            Text(DisplayFormat.money(amount, signed: amount != 0, fractionDigits: 0))
                .font(Typography.number(size: 20, weight: .semibold))
                .foregroundStyle(palette.amount)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: amount))
                .refreshGlow(isActive: isRefreshing)
        } else {
            Text(isUnavailable ? "—" : " ")
                .font(Typography.number(size: 20, weight: .semibold))
                .foregroundStyle(palette.amount.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    if !isUnavailable {
                        Capsule().fill(Color.white.opacity(0.15)).frame(width: 96, height: 18)
                    }
                }
        }
    }

    private var accessibilityValue: String {
        guard isLosses, let preview else { return "" }
        return preview.losingCount == 0
            ? L10n.text("没有持仓低于成本")
            : L10n.text("\(preview.losingCount) 只低于成本")
    }
}

/// The paints of Figma 487:5328 / 487:5331, per chart and scheme.
private struct ReturnsSourcePalette {
    struct Glow {
        let color: Color
        /// Offset from the card's top-left corner, and size, before the blur.
        let frame: CGRect
        let abovePlot: Bool
    }

    /// The card's own fill under the glows: clear in the dark (the glass and
    /// the glows carry it), the design's gradient at 86% in the light.
    let fill: LinearGradient
    /// The title over the amount: the chart's colour in the dark, white on
    /// the light scheme's coloured cards.
    let title: Color
    let amount: Color
    let solidLayerColors: [Color]?
    let glows: [Glow]
    /// Each layer: this colour at the curve, fading to `curveFade` at its base.
    let curve: Color
    let curveFade: Color
    let stroke: Color
    /// The whole layer — fill and edge — is set at this opacity.
    let layerOpacity: Double
    let backLayerOpacity: Double
    let frontLayerOpacity: Double
    let backLayerColor: Color?
    let strokeOpacity: Double
    let strokeWidth: CGFloat

    private static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255).opacity(alpha)
    }

    init(isLosses: Bool, scheme: ColorScheme) {
        amount = scheme == .light ? Self.rgb(isLosses ? 0x6836B1 : 0x005CA7) : .white
        // Front (bottom) to back (top): the daylight waves become whiter downward.
        solidLayerColors = isLosses ? nil : scheme == .light
            ? [.white, Self.rgb(0xA7D7FF), Self.rgb(0x56AFF8)]
            : [Self.rgb(0x0489F7), Self.rgb(0x0062B4), Self.rgb(0x078AF7)]
        backLayerOpacity = scheme == .dark ? (isLosses ? 0.3 : 0.4) : 1
        frontLayerOpacity = isLosses && scheme == .light ? 0.5 : 1
        backLayerColor = isLosses && scheme == .light ? Self.rgb(0xAD76FF) : nil
        strokeOpacity = scheme == .dark ? 0.3 : 0.7
        strokeWidth = scheme == .dark ? 1 : 1.5
        switch (isLosses, scheme == .dark) {
        case (false, true):
            fill = LinearGradient(stops: [
                .init(color: Self.rgb(0x004F74, 0.8), location: 0.04445),
                .init(color: Color.black.opacity(0.8), location: 0.67584)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            title = .white
            glows = [Glow(color: Self.rgb(0x004D8C), frame: CGRect(x: -99, y: 93, width: 224, height: 148), abovePlot: false)]
            curve = Self.rgb(0x0189F8); curveFade = Self.rgb(0x0189F8, 0)
            stroke = .clear; layerOpacity = 1
        case (false, false):
            fill = LinearGradient(stops: [
                .init(color: Self.rgb(0x2498F6, 0.8), location: 0.04445),
                .init(color: Self.rgb(0x71BDF9, 0.8), location: 0.67584)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            title = Self.rgb(0x2FA2FF)
            glows = [Glow(color: Self.rgb(0xFDFEFF), frame: CGRect(x: -98, y: 94, width: 224, height: 148), abovePlot: true)]
            curve = .white; curveFade = .white
            stroke = .clear; layerOpacity = 1
        case (true, true):
            fill = LinearGradient(stops: [
                .init(color: Self.rgb(0x2B006B, 0.9), location: 0.07168),
                .init(color: Color.black.opacity(0.9), location: 0.605)
            ], startPoint: .bottomLeading, endPoint: .topTrailing)
            title = Self.rgb(0xB355FF)
            glows = [Glow(color: Self.rgb(0x42197F), frame: CGRect(x: -119, y: -74, width: 264, height: 165), abovePlot: false)]
            curve = Self.rgb(0x7D25FF); curveFade = Self.rgb(0xAC74FF, 0)
            stroke = .clear; layerOpacity = 1
        case (true, false):
            fill = LinearGradient(colors: [.white, .white],
                                  startPoint: .top, endPoint: .bottom)
            title = Self.rgb(0xB355FF)
            glows = [Glow(color: Self.rgb(0x9651FF), frame: CGRect(x: -100, y: -91, width: 222, height: 165), abovePlot: false)]
            curve = Self.rgb(0x7D25FF); curveFade = Self.rgb(0xAC74FF)
            stroke = .clear; layerOpacity = 0.4
        }
    }
}

/// Apply native liquid glass to the complete card, never to its chart layers.
private struct ReturnsSourceGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(colorScheme == .dark ? .clear.interactive() : .regular.interactive(), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// The three largest sources as layered areas, with no axes: the back layer
/// is all three together, the front one the largest source alone. Each
/// fades from its curve toward its base and carries a thin edge on the curve.
private struct ReturnsSourceMiniChart: View {
    let preview: ReturnsSourcePreview?
    let hangsDown: Bool
    let palette: ReturnsSourcePalette

    /// Few enough points that each turn of the curve can be rounded off, as
    /// in the design, without the line going soft.
    private var sampleCount: Int { 14 }

    var body: some View {
        let layers = (preview?.sourceLayers() ?? []).map { ReturnsSourcePreview.sampled($0, count: sampleCount) }
        if let count = layers.first?.count, count > 1,
           let peak = layers.last?.max(), peak > 0.5 {
            Canvas { context, size in
                // Back to front: all three, then two, then the largest alone.
                for (index, layer) in layers.enumerated().reversed() {
                    // The day gain halo sits between the middle and front
                    // curves; the white foreground remains clean above it.
                    if index == 0 {
                        for glow in palette.glows where glow.abovePlot {
                            context.drawLayer { glowContext in
                                glowContext.addFilter(.blur(radius: 33))
                                glowContext.fill(Path(ellipseIn: glow.frame.offsetBy(dx: 0, dy: -ReturnsSourceCard.chartInset)),
                                                 with: .color(glow.color))
                            }
                        }
                    }
                    let curve = curvePath(layer, peak: peak, size: size)
                    var area = curve
                    let edge: CGFloat = hangsDown ? 0 : size.height
                    area.addLine(to: CGPoint(x: size.width, y: edge))
                    area.addLine(to: CGPoint(x: 0, y: edge))
                    area.closeSubpath()
                    let bounds = area.boundingRect
                    // From the curve's furthest reach to the base it grows from.
                    let start = CGPoint(x: 0, y: hangsDown ? bounds.maxY : bounds.minY)
                    let end = CGPoint(x: 0, y: edge)
                    let solidColor = palette.solidLayerColors.map { $0[min(index, $0.count - 1)] }
                        ?? (index == layers.count - 1 ? palette.backLayerColor : nil)
                    context.drawLayer { layerContext in
                        layerContext.opacity = index == 0 ? palette.frontLayerOpacity
                            : palette.layerOpacity * (index == layers.count - 1 ? palette.backLayerOpacity : 1)
                        layerContext.fill(area, with: .linearGradient(
                            Gradient(colors: [solidColor ?? palette.curve, solidColor ?? palette.curveFade]),
                            startPoint: start, endPoint: end))
                    }
                    // The edge stands clear of the fill's opacity: at the
                    // design's 30% a hairline all but vanished on the phone.
                    context.stroke(curve, with: .color(palette.stroke.opacity(palette.strokeOpacity)),
                                   style: StrokeStyle(lineWidth: palette.strokeWidth, lineCap: .round, lineJoin: .round))
                }
            }
            .transition(.opacity)
        } else if preview != nil {
            // Nothing to stack — no holding below cost all year: the axis
            // alone, where the layers would start.
            Rectangle()
                .fill(palette.stroke.opacity(0.4))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: hangsDown ? .top : .bottom)
        }
    }

    /// Round across each complete sample interval. Shared midpoint weights
    /// keep the stacked layers ordered while softening narrow peaks and dips.
    private func curvePath(_ values: [Double], peak: Double, size: CGSize) -> Path {
        guard values.count > 1 else { return Path() }
        // Broaden the bend over neighboring samples instead of increasing a
        // radius already capped by the narrow spacing in these small cards.
        let softened = values.indices.map { index in
            guard index > 0, index < values.count - 1 else { return values[index] }
            return values[index - 1] * 0.25 + values[index] * 0.5 + values[index + 1] * 0.25
        }
        let points = softened.enumerated().map { day, value -> CGPoint in
            let x = size.width * CGFloat(day) / CGFloat(values.count - 1)
            let depth = size.height * CGFloat(value / peak)
            return CGPoint(x: x, y: hangsDown ? depth : size.height - depth)
        }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        var path = Path()
        path.move(to: points[0])
        path.addLine(to: midpoint(points[0], points[1]))
        for index in 1..<(points.count - 1) {
            path.addQuadCurve(to: midpoint(points[index], points[index + 1]), control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
