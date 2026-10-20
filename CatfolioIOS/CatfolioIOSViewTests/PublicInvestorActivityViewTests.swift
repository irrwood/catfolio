import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

final class PublicInvestorActivityViewTests: XCTestCase {
    @MainActor
    func testAllSixPortraitsCoverLargestThreeScaleAvatarWithTransparency() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        for investor in catalog.investors {
            let asset = try XCTUnwrap(PublicInvestorPortrait.assetName(for: investor.id))
            let image = try XCTUnwrap(UIImage(named: asset), investor.id)
            let pixels = try XCTUnwrap(image.cgImage)
            // The largest avatar is 72 pt: 216 px covers a 3x iPhone.
            XCTAssertEqual(pixels.width, 216, investor.id)
            XCTAssertEqual(pixels.height, 216, investor.id)
            XCTAssertTrue([CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .first, .last].contains(pixels.alphaInfo))
        }
        XCTAssertNil(PublicInvestorPortrait.assetName(for: "demo"))
    }

    @MainActor
    func testRecentActivityRendersInBothAppearancesAndLargeText() async throws {
        _ = try await PublicInvestorCatalogState.shared.get()
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("zh-Hans", forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
        for (investorID, scheme, typeSize) in [
            ("ark", ColorScheme.light, DynamicTypeSize.large),
            ("pelosi", .dark, .large),
            ("pelosi", .light, .accessibility2),
            ("musk", .light, .large)
        ] {
            let controller = UIHostingController(rootView: NavigationStack {
                PublicInvestorActivityView(investorID: investorID)
            }.environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, typeSize))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertGreaterThan(controller.view.bounds.height, 0)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "investor-activity-\(investorID)-\(scheme)-\(typeSize)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func foregroundScene() async throws -> UIWindowScene {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        if scene.activationState != .foregroundActive {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
            for _ in 0..<100 {
                if scene.activationState == .foregroundActive { break }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        return try XCTUnwrap(scene.activationState == .foregroundActive ? scene : nil,
                            "The investor test host must be foregrounded to capture the page")
    }
}
