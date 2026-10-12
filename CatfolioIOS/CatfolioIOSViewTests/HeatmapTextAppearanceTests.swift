import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class HeatmapTextAppearanceTests: XCTestCase {
    func testNeutralLabelsKeepContrastOverRenderedGainLossAndNeutralTiles() throws {
        let holding = try XCTUnwrap(LocalPortfolioEngine.presentation(for: FakePortfolioGenerator.make()).2.first)
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let inks = [CatfolioTheme.heatmapIdentifier, CatfolioTheme.heatmapDetail]
                .map { $0.resolve(in: environment) }
            XCTAssertGreaterThan(inks[0].opacity, inks[1].opacity)
            XCTAssertLessThan(inks[0].opacity, 1)
            let backdrops: [Color] = scheme == .light ? [.white, CatfolioPalette.homeSky] : [.black, CatfolioPalette.blue900]
            for backdrop in backdrops {
                for change: Double? in [nil, 0, -0.2, 0.2, -3, 3, -20, 20] {
                    let model = HoldingsHeatmapTile.Model(id: holding.ticker, content: .holding(holding),
                        marketValue: holding.marketValue, portfolioFraction: 0.125,
                        changePercent: change, performanceTitle: "Today")
                    let image = try render(HoldingsHeatmapTile(model: model, fraction: 0.125,
                        size: CGSize(width: 100, height: 100), action: nil)
                        .frame(width: 100, height: 100).background(backdrop), scheme: scheme)
                    // Sample the actual rendered fill beside the labels, away
                    // from rounded corners and glyph antialiasing.
                    let background = try pixel(image, x: 4, y: 50)
                    for ink in inks {
                        let alpha = Double(ink.opacity)
                        let blended = zip([ink.red, ink.green, ink.blue], background).map {
                            Double($0.0) * alpha + $0.1 * (1 - alpha)
                        }
                        XCTAssertGreaterThanOrEqual(contrast(blended, background), 4.5,
                            "Heatmap text lost contrast in \(scheme), change: \(String(describing: change))")
                    }
                }
            }
        }
    }

    func testPerformanceInkKeepsGainAndLossColorsWithTranslucency() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let title = CatfolioTheme.heatmapIdentifier.resolve(in: environment)
            let detail = CatfolioTheme.heatmapDetail.resolve(in: environment)
            for change in [-20.0, -3, -0.01, 0.01, 3, 20] {
                let ink = CatfolioTheme.heatmapPerformance(for: change, scheme: scheme).resolve(in: environment)
                if change > 0 {
                    XCTAssertGreaterThan(ink.green, ink.red + 0.3, "Gains must retain green lettering")
                    XCTAssertGreaterThan(ink.green, ink.blue)
                } else {
                    XCTAssertGreaterThan(ink.red, ink.green + 0.3, "Losses must retain red lettering")
                    XCTAssertGreaterThan(ink.red, ink.blue)
                }
                XCTAssertLessThan(ink.opacity, title.opacity)
                XCTAssertGreaterThan(ink.opacity, detail.opacity)
            }
            for change: Double? in [nil, 0, -0.004, 0.004, .nan] {
                let ink = CatfolioTheme.heatmapPerformance(for: change, scheme: scheme).resolve(in: environment)
                XCTAssertEqual(ink.red, ink.green, accuracy: 0.001)
                XCTAssertEqual(ink.green, ink.blue, accuracy: 0.001)
            }
        }
    }

    func testHeatmapTextRendersAcrossTileSizesAndSectorGrouping() throws {
        let holdings = try LocalPortfolioEngine.presentation(for: FakePortfolioGenerator.make()).2
        let changes = Dictionary(uniqueKeysWithValues: holdings.enumerated().map {
            ($0.element.ticker, [-3.2, 2.6, 0, 0.4][$0.offset % 4])
        })
        for scheme in [ColorScheme.light, .dark] {
            for grouped in [false, true] {
                let image = try render(HoldingsHeatmapView(holdings: holdings, dailyChanges: changes,
                    isLoading: false, performancePeriod: .today, groupsBySector: grouped,
                    usesETFLookThrough: false, lookThroughRows: nil, lookThroughDailyChanges: [:],
                    isInteractive: false, onSelect: { _ in })
                    .frame(width: 370, height: 525)
                    .background(scheme == .light ? Color.white : Color.black), scheme: scheme)
                XCTAssertEqual(image.size, CGSize(width: 370, height: 525))
                let name = "heatmap-text-\(scheme)-\(grouped ? "sectors" : "holdings")"
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
            }
        }
    }

    private func render<Content: View>(_ content: Content, scheme: ColorScheme) throws -> UIImage {
        let renderer = ImageRenderer(content: content
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en_US")))
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [Double] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let offset = (y * cg.width + x) * 4
        return (0..<3).map { Double(bytes[offset + $0]) / 255 }
    }

    private func contrast(_ first: [Double], _ second: [Double]) -> Double {
        func luminance(_ color: [Double]) -> Double {
            let linear = color.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
