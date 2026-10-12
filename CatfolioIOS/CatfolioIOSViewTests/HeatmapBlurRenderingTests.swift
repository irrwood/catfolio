import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class HeatmapBlurRenderingTests: XCTestCase {
    private let size = CGSize(width: 402, height: 340)

    func testClearToBlurTransitionPreservesTileOpacityInBothAppearances() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for opacity in [0.3, 1.0] {
                let image = try await render(name: "heatmap-blur-\(scheme)-\(opacity)", scheme: scheme) {
                    Rectangle().fill(CatfolioPalette.green500.opacity(opacity))
                }
                let pixels = try Pixels(image)
                let reference = pixels.rgb(x: 201, y: 120)
                // All samples are farther from the canvas edges than the blur
                // radius. A uniform tile must stay uniform across both joins.
                var largestDifference = 0
                for y in 30..<270 {
                    let color = pixels.rgb(x: 201, y: CGFloat(y))
                    largestDifference = max(largestDifference,
                        zip(color, reference).map { abs($0 - $1) }.max()!)
                }
                XCTAssertLessThanOrEqual(largestDifference, 3,
                    "The blur must not paint a color band across a uniform \(scheme) tile at opacity \(opacity)")
            }
        }
    }

    func testProgressiveBlurSoftensAnEdgeContinuouslyAndKeepsMiddleSharp() async throws {
        let image = try await render(name: "heatmap-blur-edge", scheme: .dark) {
            HStack(spacing: 0) {
                Color.black
                Color.white
            }
        }
        let pixels = try Pixels(image)
        XCTAssertLessThan(pixels.rgb(x: 198, y: 120)[0], 3)
        XCTAssertGreaterThan(pixels.rgb(x: 204, y: 120)[0], 252)
        XCTAssertGreaterThan(pixels.rgb(x: 192, y: 260)[0], 30)
        // A wider Gaussian must mix progressively more of the white half
        // into the black half, without backward steps from changing taps.
        for x in [192.0, 196.0, 199.0] {
            var previous = pixels.rgb(x: x, y: 170)[0]
            for y in 171..<280 {
                let current = pixels.rgb(x: x, y: CGFloat(y))[0]
                XCTAssertGreaterThanOrEqual(current, previous - 1,
                    "Blur radius stepped backwards at (\(x), \(y))")
                previous = current
            }
        }
    }

    private func render<Surface: View>(name: String, scheme: ColorScheme,
                                      @ViewBuilder surface: () -> Surface) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView:
            HeatmapHeroBlurredSurface(size: size, topEnd: 81, lowerStart: 158,
                                     lowerEnd: 302, strength: 1) {
                surface().frame(width: size.width, height: size.height)
            }
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        return image
    }

    private struct Pixels {
        let width: Int
        let scale: CGFloat
        var bytes: [UInt8]

        init(_ image: UIImage) throws {
            let cg = try XCTUnwrap(image.cgImage)
            width = cg.width
            scale = image.scale
            bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }

        func rgb(x: CGFloat, y: CGFloat) -> [Int] {
            let offset = (Int(y * scale) * width + Int(x * scale)) * 4
            return (0..<3).map { Int(bytes[offset + $0]) }
        }
    }
}
