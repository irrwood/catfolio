import Foundation

/// Which exported logo tile to draw: the light logo (white tile), the dark logo
/// (brand-colored plate), or whichever matches the current appearance.
enum AssetLogoStyle: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    static let preferenceKey = "catfolio.assetLogoStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: L10n.text("跟随外观")
        case .light: L10n.text("浅色 Logo")
        case .dark: L10n.text("深色 Logo")
        }
    }

    /// True when the dark (brand-plate) export should be drawn.
    func usesDarkLogo(darkAppearance: Bool) -> Bool {
        switch self {
        case .automatic: darkAppearance
        case .light: false
        case .dark: true
        }
    }
}
