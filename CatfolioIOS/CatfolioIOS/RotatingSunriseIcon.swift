import SwiftUI

/// The existing sun rises or sets behind its fixed horizon, on a 24-point canvas.
struct RotatingSunriseIcon: View {
    enum Motion: Equatable { case rising, setting }

    var size: CGFloat = 24
    var motion: Motion = .setting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var startedAt = Date()

    var body: some View {
        Group {
            if Self.shouldAnimate(isVisible: isVisible, scenePhase: scenePhase, reduceMotion: reduceMotion) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    let frame = Self.frame(elapsed: elapsed, motion: motion)
                    SunriseIconFrame(angle: Self.angle(elapsed: elapsed),
                                     sunOffset: frame.offset, sunOpacity: frame.opacity)
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
        .onChange(of: motion) { startedAt = Date() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startedAt = Date() }
        }
    }

    static func shouldAnimate(isVisible: Bool, scenePhase: ScenePhase, reduceMotion: Bool) -> Bool {
        isVisible && scenePhase == .active && !reduceMotion
    }

    static func angle(elapsed: TimeInterval) -> Angle {
        .degrees(max(0, elapsed).truncatingRemainder(dividingBy: 12) * 30)
    }

    struct MotionFrame {
        let offset: CGFloat
        let opacity: Double
    }

    static func frame(elapsed: TimeInterval, motion: Motion) -> MotionFrame {
        // Hold the familiar icon for most of the six-second loop. The reset
        // happens while the sun is hidden; the horizon never moves or fades.
        let phase = (max(0, elapsed) + (motion == .setting ? 3.6 : 0))
            .truncatingRemainder(dividingBy: 6)
        func ease(_ value: Double) -> Double {
            let t = min(1, max(0, value))
            return t * t * (3 - 2 * t)
        }
        switch motion {
        case .rising:
            return .init(offset: 14 * (1 - ease((phase - 0.4) / 2)),
                         opacity: 1 - ease((phase - 5.6) / 0.4))
        case .setting:
            return .init(offset: 14 * ease((phase - 3.6) / 2),
                         opacity: ease(phase / 0.4))
        }
    }
}

/// The full exported sun rotates about (12, 13), not the canvas center.
/// Clip before drawing the horizon, retaining the design's two-point gap.
struct SunriseIconFrame: View {
    var angle: Angle = .zero
    var sunOffset: CGFloat = 0
    var sunOpacity: Double = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("SunriseSun")
                .renderingMode(.template)
                .rotationEffect(angle, anchor: UnitPoint(x: 0.5, y: 13.0 / 24))
                .offset(y: sunOffset)
                .opacity(sunOpacity)
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
