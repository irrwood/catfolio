import SwiftUI

/// What the Performance tab tells the heatmap hero about its scroll view.
struct HeatmapHeroState {
    var isExpanded: Bool
    /// How far the page is pulled past its top, while held.
    var pull: CGFloat
    /// From the top of the screen to the top of the page's content: the bar
    /// and the large title, which the hero runs up behind.
    var topInset: CGFloat
    /// False once the page has scrolled the hero out of sight; the drift
    /// stops.
    var isOnScreen: Bool
    var onToggle: () -> Void

    /// How far to pull before letting go stands the heatmap up, or lays it
    /// back down.
    static let threshold: CGFloat = 110
}

/// The top of the Performance tab: the holdings heatmap lying on an
/// isometric plane, drifting, with a progressive blur top and bottom and a
/// glow (the lab page, `IsometricHeatmapLab`). Pulling the page down past
/// `HeatmapHeroState.threshold` and letting go stands the plane up into the
/// ordinary heatmap, in its ordinary place, where it can be tapped; doing it
/// again lays it back down.
///
/// The plane is never a separate drawing. It is the page's own heatmap view
/// rendered into a texture, in its own colours, so every tile on the plane is
/// the tile it becomes. The morph interpolates the projection's own terms
/// (scale, skew, rotation) and the anchor and fades the repeated copies and
/// the effects out; at the end the texture is swapped for the live view in
/// the same pixels.
struct PerformanceHeatmapHero<Header: View, Heatmap: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let state: HeatmapHeroState
    /// Changes whenever the heatmap would draw differently.
    let renderKey: Int
    @ViewBuilder let header: Header
    /// The page's heatmap: live when `false`, for a texture when `true`.
    let heatmap: (_ isSnapshot: Bool) -> Heatmap

    @State private var textures: HeatmapHeroTextures?
    @State private var headerHeight: CGFloat = 40
    @State private var heatmapSize: CGSize = .zero
    @State private var drift = HeatmapHeroDrift()
    @State private var isSettling = false
    @State private var tileFrames: [CGRect] = []

    var body: some View {
        let hint = IsometricBands.smoothstep(0, HeatmapHeroState.threshold, state.pull)
        let progress = state.isExpanded ? 1 - 0.12 * hint : 0.12 * hint
        let drifts = !state.isExpanded && state.pull < 0.5 && state.isOnScreen && !isSettling && !reduceMotion

        HeatmapHeroMorph(
            progress: progress,
            state: state,
            textures: textures,
            headerHeight: headerHeight,
            heatmapSize: heatmapSize,
            drift: drift,
            drifts: drifts,
            pulses: !reduceMotion,
            tileFrames: tileFrames,
            glows: colorScheme == .dark,
            header: header,
            heatmap: heatmap(false),
            onHeaderHeight: { headerHeight = $0 },
            onHeatmapSize: { heatmapSize = $0 },
            onTileFrames: { tileFrames = $0 }
        )
        .onChange(of: drifts, initial: true) { _, drifts in
            if drifts { drift.resume(at: .now) } else { drift.pause(at: .now) }
        }
        // Hold the plane still until a morph has finished, so the drift
        // cannot move the tile being stood up or laid down.
        .task(id: state.isExpanded) {
            isSettling = true
            try? await Task.sleep(for: .seconds(0.8))
            isSettling = false
        }
        .task(id: TextureKey(renderKey: renderKey, scheme: colorScheme, width: heatmapSize.width, locale: locale.identifier)) {
            guard heatmapSize.width > 0 else { return }
            textures = await HeatmapHeroTextures.render(
                heatmap: heatmap(true),
                width: heatmapSize.width,
                scheme: colorScheme,
                locale: locale,
                displayScale: displayScale
            )
        }
    }

    private struct TextureKey: Hashable {
        let renderKey: Int
        let scheme: ColorScheme
        let width: CGFloat
        let locale: String
    }
}

/// The drift's position, kept across pauses so the plane picks up where it
/// stopped.
struct HeatmapHeroDrift {
    /// Points per second along the plane's depth axis.
    static let speed: Double = 10
    private var accumulated: Double = 0
    private var resumedAt: Date?

    func travel(at date: Date) -> CGFloat {
        CGFloat(accumulated + (resumedAt.map { date.timeIntervalSince($0) } ?? 0) * Self.speed)
    }

    mutating func resume(at date: Date) {
        guard resumedAt == nil else { return }
        resumedAt = date
    }

    mutating func pause(at date: Date) {
        guard let resumedAt else { return }
        accumulated += date.timeIntervalSince(resumedAt) * Self.speed
        self.resumedAt = nil
    }
}

/// The heatmap as images: `heatmap` is one heatmap; `pattern` is the same
/// with a copy shifted half a width under it, so it tiles the plane without
/// the repeat lining up. `blurred` and `glows` are the pattern blurred ahead
/// of time, one per blur layer and per glow, so no frame blurs anything.
struct HeatmapHeroTextures {
    let heatmap: Image
    let pattern: Image
    let blurred: [Image]
    let glows: [Image]
    let cell: CGSize

    @MainActor
    static func render<Heatmap: View>(
        heatmap: Heatmap,
        width: CGFloat,
        scheme: ColorScheme,
        locale: Locale,
        displayScale: CGFloat
    ) async -> HeatmapHeroTextures? {
        let ground = SettingsTemplate.pageBackground

        let renderer = ImageRenderer(
            content: heatmap
                .frame(width: width)
                .background(ground)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, locale)
        )
        // Full scale: this copy ends up upright, in place of the live view.
        renderer.scale = displayScale
        renderer.isOpaque = true
        guard let single = renderer.uiImage else { return nil }
        let cell = single.size
        // The repeats are only ever seen lying down, drawn at 0.8 and blurred
        // toward the edges, so they need less than the screen's scale.
        let patternRenderer = ImageRenderer(
            content: ZStack(alignment: .topLeading) {
                ground
                Image(uiImage: single)
                Image(uiImage: single).offset(x: -cell.width / 2, y: cell.height)
                Image(uiImage: single).offset(x: cell.width / 2, y: cell.height)
            }
            .frame(width: cell.width, height: cell.height * 2, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, scheme)
        )
        patternRenderer.scale = 2
        patternRenderer.isOpaque = true
        guard let pattern = patternRenderer.uiImage, let source = pattern.cgImage else { return nil }

        let baked = await Task.detached(priority: .userInitiated) {
            HeatmapHeroBlur.bake(source, scale: pattern.scale)
        }.value
        guard let baked else { return nil }
        func image(_ baked: HeatmapHeroBlur.Baked) -> Image {
            Image(uiImage: UIImage(cgImage: baked.image, scale: baked.scale, orientation: .up))
        }
        return HeatmapHeroTextures(
            heatmap: Image(uiImage: single),
            pattern: Image(uiImage: pattern),
            blurred: baked.blurred.map(image),
            glows: baked.glows.map(image),
            cell: cell
        )
    }
}

/// Blurs the tiling pattern once per blur layer and per glow, off the main
/// thread, whenever the heatmap is rendered again.
enum HeatmapHeroBlur {
    /// The glows' radius on screen and how much each saturates.
    static let glowStyles: [(radius: CGFloat, saturation: CGFloat)] = [(8, 1.2), (40, 1.8)]

    struct Baked: @unchecked Sendable {
        let image: CGImage
        /// Pixels per point: the blurrier the copy, the fewer it needs.
        let scale: CGFloat
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func bake(_ pattern: CGImage, scale: CGFloat) -> (blurred: [Baked], glows: [Baked])? {
        var blurred: [Baked] = []
        for radius in IsometricBands.radii {
            guard let copy = blur(pattern, scale: scale, radius: radius, saturation: 1) else { return nil }
            blurred.append(copy)
        }
        var glows: [Baked] = []
        for style in glowStyles {
            guard let copy = blur(pattern, scale: scale, radius: style.radius, saturation: style.saturation) else { return nil }
            glows.append(copy)
        }
        return (blurred, glows)
    }

    /// `radius` is on screen. The plane is drawn at 0.8, so the same blur
    /// in the plane's own points is a quarter again as wide.
    private static func blur(_ pattern: CGImage, scale: CGFloat, radius: CGFloat, saturation: CGFloat) -> Baked? {
        let planeRadius = radius / 0.8
        let target: CGFloat = planeRadius < 10 ? 1 : planeRadius < 25 ? 0.5 : 0.25
        let width = (CGFloat(pattern.width) * target / scale).rounded()
        let height = (CGFloat(pattern.height) * target / scale).rounded()
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        var image = CIImage(cgImage: pattern)
        if target != scale {
            let factor = height / CGFloat(pattern.height)
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: factor,
                kCIInputAspectRatioKey: (width / CGFloat(pattern.width)) / factor,
            ])
        }
        // The pattern tiles, so it is blurred as a tiling: each edge borrows
        // from the opposite one and the copies still meet without a seam.
        var output = image.cropped(to: extent)
            .applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSValue(cgAffineTransform: .identity)])
            .applyingGaussianBlur(sigma: Double(planeRadius * target))
            .cropped(to: extent)
        if saturation != 1 {
            output = output.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
        }
        guard let result = context.createCGImage(output, from: extent) else { return nil }
        return Baked(image: result, scale: target)
    }
}

private struct HeatmapHeroMorph<Header: View, Heatmap: View>: View, Animatable {
    /// 0 lying on the plane, 1 standing in its place.
    var progress: Double
    let state: HeatmapHeroState
    let textures: HeatmapHeroTextures?
    let headerHeight: CGFloat
    let heatmapSize: CGSize
    let drift: HeatmapHeroDrift
    let drifts: Bool
    let pulses: Bool
    let tileFrames: [CGRect]
    let glows: Bool
    let header: Header
    let heatmap: Heatmap
    let onHeaderHeight: (CGFloat) -> Void
    let onHeatmapSize: (CGSize) -> Void
    let onTileFrames: ([CGRect]) -> Void

    /// How much of the page the plane takes below the large title.
    static var collapsedHeight: CGFloat { 250 }
    static var spacing: CGFloat { 14 }

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let e = CGFloat(min(1, max(0, progress)))
        let isUpright = e > 0.999
        let expandedHeight = headerHeight + Self.spacing + heatmapSize.height
        let height = Self.collapsedHeight + (expandedHeight - Self.collapsedHeight) * e

        VStack(alignment: .leading, spacing: Self.spacing) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeaderHeight($0) }
                .opacity(IsometricBands.smoothstep(0.7, 1, e))
                .allowsHitTesting(isUpright)
                .accessibilityAction(named: L10n.text("收起持仓热力图")) { state.onToggle() }
            heatmap
                // The live heatmap reports where its tiles are, which is
                // where they are in the texture too: the pulses need them.
                .environment(\.reportsHeatmapTileFrames, true)
                .coordinateSpace(.named(HeatmapTileFramesKey.space))
                .onPreferenceChange(HeatmapTileFramesKey.self) { onTileFrames($0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { onHeatmapSize($0) }
                .opacity(isUpright ? 1 : 0)
                .allowsHitTesting(isUpright)
                .accessibilityHidden(!isUpright)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: max(0, height), alignment: .top)
        .overlay(alignment: .topLeading) {
            if !isUpright, let textures, heatmapSize.width > 0 {
                canvas(e: e, textures: textures, height: height)
            }
        }
        .overlay {
            if !state.isExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { state.onToggle() }
                    .accessibilityElement()
                    .accessibilityLabel(L10n.text("持仓热力图"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(L10n.text("展开持仓热力图"))
                    .accessibilityAction { state.onToggle() }
            }
        }
    }

    private func canvas(e: CGFloat, textures: HeatmapHeroTextures, height: CGFloat) -> some View {
        let inset = SettingsTemplate.pageInset
        let top = state.topInset + state.pull
        let size = CGSize(width: heatmapSize.width + inset * 2, height: top + height + 90)
        let bottom = top + Self.collapsedHeight
        let settings = HeatmapHeroSurface.Settings(
            e: e,
            canvas: size,
            isometricAnchor: CGPoint(x: size.width / 2, y: top + Self.collapsedHeight * 0.45),
            uprightOrigin: CGPoint(x: inset, y: top + headerHeight + Self.spacing),
            // Below the title and above the fade: where a pulse can be seen.
            pulseBand: (top + 10)...(bottom - 70)
        )
        var bands = IsometricBands(
            // Fully blurred through the large title, clear just below it.
            top: .init(full: state.topInset - 30, clear: state.topInset + 40, maximum: 18, degrees: 3.79),
            bottom: .init(full: bottom - 8, clear: bottom - 150, maximum: 16, degrees: 6.62),
            fade: (clear: bottom - 140, full: bottom + 4),
            // Radii and saturation are baked into the glow textures.
            glows: [
                .init(radius: HeatmapHeroBlur.glowStyles[0].radius, saturation: HeatmapHeroBlur.glowStyles[0].saturation,
                      profile: [(0, 0.1), (state.topInset, 0.06), (bottom - 110, 0.08), (bottom - 30, 0)]),
                .init(radius: HeatmapHeroBlur.glowStyles[1].radius, saturation: HeatmapHeroBlur.glowStyles[1].saturation,
                      profile: [(0, 0.1), (state.topInset, 0.03), (bottom - 120, 0.06),
                                (bottom - 45, 0.32), (bottom + 15, 0.2), (bottom + 75, 0)]),
            ]
        )
        bands.strength = 1 - IsometricBands.smoothstep(0, 0.55, e)

        // The large title sits on the plane. A veil of the page ground under
        // the bar keeps it legible without a hard edge.
        let title = state.topInset
        let veil = bands.strength
        let veilProfile: [(y: CGFloat, strength: CGFloat)] = [
            (0, 0.4), (title - 70, 0.6), (title - 15, 0.55), (title + 35, 0),
        ]

        // Only the surfaces tick; the masks, the fade and the veil stay put
        // and are not rebuilt every frame.
        return IsometricEdgeEffects(bands: bands, size: size, ground: SettingsTemplate.pageBackground, glows: glows) { layer in
            HeatmapHeroSurface(
                textures: textures,
                layer: layer,
                settings: settings,
                drift: drift,
                moves: drifts,
                tileFrames: pulses ? tileFrames : []
            )
        }
        .overlay {
            SettingsTemplate.pageBackground
                .mask {
                    IsometricBands.band(size: size, degrees: 0) { y in
                        IsometricBands.interpolate(veilProfile, at: y) * veil
                    }
                }
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .offset(x: -inset, y: -top)
        .accessibilityHidden(true)
    }
}

/// The page ground with the heatmap on it, somewhere between lying on the
/// plane and standing upright.
private struct HeatmapHeroSurface: View {
    struct Settings {
        let e: CGFloat
        let canvas: CGSize
        /// Where the plane's centre sits while it lies down.
        let isometricAnchor: CGPoint
        /// Where the heatmap's top-left corner sits once it stands up.
        let uprightOrigin: CGPoint
        let pulseBand: ClosedRange<CGFloat>
    }

    let textures: HeatmapHeroTextures
    /// Which copy to draw: the sharp one, with the live pulses, or one of
    /// the pre-blurred ones.
    let layer: IsometricLayer
    let settings: Settings
    let drift: HeatmapHeroDrift
    let moves: Bool
    /// The heatmap's tiles in its own coordinates; empty for no pulses.
    let tileFrames: [CGRect]

    /// The plane is drawn a little smaller than the heatmap stands, so it
    /// reads as a field of tiles rather than a few big ones.
    private static var isometricScale: CGFloat { 0.8 }

    var body: some View {
        // Ten points a second needs no more than thirty frames; the morph
        // itself animates at the display's rate regardless.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moves)) { context in
            content(at: context.date)
        }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        let e = settings.e
        let cell = textures.cell
        let travel = drift.travel(at: date)
        let pulseStrength = 1 - IsometricBands.smoothstep(0, 0.25, e)

        ZStack(alignment: .topLeading) {
            SettingsTemplate.pageBackground
            ZStack(alignment: .topLeading) {
                let pattern = self.pattern
                // Every other copy, fading first so one heatmap is left to
                // stand up. The pattern repeats every two heights; the copies
                // keep a whole period on each side of the main one.
                ForEach(0..<15, id: \.self) { index in
                    pattern
                        .resizable()
                        .frame(width: cell.width, height: cell.height * 2)
                        .offset(x: CGFloat(index % 5 - 2) * cell.width, y: CGFloat(index / 5 - 1) * cell.height * 2)
                }
                .opacity(1 - IsometricBands.smoothstep(0, 0.45, e))
                // The main copy: the pattern's top half, which is the
                // heatmap itself.
                if layer == .sharp {
                    textures.heatmap
                        .resizable()
                        .frame(width: cell.width, height: cell.height)
                } else {
                    pattern
                        .resizable()
                        .frame(width: cell.width, height: cell.height * 2)
                        .frame(width: cell.width, height: cell.height, alignment: .top)
                        .clipped()
                }
                if layer == .sharp, pulseStrength > 0 {
                    ForEach(pulses(cell: cell, at: date)) { pulse in
                        HeatmapHeroPulseTile(
                            image: textures.heatmap,
                            cell: cell,
                            pulse: pulse,
                            strength: pulse.strength * pulseStrength
                        )
                    }
                }
            }
            .frame(width: cell.width, height: cell.height, alignment: .topLeading)
            .transformEffect(transform(e: e, cell: cell, travel: travel))
        }
        .frame(width: settings.canvas.width, height: settings.canvas.height, alignment: .topLeading)
        .clipped()
    }

    private var pattern: Image {
        switch layer {
        case .sharp: textures.pattern
        case let .blur(index): textures.blurred[index]
        case let .glow(index): textures.glows[index]
        }
    }

    /// The tiles lit at this moment. A new pulse starts every
    /// `HeatmapHeroPulse.interval`; each picks, from its own seed, a tile in
    /// one of the copies around the main one that was in sight when it
    /// started, so it stays on the same tile for its whole life.
    private func pulses(cell: CGSize, at date: Date) -> [HeatmapHeroPulse] {
        let tiles = tileFrames.filter { min($0.width, $0.height) >= 24 }
        guard !tiles.isEmpty else { return [] }
        let now = date.timeIntervalSinceReferenceDate
        let interval = HeatmapHeroPulse.interval
        let newest = Int((now / interval).rounded(.down))
        let oldest = newest - Int((HeatmapHeroPulse.duration / interval).rounded(.up))
        var result: [HeatmapHeroPulse] = []
        for slot in oldest...newest {
            let start = Double(slot) * interval
            let age = now - start
            guard age >= 0, age < HeatmapHeroPulse.duration else { continue }
            let lying = transform(
                e: 0, cell: cell,
                travel: drift.travel(at: Date(timeIntervalSinceReferenceDate: start))
            )
            var seed = UInt64(bitPattern: Int64(slot))
            for _ in 0..<12 {
                seed = HeatmapHeroPulse.mix(seed)
                let tile = tiles[Int(seed % UInt64(tiles.count))]
                seed = HeatmapHeroPulse.mix(seed)
                let column = CGFloat(Int(seed % 3) - 1)
                seed = HeatmapHeroPulse.mix(seed)
                let row = Int(seed % 4) - 1
                let origin = CGPoint(
                    x: column * cell.width + (row.isMultiple(of: 2) ? 0 : cell.width / 2),
                    y: CGFloat(row) * cell.height
                )
                let centre = CGPoint(x: origin.x + tile.midX, y: origin.y + tile.midY).applying(lying)
                guard settings.pulseBand.contains(centre.y),
                      centre.x > 20, centre.x < settings.canvas.width - 20 else { continue }
                result.append(HeatmapHeroPulse(
                    id: slot, tile: tile, origin: origin,
                    strength: HeatmapHeroPulse.envelope(age: age)
                ))
                break
            }
        }
        return result
    }

    /// Cell coordinates to canvas coordinates: around an anchor that slides
    /// from the plane's centre to the upright centre, by the projection's own
    /// terms each moved from their isometric value to none.
    private func transform(e: CGFloat, cell: CGSize, travel: CGFloat) -> CGAffineTransform {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }

        // The drift moves the plane down its depth axis; wrapping by the
        // pattern's period keeps the main copy nearest the anchor.
        let period = cell.height * 2
        var offset = travel.truncatingRemainder(dividingBy: period)
        if offset >= cell.height { offset -= period }
        let lying = CGPoint(x: cell.width / 2, y: cell.height / 2 - offset)
        let standing = CGPoint(x: cell.width / 2, y: cell.height / 2)
        let anchor = CGPoint(x: mix(lying.x, standing.x), y: mix(lying.y, standing.y))
        let target = CGPoint(
            x: mix(settings.isometricAnchor.x, settings.uprightOrigin.x + cell.width / 2),
            y: mix(settings.isometricAnchor.y, settings.uprightOrigin.y + cell.height / 2)
        )

        let scale = mix(Self.isometricScale, 1)
        let linear = CGAffineTransform(scaleX: 1, y: mix(0.87, 1))
            .concatenating(CGAffineTransform(a: 1, b: 0, c: tan(mix(.pi / 6, 0)), d: 1, tx: 0, ty: 0))
            .concatenating(CGAffineTransform(rotationAngle: mix(-.pi / 6, 0)))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(linear)
            .concatenating(CGAffineTransform(translationX: target.x, y: target.y))
    }
}

/// One tile lighting up and fading back while the plane lies down.
struct HeatmapHeroPulse: Identifiable {
    static let interval: Double = 0.5
    static let duration: Double = 2.2
    private static let rise: Double = 0.45

    let id: Int
    /// The tile, in the heatmap's coordinates.
    let tile: CGRect
    /// The copy of the heatmap it is in, in cell coordinates.
    let origin: CGPoint
    let strength: CGFloat

    /// Quick to light, slow to fade.
    static func envelope(age: Double) -> CGFloat {
        let up = IsometricBands.smoothstep(0, CGFloat(rise), CGFloat(age))
        let down = 1 - IsometricBands.smoothstep(CGFloat(rise), CGFloat(duration), CGFloat(age))
        return min(up, down)
    }

    /// SplitMix64: a well-spread next value from any seed.
    static func mix(_ seed: UInt64) -> UInt64 {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A lit tile: the tile's own pixels, brighter and more saturated, with a
/// halo of the same colour added around it.
private struct HeatmapHeroPulseTile: View {
    let image: Image
    let cell: CGSize
    let pulse: HeatmapHeroPulse
    let strength: CGFloat

    var body: some View {
        let tile = pulse.tile
        // The tile's own corner, as `HoldingsHeatmapTile` draws it.
        let radius = min(11, min(tile.width, tile.height) * 0.25)
        let lit = image
            .resizable()
            .frame(width: cell.width, height: cell.height)
            .offset(x: -tile.minX, y: -tile.minY)
            .frame(width: tile.width, height: tile.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .brightness(0.3 * strength)
            .saturation(1 + 0.6 * strength)

        ZStack(alignment: .topLeading) {
            lit
                .blur(radius: 12)
                .opacity(0.8 * strength)
                .blendMode(.plusLighter)
            lit
        }
        .offset(x: pulse.origin.x + tile.minX, y: pulse.origin.y + tile.minY)
        .allowsHitTesting(false)
    }
}

/// Where each heatmap tile is, in the heatmap's own coordinates. Tiles only
/// report it under `reportsHeatmapTileFrames`, which the hero sets on its
/// live heatmap.
struct HeatmapTileFramesKey: PreferenceKey {
    static let space = "heatmap.tiles"
    static var defaultValue: [CGRect] { [] }

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

extension EnvironmentValues {
    @Entry var reportsHeatmapTileFrames = false
}
