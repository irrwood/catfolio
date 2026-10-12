import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class MechanicalSentimentDialTests: XCTestCase {
    func testIndustryPageUsesHostAppearanceAndPreservesDayDial() async throws {
        let suite = "IndustryDialAppearance.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "industry-sentiment.mechanical-dial")
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        await model.refreshPortfolio(refreshMarketData: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            let host = UIHostingController(rootView: NavigationStack {
                IndustrySentimentView().environment(model)
            }.defaultAppStorage(defaults).environment(\.scenePhase, .active))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(1))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let ground = try pixel(image, x: 10, y: 200)
            if style == .light {
                XCTAssertGreaterThan(ground.red, 0.9, "The industry page must no longer force night appearance")
            } else {
                XCTAssertLessThan(ground.red, 0.1, "The night page keeps its dark ground")
            }
            let name = "industry-sentiment-\(style == .light ? "light" : "dark")"
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        }
    }

    func testDayDialUsesSilverRimAndWhiteNeedleWithoutChangingNightArtwork() throws {
        let bundled = try XCTUnwrap(UIImage(named: "SentimentDialDayHeaderFace"))
        XCTAssertGreaterThan(try pixel(bundled, x: 227, y: 8).red, 0.6, "The bundled day texture must retain its silver rim")
        let light = try render(.light)
        let dark = try render(.dark)
        let lightRim = try pixel(light, x: 227, y: 8)
        let darkRim = try pixel(dark, x: 227, y: 8)
        XCTAssertGreaterThan(lightRim.red, darkRim.red + 0.25,
                             "Daylight must use the silver bezel instead of the dark one")
        XCTAssertGreaterThan(try pixel(light, x: 227.58, y: 100).blue, 0.8,
                             "The daylight needle must be white")
        XCTAssertLessThan(darkRim.red, 0.5, "Night must keep its original dark bezel")
        for (name, image) in [("light", light), ("dark", dark)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = "sentiment-dial-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-day-dial-\(name).png"))
        }
    }

    func testDayNeedleFollowsValueAndDisappearsWhenScoreIsMissing() throws {
        let neutral = try render(.light)
        let fear = try render(.light, fraction: 0)
        let missing = try render(.light, score: nil)
        let needle = try pixel(neutral, x: 227.58, y: 100)
        let rotated = try pixel(fear, x: 227.58, y: 100)
        let absent = try pixel(missing, x: 227.58, y: 100)
        XCTAssertGreaterThan(needle.blue, rotated.blue + 0.25,
                             "Changing the value must rotate the live pointer")
        XCTAssertGreaterThan(needle.blue, absent.blue + 0.25,
                             "Missing data must show the face without a fabricated reading")
    }

    private func render(_ scheme: ColorScheme, score: Int? = 50, fraction: Double = 0.5) throws -> UIImage {
        let renderer = ImageRenderer(content:
            MechanicalSentimentDial(headerOnly: true, score: score, label: "", paused: true, fraction: { _ in fraction })
                .frame(width: 454, height: 454)
                .background(scheme == .light ? Color.white : Color.black)
                .environment(\.colorScheme, scheme))
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> (red: Double, green: Double, blue: Double) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(cgImage.cropping(to: CGRect(x: x * image.scale, y: y * image.scale,
                                                           width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(rgba[0]) / 255, Double(rgba[1]) / 255, Double(rgba[2]) / 255)
    }
}
