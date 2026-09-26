//  FlowingGradientBackground.swift
//
//  Full-screen animated background driven by FlowingGradient.metal.
//  Requires iOS 17 / macOS 14 (SwiftUI shader effects).

import SwiftUI

/// The home page's backdrop: the static gradient it has always had, or the
/// flowing shader. Stored per device.
enum HomeBackgroundStyle: String, CaseIterable, Identifiable {
    case flowing
    case classic

    static let preferenceKey = "catfolio.homeBackgroundStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flowing: L10n.text("动态")
        case .classic: L10n.text("经典")
        }
    }
}

struct FlowingGradientPalette {
    var baseTop: Color
    var baseBottom: Color
    var halo: Color
    var core: Color
    /// Film-grain amplitude. Keep > 0 on dark palettes to avoid banding.
    var grain: Double

    /// A deep navy ground with a blue halo and a cyan core.
    static let night = FlowingGradientPalette(
        baseTop: Color(red: 0.012, green: 0.020, blue: 0.075),
        baseBottom: Color(red: 0.012, green: 0.020, blue: 0.075),
        halo: Color(red: 0.000, green: 0.420, blue: 1.000),
        core: Color(red: 0.000, green: 0.950, blue: 1.000),
        grain: 0.035
    )

    /// The home page's light gradient (Figma 223:31122, #9ADCFF to white)
    /// set moving: a deeper sky halo with a near-white core drifts over it.
    static let day = FlowingGradientPalette(
        baseTop: Color(red: 154 / 255, green: 220 / 255, blue: 1),
        baseBottom: .white,
        halo: Color(red: 0.420, green: 0.780, blue: 1.000),
        core: Color(red: 0.930, green: 0.980, blue: 1.000),
        grain: 0.012
    )

    static func matching(_ colorScheme: ColorScheme) -> FlowingGradientPalette {
        colorScheme == .dark ? .night : .day
    }
}

struct FlowingGradientBackground: View {
    var palette: FlowingGradientPalette
    /// 1 = default pace. The reference animation is slow; 0.6–1.5 works well.
    var speed: Double
    /// Stops the clock, e.g. while the view is covered or off screen.
    var isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    // Measure time from when the view appears: `timeIntervalSinceReferenceDate`
    // is ~8e8 s, which loses all sub-second precision once cast to Float.
    @State private var start = Date.now

    init(palette: FlowingGradientPalette = .night, speed: Double = 1, isPaused: Bool = false) {
        self.palette = palette
        self.speed = speed
        self.isPaused = isPaused
    }

    var body: some View {
        let paused = isPaused || reduceMotion || scenePhase != .active
        TimelineView(.animation(paused: paused)) { context in
            // With Reduce Motion on, show a single pleasant still frame.
            let time = reduceMotion ? 12 : context.date.timeIntervalSince(start) * speed
            Rectangle()
                .fill(palette.baseBottom)
                .visualEffect { [palette] content, proxy in
                    content.colorEffect(
                        ShaderLibrary.flowingGradient(
                            .float2(proxy.size),
                            .float(Float(time)),
                            .color(palette.baseTop),
                            .color(palette.baseBottom),
                            .color(palette.halo),
                            .color(palette.core),
                            .float(Float(palette.grain))
                        )
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
