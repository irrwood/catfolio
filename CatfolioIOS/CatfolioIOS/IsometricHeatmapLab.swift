import SwiftUI

/// An experiment: the holdings heatmap laid flat on an isometric plane,
/// drifting slowly toward the viewer, with a progressive blur at the top and
/// the bottom (Figma `304:10653`).
///
/// One treemap of the portfolio, at the drawing's size, is rendered once into
/// a texture. Every other row of the texture is shifted by half a treemap, so
/// the plane tiles without the repeat lining up, and the plane slides by
/// exactly one texture height, so the loop has no seam. Per frame the only
/// work is moving one image, which is also what lets the blur be built from
/// several copies of it.
struct IsometricHeatmapLabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var texture: Image?

    var body: some View {
        let tiles = IsometricHeatmapLabStyle.tiles(for: model.holdings, dailyChanges: model.holdingDailyChanges)

        GeometryReader { proxy in
            let hero = CGSize(width: proxy.size.width, height: IsometricHeatmapLabStyle.heroHeight)
            ZStack(alignment: .top) {
                Color.black
                if let texture {
                    IsometricHeatmapPlane(texture: texture, hero: hero, isMoving: !reduceMotion)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .task(id: tiles) {
            let renderer = ImageRenderer(content: IsometricHeatmapTexture(tiles: tiles))
            renderer.scale = displayScale
            renderer.isOpaque = true
            guard let image = renderer.uiImage else { return }
            withAnimation(.easeOut(duration: 0.6)) { texture = Image(uiImage: image) }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("等距热力图"))
    }
}

enum IsometricHeatmapLabStyle {
    /// The drawing's frame is 402pt wide; the hero keeps its height on
    /// narrower phones rather than scaling with the width.
    static let heroHeight: CGFloat = 480
    /// One treemap, the size of the drawing's heatmap.
    static let cell = CGSize(width: 520, height: 320)
    static let gap: CGFloat = 2.7
    static let cornerRadius: CGFloat = 5.4
    static let borderWidth: CGFloat = 0.675
    /// Points per second along the plane's depth axis.
    static let speed: Double = 10

    /// The texture: the treemap, and below it the same treemap shifted by
    /// half its width.
    static var textureSize: CGSize { CGSize(width: cell.width, height: cell.height * 2) }

    /// Scale Y to cos 30°, skew X by 30°, rotate −30°: the drawing's
    /// isometric projection, in that order.
    static let projection: CGAffineTransform = {
        let scale = CGAffineTransform(scaleX: 1, y: 0.87)
        let skew = CGAffineTransform(a: 1, b: 0, c: tan(.pi / 6), d: 1, tx: 0, ty: 0)
        let rotation = CGAffineTransform(rotationAngle: -.pi / 6)
        return scale.concatenating(skew).concatenating(rotation)
    }()

    /// The plane window, in plane points, whose projection covers the whole
    /// hero plus the reach of the blur.
    static func planeSize(covering hero: CGSize) -> CGSize {
        let inverse = projection.inverted()
        let corners = [
            CGPoint(x: -hero.width / 2, y: -hero.height / 2),
            CGPoint(x: hero.width / 2, y: -hero.height / 2),
            CGPoint(x: -hero.width / 2, y: hero.height / 2),
            CGPoint(x: hero.width / 2, y: hero.height / 2),
        ].map { $0.applying(inverse) }
        let margin: CGFloat = 60
        let width = 2 * (corners.map { abs($0.x) }.max() ?? 0) + margin * 2
        let height = 2 * (corners.map { abs($0.y) }.max() ?? 0) + margin * 2
        return CGSize(width: ceil(width), height: ceil(height))
    }

    /// Places the plane window's centre on the hero's centre.
    static func transform(plane: CGSize, hero: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: -plane.width / 2, y: -plane.height / 2)
            .concatenating(projection)
            .concatenating(CGAffineTransform(translationX: hero.width / 2, y: hero.height / 2))
    }

    struct Tile: Identifiable, Hashable {
        let id: Int
        let ticker: String
        let change: Double?
        /// How far a change has to go before it takes the strongest colour.
        let strongChange: Double
        let frame: CGRect
    }

    /// One treemap of the portfolio, coloured by today's change.
    ///
    /// Where no holding has a change for today — a closed market, or a
    /// portfolio that has not been priced yet — the holding-period return
    /// colours it instead, on a scale ten times wider.
    static func tiles(for holdings: [Holding], dailyChanges: [String: Double]) -> [Tile] {
        let priced = holdings
            .filter { $0.marketValue.isFinite && $0.marketValue > 0 }
            .sorted { $0.marketValue > $1.marketValue }
            .prefix(40)
        let today = priced.map { $0.todayChangePercent ?? dailyChanges[$0.ticker.uppercased()] }
        let usesToday = today.contains { $0 != nil }
        var items = zip(priced, today).map { holding, change in
            (ticker: holding.ticker, weight: holding.marketValue,
             change: usesToday ? change : (holding.unrealizedPercent.isFinite ? holding.unrealizedPercent : nil))
        }
        var strongChange = usesToday ? 2.0 : 20.0
        if items.isEmpty {
            items = sample
            strongChange = 2
        }
        let placements = HoldingsTreemapLayout.layout(
            items: items.map { HoldingsTreemapLayout.Item(ticker: $0.ticker, weight: $0.weight) },
            in: CGRect(origin: .zero, size: cell)
        )
        return placements.map { placement in
            let item = items[placement.sourceIndex]
            return Tile(
                id: placement.sourceIndex,
                ticker: item.ticker,
                change: item.change,
                strongChange: strongChange,
                frame: placement.frame.insetBy(dx: gap / 2, dy: gap / 2)
            )
        }
    }

    /// Shown when there are no holdings yet, so the experiment still has
    /// something to move.
    private static let sample: [(ticker: String, weight: Double, change: Double?)] = [
        ("NVDA", 18, 2.21), ("AAPL", 14, 1.12), ("MSFT", 12, 0.42), ("AMZN", 9, -0.64),
        ("GOOGL", 8, 1.38), ("META", 7, -2.35), ("TSLA", 6, -1.48), ("AVGO", 5, 3.02),
        ("TSM", 4.5, 0.08), ("BRK.B", 4, -0.21), ("JPM", 3.6, 0.55), ("LLY", 3.2, -1.05),
        ("V", 3, 0.01), ("COST", 2.6, -0.33), ("NFLX", 2.4, 1.64), ("AMD", 2.2, -2.9),
        ("ASML", 2, 0.73), ("ORCL", 1.8, -0.02), ("XOM", 1.6, 0), ("KO", 1.4, -0.4),
    ]

    static func fill(for tile: Tile) -> Color {
        pastelFill(change: tile.change, strongChange: tile.strongChange)
    }

    /// The drawing's four steps each way, and white for flat. `strongChange`
    /// is how far a change has to go before it takes the strongest colour.
    static func pastelFill(change: Double?, strongChange: Double) -> Color {
        guard let change, abs(change) >= 0.005 else { return .white }
        let step = abs(change) / strongChange
        let hex: UInt32
        if change > 0 {
            hex = step >= 1 ? 0x89D663 : step >= 0.5 ? 0xA6E585 : step >= 0.15 ? 0xD0F6B7 : 0xEDFFE0
        } else {
            hex = step >= 1 ? 0xFF889E : step >= 0.5 ? 0xFF97A8 : step >= 0.15 ? 0xFFD3D9 : 0xFFEFF1
        }
        return Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private struct IsometricHeatmapPlane: View {
    let texture: Image
    let hero: CGSize
    let isMoving: Bool

    var body: some View {
        let period = IsometricHeatmapLabStyle.textureSize.height

        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isMoving)) { context in
            let travel = isMoving
                ? (context.date.timeIntervalSinceReferenceDate * IsometricHeatmapLabStyle.speed)
                    .truncatingRemainder(dividingBy: Double(period))
                : 0
            let surface = IsometricHeatmapSurface(texture: texture, hero: hero, travel: CGFloat(travel))
            IsometricEdgeEffects(bands: .lab, size: hero, ground: .black, glows: true) { layer in
                surface.liveBlur(for: layer, bands: .lab)
            }
        }
    }
}

/// The black ground and the projected plane.
private struct IsometricHeatmapSurface: View {
    let texture: Image
    let hero: CGSize
    let travel: CGFloat

    var body: some View {
        let plane = IsometricHeatmapLabStyle.planeSize(covering: hero)
        let tile = IsometricHeatmapLabStyle.textureSize

        ZStack(alignment: .topLeading) {
            Color.black
            texture
                .resizable(resizingMode: .tile)
                .frame(width: plane.width, height: plane.height + tile.height)
                // Toward the viewer: down the plane, which projects to down-right.
                .offset(y: travel - tile.height)
                .frame(width: plane.width, height: plane.height, alignment: .top)
                .clipped()
                .transformEffect(IsometricHeatmapLabStyle.transform(plane: plane, hero: hero))
        }
        .frame(width: hero.width, height: hero.height, alignment: .topLeading)
        .clipped()
    }
}

/// Where the plane blurs, fades and glows, in the coordinates of the view it
/// is drawn in.
///
/// Blur rises toward the top edge and toward the bottom edge, along two
/// tilted bands (the drawing's bands are rotated 3.79° and 6.62°). Below the
/// bottom band the plane fades out to the ground.
struct IsometricBands {
    struct Blur {
        /// Fully blurred at `full`, clear at `clear` — y at the horizontal
        /// centre, in either order.
        var full: CGFloat
        var clear: CGFloat
        var maximum: CGFloat
        var degrees: Double
    }

    /// Light from the plane, added on top: blurred copies of the surface
    /// added with `plusLighter`, so the glow is always the colour of the tiles
    /// it comes from.
    struct Glow {
        let radius: CGFloat
        let saturation: Double
        /// (y, strength) pairs, linearly interpolated, along the bottom band's
        /// tilt.
        let profile: [(y: CGFloat, strength: CGFloat)]
    }

    var top: Blur
    var bottom: Blur
    var fade: (clear: CGFloat, full: CGFloat)
    var glows: [Glow]
    /// Scales every effect at once; zero leaves the plane untouched.
    var strength: CGFloat = 1

    /// The blurred copies. Copy `k` shows where the wanted blur has passed
    /// the copy below it, so any point is a cross-fade between the two copies
    /// whose radii bracket the blur it wants.
    static let radii: [CGFloat] = [2, 4.5, 8, 12.5, 18]

    /// The lab page: a 480pt hero under an inline bar.
    static let lab = IsometricBands(
        top: Blur(full: 6, clear: 122, maximum: 18, degrees: 3.79),
        bottom: Blur(full: 330, clear: 180, maximum: 16, degrees: 6.62),
        fade: (clear: 200, full: 345),
        glows: [
            // A tight bloom into the gutters between tiles.
            Glow(radius: 8, saturation: 1.2, profile: [(0, 0.18), (120, 0.08), (240, 0.08), (320, 0)]),
            // A wide haze that carries the colour past the fade onto the ground.
            Glow(radius: 40, saturation: 1.8, profile: [(0, 0.2), (120, 0.04), (210, 0.06), (290, 0.32), (350, 0.2), (420, 0)]),
        ]
    )

    /// Room above and below, so a rotated gradient still covers the view.
    private static let overscan: CGFloat = 60

    func blurMask(layer: Int, size: CGSize) -> some View {
        let lower = layer == 0 ? 0 : Self.radii[layer - 1]
        let upper = Self.radii[layer]
        let strength = strength
        func alpha(_ sigma: CGFloat) -> CGFloat { min(1, max(0, (sigma - lower) / (upper - lower))) * strength }
        return ZStack {
            Self.band(size: size, degrees: top.degrees) { y in
                alpha(top.maximum * (1 - Self.smoothstep(top.full, top.clear, y)))
            }
            Self.band(size: size, degrees: bottom.degrees) { y in
                alpha(bottom.maximum * (1 - Self.smoothstep(bottom.full, bottom.clear, y)))
            }
        }
    }

    func fadeMask(size: CGSize) -> some View {
        Self.band(size: size, degrees: bottom.degrees) { y in
            Self.smoothstep(fade.clear, fade.full, y) * strength
        }
    }

    func glowMask(_ glow: Glow, size: CGSize) -> some View {
        Self.band(size: size, degrees: bottom.degrees) { y in
            Self.interpolate(glow.profile, at: y) * strength
        }
    }

    /// A vertical gradient whose opacity at y is `opacity(y)`, rotated about
    /// the view's centre.
    static func band(
        size: CGSize,
        degrees: Double,
        opacity: (CGFloat) -> CGFloat
    ) -> some View {
        let height = size.height + overscan * 2
        let samples = 40
        let stops = (0...samples).map { index in
            let location = CGFloat(index) / CGFloat(samples)
            let y = location * height - overscan
            return Gradient.Stop(color: .white.opacity(opacity(y)), location: location)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .frame(width: size.width * 1.6, height: height)
            .rotationEffect(.degrees(degrees))
            .frame(width: size.width, height: size.height)
    }

    /// Hermite ease between `edge0` and `edge1`, in either direction.
    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    static func interpolate(_ profile: [(y: CGFloat, strength: CGFloat)], at y: CGFloat) -> CGFloat {
        guard let first = profile.first, let last = profile.last else { return 0 }
        if y <= first.y { return first.strength }
        if y >= last.y { return last.strength }
        for (a, b) in zip(profile, profile.dropFirst()) where y <= b.y {
            return a.strength + (b.strength - a.strength) * (y - a.y) / (b.y - a.y)
        }
        return last.strength
    }
}

/// Which copy of the surface a layer of `IsometricEdgeEffects` wants: the
/// sharp one, one blurred by `IsometricBands.radii[k]`, or one blurred and
/// saturated for `IsometricBands.glows[k]`.
enum IsometricLayer: Hashable {
    case sharp
    case blur(Int)
    case glow(Int)
}

/// A surface with the bands applied: the blurred copies, the fade to the
/// ground, and — on a dark ground, where added light shows — the glow.
///
/// The surface is asked for by layer, so a caller can hand over copies it
/// blurred ahead of time instead of blurring every frame; `liveBlur(for:)`
/// is the simple way to answer.
struct IsometricEdgeEffects<Surface: View>: View {
    let bands: IsometricBands
    let size: CGSize
    let ground: Color
    let glows: Bool
    @ViewBuilder let surface: (IsometricLayer) -> Surface

    var body: some View {
        ZStack(alignment: .topLeading) {
            surface(.sharp)
            if bands.strength > 0.001 {
                ForEach(IsometricBands.radii.indices, id: \.self) { layer in
                    surface(.blur(layer))
                        .mask { bands.blurMask(layer: layer, size: size) }
                }
                ground.mask { bands.fadeMask(size: size) }
                if glows {
                    ForEach(bands.glows.indices, id: \.self) { index in
                        surface(.glow(index))
                            .mask { bands.glowMask(bands.glows[index], size: size) }
                            .blendMode(.plusLighter)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }
}

extension View {
    /// Blurs this surface for `layer` as it draws: simple, and paid every
    /// frame.
    @ViewBuilder
    func liveBlur(for layer: IsometricLayer, bands: IsometricBands) -> some View {
        switch layer {
        case .sharp:
            self
        case let .blur(index):
            blur(radius: IsometricBands.radii[index], opaque: true)
        case let .glow(index):
            blur(radius: bands.glows[index].radius, opaque: true)
                .saturation(bands.glows[index].saturation)
        }
    }
}

/// What gets rendered into the texture: the treemap, and under it the same
/// treemap shifted half a width, wrapping.
private struct IsometricHeatmapTexture: View {
    let tiles: [IsometricHeatmapLabStyle.Tile]

    var body: some View {
        let cell = IsometricHeatmapLabStyle.cell
        ZStack(alignment: .topLeading) {
            Color.black
            treemap
            treemap.offset(x: -cell.width / 2, y: cell.height)
            treemap.offset(x: cell.width / 2, y: cell.height)
        }
        .frame(
            width: IsometricHeatmapLabStyle.textureSize.width,
            height: IsometricHeatmapLabStyle.textureSize.height,
            alignment: .topLeading
        )
        .clipped()
        .environment(\.colorScheme, .light)
    }

    private var treemap: some View {
        ZStack(alignment: .topLeading) {
            ForEach(tiles) { tile in
                IsometricHeatmapTile(tile: tile)
                    .frame(width: max(0, tile.frame.width), height: max(0, tile.frame.height))
                    .offset(x: tile.frame.minX, y: tile.frame.minY)
            }
        }
        .frame(
            width: IsometricHeatmapLabStyle.cell.width,
            height: IsometricHeatmapLabStyle.cell.height,
            alignment: .topLeading
        )
    }
}

private struct IsometricHeatmapTile: View {
    let tile: IsometricHeatmapLabStyle.Tile

    var body: some View {
        let side = min(tile.frame.width, tile.frame.height)
        let tickerSize = min(12.15, max(4.05, side * 0.14))
        let padding = min(10.8, max(3, side * 0.12))
        let shape = RoundedRectangle(cornerRadius: IsometricHeatmapLabStyle.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            if side >= 20 {
                Text(tile.ticker)
                    .font(.system(size: tickerSize, weight: .bold, design: .rounded))
                if let change = tile.change {
                    Text(DisplayFormat.percent(change))
                        .font(.system(size: tickerSize * 0.78, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .opacity(0.5)
                }
            }
        }
        .lineLimit(1)
        .foregroundStyle(CatfolioTheme.blackTextOnColor)
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IsometricHeatmapLabStyle.fill(for: tile), in: shape)
        .overlay(shape.strokeBorder(.black.opacity(0.04), lineWidth: IsometricHeatmapLabStyle.borderWidth))
    }
}
