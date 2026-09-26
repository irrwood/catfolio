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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    // Measure time from when the view appears: `timeIntervalSinceReferenceDate`
    // is ~8e8 s, which loses all sub-second precision once cast to Float.
    @State private var start = Date.now

    public init(
        baseColor: Color = Color(red: 0.012, green: 0.020, blue: 0.075),
        haloColor: Color = Color(red: 0.000, green: 0.420, blue: 1.000),
        coreColor: Color = Color(red: 0.000, green: 0.950, blue: 1.000),
        speed: Double = 1,
        grain: Double = 0.035
    ) {
        self.baseColor = baseColor
        self.haloColor = haloColor
        self.coreColor = coreColor
        self.speed = speed
        self.grain = grain
    }

    public var body: some View {
        let paused = reduceMotion || scenePhase != .active
        TimelineView(.animation(paused: paused)) { context in
            // With Reduce Motion on, show a single pleasant still frame.
            let time = reduceMotion ? 12 : context.date.timeIntervalSince(start) * speed
            Rectangle()
                .fill(baseColor)
                .visualEffect { [baseColor, haloColor, coreColor, grain] content, proxy in
                    content.colorEffect(
                        ShaderLibrary.flowingGradient(
                            .float2(proxy.size),
                            .float(Float(time)),
                            .color(baseColor),
                            .color(haloColor),
                            .color(coreColor),
                            .float(Float(grain))
                        )
                    )
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#Preview {
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
