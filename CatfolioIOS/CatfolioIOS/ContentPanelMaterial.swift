import SwiftUI

/// One backdrop per content panel: the page blurred and a little more
/// saturated, under a white wash by day; at night the material's own grey is
/// taken back out, leaving the blur under 12% white — as bright as the
/// Liquid Glass tiles beside it.
/// Controls retain their own native Liquid Glass treatment above this layer.
struct ContentPanelMaterial: View {
    let colorScheme: ColorScheme
    let isOpaque: Bool
    let increasedContrast: Bool
    var cornerRadius: CGFloat = SettingsTemplate.cardRadius
    /// A pressed panel thins its white a little, so more of the page shows
    /// through: the press reads as the panel giving way, with no second fill.
    var isPressed = false
    @Environment(\.displayScale) private var displayScale

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// A stronger white wash keeps daylight panels bright without removing
    /// the backdrop's colour or the material's blur.
    private static let dayWash = Color.white.opacity(0.72)
    private static let pressedDayWash = Color.white.opacity(0.62)
    /// Regular glass over black reads at 32/255; 12% white matches it, and
    /// the backdrop's colour still shows through.
    private static let nightFill = Color.white.opacity(0.12)
    private static let pressedNightFill = Color.white.opacity(0.08)
    /// The night material lifts black to a flat grey. Plus-darker with this
    /// grey takes that lift back out, so black stays black under the fill.
    private static let nightMaterialLift = CatfolioTheme.nightMaterialLift
    /// A touch more colour from the page than the material gives on its own.
    private static let backdropSaturation = 1.3

    private var border: Color {
        if increasedContrast {
            return colorScheme == .dark ? .white.opacity(0.28) : .white
        }
        return .white.opacity(colorScheme == .dark ? 0.06 : 0.8)
    }

    var body: some View {
        Group {
            if isOpaque || increasedContrast {
                shape.fill(SettingsTemplate.card)
            } else if colorScheme == .dark {
                shape.fill(.ultraThinMaterial)
                    .saturation(Self.backdropSaturation)
                    .overlay { shape.fill(Self.nightMaterialLift).blendMode(.plusDarker) }
                    .overlay { shape.fill(isPressed ? Self.pressedNightFill : Self.nightFill) }
            } else {
                // Blur the backdrop beneath the white wash without refraction
                // or interactive glass.
                shape.fill(.thinMaterial)
                    .saturation(Self.backdropSaturation)
                    .overlay { shape.fill(isPressed ? Self.pressedDayWash : Self.dayWash) }
            }
        }
        .overlay {
            shape.strokeBorder(border, lineWidth: increasedContrast ? 1 : 1 / max(displayScale, 1))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ContentPanelSurface: ViewModifier {
    var cornerRadius: CGFloat = SettingsTemplate.cardRadius
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isPanelPressed) private var isPressed

    func body(content: Content) -> some View {
        content
            .background {
                ContentPanelMaterial(colorScheme: colorScheme, isOpaque: reduceTransparency,
                                     increasedContrast: contrast == .increased, cornerRadius: cornerRadius,
                                     isPressed: isPressed)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Translucent rules blend with the same backing as their rows.
struct ContentPanelSeparator: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color.primary.opacity(contrast == .increased ? 0.24 : (colorScheme == .dark ? 0.12 : 0.08))
            .frame(height: contrast == .increased ? 1 : 1 / max(displayScale, 1))
            .accessibilityHidden(true)
    }
}

private struct PanelPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by `PanelPressButtonStyle` while its panel is under a finger.
    var isPanelPressed: Bool {
        get { self[PanelPressedKey.self] }
        set { self[PanelPressedKey.self] = newValue }
    }
}

/// Whole-card entries share a gentle press, including cards with artwork
/// instead of a material surface. Native buttons still own tap cancellation.
struct PanelPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PanelPressFeedback(isPressed: configuration.isPressed,
                                                         reduceMotion: reduceMotion))
    }
}

struct PanelPressFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let isPressed: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let pressed = isPressed && isEnabled
        content
            .environment(\.isPanelPressed, pressed)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .opacity(pressed && reduceMotion ? 0.8 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: pressed ? 0.12 : 0.2), value: pressed)
    }
}
