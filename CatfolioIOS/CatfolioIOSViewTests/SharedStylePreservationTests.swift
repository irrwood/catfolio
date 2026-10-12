import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

/// Preserve the appearance of existing screens while moving their styles to
/// shared definitions. Compare rendered output, including digits and currency
/// glyphs that differ between the native and alternate SF Rounded treatments.
@MainActor
final class SharedStylePreservationTests: XCTestCase {
    func testFixedRoundedFontsKeepTheirRenderedGlyphsAndMetrics() throws {
        for size: CGFloat in [10, 11, 12, 13, 14, 15, 16, 17, 19, 24, 27] {
            for weight in [Font.Weight.regular, .medium, .semibold, .bold] {
                let before = Font.system(size: size, weight: weight, design: .rounded)
                let after = Typography.rounded(size: size, weight: weight)
                XCTAssertEqual(try image(font: after), try image(font: before), "\(size), \(weight)")
            }
        }
    }

    func testSemanticRoundedFontsKeepDynamicTypeAndOriginalWeight() throws {
        for style in [Font.TextStyle.body, .caption, .caption2, .largeTitle, .title2] {
            for weight: Font.Weight? in [nil, .medium, .semibold] {
                for size in [DynamicTypeSize.large, .accessibility3] {
                    XCTAssertEqual(
                        try image(font: Typography.rounded(style, weight: weight), size: size),
                        try image(font: .system(style, design: .rounded, weight: weight), size: size))
                }
            }
        }
        let standard = try image(font: Typography.rounded(.body), size: .large)
        let accessible = try image(font: Typography.rounded(.body), size: .accessibility3)
        XCTAssertNotEqual(standard, accessible)
    }

    func testChartItalicAndTabularDigitsKeepTheirRendering() throws {
        for transform: (Font) -> Font in [{ $0.italic() }, { $0.monospacedDigit() }] {
            XCTAssertEqual(
                try image(font: transform(Typography.rounded(size: 14))),
                try image(font: transform(.system(size: 14, design: .rounded))))
        }
    }

    func testSharedSwatchesRetainExactComponentsInBothAppearances() {
        let swatches: [(Color, Color)] = [
            (CatfolioPalette.ChartSeries.green, Color(red: 0.204, green: 0.780, blue: 0.349)),
            (CatfolioPalette.ChartSeries.orange, Color(red: 1, green: 0.584, blue: 0)),
            (CatfolioPalette.ChartSeries.blue, Color(red: 0.204, green: 0.459, blue: 1)),
            (CatfolioPalette.ChartSeries.rose, Color(red: 0.890, green: 0, blue: 0.271)),
            (CatfolioPalette.ChartSeries.magenta, Color(red: 0.780, green: 0, blue: 0.910)),
            (CatfolioPalette.ChartSeries.sky, Color(red: 0.627, green: 0.804, blue: 1)),
            (CatfolioPalette.ChartSeries.peach, Color(red: 1, green: 0.824, blue: 0.741)),
            (CatfolioPalette.ChartSeries.mint, Color(red: 0, green: 0.882, blue: 0.698)),
            (CatfolioPalette.ChartSeries.pink, Color(red: 1, green: 0.431, blue: 0.702)),
            (CatfolioPalette.ChartSeries.lavender, Color(red: 0.722, green: 0.600, blue: 1)),
            (CatfolioPalette.ChartSeries.teal, Color(red: 0, green: 0.620, blue: 0.540)),
            (CatfolioPalette.ChartSeries.neutral, Color(red: 0.4, green: 0.4, blue: 0.45)),
            (CatfolioPalette.researchViolet, Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)),
            (CatfolioPalette.fixedNeutralGray, Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)),
            (CatfolioPalette.homeSky, Color(red: 154 / 255, green: 220 / 255, blue: 1)),
            (CatfolioPalette.rangeNegative, Color(red: 1, green: 16 / 255, blue: 89 / 255)),
            (CatfolioPalette.contributionSky, Color(red: 124 / 255, green: 212 / 255, blue: 1)),
            (CatfolioPalette.stockMapBackground, Color(red: 0.045, green: 0.063, blue: 0.094)),
            (CatfolioPalette.emptyStateGraphite, Color(white: 0x1E / 255)),
            (CatfolioPalette.calendarMutedGreen, Color(red: 0.58, green: 0.66, blue: 0.27)),
            (CatfolioPalette.Ambient.night, Color(red: 0.012, green: 0.020, blue: 0.130)),
            (CatfolioPalette.Ambient.pinkFringe, Color(red: 1, green: 0.450, blue: 0.850)),
            (CatfolioPalette.Ambient.nightBright, Color(red: 0.012, green: 0.020, blue: 0.075)),
            (CatfolioPalette.Ambient.clearSkyDay, Color(red: 0.482, green: 0.820, blue: 1)),
            (CatfolioPalette.Ambient.clearSkyNight, Color(red: 0.020, green: 0.070, blue: 0.160)),
            (CatfolioPalette.Ambient.ringsNight, Color(red: 0.020, green: 0.050, blue: 0.100)),
            (CatfolioPalette.securityPriceLine, Color(red: 52 / 255, green: 117 / 255, blue: 1))
        ]
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            for (shared, previous) in swatches {
                XCTAssertEqual(shared.resolve(in: environment), previous.resolve(in: environment))
            }
        }
    }

    private func image(font: Font, size: DynamicTypeSize = .large) throws -> Data {
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 5) {
            Text("Portfolio 股票 · 0123456789")
            Text("$¢ £€¥ 1,469.59 −12.3%")
        }.font(font).fixedSize().foregroundStyle(.black).padding(8).background(.white)
            .environment(\.dynamicTypeSize, size))
        renderer.scale = 2
        return try XCTUnwrap(renderer.uiImage?.pngData())
    }
}
