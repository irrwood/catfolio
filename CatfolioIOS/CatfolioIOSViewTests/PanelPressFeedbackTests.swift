import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class PanelPressFeedbackTests: XCTestCase {
    func testPressedCardShrinksAroundItsCenterWithoutMovingSurroundingLayout() throws {
        let resting = try render(pressed: false)
        let pressed = try render(pressed: true)
        let released = try render(pressed: false)
        XCTAssertEqual(resting.size, pressed.size, "A press must not reflow the grid or scroll view")
        let fullBounds = try visibleBounds(resting)
        let pressedBounds = try visibleBounds(pressed)
        XCTAssertLessThan(pressedBounds.width, fullBounds.width)
        XCTAssertLessThan(pressedBounds.height, fullBounds.height)
        XCTAssertGreaterThan(pressedBounds.width, fullBounds.width * 0.95, "The press should stay subtle")
        XCTAssertEqual(pressedBounds.midX, fullBounds.midX, accuracy: 0.5)
        XCTAssertEqual(pressedBounds.midY, fullBounds.midY, accuracy: 0.5)
        XCTAssertEqual(try visibleBounds(released), fullBounds, "Release or cancellation restores the card")
    }

    func testDisabledCardsStayStillAndReducedMotionUsesOpacityFeedback() throws {
        let resting = try render(pressed: false)
        let disabled = try render(pressed: true, enabled: false)
        XCTAssertEqual(disabled.pngData(), resting.pngData())
        let reduced = try render(pressed: true, reducedMotion: true)
        XCTAssertEqual(try visibleBounds(reduced), try visibleBounds(resting))
        XCTAssertLessThan(try centerAlpha(reduced), try centerAlpha(resting),
                          "Reduced Motion still needs visible feedback without scaling")
    }

    private func render(pressed: Bool, enabled: Bool = true, reducedMotion: Bool = false) throws -> UIImage {
        let renderer = ImageRenderer(content: Color.blue
            .frame(width: 200, height: 120)
            .modifier(PanelPressFeedback(isPressed: pressed, reduceMotion: reducedMotion))
            .environment(\.isEnabled, enabled)
            .frame(width: 240, height: 160))
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }

    private func pixels(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return (bytes, cgImage.width, cgImage.height)
    }

    private func visibleBounds(_ image: UIImage) throws -> CGRect {
        let image = try pixels(image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where image.bytes[(y * image.width + x) * 4 + 3] > 20 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX)
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func centerAlpha(_ image: UIImage) throws -> UInt8 {
        let image = try pixels(image)
        return image.bytes[((image.height / 2) * image.width + image.width / 2) * 4 + 3]
    }
}
