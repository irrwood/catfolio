import SwiftUI
import UIKit

/// A ranking row that swipes: right to highlight its line or band (again to
/// clear it), left to take it away — out of the comparison, or off the
/// chart on the source pages. A row with nothing to take away only
/// highlights.
struct ReturnsSwipeRow<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let color: Color
    let isHighlighted: Bool
    let canRemove: Bool
    var removeTitle = L10n.text("移除")
    var removeIcon = "trash"
    /// True when the row leaves the list; false when it stays (dimmed, say)
    /// and should spring back instead of sliding out.
    var removeSlidesOut = true
    let onHighlight: () -> Void
    let onRemove: () -> Void
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var isRemoving = false

    private static var threshold: CGFloat { 76 }
    private var isPastThreshold: Bool {
        offset >= Self.threshold || (canRemove && offset <= -Self.threshold)
    }

    var body: some View {
        content
            .offset(x: offset)
            .background { actions }
            .gesture(ReturnsHorizontalPan(onChange: drag, onEnd: end))
            .sensoryFeedback(.impact(weight: .light), trigger: isPastThreshold) { wasPast, isPast in
                hapticsEnabled && !wasPast && isPast
            }
    }

    private var actions: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            if offset > 0 {
                action(icon: "highlighter",
                       title: isHighlighted ? L10n.text("取消高亮") : L10n.text("高亮"),
                       tint: color, armedText: CatfolioTheme.blackTextOnColor, width: offset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if offset < 0, canRemove {
                action(icon: removeIcon, title: removeTitle, tint: CatfolioStyle.red, armedText: .white,
                       width: -offset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .clipShape(shape)
    }

    private func action(icon: String, title: String, tint: Color, armedText: Color, width: CGFloat) -> some View {
        let isArmed = width >= Self.threshold
        return VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(isArmed ? armedText : .white)
        .scaleEffect(isArmed ? 1 : 0.86)
        .opacity(min(1, Double(width / 44)))
        .frame(width: max(0, width - 8))
        .frame(maxHeight: .infinity)
        .background(tint.opacity(isArmed ? 1 : 0.35),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isArmed)
    }

    private func drag(_ translation: CGFloat) {
        guard !isRemoving else { return }
        // Past the threshold, and wherever there is no action, the row resists.
        func resisted(_ value: CGFloat, limit: CGFloat) -> CGFloat {
            abs(value) <= limit ? value : (value > 0 ? 1 : -1) * (limit + (abs(value) - limit) * 0.3)
        }
        if translation < 0, !canRemove {
            offset = resisted(translation, limit: 0)
        } else {
            offset = resisted(translation, limit: Self.threshold + 24)
        }
    }

    private func end(_ translation: CGFloat, _ velocity: CGFloat) {
        guard !isRemoving else { return }
        let settle: Animation? = reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.18)
        if offset >= Self.threshold || (offset > 30 && velocity > 700) {
            onHighlight()
            withAnimation(settle) { offset = 0 }
        } else if canRemove, offset <= -Self.threshold || (offset < -30 && velocity < -700) {
            guard removeSlidesOut else {
                onRemove()
                withAnimation(settle) { offset = 0 }
                return
            }
            isRemoving = true
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { offset = -500 } completion: {
                onRemove()
            }
        } else {
            withAnimation(settle) { offset = 0 }
        }
    }
}

/// A pan that only starts on a mostly sideways drag, so the page above still
/// scrolls when the finger lands on a row.
struct ReturnsHorizontalPan: UIGestureRecognizerRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            onChange(translation)
        case .ended, .cancelled, .failed:
            onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.3
        }
    }
}

struct ReturnsRankBadge: View {
    /// Nil for a row outside the ranking, such as the others or the principal.
    let rank: Int?
    let color: Color
    let isPortfolio: Bool
    /// The others' band: white under the chart's diagonal stripes, as the
    /// band itself is painted.
    var isStriped = false
    var usesTintedGlass = false
    @Environment(\.self) private var environment

    var body: some View {
        if usesTintedGlass {
            tintedGlassBadge
        } else {
            legacyBadge
        }
    }

    /// Two digits keep the design's 16pt type; longer ranks shrink inside the
    /// same slot, so the row's text never moves as the rank changes.
    private var rankText: some View {
        Text(rank.map(String.init) ?? "")
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(labelColor)
            .frame(width: 20, height: 28)
            .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var tintedGlassBadge: some View {
        if #available(iOS 26.0, *) {
            rankText.glassEffect(.regular.tint(color.opacity(0.8)), in: Capsule())
        } else {
            rankText.background(.ultraThinMaterial, in: Capsule())
                .background(color.opacity(0.8), in: Capsule())
        }
    }

    private var legacyBadge: some View {
        ZStack {
            if isStriped {
                Circle().fill(.white)
                Canvas { context, size in
                    var stripes = Path()
                    for x in stride(from: -size.height, through: size.width, by: 6) {
                        stripes.move(to: CGPoint(x: x - 4, y: size.height + 4))
                        stripes.addLine(to: CGPoint(x: x + size.height + 4, y: -4))
                    }
                    // Stronger than the band's 10%: on a 24pt ball the
                    // band's own tint would not read at all.
                    context.stroke(stripes, with: .color(Color(red: 92 / 255, green: 187 / 255, blue: 253 / 255).opacity(0.35)),
                                   lineWidth: 2.2)
                }
                .clipShape(Circle())
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.52), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 16, height: 9)
                    .offset(y: -6)
            } else if isPortfolio {
                Circle().fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255), location: 0),
                            .init(color: Color(red: 39 / 255, green: 148 / 255, blue: 66 / 255), location: 0.5),
                            .init(color: Color(red: 25 / 255, green: 97 / 255, blue: 43 / 255), location: 1),
                        ],
                        center: .bottom,
                        startRadius: 0,
                        endRadius: 24
                    )
                )
                // Figma's 16 × 11 ellipse starts 1.5 pt below the ball's top.
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.6), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 16, height: 11)
                    .offset(y: -5)
            } else {
                Circle().fill(color.opacity(0.88))
                if #available(iOS 26.0, *) {
                    Color.clear
                        .glassEffect(.clear.tint(color.opacity(0.28)), in: Circle())
                } else {
                    Circle().fill(.ultraThinMaterial).opacity(0.30)
                }
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.52), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 16, height: 9)
                    .offset(y: -6)
            }

            Text(rank.map(String.init) ?? "")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(labelColor)
        }
        .frame(width: 24, height: 24)
        .overlay {
            Circle().strokeBorder(isPortfolio || isStriped ? .black.opacity(0.1) : .white.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isPortfolio ? 0.25 : 0), radius: 7, y: 4)
        .shadow(color: .black.opacity(isPortfolio ? 0.20 : 0), radius: 1.5, y: 2)
    }
    private var labelColor: Color {
        guard usesTintedGlass else {
            return isPortfolio ? .white : Color(red: 0.004, green: 0.004, blue: 0.008)
        }
        let resolved = color.resolve(in: environment)
        let brightness = 0.2126 * resolved.red + 0.7152 * resolved.green + 0.0722 * resolved.blue
        return brightness < 0.7 ? .white : Color(white: 0.05)
    }

}

/// The ranking rows' card: faint glass on the comparison's dark field, and a
/// plain tinted card on a light page.
struct ReturnsGlassCardSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    var glow: Color?

    var body: some View {
        if colorScheme == .dark { dark } else { light }
    }

    private var light: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            shape.fill(Color.black.opacity(0.04))
            if let glow {
                RadialGradient(colors: [glow.opacity(0.22), .clear],
                               center: .leading, startRadius: 0, endRadius: 110)
                    .clipShape(shape)
            }
        }
        .allowsHitTesting(false)
    }

    private var dark: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            if #available(iOS 26.0, *) {
                Color.clear
                    .glassEffect(.clear.tint(.white.opacity(0.035)), in: shape)
                    .opacity(0.25)
            } else {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(.white.opacity(0.08))
            if let glow {
                RadialGradient(colors: [glow.opacity(0.30), .clear],
                               center: .leading, startRadius: 0, endRadius: 110)
                    .clipShape(shape)
            }
            shape.strokeBorder(.white.opacity(0.05), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// The comparison's ranking row, for the gain-sources and loss-analysis
/// lists: a ball in the band's colour, the company's logo, the name over
/// its detail, and the figure on the right, on the same card. Rows that are
/// not one company — the others, the principal — have no logo.
struct ReturnsSourceListRow<Trailing: View>: View {
    let rank: Int?
    let color: Color
    let title: String
    let subtitle: String
    /// Off: the band is hidden from the chart.
    let isOn: Bool
    /// The company's ticker and logo symbol; nil for a row that is not one
    /// company.
    var logo: (ticker: String, symbol: String)? = nil
    /// The others' row, whose band is striped.
    var isStriped = false
    var isOnBlueField = false
    var isHighlighted = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            ReturnsRankBadge(rank: rank, color: isOn ? color : Color(white: 0.55), isPortfolio: false,
                             isStriped: isStriped && isOn, usesTintedGlass: isOnBlueField)
                .padding(.trailing, 4)
            if let logo {
                AssetLogo(ticker: logo.ticker, logoSymbol: logo.symbol, size: 36, cornerRadius: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(isOnBlueField ? Color.white.opacity(0.5) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: 65)
        .foregroundStyle(isOnBlueField ? Color.white : Color.primary)
        .background {
            if isOnBlueField {
                RoundedRectangle(cornerRadius: 16).fill(.white.opacity(isHighlighted ? 0.2 : 0.1))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(isHighlighted ? color.opacity(0.85) : .white.opacity(0.05),
                                                                               lineWidth: isHighlighted ? 1.5 : 1) }
            } else { ReturnsGlassCardSurface() }
        }
        .opacity(isOn ? 1 : 0.4)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A ranking row set back while another is highlighted: covered by the
    /// page's own ground, so it darkens (on a dark page) and stays solid —
    /// fading its opacity let the page and the glass show through the card.
    func returnsDimmed(_ isDimmed: Bool, ground: Color = Color(uiColor: .systemBackground)) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ground.opacity(isDimmed ? 0.55 : 0))
                .allowsHitTesting(false)
        }
    }
}
