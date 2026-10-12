import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

final class ReturnsEntryAppearanceTests: XCTestCase {
    func testSourceAmountsUseTheDesignedContrastInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let losses = ReturnsSourcePalette(isLosses: true, scheme: scheme)
            XCTAssertEqual(losses.amount.resolve(in: environment), Color.white.resolve(in: environment))
            let gains = ReturnsSourcePalette(isLosses: false, scheme: scheme)
            let ink = gains.amount.resolve(in: environment)
            if scheme == .light {
                XCTAssertLessThan(ink.red, 0.05)
                XCTAssertLessThan(ink.green, 0.4)
                XCTAssertGreaterThan(ink.blue, 0.6)
            } else {
                XCTAssertEqual(ink, Color.white.resolve(in: environment))
            }
        }
    }

    func testExportedArtworkKeepsItsCanvasAndVisiblePixels() throws {
        let assets: [(String, CGSize)] = [
            ("EntryGainIcon", CGSize(width: 18, height: 16)),
            ("EntryLossDayIcon", CGSize(width: 17, height: 24)),
            ("EntryLossNightIcon", CGSize(width: 14.3294, height: 12.1749)),
            ("EntryReturnIcon", CGSize(width: 20, height: 20)),
            ("EntryCycleIcon", CGSize(width: 20, height: 20)),
            ("EntryChevron", CGSize(width: 5, height: 10)),
            ("EntryLossChevron", CGSize(width: 5, height: 10)),
            ("EntryReturnChevron", CGSize(width: 5, height: 10)),
            ("EntryGainGlow", CGSize(width: 355.6, height: 279.6)),
            ("EntryLossGlow", CGSize(width: 395.6, height: 296.6)),
            ("EntryLossDayGlow", CGSize(width: 353.6, height: 296.6)),
            ("EntryReturnGlow", CGSize(width: 355.6, height: 279.6)),
            ("EntryCycleGlow", CGSize(width: 355.6, height: 279.6)),
            ("EntryReturnBack", CGSize(width: 188, height: 156.955)),
            ("EntryReturnMiddle", CGSize(width: 188.5, height: 141.028)),
            ("EntryReturnFront", CGSize(width: 188.5, height: 142.214)),
            ("EntryCycleBack", CGSize(width: 188, height: 156.955)),
            ("EntryCycleMiddle", CGSize(width: 188.5, height: 141.028)),
            ("EntryCycleFront", CGSize(width: 188.5, height: 112.456))
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (name, size) in assets {
                let image = try XCTUnwrap(UIImage(named: name, in: .main,
                    compatibleWith: UITraitCollection(userInterfaceStyle: style)), name)
                XCTAssertEqual(image.size.width, size.width, accuracy: 0.5, name)
                XCTAssertEqual(image.size.height, size.height, accuracy: 0.5, name)
                var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
                let context = try XCTUnwrap(CGContext(data: &pixels, width: 32, height: 32,
                    bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(try XCTUnwrap(image.cgImage, name), in: CGRect(x: 0, y: 0, width: 32, height: 32))
                XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }, name)
            }
        }
    }
}
