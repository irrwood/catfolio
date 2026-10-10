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
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    sheen
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .mask(content)
                        // A small contrast shift also reads on white digits.
                        .blendMode(.difference)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isActive)
    }

    @ViewBuilder
    private var sheen: some View {
        if reduceMotion {
            // No travelling light: a still tint that says the same thing.
            Color.white.opacity(0.04)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                AmountRefreshSheen(elapsed: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }
}

/// A soft band travels diagonally through the glyph mask, with a quiet pause
/// between passes. Pixel coordinates keep the angle at 45° even on a wide amount.
struct AmountRefreshSheen: View {
    let elapsed: TimeInterval

    var body: some View {
        Canvas { context, size in
            let progress = elapsed.truncatingRemainder(dividingBy: 3) / 2
            guard progress < 1 else { return }
            let span = size.width + size.height
            let halfBand = max(30, span * 0.2)
            let center = -halfBand + CGFloat(progress) * (span + 2 * halfBand)
            let start = (center - halfBand) / 2
            let end = (center + halfBand) / 2
            let light = Color.white.opacity(0.16)
            let gradient = Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: light.opacity(0.12), location: 0.2),
                .init(color: light.opacity(0.55), location: 0.35),
                .init(color: light, location: 0.5),
                .init(color: light.opacity(0.55), location: 0.65),
                .init(color: light.opacity(0.12), location: 0.8),
                .init(color: .clear, location: 1)
            ])
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                gradient, startPoint: CGPoint(x: start, y: start), endPoint: CGPoint(x: end, y: end)))
        }
    }
}

extension View {
    /// A light that sweeps along a figure while it is stale and refreshing.
    func refreshGlow(isActive: Bool) -> some View {
        modifier(RefreshGlow(isActive: isActive))
    }
}
