import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountDetailHeaderTests: XCTestCase {
    func testExpandedIdentityHandsOffToCenteredTitleAndReturnsWithoutChangingBarHeight() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "account-detail-header-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }

        for (source, name, dark, width, size) in [
            ("Trading 212", "Trading 212 · 橘子", false, 402.0, DynamicTypeSize.large),
            ("IBKR Flex", "IBKR · Individual", true, 402.0, .large),
            ("Trading 212", "Trading 212 · Long term retirement account", false, 320.0, .accessibility1),
            ("公开披露", "公开账户", true, 320.0, .large)
        ] {
            let account = PortfolioAccount(id: "header-fixture", accountID: source == "公开披露" ? "pelosi" : nil, source: source,
                name: name, baseCurrency: "USD", positionCount: 3, transactionCount: 8,
                manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 12500)
            let route = Route()
            let host = UIHostingController(rootView: NavigationStack(path: Binding(
                get: { route.path }, set: { route.path = $0 }
            )) {
                SettingsView()
                    .navigationDestination(for: Int.self) { _ in
                        AccountDetailView(accountID: account.id, initialAccount: account)
                    }
            }
            .environment(model)
            .defaultAppStorage(defaults)
            .environment(\.dynamicTypeSize, size)
            .preferredColorScheme(dark ? .dark : .light))
            window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            withAnimation { route.path = [1] }
            try await Task.sleep(for: .milliseconds(800))
            let navigation = try XCTUnwrap(controller(UINavigationController.self, in: host))
            let page = try XCTUnwrap(navigation.topViewController)
            let title = try XCTUnwrap(page.navigationItem.titleView)
            let frame = title.convert(title.bounds, to: window)
            XCTAssertEqual(page.navigationItem.title, account.localizedDisplayName)
            XCTAssertEqual(frame.midX, window.bounds.midX, accuracy: 1, "The logo and name center as one title")
            XCTAssertGreaterThan(frame.width, 30)
            XCTAssertGreaterThan(frame.height, 15)
            XCTAssertLessThanOrEqual(frame.height, 44)
            XCTAssertGreaterThanOrEqual(frame.minX, 60, "Keep the native back button reachable")
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX - 16)
            let height = navigation.navigationBar.frame.height
            XCTAssertLessThanOrEqual(height, 60, "Account details use an inline title")
            let backPoint = navigation.navigationBar.convert(CGPoint(x: 38, y: 22), to: window)
            let backHit = try XCTUnwrap(window.hitTest(backPoint, with: nil))
            XCTAssertFalse(backHit === title || backHit.isDescendant(of: title))
            XCTAssertLessThan(try titleInk(in: window, frame: frame, dark: dark), 5,
                              "The compact title stays hidden while the expanded identity is visible")

            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Account-title-\(source)-\(width)-\(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
            if width == 402 {
                try image.pngData()?.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("account-expanded-header-\(dark ? "dark" : "light").png"))
            }
            if size == .accessibility1 {
                try image.pngData()?.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("account-expanded-header-large-text.png"))
            }
            let scroll = try XCTUnwrap(page.contentScrollView(for: .top))
            let top = scroll.contentOffset
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.setContentOffset(CGPoint(x: 0, y: min(400, bottom)), animated: true)
            try await Task.sleep(for: .milliseconds(850))
            XCTAssertEqual(navigation.navigationBar.frame.height, height, accuracy: 1)
            XCTAssertEqual(title.convert(title.bounds, to: window).midY, frame.midY, accuracy: 1,
                           "Scrolling must not move or expand the compact title")
            XCTAssertGreaterThan(try titleInk(in: window, frame: frame, dark: dark), 50,
                                 "The compact identity appears after the expanded header scrolls away")
            if width == 402 {
                let collapsed = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try collapsed.pngData()?.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("account-collapsed-header-\(dark ? "dark" : "light").png"))
            }

            scroll.setContentOffset(top, animated: true)
            try await Task.sleep(for: .milliseconds(850))
            XCTAssertEqual(navigation.navigationBar.frame.height, height, accuracy: 1)
            XCTAssertEqual(scroll.contentOffset.y, top.y, accuracy: 1)
            XCTAssertLessThan(try titleInk(in: window, frame: frame, dark: dark), 5,
                              "Returning to the top restores the expanded header without a duplicate title")
        }
    }

    @Observable final class Route { var path: [Int] = [] }

    /// Read the rendered toolbar, including SwiftUI opacity, instead of relying
    /// on UIKit's container alpha (which does not expose SwiftUI's drawing).
    private func titleInk(in window: UIWindow, frame: CGRect, dark: Bool) throws -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { context in
            context.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: pixels.count, by: 4).filter { i in
            let rgb = pixels[i...i + 2]
            return dark ? rgb.allSatisfy { $0 > 200 } : rgb.allSatisfy { $0 < 60 }
        }.count
    }

    private func controller<T: UIViewController>(_ type: T.Type, in parent: UIViewController) -> T? {
        if let match = parent as? T { return match }
        return parent.children.lazy.compactMap { self.controller(type, in: $0) }.first
    }
}
