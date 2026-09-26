import Foundation
import SwiftUI

/// Reviewed SVG logo pairs are rasterized into the AssetLogos folder for iOS.
/// ETF codes can share one issuer asset without duplicating thousands of files.
enum AssetLogoExportCatalog {
    private struct Manifest: Decodable {
        let logos: [String: Logo]
        let aliases: [String: String]
    }

    private struct Logo: Decodable {
        let themeColor: String
    }

    private static let manifest: Manifest? = {
        guard let url = Bundle.main.url(
            forResource: "LogoExports", withExtension: "json", subdirectory: "AssetLogos"
        ), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    static func imageURL(for symbol: String, dark: Bool) -> URL? {
        guard let stem = stem(for: symbol) else { return nil }
        return Bundle.main.url(
            forResource: stem + (dark ? ".dark" : ".light"),
            withExtension: "png",
            subdirectory: "AssetLogos"
        )
    }

    static func themeColor(for symbol: String) -> Color? {
        guard let stem = stem(for: symbol),
              let hex = manifest?.logos[stem]?.themeColor,
              hex.count == 7, hex.first == "#",
              let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// A renamed listing keeps the logo exported under its other code.
    private static func stem(for symbol: String) -> String? {
        TickerRenames.equivalents(of: symbol).lazy.compactMap { manifest?.aliases[$0] }.first
    }
}
