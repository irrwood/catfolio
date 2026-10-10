import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class HistoryIncomeSummaryCardTests: XCTestCase {
    func testOverviewIsOneCompactTotalEvenWithBrokerAndEstimateSources() throws {
        let summary = HistoryIncomeSummary(realised: .init(brokerTotals: ["USD": 100], brokerCount: 3,
            estimatedUSD: 10, estimatedCount: 1, brokerUSD: 100), dividendsUSD: 50,
            dividendCount: 2, dividendsComplete: true)
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                let image = try render(summary, language: language, dark: dark)
                XCTAssertEqual(image.size.width, 370, accuracy: 0.5)
                XCTAssertEqual(image.size.height, 60, accuracy: 0.5,
                               "All's overview must not add broker or estimate detail rows")
                let attachment = XCTAttachment(image: image)
                attachment.name = "All-total-income-\(language)-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testLargeTextAndLongSignedAmountsFitWithoutWideningTheOverview() throws {
        let summary = HistoryIncomeSummary(realised: .init(brokerCount: 1, brokerUSD: -123_456.78),
            dividendsUSD: 100, dividendCount: 1, dividendsComplete: true)
        let regular = try render(summary, width: 288)
        let large = try render(summary, width: 288, size: .accessibility2)
        XCTAssertEqual(large.size.width, 288, accuracy: 0.5)
        XCTAssertGreaterThan(large.size.height, regular.size.height)
    }

    private func render(_ summary: HistoryIncomeSummary, language: String = "en", dark: Bool = false,
                        width: CGFloat = 370, size: DynamicTypeSize = .large) throws -> UIImage {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let previousCurrency = UserDefaults.standard.object(forKey: DisplayCurrency.preferenceKey)
        UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("USD", forKey: DisplayCurrency.preferenceKey)
        defer {
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            UserDefaults.standard.set(previousCurrency, forKey: DisplayCurrency.preferenceKey)
        }
        let renderer = ImageRenderer(content: HistoryIncomeSummaryCard(summary: summary)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, size).frame(width: width))
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }
}
