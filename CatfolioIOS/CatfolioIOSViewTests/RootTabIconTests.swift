import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class RootTabIconTests: XCTestCase {
    func testTabIconsRenderDistinctStatesAtTheirNativeSize() throws {
        let names = ["TabPortfolio", "TabPerformance", "TabResearch", "TabSettings", "TabAI"]
        var pairs: [(UIImage, UIImage)] = []
        for name in names {
            let outline = try XCTUnwrap(UIImage(named: name + "Unselected"), name)
            let filled = try XCTUnwrap(UIImage(named: name + "Selected"), name)
            for icon in [outline, filled] {
                XCTAssertEqual(icon.size, CGSize(width: 24, height: 24), name)
                XCTAssertEqual(icon.renderingMode, .alwaysTemplate, "Icons must inherit the tab bar's tint")
            }
            let outlineMask = try alphaMask(outline)
            let filledMask = try alphaMask(filled)
            XCTAssertTrue(outlineMask.contains { $0 > 0 }, "The compiled outline SVG must render: \(name)")
            XCTAssertTrue(filledMask.contains { $0 > 0 }, "The compiled selected SVG must render: \(name)")
            XCTAssertNotEqual(outlineMask, filledMask, "Selection must visibly change the icon: \(name)")
            pairs.append((outline, filled))
        }

        // Inspect the compiled assets at their actual 24 pt size in both themes.
        for dark in [false, true] {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 240))
            let preview = renderer.image { context in
                (dark ? UIColor.black : UIColor.white).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 180, height: 240))
                let tint = dark ? UIColor.white : UIColor.black
                for (row, pair) in pairs.enumerated() {
                    pair.0.withTintColor(tint, renderingMode: .alwaysOriginal)
                        .draw(at: CGPoint(x: 50, y: 20 + row * 44))
                    pair.1.withTintColor(tint, renderingMode: .alwaysOriginal)
                        .draw(at: CGPoint(x: 106, y: 20 + row * 44))
                }
            }
            let attachment = XCTAttachment(image: preview)
            attachment.name = dark ? "tab-icons-dark" : "tab-icons-light"
            attachment.lifetime = .keepAlways
            add(attachment)
            try preview.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-tab-icons-\(dark ? "dark" : "light").png"))
        }
    }

    private func alphaMask(_ image: UIImage) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let raster = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
        let cgImage = try XCTUnwrap(raster.cgImage)
        var bytes = [UInt8](repeating: 0, count: 24 * 24 * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 24, height: 24,
                                             bitsPerComponent: 8, bytesPerRow: 24 * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 24, height: 24))
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }
}
