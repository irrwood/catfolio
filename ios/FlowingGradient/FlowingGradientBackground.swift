//  FlowingGradientBackground.swift
//
//  Full-screen animated background driven by FlowingGradient.metal.
//  Requires iOS 17 / macOS 14 (SwiftUI shader effects).

import SwiftUI

public struct FlowingGradientBackground: View {
    public var baseColor: Color
    public var haloColor: Color
    public var coreColor: Color
    /// 1 = default pace. The reference animation is slow; 0.6–1.5 works well.
    public var speed: Double
    /// Film-grain amplitude. Keep > 0 on dark palettes to avoid banding.
    public var grain: Double
    /// Overall glow strength, 0–1. Lower is calmer and darker.
    public var intensity: Double
    /// Vertical band the glow must stay out of (e.g. a chart), as fractions of
    /// the view height from the top: `0.12...0.52`. The glow then lives above
    /// and below it, handing over between the two. `nil` = roam everywhere.
    /// The background ignores safe areas, so measure against the full screen.
    public var clearBand: ClosedRange<Double>?
    /// Softness of the band edges, as a fraction of the view height.
    public var feather: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    // Measure time from when the view appears: `timeIntervalSinceReferenceDate`
    // is ~8e8 s, which loses all sub-second precision once cast to Float.
    @State private var start = Date.now

    public init(
        baseColor: Color = Color(red: 0.012, green: 0.020, blue: 0.130),
        haloColor: Color = Color(red: 0.000, green: 0.420, blue: 0.710),
        coreColor: Color = Color(red: 0.000, green: 0.580, blue: 0.900),
        speed: Double = 1,
        grain: Double = 0.035,
        intensity: Double = 0.6,
        clearBand: ClosedRange<Double>? = nil,
        feather: Double = 0.06
    ) {
        self.baseColor = baseColor
        self.haloColor = haloColor
        self.coreColor = coreColor
        self.speed = speed
        self.grain = grain
        self.intensity = intensity
        self.clearBand = clearBand
        self.feather = feather
    }

    public var body: some View {
        let paused = reduceMotion || scenePhase != .active
        TimelineView(.animation(paused: paused)) { context in
            // With Reduce Motion on, show a single pleasant still frame.
            let time = reduceMotion ? 12 : context.date.timeIntervalSince(start) * speed
            let band = clearBand.map { (Float($0.lowerBound), Float($0.upperBound)) } ?? (0, 0)
            Rectangle()
                .fill(baseColor)
                .visualEffect { [baseColor, haloColor, coreColor, grain, intensity, feather] content, proxy in
                    content.colorEffect(
                        ShaderLibrary.flowingGradient(
                            .float2(proxy.size),
                            .float(Float(time)),
                            .color(baseColor),
                            .color(haloColor),
                            .color(coreColor),
                            .float(Float(grain)),
                            .float2(band.0, band.1),
                            .float(Float(feather)),
                            .float(Float(intensity))
                        )
                    )
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#Preview("Full screen") {
    ZStack {
        FlowingGradientBackground()
        VStack(spacing: 24) {
            Text("EMBRACE SERENDIPITY")
                .font(.footnote.weight(.medium))
                .kerning(3)
            Text("Save more cards to\nunlock this feature.")
                .font(.system(size: 40, design: .serif))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
    }
}

#Preview("Avoid chart") {
    GeometryReader { geo in
        ZStack(alignment: .top) {
            // Chart occupies 12%–52% of the height; glow stays above/below it.
            FlowingGradientBackground(clearBand: 0.12...0.52)
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.3), style: StrokeStyle(dash: [4]))
                    .frame(height: geo.size.height * 0.40 - 16)
                    .overlay(Text("chart").foregroundStyle(.white.opacity(0.5)))
                    .padding(.top, geo.size.height * 0.12 + 8)
                ForEach(0..<3) { _ in
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                        .frame(height: 64)
                }
            }
            .padding(.horizontal, 16)
        }
    }
    .ignoresSafeArea() // measure fractions against the same full-screen height
}
