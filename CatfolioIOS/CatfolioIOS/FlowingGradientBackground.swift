//  FlowingGradientBackground.swift
//
//  Full-screen animated background driven by FlowingGradient.metal.
//  Requires iOS 17 / macOS 14 (SwiftUI shader effects).

import SwiftUI

/// The home page's backdrop: one of the shader variants, or the static
/// gradient it has always had. Stored per device.
enum HomeBackgroundStyle: String, CaseIterable, Identifiable {
    /// Calm glow, kept behind the content card.
    case flowing
    /// The same glow in the brighter night palette.
    case flowingBright
    /// Glows above and below the chart, never on it.
    case flowingAroundChart
    /// Glowing arcs behind the content card.
    case rings
    /// The same arcs, blurred into soft glowing bands.
    case ringsBlurred
    /// One huge soft light from the top, mist to navy to black.
    case mist
    /// A big wandering white halo.
    case haloWhite
    /// The same halo in cyan-blue.
    case haloCyan
    /// A wide arch of light over sky blue (Figma 486:6627).
    case clearSky
    case classic

    static let preferenceKey = "catfolio.homeBackgroundStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flowing: L10n.text("动态")
        case .flowingBright: L10n.text("动态 · 明亮")
        case .flowingAroundChart: L10n.text("动态 · 避开图表")
        case .rings: L10n.text("光环")
        case .ringsBlurred: L10n.text("光环 · 模糊")
        case .mist: L10n.text("雾光")
        case .haloWhite: L10n.text("白色光晕")
        case .haloCyan: L10n.text("青蓝光晕")
        case .clearSky: L10n.text("晴空")
        case .classic: L10n.text("经典")
        }
    }

    /// The shader to draw, or nil for the static classic backdrop.
    var shaderPattern: FlowingGradientBackground.Pattern? {
        switch self {
        case .flowing, .flowingBright, .flowingAroundChart: .glow
        case .rings, .ringsBlurred: .rings
        case .mist: .mist
        case .haloWhite, .haloCyan: .bigHalo
        case .clearSky: .arch
        case .classic: nil
        }
    }

    func palette(for colorScheme: ColorScheme) -> FlowingGradientPalette {
        let dark = colorScheme == .dark
        switch self {
        case .flowing, .flowingAroundChart, .classic: return dark ? .night : .day
        case .flowingBright: return dark ? .nightBright : .day
        case .rings: return dark ? .ringsNight : .ringsDay
        case .ringsBlurred: return (dark ? FlowingGradientPalette.ringsNight : .ringsDay).blurred(1)
        case .mist: return dark ? .mistNight : .mistDay
        case .haloWhite: return dark ? .haloWhite.dimmed(0.72) : .haloWhite
        case .haloCyan: return dark ? .haloCyan.dimmed(0.72) : .haloCyan
        case .clearSky: return dark ? .clearSkyNight : .clearSkyDay
        }
    }
}

struct FlowingGradientPalette {
    var baseTop: Color
    var baseBottom: Color
    var halo: Color
    var core: Color
    /// The warm edge where the glow's colours split apart.
    var fringe: Color
    /// How far the split opens; 0 turns it off.
    var dispersion: Double
    /// Film-grain amplitude. Keep > 0 on dark palettes to avoid banding.
    var grain: Double
    /// Overall glow strength, 0–1. Lower is calmer and darker.
    var intensity: Double = 1
    /// Where the mist's light sits and how it moves, in height units:
    /// centre y (-0.5 top, 0.5 bottom), sideways sway, width, height.
    /// Only `mistGlow` reads it.
    var lightShape = SIMD4<Float>(-0.30, 0.12, 1.5, 0.46)
    /// Softness of the rings, 0 (thin sharp rims) to 1 (wide glowing
    /// bands). Only `flowingRings` reads it.
    var blur: Double = 0

    /// A deep-blue ground with a calm blue glow, sampled from the calm
    /// reference frame.
    static let night = FlowingGradientPalette(
        baseTop: Color(red: 0.012, green: 0.020, blue: 0.130),
        baseBottom: Color(red: 0.012, green: 0.020, blue: 0.130),
        halo: Color(red: 0.000, green: 0.420, blue: 0.710),
        core: Color(red: 0.000, green: 0.580, blue: 0.900),
        fringe: Color(red: 1.000, green: 0.450, blue: 0.850),
        dispersion: 2,
        grain: 0.035,
        intensity: 0.6
    )

    /// The home page's light gradient (Figma 223:31122, #9ADCFF to white)
    /// set moving: a vivid azure halo with a white core drifts over it.
    static let day = FlowingGradientPalette(
        baseTop: Color(red: 154 / 255, green: 220 / 255, blue: 1),
        baseBottom: .white,
        halo: Color(red: 0.300, green: 0.600, blue: 1.000),
        core: .white,
        // The pink-to-violet band beside a bright sky edge. It sits behind
        // the glass card, so it can be brighter than the open sky above.
        fringe: Color(red: 0.980, green: 0.600, blue: 0.820),
        dispersion: 2,
        grain: 0.012
    )

    /// For the arcs: a deeper blue so the bands read against the navy,
    /// white rims and lit centres, and a peach warmth at the lower sides.
    /// The earlier, brighter night: a vivid blue halo and a pale cyan core
    /// at full strength.
    static let nightBright = FlowingGradientPalette(
        baseTop: Color(red: 0.012, green: 0.020, blue: 0.075),
        baseBottom: Color(red: 0.012, green: 0.020, blue: 0.075),
        halo: Color(red: 0.100, green: 0.520, blue: 1.000),
        core: Color(red: 0.600, green: 1.000, blue: 1.000),
        fringe: Color(red: 1.000, green: 0.450, blue: 0.850),
        dispersion: 2,
        grain: 0.035
    )

    /// For the mist: its colours are the shader's own ramp, so only grain
    /// and intensity matter. Full strength by day; by night the light is
    /// held back so the top stays steel blue under white text.
    static let mistDay = FlowingGradientPalette(
        baseTop: .white, baseBottom: .black, halo: .blue, core: .white, fringe: .white,
        dispersion: 0, grain: 0.02, intensity: 1
    )

    /// Night: the light sits below the middle and narrower, so the top falls dark and
    /// it visibly sways side to side with a slight rise and fall.
    static let mistNight = FlowingGradientPalette(
        baseTop: .white, baseBottom: .black, halo: .blue, core: .white, fringe: .white,
        dispersion: 0, grain: 0.025, intensity: 0.72,
        lightShape: SIMD4<Float>(0.08, 0.22, 0.85, 0.36)
    )

    /// For the big halo, the five ramp colours darkest to brightest are
    /// baseBottom, fringe, halo, core, baseTop.
    static let haloWhite = FlowingGradientPalette(
        baseTop: .white,
        baseBottom: Color(red: 0.030, green: 0.034, blue: 0.042),
        halo: Color(red: 0.520, green: 0.545, blue: 0.580),
        core: Color(red: 0.880, green: 0.895, blue: 0.915),
        fringe: Color(red: 0.150, green: 0.160, blue: 0.180),
        dispersion: 0,
        grain: 0.02
    )

    static let haloCyan = FlowingGradientPalette(
        baseTop: Color(red: 0.860, green: 0.985, blue: 1.000),
        baseBottom: Color(red: 0.008, green: 0.028, blue: 0.055),
        halo: Color(red: 0.040, green: 0.440, blue: 0.690),
        core: Color(red: 0.420, green: 0.840, blue: 0.950),
        fringe: Color(red: 0.020, green: 0.140, blue: 0.260),
        dispersion: 0,
        grain: 0.02
    )

    /// The same palette with its rings softened.
    func blurred(_ blur: Double) -> FlowingGradientPalette {
        var palette = self
        palette.blur = blur
        return palette
    }

    /// The same palette with its light held back, for dark mode.
    func dimmed(_ intensity: Double) -> FlowingGradientPalette {
        var palette = self
        palette.intensity = intensity
        return palette
    }

    /// For the arch: baseTop is the sky, core the rim, halo the inside.
    /// Day is sampled from the Figma render of 486:6627; night is the same
    /// arch in navy with a cyan rim.
    static let clearSkyDay = FlowingGradientPalette(
        baseTop: Color(red: 0.482, green: 0.820, blue: 1.000),
        baseBottom: Color(red: 0.482, green: 0.820, blue: 1.000),
        halo: Color(red: 0.680, green: 0.890, blue: 1.000),
        core: Color(red: 0.945, green: 0.980, blue: 1.000),
        fringe: .white,
        dispersion: 1,
        grain: 0.012
    )

    static let clearSkyNight = FlowingGradientPalette(
        baseTop: Color(red: 0.020, green: 0.070, blue: 0.160),
        baseBottom: Color(red: 0.020, green: 0.070, blue: 0.160),
        halo: Color(red: 0.060, green: 0.200, blue: 0.360),
        core: Color(red: 0.500, green: 0.820, blue: 0.980),
        fringe: .white,
        dispersion: 1,
        grain: 0.03
    )

    static let ringsNight = FlowingGradientPalette(
        baseTop: night.baseTop,
        baseBottom: night.baseBottom,
        halo: Color(red: 0.100, green: 0.400, blue: 1.000),
        core: Color(red: 0.920, green: 0.970, blue: 1.000),
        fringe: Color(red: 1.000, green: 0.620, blue: 0.450),
        dispersion: 2,
        grain: 0.035
    )

    static let ringsDay = FlowingGradientPalette(
        baseTop: day.baseTop,
        baseBottom: day.baseBottom,
        halo: Color(red: 0.220, green: 0.480, blue: 1.000),
        core: .white,
        fringe: Color(red: 0.980, green: 0.600, blue: 0.620),
        dispersion: 2,
        grain: 0.012
    )

}

struct FlowingGradientBackground: View {
    enum Pattern {
        /// Drifting soft halos (`flowingGradient` in the .metal file).
        case glow
        /// Concentric glowing arcs lit by the same drifting light (`flowingRings`).
        case rings
        /// One huge soft light from the top (`mistGlow`).
        case mist
        /// One big wandering halo through a five-colour ramp (`bigHalo`).
        case bigHalo
        /// A wide breathing arch of light (`archGlow`).
        case arch

        var functionName: String {
            switch self {
            case .glow: "flowingGradient"
            case .rings: "flowingRings"
            case .mist: "mistGlow"
            case .bigHalo: "bigHalo"
            case .arch: "archGlow"
            }
        }
    }

    var pattern: Pattern
    var palette: FlowingGradientPalette
    /// 1 = default pace. The reference animation is slow; 0.6–1.5 works well.
    var speed: Double
    /// Stops the clock, e.g. while the view is covered or off screen.
    var isPaused: Bool
    /// Vertical band the glow must stay out of (e.g. a chart), as fractions of
    /// the view height from the top: `0.12...0.52`. The glow then lives above
    /// and below it, handing over between the two. `nil` = no band. The
    /// background ignores safe areas, so measure against the full screen.
    var clearBand: ClosedRange<Double>?
    /// The same band in points, for callers that know where the chart is
    /// but not the view's height. Used when `clearBand` is nil.
    var clearBandPoints: ClosedRange<CGFloat>?
    /// Softness of the band edges, as a fraction of the view height.
    var feather: Double
    /// No glow is drawn above this y (in the view's own space); nil lets it
    /// wander the whole view.
    var glowTop: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    // Measure time from when the view appears: `timeIntervalSinceReferenceDate`
    // is ~8e8 s, which loses all sub-second precision once cast to Float.
    @State private var start = Date.now

    init(
        pattern: Pattern = .glow,
        palette: FlowingGradientPalette = .night,
        speed: Double = 1,
        isPaused: Bool = false,
        glowTop: CGFloat? = nil,
        clearBand: ClosedRange<Double>? = nil,
        clearBandPoints: ClosedRange<CGFloat>? = nil,
        feather: Double = 0.06
    ) {
        self.clearBand = clearBand
        self.clearBandPoints = clearBandPoints
        self.feather = feather
        self.pattern = pattern
        self.palette = palette
        self.speed = speed
        self.isPaused = isPaused
        self.glowTop = glowTop
    }

    var body: some View {
        let paused = isPaused || reduceMotion || scenePhase != .active
        TimelineView(.animation(paused: paused)) { context in
            // With Reduce Motion on, show a single pleasant still frame.
            let time = reduceMotion ? 12 : context.date.timeIntervalSince(start) * speed
            Rectangle()
                .fill(palette.baseBottom)
                .visualEffect { [pattern, palette, glowTop, clearBand, clearBandPoints, feather] content, proxy in
                    let height = max(proxy.size.height, 1)
                    let band = clearBand
                        ?? clearBandPoints.map { Double($0.lowerBound / height)...Double($0.upperBound / height) }
                    return content.colorEffect(
                        // Both functions take the same arguments.
                        Shader(function: ShaderFunction(library: .default, name: pattern.functionName), arguments: [
                            .float2(proxy.size),
                            .float(Float(time)),
                            .color(palette.baseTop),
                            .color(palette.baseBottom),
                            .color(palette.halo),
                            .color(palette.core),
                            .float(Float(palette.grain)),
                            .float(Float(min(max(glowTop ?? 0, 0), proxy.size.height))),
                            .color(palette.fringe),
                            .float(Float(palette.dispersion)),
                            .float2(Float(band?.lowerBound ?? 0), Float(band?.upperBound ?? 0)),
                            .float(Float(feather)),
                            .float(Float(palette.intensity)),
                            .float4(palette.lightShape.x, palette.lightShape.y, palette.lightShape.z, palette.lightShape.w),
                            .float(Float(palette.blur)),
                        ])
                    )
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview("Night") {
    FlowingGradientBackground(palette: .night)
}

#Preview("Day") {
    FlowingGradientBackground(palette: .day)
}

#Preview("Avoid chart") {
    // Chart occupies 12%–52% of the height; glow stays above/below it.
    FlowingGradientBackground(palette: .night, clearBand: 0.12...0.52)
}

#Preview("Rings, night") {
    FlowingGradientBackground(pattern: .rings, palette: .ringsNight, glowTop: 380)
}

#Preview("Halo, cyan") {
    FlowingGradientBackground(pattern: .bigHalo, palette: .haloCyan)
}

#Preview("Clear sky") {
    FlowingGradientBackground(pattern: .arch, palette: .clearSkyDay)
}

#Preview("Mist") {
    FlowingGradientBackground(pattern: .mist, palette: .mistDay)
}

#Preview("Day, below a card") {
    FlowingGradientBackground(palette: .day, glowTop: 420)
}
