import SwiftUI

/// Scroll samples are observed by the hero only. A pull must not rebuild the
/// returns cards, recompute holdings, or restart their loading tasks each frame.
@Observable
final class HeatmapHeroScroll {
    struct Geometry: Equatable {
        var pull: CGFloat = 0
        var topInset: CGFloat = 0
        var isHeroOnScreen = true
    }

    struct Presentation: Equatable {
        var topInset: CGFloat = 0
        var isHeroOnScreen = true
        var isPulling = false
        var isPastThreshold = false
    }

    // Keep the exact distance for release handling, without publishing every
    // pixel to SwiftUI. Only the visual state boundaries invalidate the hero.
    @ObservationIgnored var geometry = Geometry() {
        didSet {
            let next = Presentation(topInset: geometry.topInset, isHeroOnScreen: geometry.isHeroOnScreen,
                                    isPulling: geometry.pull >= 0.5,
                                    isPastThreshold: geometry.pull >= HeatmapHeroState.threshold)
            if presentation != next { presentation = next }
        }
    }
    private(set) var presentation = Presentation()
    var isScrolling = false
}

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
    /// Pause ambient motion and texture baking while the native scroll view
    /// tracks, drags, decelerates or scrolls programmatically.
    var isScrolling: Bool
    var onToggle: () -> Void
    var collapsedHeight: CGFloat = 202
    var scroll: HeatmapHeroScroll? = nil

    func resolved() -> Self {
        guard let scroll else { return self }
        var result = self
        result.pull = scroll.geometry.pull
        result.topInset = scroll.presentation.topInset
        result.isOnScreen = scroll.presentation.isHeroOnScreen
        result.isScrolling = scroll.isScrolling
        return result
    }

    /// Align the expanded tiles with the inline toolbar, keeping the status
    /// bar clear while the filter button remains over the heatmap.
    var expandedTopLift: CGFloat { min(44, max(0, topInset)) }

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
struct PerformanceHeatmapHero<Heatmap: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    let state: HeatmapHeroState
    /// Changes whenever the heatmap would draw differently.
    let renderKey: Int
    /// The page's heatmap: live when `false`, for a texture when `true`.
    let heatmap: (_ isSnapshot: Bool) -> Heatmap

    @State private var textures: HeatmapHeroTextures?
    @State private var heatmapSize: CGSize = .zero
    @State private var drift = HeatmapHeroDrift()
    @State private var isSettling = false
    @State private var resolvedLogoURLs: Set<URL> = []
    @State private var isVisible = false
    @State private var renderedTextureKey: TextureKey?
    /// The plane fades in when its first texture is ready instead of
    /// appearing at once.
    @State private var planeOpacity: Double = 0

    var body: some View {
        let state = state.resolved()
        // Native rubber-banding moves the hero during a pull. Morph its
        // projection only after release, so dragging does not resize and
        // rerasterize the plane and the rest of the page on every frame.
        let progress = state.isExpanded ? 1.0 : 0.0
        let canRender = isVisible && scenePhase == .active && !state.isScrolling
        let drifts = canRender && !state.isExpanded && state.pull < 0.5
            && state.isOnScreen && !isSettling && !reduceMotion
        let textureKey = TextureKey(renderKey: renderKey, scheme: colorScheme, width: heatmapSize.width,
                                    scale: displayScale, locale: locale.identifier,
                                    logoRevision: resolvedLogoURLs.count)

        HeatmapHeroMorph(
            progress: progress,
            state: state,
            textures: textures,
            heatmapSize: heatmapSize,
            drift: drift,
            drifts: drifts,
            planeOpacity: reduceMotion ? 1 : planeOpacity,
            heatmap: heatmap(false),
            onHeatmapSize: { heatmapSize = $0 }
        )
        .environment(\.assetLogoDidResolve) { url in
            // The live tiles load even while the plane is shown. A newly
            // decoded logo must invalidate the plane's earlier fallback.
            resolvedLogoURLs.insert(url)
        }
        .onChange(of: drifts, initial: true) { _, drifts in
            if drifts { drift.resume(at: .now) } else { drift.pause(at: .now) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: state.pull >= HeatmapHeroState.threshold) { wasPast, isPast in
            hapticsEnabled && !wasPast && isPast
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            drift.pause(at: .now)
        }
        // Hold the plane still until a morph has finished, so the drift
        // cannot move the tile being stood up or laid down.
        .task(id: state.isExpanded) {
            isSettling = true
            do { try await Task.sleep(for: .seconds(0.8)) } catch { return }
            isSettling = false
        }
        .task(id: TextureRequest(key: textureKey, canRender: canRender)) {
            guard canRender, heatmapSize.width > 0, renderedTextureKey != textureKey else { return }
            // Batch a screenful of logos into one bake, and discard any bake
            // superseded by another logo, layout, or account update.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let rendered = await HeatmapHeroTextures.render(
                heatmap: heatmap(true),
                width: heatmapSize.width,
                scheme: colorScheme,
                locale: locale,
                displayScale: displayScale
            )
            guard !Task.isCancelled else { return }
            let isFirst = textures == nil && rendered != nil
            textures = rendered
            if rendered != nil { renderedTextureKey = textureKey }
            if isFirst, !reduceMotion {
                drift.beginIntro(at: .now)
                withAnimation(.easeOut(duration: 0.8)) { planeOpacity = 1 }
            }
        }
    }

    private struct TextureKey: Hashable {
        let renderKey: Int
        let scheme: ColorScheme
        let width: CGFloat
        let scale: CGFloat
        let locale: String
        let logoRevision: Int
    }

    private struct TextureRequest: Equatable {
        let key: TextureKey
        let canRender: Bool
    }
}

/// The drift's position, kept across pauses so the plane picks up where it
/// stopped.
struct HeatmapHeroDrift {
    /// Points per second along the plane's depth axis.
    static let speed: Double = 10
    /// The plane's first appearance runs in: from the cruise it speeds up to
    /// `introBoost` times faster and eases back, over `introDuration`.
    static let introDuration: Double = 2.2
    static let introBoost: Double = 7
    private var accumulated: Double = 0
    private var resumedAt: Date?
    private var introStartedAt: Date?

    func travel(at date: Date) -> CGFloat {
        CGFloat(accumulated + (resumedAt.map { date.timeIntervalSince($0) } ?? 0) * Self.speed
                + introTravel(at: date))
    }

    mutating func beginIntro(at date: Date) {
        guard introStartedAt == nil else { return }
        introStartedAt = date
    }

    /// The extra distance of the run-in: its speed follows sin² of the time,
    /// so it leaves the cruise and returns to it without a jolt.
    func introTravel(at date: Date) -> Double {
        guard let introStartedAt else { return 0 }
        let duration = Self.introDuration
        let t = min(max(0, date.timeIntervalSince(introStartedAt)), duration)
        let integral = t / 2 - duration / (4 * .pi) * sin(2 * .pi * t / duration)
        return Self.introBoost * Self.speed * integral
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
/// the repeat lining up. The progressive shader uses these two textures;
/// there are no unused blur or glow copies to bake when logos arrive.
struct HeatmapHeroTextures {
    let heatmap: Image
    let pattern: Image
    let cell: CGSize

    @MainActor
    static func render<Heatmap: View>(
        heatmap: Heatmap,
        width: CGFloat,
        scheme: ColorScheme,
        locale: Locale,
        displayScale: CGFloat
    ) async -> HeatmapHeroTextures? {
        let renderer = ImageRenderer(
            content: heatmap
                .frame(width: width)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, locale)
        )
        // Full scale: this copy ends up upright, in place of the live view.
        renderer.scale = displayScale
        // Preserve the gaps between tiles so the page gradient shows through.
        renderer.isOpaque = false
        guard let single = renderer.uiImage else { return nil }
        let cell = single.size
        // The repeats are only ever seen lying down, drawn at 0.8 and blurred
        // toward the edges, so they need less than the screen's scale.
        let patternRenderer = ImageRenderer(
            content: ZStack(alignment: .topLeading) {
                Image(uiImage: single)
                Image(uiImage: single).offset(x: -cell.width / 2, y: cell.height)
                Image(uiImage: single).offset(x: cell.width / 2, y: cell.height)
            }
            .frame(width: cell.width, height: cell.height * 2, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, scheme)
        )
        patternRenderer.scale = 2
        patternRenderer.isOpaque = false
        guard let pattern = patternRenderer.uiImage, !Task.isCancelled else { return nil }
        return HeatmapHeroTextures(
            heatmap: Image(uiImage: single),
            pattern: Image(uiImage: pattern),
            cell: cell
        )
    }
}

private struct HeatmapHeroMorph<Heatmap: View>: View, Animatable {
    /// 0 lying on the plane, 1 standing in its place.
    var progress: Double
    let state: HeatmapHeroState
    let textures: HeatmapHeroTextures?
    let heatmapSize: CGSize
    let drift: HeatmapHeroDrift
    let drifts: Bool
    let planeOpacity: Double
    let heatmap: Heatmap
    let onHeatmapSize: (CGSize) -> Void

    /// How much of the page the plane takes below the large title.
    var collapsedHeight: CGFloat { state.collapsedHeight }

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let e = CGFloat(min(1, max(0, progress)))
        let isUpright = e > 0.999
        let expandedHeight = max(0, heatmapSize.height - state.expandedTopLift)
        let height = collapsedHeight + (expandedHeight - collapsedHeight) * e

        heatmap
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onHeatmapSize($0) }
        .offset(y: -state.expandedTopLift * e)
        .opacity(isUpright ? 1 : 0)
        .allowsHitTesting(isUpright)
        .accessibilityHidden(!isUpright)
        .accessibilityAction(named: L10n.text("收起持仓热力图")) { state.onToggle() }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: max(0, height), alignment: .top)
        .overlay(alignment: .topLeading) {
            if !isUpright, let textures, heatmapSize.width > 0 {
                canvas(e: e, textures: textures, height: height)
                    .opacity(planeOpacity)
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
        let top = state.topInset
        let size = CGSize(width: heatmapSize.width + inset * 2, height: top + height + 90)
        let settings = HeatmapHeroSurface.Settings(
            e: e,
            canvas: size,
            isometricAnchor: CGPoint(x: size.width / 2, y: top + collapsedHeight * 0.45),
            uprightOrigin: CGPoint(x: inset, y: top - state.expandedTopLift)
        )
        // Figma 496:23660: two vertical layers, with a clear interval
        // between the status-bar fade and the lower fade behind the title.
        let scale = size.width / 402
        let topEnd = 81 * scale
        let lowerStart = 158 * scale
        let lowerEnd = 302 * scale
        let effectStrength = 1 - IsometricBands.smoothstep(0, 0.55, e)

        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !drifts)) { context in
            HeatmapHeroBlurredSurface(size: size, topEnd: topEnd, lowerStart: lowerStart,
                                     lowerEnd: lowerEnd, strength: effectStrength) {
                HeatmapHeroSurface(textures: textures, settings: settings,
                                   travel: drift.travel(at: context.date))
            }
        }
        // Fade the artwork itself so the shared page gradient stays visible
        // through the status area and behind the title.
        .mask {
            LinearGradient(stops: [
                .init(color: .white.opacity(1 - effectStrength), location: 0),
                .init(color: .white, location: min(1, topEnd / size.height)),
                .init(color: .white, location: min(1, lowerStart / size.height)),
                .init(color: .white.opacity(1 - effectStrength), location: min(1, lowerEnd / size.height))
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .offset(x: -inset, y: -top)
        .accessibilityHidden(true)
    }
}

/// Blur only needs one pixel per point. Rasterize that branch at that size,
/// then composite the clear band at native resolution so logos stay sharp.
/// Both branches use the same timeline sample and projection.
struct HeatmapHeroBlurredSurface<Surface: View>: View {
    @Environment(\.displayScale) private var displayScale
    let size: CGSize
    let topEnd: CGFloat
    let lowerStart: CGFloat
    let lowerEnd: CGFloat
    let strength: CGFloat
    @ViewBuilder let surface: Surface

    var body: some View {
        let rasterScale = 1 / max(1, displayScale)
        if strength <= 0.001 {
            surface
        } else {
            surface
                .scaleEffect(rasterScale, anchor: .topLeading)
                .frame(width: size.width * rasterScale, height: size.height * rasterScale, alignment: .topLeading)
                .clipped()
                .drawingGroup(opaque: false)
                .visualEffect { content, proxy in
                    let arguments: [Shader.Argument] = [
                        .float2(proxy.size), .float(Float(topEnd * rasterScale)),
                        .float(Float(lowerStart * rasterScale)), .float(Float(lowerEnd * rasterScale)),
                        .float(Float(strength)), .float(Float(displayScale)), .float(Float(rasterScale))
                    ]
                    return content
                        .layerEffect(Shader(function: ShaderFunction(library: .default, name: "performanceHeroBlur"),
                                            arguments: arguments + [.float2(1, 0)]),
                                     maxSampleOffset: CGSize(width: 45.1 * rasterScale, height: 0))
                        .layerEffect(Shader(function: ShaderFunction(library: .default, name: "performanceHeroBlur"),
                                            arguments: arguments + [.float2(0, 1)]),
                                     maxSampleOffset: CGSize(width: 0, height: 45.1 * rasterScale))
                }
                .scaleEffect(1 / rasterScale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                // Cross-fade premultiplied colors and alpha together. Normal
                // source-over blending attenuates the lower copy a second
                // time, leaving a stripe even with complementary masks.
                .mask { clearBand(inverted: true) }
                .overlay {
                    // The genuinely clear interval remains native pixels.
                    surface.mask { clearBand(inverted: false) }
                        .blendMode(.plusLighter)
                }
                .compositingGroup()
        }
    }

    /// Opaque over the clear interval, feathering out over only the first
    /// two points of blur on either side; `inverted` is its complement.
    private func clearBand(inverted: Bool) -> some View {
        let topFeather = topEnd * min(1, 2 / (20 * strength))
        let bottomFeather = (lowerEnd - lowerStart) * min(1, 2 / (44.1 * strength))
        let inside: Color = inverted ? .clear : .black
        let outside: Color = inverted ? .black : .clear
        return LinearGradient(stops: [
            .init(color: outside, location: 0),
            .init(color: outside, location: max(0, (topEnd - topFeather) / size.height)),
            .init(color: inside, location: min(1, topEnd / size.height)),
            .init(color: inside, location: min(1, lowerStart / size.height)),
            .init(color: outside, location: min(1, (lowerStart + bottomFeather) / size.height)),
            .init(color: outside, location: 1)
        ], startPoint: .top, endPoint: .bottom)
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
    }

    let textures: HeatmapHeroTextures
    let settings: Settings
    let travel: CGFloat

    /// The plane is drawn a little smaller than the heatmap stands, so it
    /// reads as a field of tiles rather than a few big ones.
    private static var isometricScale: CGFloat { 0.8 }

    var body: some View {
        let e = settings.e
        let cell = textures.cell

        ZStack(alignment: .topLeading) {
            Color.clear
            ZStack(alignment: .topLeading) {
                let pattern = textures.pattern
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
                textures.heatmap
                    .resizable()
                    .frame(width: cell.width, height: cell.height)
            }
            .frame(width: cell.width, height: cell.height, alignment: .topLeading)
            .transformEffect(transform(e: e, cell: cell, travel: travel))
        }
        .frame(width: settings.canvas.width, height: settings.canvas.height, alignment: .topLeading)
        .clipped()
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
