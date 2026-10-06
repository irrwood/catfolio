import ImageIO
import Observation
import SwiftUI
import UIKit

/// Presentation rules use image geometry and its canvas, not ticker-specific
/// guesses about which companies have wordmarks. Run once when decoding.
struct AssetLogoLayout: Equatable {
    let insetFraction: CGFloat
    let usesWhiteCanvas: Bool
    var usesDarkCanvas: Bool = false
    var edgeCanvas: EdgeColor? = nil
    var edgeTileBounds: CGRect? = nil

    struct EdgeColor: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    /// Locate an inset colour tile before sampling. Source padding can be
    /// transparent or baked-in white; neither should become a white frame.
    private static func matchingEdgeTile(_ pixels: [UInt8], edge: Int) -> (EdgeColor, CGRect)? {
        var minX = edge, minY = edge, maxX = -1, maxY = -1
        for y in 0..<edge { for x in 0..<edge {
            let i = (y * edge + x) * 4
            let alpha = Double(pixels[i + 3])
            guard alpha > 240,
                  min(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / alpha < 0.92 else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        } }
        let width = maxX - minX + 1, height = maxY - minY + 1
        // A broad, nearly square tile, not a narrow wordmark or small glyph.
        guard width >= edge * 2 / 3, height >= edge * 2 / 3,
              (0.88...1.12).contains(Double(width) / Double(height)) else { return nil }
        let horizontal = (minX + width / 4)..<(minX + width * 3 / 4)
        let vertical = (minY + height / 4)..<(minY + height * 3 / 4)
        let sides = [horizontal.map { ($0, minY + 1) }, horizontal.map { ($0, maxY - 1) },
                     vertical.map { (minX + 1, $0) }, vertical.map { (maxX - 1, $0) }]
        let samples = sides.map { side in
            side.compactMap { x, y -> (Double, Double, Double)? in
                let i = (y * edge + x) * 4
                let alpha = Double(pixels[i + 3])
                guard alpha > 240 else { return nil }
                return (Double(pixels[i]) / alpha, Double(pixels[i + 1]) / alpha,
                        Double(pixels[i + 2]) / alpha)
            }
        }
        guard zip(samples, sides).allSatisfy({ Double($0.0.count) / Double($0.1.count) >= 0.9 }) else { return nil }
        let all = samples.flatMap { $0 }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let red = median(all.map { $0.0 }), green = median(all.map { $0.1 }), blue = median(all.map { $0.2 })
        func matches(_ value: (Double, Double, Double)) -> Bool {
            max(abs(value.0 - red), abs(value.1 - green), abs(value.2 - blue)) < 0.10
        }
        // Tolerate a few compressed/antialiased pixels, but require every
        // side to agree. This rejects circles, multicolour marks and letters.
        guard min(red, green, blue) < 0.92,
              samples.allSatisfy({ Double($0.filter(matches).count) / Double($0.count) >= 0.9 }) else { return nil }
        let matching = all.filter(matches)
        let count = Double(matching.count)
        let color = EdgeColor(red: matching.reduce(0) { $0 + $1.0 } / count,
                              green: matching.reduce(0) { $0 + $1.1 } / count,
                              blue: matching.reduce(0) { $0 + $1.2 } / count)
        let bounds = CGRect(x: Double(minX) / Double(edge), y: Double(minY) / Double(edge),
                            width: Double(width) / Double(edge), height: Double(height) / Double(edge))
        return (color, bounds)
    }

    static func resolve(_ image: UIImage) -> Self {
        let ratio = image.size.width / max(1, image.size.height)
        let isSquare = (0.9...1.1).contains(ratio)
        guard let cgImage = image.cgImage else {
            return Self(insetFraction: isSquare ? 0 : 0.08, usesWhiteCanvas: !isSquare)
        }
        let edge = 32
        var pixels = [UInt8](repeating: 0, count: edge * edge * 4)
        guard let context = CGContext(data: &pixels, width: edge, height: edge,
            bitsPerComponent: 8, bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Self(insetFraction: 0.08, usesWhiteCanvas: true)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        let corners = [(0, 0), (31, 0), (0, 31), (31, 31)]
        let transparentCanvas = corners.allSatisfy { pixels[($0.1 * edge + $0.0) * 4 + 3] < 24 }
        func isCanvas(_ x: Int, _ y: Int) -> Bool {
            let i = (y * edge + x) * 4
            // Transparent or near-white padding. Dark/coloured square tiles
            // retain their complete background and original optical size.
            return pixels[i + 3] < 24 || (!transparentCanvas && pixels[i + 3] > 240
                && pixels[i] > 240 && pixels[i + 1] > 240 && pixels[i + 2] > 240)
        }
        let hasNeutralCorners = corners.allSatisfy { isCanvas($0.0, $0.1) }
        guard hasNeutralCorners || !isSquare else {
            return Self(insetFraction: 0, usesWhiteCanvas: false)
        }
        // Do not double-pad assets that already include a generous safe area.
        // The scan measures padding only; it never crops or deforms artwork.
        let occupiedEdge = (0..<edge).contains { position in
            (0..<3).contains { margin in
                !isCanvas(margin, position) || !isCanvas(edge - 1 - margin, position)
                    || !isCanvas(position, margin) || !isCanvas(position, edge - 1 - margin)
            }
        }
        // White artwork on transparency needs a dark backing in either app
        // theme. Count only opaque ink so antialiased edges cannot dominate.
        var opaqueInk = 0, lightInk = 0
        if transparentCanvas {
            for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 240 {
                opaqueInk += 1
                if min(pixels[i], pixels[i + 1], pixels[i + 2]) > 210 { lightInk += 1 }
            }
        }
        let needsDarkCanvas = opaqueInk > 0 && Double(lightInk) / Double(opaqueInk) > 0.8
        if isSquare, let (edgeColor, bounds) = matchingEdgeTile(pixels, edge: edge) {
            return Self(insetFraction: occupiedEdge ? 0.08 : 0, usesWhiteCanvas: false,
                        edgeCanvas: edgeColor, edgeTileBounds: bounds)
        }
        return Self(insetFraction: occupiedEdge ? 0.08 : 0,
                    usesWhiteCanvas: !needsDarkCanvas, usesDarkCanvas: needsDarkCanvas)
    }
}

struct AssetLogoArtwork: View {
    let image: UIImage
    let layout: AssetLogoLayout
    let size: CGFloat

    var body: some View {
        ZStack {
            if let edgeColor = layout.edgeCanvas { edgeColor.color }
            else if layout.usesDarkCanvas { Color(white: 0.12) }
            else if layout.usesWhiteCanvas { Color.white }
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                // Matched tiles can carry white pixels outside their own
                // rounded corners. Let the matching canvas show there too.
                .clipShape(AssetLogoTileMask(bounds: layout.edgeTileBounds))
                .padding(size * layout.insetFraction)
        }
        .frame(width: size, height: size)
    }
}

struct AssetLogoTileMask: Shape {
    let bounds: CGRect?

    func path(in rect: CGRect) -> Path {
        guard let bounds else { return Path(rect) }
        let tile = CGRect(x: rect.minX + bounds.minX * rect.width,
                          y: rect.minY + bounds.minY * rect.height,
                          width: bounds.width * rect.width, height: bounds.height * rect.height)
        // Core Graphics bitmap rows run bottom-up; logo views run top-down.
        let upright = CGRect(x: tile.minX, y: rect.minY + (1 - bounds.maxY) * rect.height,
                             width: tile.width, height: tile.height)
        return RoundedRectangle(cornerRadius: min(tile.width, tile.height) * 0.12).path(in: upright)
    }
}

/// The logo image each ticker is showing right now. The security page's
/// flying logo is built from it: already decoded, nothing redrawn at the tap.
@MainActor
final class AssetLogoShownImages {
    static let shared = AssetLogoShownImages()
    private let images = NSCache<NSString, UIImage>()

    private init() { images.countLimit = 200 }

    func record(_ image: UIImage, for ticker: String) {
        images.setObject(image, forKey: ticker.uppercased() as NSString)
    }

    func image(for ticker: String) -> UIImage? {
        images.object(forKey: ticker.uppercased() as NSString)
    }
}

final class AssetLogoImageCache: @unchecked Sendable {
    static let shared = AssetLogoImageCache()

    private let images = NSCache<NSURL, Entry>()

    private final class Entry {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }

    private init() {
        // Asset logos are decoded at up to 192 px, and only when visible.
        // Keeping roughly two long scrolling screens avoids churn without
        // allowing the full logo library to become resident at once.
        images.countLimit = 120
        images.totalCostLimit = 18 * 1_024 * 1_024
    }

    func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)?.image
    }

    func insert(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        images.setObject(Entry(image), forKey: url as NSURL, cost: cost)
    }
}

actor AssetLogoRepository {
    struct DecodedImage: @unchecked Sendable {
        let value: UIImage
    }

    static let shared = AssetLogoRepository()
    private let lightTransitionImages = NSCache<UIImage, UIImage>()

    /// Rasterize once off the main actor at the decoded image's own scale.
    func transitionImage(_ image: DecodedImage, light: Bool) -> DecodedImage {
        guard light else { return image }
        if let saved = lightTransitionImages.object(forKey: image.value) { return DecodedImage(value: saved) }
        let format = image.value.imageRendererFormat
        format.scale = image.value.scale
        let shown = UIGraphicsImageRenderer(size: image.value.size, format: format).image { context in
            image.value.draw(at: .zero)
            context.cgContext.setBlendMode(.multiply)
            context.cgContext.setFillColor(UIColor(red: 247 / 255, green: 248 / 255, blue: 250 / 255, alpha: 1).cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: image.value.size))
        }
        lightTransitionImages.countLimit = 120
        lightTransitionImages.totalCostLimit = 18 * 1_024 * 1_024
        lightTransitionImages.setObject(shown, forKey: image.value,
            cost: Int(shown.size.width * shown.size.height * shown.scale * shown.scale * 4))
        return DecodedImage(value: shown)
    }

    func image(for url: URL) async throws -> DecodedImage {
        if let cached = AssetLogoImageCache.shared.image(for: url) {
            return DecodedImage(value: cached)
        }
        guard url.isFileURL else { throw URLError(.unsupportedURL) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if let cached = AssetLogoImageCache.shared.image(for: url) {
            return DecodedImage(value: cached)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      // The export's canvas. 96 px was below what a 36–44 pt
                      // tile needs on a 3× screen (108–132 px), so logos
                      // were upscaled and looked soft.
                      kCGImageSourceThumbnailMaxPixelSize: 192,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary
              ) else {
            throw URLError(.cannotDecodeContentData)
        }
        let image = UIImage(cgImage: cgImage)
        AssetLogoImageCache.shared.insert(image, for: url)
        return DecodedImage(value: image)
    }
}

struct AssetLogoResolvedKey: EnvironmentKey {
    static let defaultValue: (URL) -> Void = { _ in }
}

extension EnvironmentValues {
    /// A snapshot owner can redraw when a visible logo replaces its fallback.
    var assetLogoDidResolve: (URL) -> Void {
        get { self[AssetLogoResolvedKey.self] }
        set { self[AssetLogoResolvedKey.self] = newValue }
    }
}

struct AssetLogo: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.assetLogoDidResolve) private var didResolve
    @AppStorage(AssetLogoStyle.preferenceKey) private var logoStyleRaw = AssetLogoStyle.automatic.rawValue
    let ticker: String
    let logoSymbol: String?
    var size: CGFloat = 28
    var cornerRadius: CGFloat? = nil
    var onBrandColorResolved: ((Color) -> Void)? = nil
    @State private var loadedImage: UIImage?
    @State private var brandfetchLoaded = false
    @State private var brandfetchMissing = false
    @State private var brandfetchDarkMissing = false

    var body: some View {
        Group {
            if let image = displayedImage {
                // Both bundled sets (the reviewed export and the older logos
                // filling its gaps) are finished 192 px tiles, laid out by
                // the export's optical centre and size: draw them as they are.
                AssetLogoArtwork(image: image,
                    layout: AssetLogoLayout(insetFraction: 0, usesWhiteCanvas: false),
                    size: size)
                    // Light tiles carry a white ground in the file itself;
                    // multiplying by the tile colour lays them on it, as the
                    // logo workbench shows them.
                    .colorMultiply(usesLightTile ? Self.lightTile : .white)
            } else if let brandfetchURL {
                ZStack {
                    // A plain tile while the icon loads, not the coloured
                    // letter: every new logo view — the security page's own
                    // on each open — flashed the letter before the brand's
                    // icon arrived. The letter is for a confirmed miss, which
                    // clears `brandfetchURL` and lands in `fallback` below.
                    usesLightTile ? Self.lightTile : SettingsTemplate.card
                    BrandfetchLogoImage(url: brandfetchURL) {
                        BrandfetchMissCache.shared.clear(logoSymbol ?? ticker)
                        brandfetchLoaded = true
                    } onMissing: {
                        if BrandfetchLogoURL.isDark(brandfetchURL) {
                            // No dark icon: remembered for a week, and the
                            // default icon is requested instead.
                            BrandfetchMissCache.shared.recordMissing(
                                BrandfetchLogoURL.darkMissKey(logoSymbol ?? ticker))
                            brandfetchDarkMissing = true
                        } else {
                            // Remembered for a week; the letter tile stays and the
                            // next appearance skips the web view entirely.
                            BrandfetchMissCache.shared.recordMissing(logoSymbol ?? ticker)
                            brandfetchMissing = true
                        }
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(usesLightTile ? Self.lightTile : SettingsTemplate.card,
                    in: RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                .stroke(
                    colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05),
                    lineWidth: 0.5
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .onChange(of: displayedImage, initial: true) { _, image in recordShownImage(image) }
        .onChange(of: usesLightTile) { _, _ in recordShownImage(displayedImage) }
        .task(id: logoURL ?? brandfetchURL) {
            // SwiftUI may reuse this view when a ranked chart slot changes
            // ticker. Clear the old decoded image before resolving the new URL.
            loadedImage = nil
            brandfetchLoaded = false
            brandfetchMissing = false
            brandfetchDarkMissing = false
            await loadLogo()
        }
    }

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? size * 2 / 7
    }

    /// The artwork on screen, for a transition to fly without redrawing it.
    private func recordShownImage(_ image: UIImage?) {
        guard let image else { return }
        let light = usesLightTile
        Task {
            let shown = await AssetLogoRepository.shared.transitionImage(.init(value: image), light: light)
            guard displayedImage === image, usesLightTile == light else { return }
            AssetLogoShownImages.shared.record(shown.value, for: ticker)
        }
    }

    private var displayedImage: UIImage? {
        loadedImage ?? logoURL.flatMap { AssetLogoImageCache.shared.image(for: $0) }
    }

    @MainActor
    private func loadLogo() async {
        guard loadedImage == nil, let logoURL else {
            onBrandColorResolved?(exportedThemeColor ?? AssetBrandColor.fallback(for: logoSymbol ?? ticker))
            return
        }
        if let cached = AssetLogoImageCache.shared.image(for: logoURL) {
            loadedImage = cached
            didResolve(logoURL)
            onBrandColorResolved?(exportedThemeColor ?? AssetBrandColor.resolved(from: cached, fallbackKey: logoSymbol ?? ticker))
            return
        }
        guard let decoded = try? await AssetLogoRepository.shared.image(for: logoURL),
              !Task.isCancelled else {
            onBrandColorResolved?(exportedThemeColor ?? AssetBrandColor.fallback(for: logoSymbol ?? ticker))
            return
        }
        loadedImage = decoded.value
        didResolve(logoURL)
        onBrandColorResolved?(exportedThemeColor ?? AssetBrandColor.resolved(from: decoded.value, fallbackKey: logoSymbol ?? ticker))
    }

    /// The letter tile in the exported logos' two versions, following the
    /// same Logo 样式: light is a white tile with the letter in the brand
    /// colour; dark is a brand-colour tile with an off-white letter.
    private var fallback: some View {
        let style = AssetLogoStyle(rawValue: logoStyleRaw) ?? .automatic
        let dark = style.usesDarkLogo(darkAppearance: colorScheme == .dark)
        return ZStack {
            dark ? fallbackColor : Self.lightTile
            Text(String(ticker.prefix(1)).uppercased())
                .font(.system(size: max(10, size * 0.42), weight: .bold, design: .rounded))
                .foregroundStyle(dark ? Color(red: 0xF3 / 255, green: 0xF6 / 255, blue: 0xF9 / 255) : fallbackColor)
        }
    }

    private var fallbackColor: Color {
        AssetBrandColor.fallback(for: logoSymbol ?? ticker)
    }

    /// The pale grey every light logo sits on — the workbench's #F7F8FA —
    /// so a white logo never merges into a white card.
    static let lightTile = Color(red: 247 / 255, green: 248 / 255, blue: 250 / 255)

    /// True when the light version of the logo is the one shown.
    private var usesLightTile: Bool {
        let style = AssetLogoStyle(rawValue: logoStyleRaw) ?? .automatic
        return !style.usesDarkLogo(darkAppearance: colorScheme == .dark)
    }

    /// Reviewed export first, then the older built-in logo set, then Brandfetch.
    private var logoURL: URL? {
        exportedLogoURL ?? legacyLogoURL
    }

    private var symbol: String? {
        let symbol = (logoSymbol ?? ticker).trimmingCharacters(in: .whitespacesAndNewlines)
        return symbol.isEmpty || symbol == "ETF 其他" ? nil : symbol
    }

    private var exportedLogoURL: URL? {
        guard let symbol else { return nil }
        let style = AssetLogoStyle(rawValue: logoStyleRaw) ?? .automatic
        return AssetLogoExportCatalog.imageURL(
            for: symbol, dark: style.usesDarkLogo(darkAppearance: colorScheme == .dark))
    }

    /// The pre-export logo set (`AssetLogos/<TICKER>.png`) covers tickers the
    /// reviewed export doesn't. It has one version, so the style doesn't apply.
    private var legacyLogoURL: URL? {
        guard let symbol else { return nil }
        return Bundle.main.url(
            forResource: symbol.uppercased(), withExtension: "png", subdirectory: "AssetLogos")
    }

    private var exportedThemeColor: Color? {
        guard exportedLogoURL != nil else { return nil }
        return AssetLogoExportCatalog.themeColor(for: logoSymbol ?? ticker)
    }

    private var brandfetchURL: URL? {
        guard logoURL == nil, !brandfetchMissing else { return nil }
        // At night (or with 深色 Logo chosen) ask for the brand's dark icon,
        // which WebKit then caches as its own URL; fall back to the default.
        let style = AssetLogoStyle(rawValue: logoStyleRaw) ?? .automatic
        let wantsDark = !brandfetchDarkMissing && style.usesDarkLogo(darkAppearance: colorScheme == .dark)
        return (wantsDark ? BrandfetchLogoURL.icon(for: logoSymbol ?? ticker, dark: true) : nil)
            ?? BrandfetchLogoURL.icon(for: logoSymbol ?? ticker)
    }
}

/// Resolves a usable brand accent from the actual logo while ignoring the
/// transparent/white canvas common in market-data logo assets.
enum AssetBrandColor {
    private struct Bucket {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weight = 0.0
    }

    static func resolved(from image: UIImage, fallbackKey: String) -> Color {
        guard let color = dominantColor(from: image) else {
            return fallback(for: fallbackKey)
        }
        return Color(uiColor: vivid(color))
    }

    static func fallback(for key: String) -> Color {
        let normalized = key.uppercased()

        if normalized.contains("NVDA") { return Color(red: 0.45, green: 0.72, blue: 0.10) }
        if normalized.contains("VUSA") || normalized.contains("VUAG") || normalized.contains("VTI") {
            return Color(red: 0.67, green: 0.08, blue: 0.12)
        }
        if normalized.contains("DWS") || normalized.contains("XS2D") {
            return Color(red: 0.05, green: 0.58, blue: 0.66)
        }
        if normalized.contains("QQQ") || normalized.contains("EQGB") || normalized.contains("OKTA") {
            return Color(red: 0.12, green: 0.37, blue: 0.90)
        }

        let colors = [
            Color(red: 0.26, green: 0.47, blue: 0.96),
            Color(red: 0.20, green: 0.62, blue: 0.36),
            Color(red: 0.92, green: 0.47, blue: 0.16),
            Color(red: 0.55, green: 0.36, blue: 0.86),
            Color(red: 0.12, green: 0.60, blue: 0.62),
            Color(red: 0.82, green: 0.32, blue: 0.56),
            Color(red: 0.34, green: 0.37, blue: 0.78),
            Color(red: 0.62, green: 0.43, blue: 0.28),
        ]
        let hash = normalized.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1.value)) &* 1_099_511_628_211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }

    private static func vivid(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else { return color }

        return UIColor(
            hue: hue,
            saturation: min(max(saturation, 0.58), 0.92),
            brightness: min(max(brightness, 0.72), 0.94),
            alpha: 1
        )
    }

    private static func dominantColor(from image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        let width = 24
        let height = 24
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var buckets = Array(repeating: Bucket(), count: 18)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.18 else { continue }

            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            let saturation = maximum == 0 ? 0 : delta / maximum

            // White/grey image canvases are not brand colours. Very dark marks
            // fall back to a stable accessible accent instead of muddying glass.
            guard saturation > 0.18, maximum > 0.12 else { continue }

            let hue: Double
            if delta == 0 {
                hue = 0
            } else if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
            } else if maximum == green {
                hue = (((blue - red) / delta) + 2) / 6
            } else {
                hue = (((red - green) / delta) + 4) / 6
            }
            let normalizedHue = hue < 0 ? hue + 1 : hue
            let index = min(Int(normalizedHue * Double(buckets.count)), buckets.count - 1)
            let weight = saturation * saturation * (0.35 + min(maximum, 0.9)) * alpha
            buckets[index].red += red * weight
            buckets[index].green += green * weight
            buckets[index].blue += blue * weight
            buckets[index].weight += weight
        }

        guard let winner = buckets.max(by: { $0.weight < $1.weight }), winner.weight > 0.10 else {
            return nil
        }
        return UIColor(
            red: winner.red / winner.weight,
            green: winner.green / winner.weight,
            blue: winner.blue / winner.weight,
            alpha: 1
        )
    }
}
