import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class HomeTopScrollEdgeTests: XCTestCase {
    func testHeroStatusAreaPreservesTheUntintedBackdropInBothAppearances() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires scroll edge effects") }
        let suite = "home-top-edge-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(Color.clear))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }

        for style in [HomeBackgroundStyle.classic, .plain] {
            defaults.set(style.rawValue, forKey: HomeBackgroundStyle.preferenceKey)
            for appearance in [UIUserInterfaceStyle.light, .dark] {
                window.overrideUserInterfaceStyle = appearance
                var reference: [[Double]] = []
                for appliesHomeEdge in [false, true] {
                    let content = ScrollView { Color.clear.frame(height: 1800) }
                        .homeTabBackground()
                        .toolbarVisibility(.hidden, for: .navigationBar)
                    let page = appliesHomeEdge
                        ? AnyView(content.modifier(PortfolioTopScrollEdge(hasFloatingHeader: false)))
                        : AnyView(content.scrollEdgeEffectHidden(true, for: .top))
                    host.rootView = AnyView(RootPageNavigation { page }.defaultAppStorage(defaults))
                    try await Task.sleep(for: .milliseconds(250))
                    host.view.layoutIfNeeded()
                    XCTAssertGreaterThan(host.view.safeAreaInsets.top, 40)
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    // Along the screen's left edge, clear of status glyphs:
                    // these sample the safe area where the grey veil appeared.
                    let pixels = try [CGFloat(10), 25, 40].map {
                        try sample(image, at: CGPoint(x: 12, y: $0))
                    }
                    if appliesHomeEdge {
                        for (actual, expected) in zip(pixels.flatMap { $0 }, reference.flatMap { $0 }) {
                            XCTAssertEqual(actual, expected, accuracy: 0.02,
                                "The home top edge must not tint the \(style) / \(appearance) status backdrop")
                        }
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "home-top-\(style.rawValue)-\(appearance.rawValue)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    } else {
                        reference = pixels
                    }
                }
            }
        }
    }

    private func sample(_ image: UIImage, at point: CGPoint) throws -> [Double] {
        let cg = try XCTUnwrap(image.cgImage)
        let pixel = try XCTUnwrap(cg.cropping(to: CGRect(
            x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map { Double($0) / 255 }
    }
}
