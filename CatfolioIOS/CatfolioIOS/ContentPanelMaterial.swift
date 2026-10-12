import SwiftUI

/// One backdrop per content panel. The system material blends the page's
/// colours; the neutral wash protects text without fixing the panel to blue.
/// Controls retain their own native Liquid Glass treatment above this layer.
struct ContentPanelMaterial: View {
    let colorScheme: ColorScheme
    let isOpaque: Bool
    let increasedContrast: Bool
    var cornerRadius: CGFloat = SettingsTemplate.cardRadius
    @Environment(\.displayScale) private var displayScale

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var wash: Color {
        // A stronger white wash keeps daylight panels bright without removing
        // the backdrop's colour or the material's blur.
        colorScheme == .dark ? .black.opacity(0.38) : .white.opacity(0.72)
    }

    private var border: Color {
        if increasedContrast {
            return colorScheme == .dark ? .white.opacity(0.28) : .white
        }
        return colorScheme == .dark ? .white.opacity(0.10) : .white.opacity(0.8)
    }

    var body: some View {
        Group {
            if isOpaque || increasedContrast {
                shape.fill(SettingsTemplate.card)
            } else {
                // The account overview's glass has a translucent charcoal body at
                // night. Approximate that colour with ordinary material, keeping
                // the backdrop visible without refraction or interactive glass.
                shape.fill(colorScheme == .dark ? .ultraThinMaterial : .thinMaterial)
                    .overlay { shape.fill(wash) }
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

    func body(content: Content) -> some View {
        content
            .background {
                ContentPanelMaterial(colorScheme: colorScheme, isOpaque: reduceTransparency,
                                     increasedContrast: contrast == .increased, cornerRadius: cornerRadius)
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
