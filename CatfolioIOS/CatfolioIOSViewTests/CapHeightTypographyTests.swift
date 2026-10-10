import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class CapHeightTypographyTests: XCTestCase {
    func testTrimRemovesLeadingWithoutShrinkingOrClippingGlyphs() throws {
        for sample in ["Calendar", "NVIDIA", "$3.07", "gypÅ", "派息"] {
            let normal = try render(Text(sample).appText(.heading, weight: .medium))
            let trimmed = try render(Text(sample).appText(.heading, weight: .medium, trimsLeading: true))
            let font = CurrencySymbolAlternates.font(size: TypeScale.heading.size, weight: .medium, rounded: true)
            XCTAssertEqual(trimmed.size.height, font.capHeight + 40, accuracy: 0.5)
            XCTAssertLessThan(trimmed.size.height, normal.size.height)
            let before = try inkBounds(normal)
            let after = try inkBounds(trimmed)
            XCTAssertEqual(after.width, before.width, accuracy: 1, "The glyphs keep their original size: \(sample)")
            XCTAssertEqual(after.height, before.height, accuracy: 1, "Accents and descenders survive: \(sample)")
        }
    }

    func testMultilineTextKeepsItsBaselineSpacingAndScalesWithDynamicType() throws {
        let text = "NVIDIA\nDividend paid"
        let normal = try render(Text(text).appText(.body))
        let trimmed = try render(Text(text).appText(.body, trimsLeading: true))
        XCTAssertEqual(try inkBounds(trimmed).height, try inkBounds(normal).height, accuracy: 1)
        let large = try render(Text(text).appText(.body, trimsLeading: true), size: .accessibility2)
        XCTAssertGreaterThan(large.size.height - 40, (trimmed.size.height - 40) * 1.5)
        XCTAssertGreaterThan(try inkBounds(large).height, try inkBounds(trimmed).height * 1.5)
    }

    private func render<V: View>(_ text: V, size: DynamicTypeSize = .large) throws -> UIImage {
        let renderer = ImageRenderer(content: text.fixedSize().foregroundStyle(.black)
            .padding(20).background(.white).environment(\.dynamicTypeSize, size))
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func inkBounds(_ image: UIImage) throws -> CGRect {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] < 128 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        XCTAssertGreaterThanOrEqual(right, left)
        return CGRect(x: CGFloat(left) / image.scale, y: CGFloat(top) / image.scale,
                      width: CGFloat(right - left + 1) / image.scale, height: CGFloat(bottom - top + 1) / image.scale)
    }
}
