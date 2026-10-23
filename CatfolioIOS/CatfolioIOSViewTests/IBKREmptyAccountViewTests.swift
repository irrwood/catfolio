import SwiftUI
import Vision
import XCTest
@testable import CatfolioIOS

@MainActor
final class IBKREmptyAccountViewTests: XCTestCase {
    func testSyncedEmptyAccountHeaderShowsNoHoldingsInBothLanguages() throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
        let account = PortfolioAccount(id: "IBKR Flex|U123", accountID: "U123", source: "IBKR Flex",
            name: "IBKR", baseCurrency: "USD", positionCount: 0, transactionCount: 0,
            manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0)
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let renderer = ImageRenderer(content: AccountDetailHeader(account: account)
                .padding(20).frame(width: 390).background(Color.white)
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: language)))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "IBKR-empty-\(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = language == "en" ? ["en-US"] : ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            XCTAssertTrue(text.contains(language == "en" ? "No holdings yet" : "暂无持仓"), text)
        }
    }
}
