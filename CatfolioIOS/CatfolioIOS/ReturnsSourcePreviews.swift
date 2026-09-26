import SwiftUI

/// The gain-sources and loss-analysis charts, cut down to what fits on the
/// entry card: the headline figure and the bands' shapes over the range each
/// page opens on. Built from the same stacks the pages draw, so the card and
/// the page agree.
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
        let rows = stack.window(for: .yearToDate).rows
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
/// then redraw them, and fresh prices are fetched once per portfolio change —
/// not on every visit to the tab. Coming back from a chart page redraws from
/// the saved prices, which that page has just brought up to date.
@MainActor @Observable
final class ReturnsSourcePreviewStore {
    private(set) var gains: ReturnsSourcePreview?
    private(set) var losses: ReturnsSourcePreview?
    /// Figures are up and fresh prices are still coming in.
    private(set) var isRefreshing = false
    /// Nothing to show and nothing coming: no saved prices and the fetch failed.
    private(set) var isUnavailable = false

    private var shownScope: String?
    private var freshRevision: String?
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
    ///   - revision: changes whenever the portfolio does; fresh prices are
    ///     fetched once for each.
    ///   - isPortfolioLoaded: false in the moment after launch, before the
    ///     accounts and holdings are known.
    func load(scope: String, revision: String, holdings: [Holding], isPortfolioLoaded: Bool,
              fetch: (Bool) async throws -> HoldingValueHistory) async {
        generation &+= 1
        let request = generation
        isUnavailable = false

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
        guard !Task.isCancelled, request == generation, freshRevision != revision else { return }

        isRefreshing = true
        defer { if request == generation { isRefreshing = false } }
        do {
            let fresh = try await fetch(false)
            guard !Task.isCancelled, request == generation else { return }
            publish(fresh, holdings: holdings, scope: scope)
            freshRevision = revision
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
        HStack(alignment: .top, spacing: SettingsTemplate.tileSpacing) {
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

/// Figma 448:5900: a tinted liquid-glass tile per chart. Gains rise from the
/// bottom edge with the label on top; losses hang from the top edge with the
/// label underneath, so the two read as a mirrored pair.
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
        VStack(alignment: .leading, spacing: 12) {
            if isLosses {
                Spacer(minLength: 0)
                headline
                label
            } else {
                label
                headline
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .background {
            ReturnsSourceMiniChart(preview: preview, hangsDown: isLosses, palette: palette)
                .padding(isLosses ? .bottom : .top, Self.chartInset)
        }
        .clipShape(shape)
        .background { ReturnsSourceGlass(tint: palette.card, shape: shape) }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    private var label: some View {
        HStack(spacing: 4) {
            icon
            Text(chart.title)
                .appCaps(.footnote, weight: .bold)
                .textCase(.uppercase)
                .foregroundStyle(palette.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private var icon: some View {
        if isLosses {
            Image(systemName: "arrowtriangle.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.label)
                .frame(width: 24, height: 24)
                .background(Circle().fill(palette.label.opacity(0.1)))
        } else {
            Image(systemName: "mug.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.label)
                .frame(width: 18, height: 16)
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let preview {
            // The label says which way the money went; the figure is its size.
            let amount = abs(preview.headline)
            Text(DisplayFormat.money(amount, fractionDigits: 0))
                .appNumber(.heading, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: amount))
                .refreshGlow(isActive: isRefreshing)
        } else {
            Text(isUnavailable ? "—" : " ")
                .appNumber(.heading, weight: .medium)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    if !isUnavailable {
                        Capsule().fill(Color.primary.opacity(0.07)).frame(width: 96, height: 18)
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

/// The card's colours from the Figma frame: green for gains, gold for losses.
private struct ReturnsSourcePalette {
    let label: Color
    let card: Color
    let curve: Color
    let curveFade: Color

    init(isLosses: Bool, scheme: ColorScheme) {
        let dark = scheme == .dark
        if isLosses {
            label = dark ? Color(red: 0.922, green: 0.753, blue: 0) : Color(red: 0.62, green: 0.49, blue: 0)
            card = Color(red: 0.686, green: 0.561, blue: 0).opacity(0.2)
            curve = Color(red: 0.863, green: 0.776, blue: 0.027)
            curveFade = curve
        } else {
            label = dark ? Color(red: 0, green: 0.686, blue: 0) : Color(red: 0, green: 0.56, blue: 0)
            card = Color(red: 0, green: 0.686, blue: 0).opacity(0.2)
            curve = dark ? Color(red: 0, green: 1, blue: 0) : Color(red: 0, green: 0.8, blue: 0)
            curveFade = Color(red: 0.494, green: 1, blue: 0.494)
        }
    }
}

/// Liquid glass on iOS 26, tinted with the card's colour; a tinted material
/// before it.
private struct ReturnsSourceGlass: View {
    let tint: Color
    let shape: RoundedRectangle

    var body: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(tint))
        }
    }
}

/// The three largest sources as layered areas, with no axes: the back layer
/// is all three together, faint; the front one the largest source alone.
private struct ReturnsSourceMiniChart: View {
    let preview: ReturnsSourcePreview?
    let hangsDown: Bool
    let palette: ReturnsSourcePalette

    /// Few enough points that each turn of the curve can be rounded off, as
    /// in the design, without the line going soft.
    private static let points = 14

    var body: some View {
        let layers = (preview?.sourceLayers() ?? []).map { ReturnsSourcePreview.sampled($0, count: Self.points) }
        if let count = layers.first?.count, count > 1,
           let peak = layers.last?.max(), peak > 0.5 {
            Canvas { context, size in
                // Back to front: all three, then two, then the largest alone.
                for (depth, layer) in layers.enumerated().reversed() {
                    let isBack = depth == layers.count - 1 && layers.count > 1
                    let area = path(layer, peak: peak, size: size)
                    // Full colour at the layer's peak, down to a tenth a
                    // half the chart's height beyond it, most of it early, as in
                    // the design — so the low stretches stay dark.
                    let top = area.boundingRect
                    let fade = size.height * 0.5
                    let start = CGPoint(x: 0, y: hangsDown ? top.maxY : top.minY)
                    let end = CGPoint(x: 0, y: hangsDown ? top.maxY - fade : top.minY + fade)
                    context.drawLayer { layerContext in
                        layerContext.opacity = isBack ? 0.2 : 1
                        layerContext.fill(area, with: .linearGradient(
                            Gradient(stops: [
                                .init(color: palette.curve, location: 0),
                                .init(color: palette.curve.opacity(0.4), location: 0.3),
                                .init(color: palette.curveFade.opacity(0.1), location: 1),
                            ]),
                            startPoint: start, endPoint: end))
                    }
                }
            }
            .transition(.opacity)
        } else if preview != nil {
            // Nothing to stack — no holding below cost all year: the axis
            // alone, where the layers would start.
            Rectangle()
                .fill(palette.label.opacity(0.3))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: hangsDown ? .top : .bottom)
        }
    }

    /// The layer's outline with each corner rounded: a quadratic through the
    /// midpoints, so the line passes near every day without overshooting.
    private func path(_ values: [Double], peak: Double, size: CGSize) -> Path {
        let count = values.count
        let points = values.enumerated().map { day, value -> CGPoint in
            let x = size.width * CGFloat(day) / CGFloat(count - 1)
            let depth = size.height * CGFloat(value / peak)
            return CGPoint(x: x, y: hangsDown ? depth : size.height - depth)
        }
        let edge: CGFloat = hangsDown ? 0 : size.height
        var path = Path()
        path.move(to: CGPoint(x: 0, y: edge))
        path.addLine(to: points[0])
        for index in 1..<count {
            let previous = points[index - 1], point = points[index]
            let middle = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            path.addQuadCurve(to: middle, control: previous)
        }
        path.addLine(to: points[count - 1])
        path.addLine(to: CGPoint(x: size.width, y: edge))
        path.closeSubpath()
        return path
    }
}
