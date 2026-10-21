import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class AddAccountLayoutTests: XCTestCase {
    func testAllProviderChoicesKeepTheDesignedRowAndCardGeometry() async throws {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            for dark in [false, true] {
                let options = try await render(AddAccountOptions { _ in }, width: 370, dark: dark)
                XCTAssertEqual(options.size.width, 370, accuracy: 0.5)
                // Broker choices and imports have one gap; each card separates its rows.
                XCTAssertEqual(options.size.height, CGFloat(AddAccountProvider.allCases.count) * 96 + 12 + CGFloat(AddAccountProvider.allCases.count - 2) / options.scale, accuracy: 1)
                if dark {
                    try assertLightGlyph(in: options, center: CGPoint(x: 48, y: CGFloat(AddAccountProvider.allCases.firstIndex(of: .snaptrade)!) * (96 + 1 / options.scale) + 48))
                    try assertLightGlyph(in: options, center: CGPoint(x: 48, y: CGFloat(AddAccountProvider.allCases.firstIndex(of: .csv)!) * 96 + 12 + CGFloat(AddAccountProvider.allCases.count - 3) / options.scale + 48))
                }
                attach(options, name: "Add-account-\(language)-\(dark ? "dark" : "light")")
                for provider in AddAccountProvider.allCases {
                    let row = try await render(AddAccountProviderRow(provider: provider, action: {}),
                                         width: 370, dark: dark)
                    XCTAssertEqual(row.size.height, 96, accuracy: 0.5, provider.rawValue)
                    let icon = try await render(AddAccountProviderIcon(provider: provider), width: 56, dark: dark)
                    XCTAssertEqual(icon.size, CGSize(width: 56, height: 56))
                }
            }
        }
    }

    func testNarrowLargeTextWrapsWithoutClippingOrWideningChoices() async throws {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        let normal = try await render(AddAccountOptions { _ in }, width: 288)
        let large = try await render(AddAccountOptions { _ in }, width: 288, size: .accessibility2)
        XCTAssertEqual(normal.size.width, 288, accuracy: 0.5)
        XCTAssertEqual(large.size.width, 288, accuracy: 0.5)
        XCTAssertGreaterThan(large.size.height, normal.size.height)
        let longName = try await render(AddAccountProviderRow(provider: .snaptrade, action: {}),
                                  width: 288, size: .accessibility2)
        XCTAssertGreaterThan(longName.size.height, 96)
        attach(normal, name: "Add-account-narrow")
        attach(large, name: "Add-account-large-text")
    }

    func testAllIconsLoadAndExportedGlyphDimensionsArePreserved() throws {
        for provider in AddAccountProvider.allCases where provider.monogram == nil {
            let icon = try XCTUnwrap(UIImage(named: provider.iconAsset), provider.rawValue)
            XCTAssertGreaterThan(icon.size.width, 0)
            XCTAssertGreaterThan(icon.size.height, 0)
        }
        for name in ["AddAccountTrading212", "AddAccountMoomoo"] {
            XCTAssertEqual(try XCTUnwrap(UIImage(named: name)).size, CGSize(width: 56, height: 56))
        }
        for name in ["AddAccountConnection", "AddAccountCSV"] {
            XCTAssertEqual(try XCTUnwrap(UIImage(named: name)).size, CGSize(width: 32, height: 32))
        }
    }

    func testIBKRAndRobinhoodKeepTheirDarkLogoBackgroundsInBothAppearances() async throws {
        for dark in [false, true] {
            for provider in [AddAccountProvider.ibkr, .robinhood] {
                let image = try await render(AddAccountProviderIcon(provider: provider), width: 56, dark: dark)
                // The left interior is the logo's background, clear of the mark.
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
                    x: 7 * image.scale, y: 28 * image.scale, width: 1, height: 1)))
                var pixel = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if provider == .ibkr {
                    XCTAssertGreaterThan(Int(pixel[0]) - Int(pixel[1]), 80, "IBKR keeps its red background")
                } else {
                    XCTAssertGreaterThan(pixel[0], 100)
                    XCTAssertGreaterThan(pixel[1], 100)
                    XCTAssertLessThan(pixel[2], 100, "Robinhood keeps its lime background")
                }
            }
        }
    }

    func testCompleteAddAccountPageKeepsItsNativeNavigationAndScrollsToImport() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let suite = "add-account-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 660)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
        }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        // Its own store: the app's shared one may carry a resume flag from
        // elsewhere, which opens the Trading 212 page instead of the list.
        let host = UIHostingController(rootView: AddAccountView(setupStore: Trading212SetupStore(
                defaults: defaults, read: { _ in nil }, write: { _, _ in }))
            .environment(model)
            .environment(\.locale, Locale(identifier: "en_GB"))
            .preferredColorScheme(.light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(descendants(host.view, of: UIScrollView.self).first)
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertFalse(descendants(host.view, of: UINavigationBar.self).isEmpty)
        attach(snapshot(window), name: "Add-account-page-top")
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
        attach(snapshot(window), name: "Add-account-page-import")
    }

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool = false,
                                 size: DynamicTypeSize = .large) async throws -> UIImage {
        // Native hosting renders the vector assets with the current UIKit appearance.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let host = UIHostingController(rootView: view
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width)
            .background(SettingsTemplate.pageBackground))
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(100))
        let measured = host.sizeThatFits(in: CGSize(width: width, height: 3000))
        host.view.bounds = CGRect(origin: .zero, size: measured)
        host.view.layoutIfNeeded()
        // Let vector drawing layers finish after resizing the host for capture.
        try await Task.sleep(for: .milliseconds(150))
        return snapshot(host.view)
    }

    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func snapshot(_ view: UIView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    private func assertLightGlyph(in image: UIImage, center: CGPoint) throws {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: (center.x - 15) * image.scale, y: (center.y - 15) * image.scale,
            width: 30 * image.scale, height: 30 * image.scale)))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        // The updated Figma glyphs use 80% white over the colored badge.
        let lightPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 200 && pixels[$0 + 1] > 200 && pixels[$0 + 2] > 200
        }.count
        XCTAssertGreaterThan(lightPixels, 100, "The action glyph must stay visible after changing appearance")
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
