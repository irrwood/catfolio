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

/// Shared capsule for chart labels and ranking numbers. The opaque tint keeps
/// text contrast independent of the chart or glass underneath it.
struct ReturnsChartBadge: View {
    let text: String
    let color: Color
    var width: CGFloat = 36
    var height: CGFloat = 28
    var fontSize: CGFloat = 16
    var isStriped = false
    @Environment(\.self) private var environment

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.horizontal, 4)
            .frame(width: width, height: height)
            .foregroundStyle(Self.textColor(on: background, environment: environment))
            .background(background, in: Capsule())
            .overlay {
                if isStriped {
                    Canvas { context, size in
                        var stripes = Path()
                        for x in stride(from: -size.height, through: size.width, by: 6) {
                            stripes.move(to: CGPoint(x: x, y: size.height))
                            stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                        }
                        context.stroke(stripes, with: .color(color.opacity(0.25)), lineWidth: 2)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
            .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
    }

    private var background: Color { isStriped ? .white : color }

    static func textColor(on color: Color, environment: EnvironmentValues) -> Color {
        let value = color.resolve(in: environment)
        func linear(_ channel: Float) -> Double {
            let c = Double(channel)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
        // Choose whichever foreground provides the stronger contrast ratio.
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? .black : .white
    }
}

struct ReturnsRankBadge: View {
    let rank: Int?
    let color: Color
    let isPortfolio: Bool
    var isStriped = false
    // Kept for existing previews; every ranking now uses the shared capsule.
    var usesTintedGlass = true

    var body: some View {
        ReturnsChartBadge(text: rank.map(String.init) ?? "", color: color, isStriped: isStriped)
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
