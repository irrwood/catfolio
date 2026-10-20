import SwiftUI

/// Figma 722:138: the sun turns behind a fixed horizon in a 24-point canvas.
struct RotatingSunriseIcon: View {
    var size: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var startedAt = Date()

    var body: some View {
        Group {
            if Self.shouldAnimate(isVisible: isVisible, scenePhase: scenePhase, reduceMotion: reduceMotion) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    SunriseIconFrame(angle: Self.angle(elapsed: timeline.date.timeIntervalSince(startedAt)))
                }
            } else {
                Image("SunriseRest").renderingMode(.template)
            }
        }
        .frame(width: 24, height: 24)
        .scaleEffect(size / 24)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { startedAt = Date(); isVisible = true }
        .onDisappear { isVisible = false }
    }

    static func shouldAnimate(isVisible: Bool, scenePhase: ScenePhase, reduceMotion: Bool) -> Bool {
        isVisible && scenePhase == .active && !reduceMotion
    }

    static func angle(elapsed: TimeInterval) -> Angle {
        .degrees(max(0, elapsed).truncatingRemainder(dividingBy: 12) * 30)
    }
}

/// The full exported sun rotates about (12, 13), not the canvas center.
/// Clip before drawing the horizon, retaining the design's two-point gap.
struct SunriseIconFrame: View {
    var angle: Angle = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("SunriseSun")
                .renderingMode(.template)
                .rotationEffect(angle, anchor: UnitPoint(x: 0.5, y: 13.0 / 24))
                .frame(width: 24, height: 16, alignment: .topLeading)
                .clipped()
            Capsule()
                .frame(width: 20, height: 2)
                .offset(x: 2, y: 18)
        }
        .frame(width: 24, height: 24, alignment: .topLeading)
        .clipped()
    }
}
