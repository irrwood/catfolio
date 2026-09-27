import SwiftUI
import UIKit
import Vision
import XCTest
@testable import CatfolioIOS

final class HoldingAmountSourcesViewTests: XCTestCase {
    @MainActor
    func testPageShowsAmountsWithoutAllocatedProfitOrFootnotes() async throws {
        let defaults = UserDefaults.standard
        let language = defaults.string(forKey: AppLanguage.preferenceKey)
        let currency = defaults.string(forKey: DisplayCurrency.preferenceKey)
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        defaults.set("usd", forKey: DisplayCurrency.preferenceKey)
        defer {
            defaults.set(language, forKey: AppLanguage.preferenceKey)
            defaults.set(currency, forKey: DisplayCurrency.preferenceKey)
        }
        let row = ETFLookThroughRow(ticker: "NVDA", logoSymbol: "NVDA", name: "NVIDIA",
            directUSD: 18_766.75, fromETFUSD: 1_457.41, totalUSD: 20_224.16,
            etfWeightPercent: 5, sector: "Technology", allocatedCostUSD: 16_720.01,
            fundMarketValues: ["VUAG.L": 997.59, "VUSA.L": 205.08, "XS2D.L": 254.74])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView:
            HoldingAmountSourcesPage(ticker: "NVDA", initialRow: row)
                .environment(AppModel()).environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(.light))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").lowercased()
        for expected in ["merged value", "value sources", "20,224.16", "16,720.01", "18,766.75",
                         "vuag.l", "vusa.l", "xs2d.l"] {
            XCTAssertTrue(text.contains(expected), "Missing \(expected) in rendered page: \(text)")
        }
        for removed in ["allocated profit", "holding period", "today", "approximation", "broker positions"] {
            XCTAssertFalse(text.contains(removed), "Removed content must not appear: \(removed)")
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "holding-amount-sources"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-amount-sources.png"))
    }
}
