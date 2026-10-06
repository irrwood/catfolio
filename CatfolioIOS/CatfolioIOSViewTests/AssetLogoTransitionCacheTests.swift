import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AssetLogoTransitionCacheTests: XCTestCase {
    func testLightArtworkKeepsPixelSizeAndReusesTheRaster() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 192), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 192, height: 192))
        }
        let repository = AssetLogoRepository()
        let first = await repository.transitionImage(.init(value: original), light: true)
        let second = await repository.transitionImage(.init(value: original), light: true)
        XCTAssertTrue(first.value === second.value)
        XCTAssertEqual(first.value.cgImage?.width, 192)
        XCTAssertEqual(first.value.cgImage?.height, 192)
        let dark = await repository.transitionImage(.init(value: original), light: false)
        XCTAssertTrue(dark.value === original)
    }
}
