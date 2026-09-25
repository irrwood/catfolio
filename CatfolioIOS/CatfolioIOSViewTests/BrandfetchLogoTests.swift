import XCTest
import SwiftUI
@testable import CatfolioIOS

final class BrandfetchLogoTests: XCTestCase {
    func testTickerURLUsesExplicitBrandfetchRouteAndClientID() throws {
        let url = try XCTUnwrap(BrandfetchLogoURL.icon(for: " brk.b "))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "cdn.brandfetch.io")
        XCTAssertEqual(url.path, "/ticker/BRK.B/w/96/h/96/fallback/404/icon.png")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "c", value: "1idSx9hVGNTVGELIzRe")])
        XCTAssertNil(BrandfetchLogoURL.icon(for: "ETF 其他"))
        XCTAssertNil(BrandfetchLogoURL.icon(for: "../AAPL"))
    }

    func testDarkIconURLAsksForTheDarkTheme() throws {
        let url = try XCTUnwrap(BrandfetchLogoURL.icon(for: "brk.b", dark: true))
        XCTAssertEqual(url.path, "/ticker/BRK.B/w/96/h/96/theme/dark/fallback/404/icon.png")
        XCTAssertTrue(BrandfetchLogoURL.isDark(url))
        XCTAssertEqual(BrandfetchLogoURL.darkMissKey(" brk.b "), "BRK.B@DARK")
    }

    @MainActor
    func testBrandfetchLogoLoadsInEmbeddedImage() async throws {
        let url = try XCTUnwrap(BrandfetchLogoURL.icon(for: "AAPL"))
        let loaded = expectation(description: "Brandfetch HTML image loaded")
        let controller = UIHostingController(rootView: BrandfetchLogoImage(url: url) {
            loaded.fulfill()
        }.frame(width: 44, height: 44).opacity(0))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        await fulfillment(of: [loaded], timeout: 15)
    }
}
