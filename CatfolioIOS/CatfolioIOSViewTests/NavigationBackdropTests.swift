import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class NavigationBackdropTests: XCTestCase {
    func testExposedNavigationGroundMatchesPageInBothAppearances() async throws {
        for style in [HomeBackgroundStyle.classic, .plain] {
            for appearance in [UIUserInterfaceStyle.light, .dark] {
                try await withNavigation(style: style, appearance: appearance) { window, navigation, route, _ in
                    for pushed in [false, true, false] {
                        route.showsDetail = pushed
                        try await Task.sleep(for: .milliseconds(400))
                        XCTAssertEqual(navigation.viewControllers.count, pushed ? 2 : 1)
                        let page = try XCTUnwrap(navigation.topViewController)
                        let reference = try self.sample(window)
                        // Native interactive returns can expose the stack behind
                        // either moving page, especially around their rounded edges.
                        page.view.isHidden = true
                        defer { page.view.isHidden = false }
                        try await Task.sleep(for: .milliseconds(100))
                        let exposed = try self.sample(window)
                        // UIKit may dim the preceding page behind a pushed
                        // page. Preserve that neutral shadow while requiring
                        // the same ground colour, never a white replacement.
                        let brightness = reference.max() ?? 0
                        let dimming = pushed && brightness > 0.1
                            ? min(1, (exposed.max() ?? 0) / brightness) : 1
                        XCTAssertGreaterThanOrEqual(dimming, 0.75)
                        for (actual, expected) in zip(exposed, reference) {
                            XCTAssertEqual(actual, expected * dimming, accuracy: 0.04,
                                "The exposed \(style.rawValue) / \(appearance.rawValue) stack must retain the page ground")
                        }
                        try self.capture(window, name: "navigation-ground-\(style.rawValue)-\(appearance.rawValue)")
                    }
                }
            }
        }
    }

    func testNativePopDoesNotExposeWhiteAboveTheLightGradient() async throws {
        try await withNavigation(style: .classic, appearance: .light) { window, navigation, route, _ in
            route.showsDetail = true
            try await Task.sleep(for: .milliseconds(400))
            navigation.popViewController(animated: true)
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(40))
                let channels = try self.sample(window)
                XCTAssertLessThan(channels[0], 0.85, "The light sky must remain visible during pop")
            }
        }
    }

    func testBackgroundAndAppearanceChangesUpdateTheExposedGround() async throws {
        try await withNavigation(style: .classic, appearance: .light) { window, navigation, route, defaults in
            route.showsDetail = true
            try await Task.sleep(for: .milliseconds(400))
            defaults.set(HomeBackgroundStyle.plain.rawValue, forKey: HomeBackgroundStyle.preferenceKey)
            for appearance in [UIUserInterfaceStyle.dark, .light] {
                window.overrideUserInterfaceStyle = appearance
                try await Task.sleep(for: .milliseconds(350))
                let page = try XCTUnwrap(navigation.topViewController)
                let reference = try self.sample(window)
                page.view.isHidden = true
                defer { page.view.isHidden = false }
                try await Task.sleep(for: .milliseconds(100))
                for (actual, expected) in zip(try self.sample(window), reference) {
                    XCTAssertEqual(actual, expected, accuracy: 0.04)
                }
            }
        }
    }

    @Observable final class Route {
        var showsDetail = false
    }

    private func withNavigation(style: HomeBackgroundStyle, appearance: UIUserInterfaceStyle,
                                run: (UIWindow, UINavigationController, Route, UserDefaults) async throws -> Void) async throws {
        let suite = "navigation-backdrop-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(style.rawValue, forKey: HomeBackgroundStyle.preferenceKey)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = appearance
        let route = Route()
        let host = UIHostingController(rootView: RootPageNavigation {
            Color.clear.homeTabBackground()
                .toolbarVisibility(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: Binding(get: { route.showsDetail }, set: { route.showsDetail = $0 })) {
                    Color.clear.homeTabBackground().toolbarVisibility(.hidden, for: .navigationBar)
                }
        }.defaultAppStorage(defaults))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(350))
        func find(_ controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController { return navigation }
            return controller.children.lazy.compactMap(find).first
        }
        try await run(window, XCTUnwrap(find(host)), route, defaults)
    }

    private func sample(_ window: UIWindow) throws -> [Double] {
        let point = CGPoint(x: window.bounds.midX, y: window.bounds.height * 0.2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            context.cgContext.translateBy(x: -point.x, y: -point.y)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel.prefix(3).map { Double($0) / 255 }
    }

    private func capture(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
}
