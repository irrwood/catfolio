import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AIHeaderAppearanceTests: XCTestCase {
    func testTopEdgeMatchesHomeWithoutAnOpaqueStatusOverlay() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires native scroll edge effects") }
        let suite = "ai-header-\(UUID())"
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

        for scheme in [ColorScheme.light, .dark, .light] {
            window.overrideUserInterfaceStyle = scheme == .light ? .light : .dark
            var reference: [[Double]] = []
            for usesAIHeader in [false, true] {
                let content = ScrollView { Color.clear.frame(height: 1800) }
                    .background(CatfolioPalette.homeSky.ignoresSafeArea())
                    .navigationTitle("AI")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarVisibility(.visible, for: .navigationBar)
                    .toolbarBackground(.hidden, for: .navigationBar)
                let page = usesAIHeader
                    ? AnyView(content.modifier(AIConversationTopEdge()))
                    : AnyView(content.modifier(PortfolioTopScrollEdge(hasFloatingHeader: true)))
                host.rootView = AnyView(RootPageNavigation { page }
                    .environment(\.colorScheme, scheme))
                try await Task.sleep(for: .milliseconds(200))
                host.view.layoutIfNeeded()
                let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
                XCTAssertFalse(scroll.topEdgeEffect.isHidden,
                               "Scrolling content uses the same native fade as the home toolbar")
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let pixels = try [CGFloat(20), 90, 170].map { try pixel(image, y: $0) }
                if usesAIHeader {
                    for (actual, expected) in zip(pixels.flatMap { $0 }, reference.flatMap { $0 }) {
                        XCTAssertEqual(actual, expected, accuracy: 0.025,
                                       "The AI header must not add a white or black wash over the home's fade")
                    }
                } else {
                    reference = pixels
                }
            }
        }

        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        for scheme in [ColorScheme.light, .dark] {
            window.overrideUserInterfaceStyle = scheme == .light ? .light : .dark
            host.rootView = AnyView(RootPageNavigation {
                AIView(isEmbedded: true, usesRootTabHeader: true, loadsHistoryOnAppear: false)
                    .homeTabBackground()
            }.environment(model).defaultAppStorage(defaults).environment(\.colorScheme, scheme))
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "ai-soft-header-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-ai-soft-header-\(scheme).png"))
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func pixel(_ image: UIImage, y: CGFloat) throws -> [Double] {
        let cg = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(cg.cropping(to: CGRect(
            x: 12 * image.scale, y: y * image.scale, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map { Double($0) / 255 }
    }
}
