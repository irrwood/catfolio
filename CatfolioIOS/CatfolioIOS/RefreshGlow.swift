import SwiftUI

/// The home page puts its cached figures up first and refreshes behind them.
/// While that is running, a light sweeps along the figures still being
/// refreshed: the number keeps its place and stays readable, but it reads as
/// busy rather than settled, and nothing has to be replaced by a grey box.
///
/// The light travels through the figure's own glyphs rather than behind them.
/// A halo behind the number disappears against the hero's blue gradient and
/// against the white card below it; a sheen on the digits reads on both.
///
/// The sweep is driven by the clock, not by state, so it runs only while the
/// figure is on screen and stops the moment the refresh ends.
struct RefreshGlow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let isActive: Bool

    /// One pass, then a rest before the next: a heartbeat, not a barber's pole.
    private static let sweep: Double = 1.1
    private static let rest: Double = 0.5

    private var period: Double { Self.sweep + Self.rest }

    private var light: Color {
        CatfolioStyle.blue.opacity(colorScheme == .dark ? 0.95 : 0.8)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    sheen
                        .allowsHitTesting(false)
                        .mask(content)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: isActive)
    }

    @ViewBuilder
    private var sheen: some View {
        if reduceMotion {
            // No travelling light: a still tint that says the same thing.
            light.opacity(0.5)
        } else {
            GeometryReader { geometry in
                TimelineView(.animation) { timeline in
                    let width = max(geometry.size.width, 1)
                    let band = max(60, width * 0.4)
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    let progress = elapsed.truncatingRemainder(dividingBy: period) / Self.sweep
                    LinearGradient(
                        colors: [light.opacity(0), light, light.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: band)
                    .offset(x: -band + min(progress, 1) * (width + band))
                    // Off screen for the resting part of the period, so the
                    // light passes by rather than looping without a break.
                    .opacity(progress <= 1 ? 1 : 0)
                }
            }
        }
    }
}

extension View {
    /// A light that sweeps along a figure while it is stale and refreshing.
    func refreshGlow(isActive: Bool) -> some View {
        modifier(RefreshGlow(isActive: isActive))
    }
}
