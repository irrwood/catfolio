import SwiftUI
import UIKit

/// An empty page's message (Figma 577:6506): a 64 pt grey disc with the
/// icon, a 17 pt title, and the explanation at 40% ink, centred in 284 pt.
struct CatfolioEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let message: String
    var icon: Image = Image("EmptyStateInbox")

    var body: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(LinearGradient(colors: discColors, startPoint: .top, endPoint: .bottom))
                .overlay { Circle().strokeBorder(SettingsTemplate.cardBorder, lineWidth: 1) }
                .overlay {
                    icon
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .foregroundStyle(iconColors)
                }
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(title)
                .font(Typography.rounded(size: 17, weight: .semibold))
                .foregroundStyle(CatfolioTheme.primaryText)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Typography.rounded(size: 17, weight: .regular))
                .foregroundStyle(CatfolioTheme.primaryText.opacity(0.4))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 284)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// `#F3F3F3` to `#C3C3C3` by day; the same fall in light at night.
    private var discColors: [Color] {
        colorScheme == .dark
            ? [Color(white: 0x3A / 255), CatfolioPalette.emptyStateGraphite]
            : [Color(white: 0xF3 / 255), Color(white: 0xC3 / 255)]
    }

    /// For a template symbol in place of the drawn inbox, which carries its
    /// own gradient.
    private var iconColors: LinearGradient {
        LinearGradient(colors: colorScheme == .dark
                ? [Color(white: 0.95), Color(white: 0.6)]
                : [CatfolioPalette.emptyStateGraphite, Color(white: 0x6D / 255)],
            startPoint: .top, endPoint: .bottom)
    }
}
