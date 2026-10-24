import Foundation
import XCTest
@testable import CatfolioIOS

final class LocalAIContextTests: XCTestCase {
    func testDisclosureContextPreservesProfitAndLossDirection() throws {
        let defaults = UserDefaults.standard
        let savedCurrency = defaults.object(forKey: DisplayCurrency.preferenceKey)
        let savedLanguage = defaults.object(forKey: AppLanguage.preferenceKey)
        defaults.set("USD", forKey: DisplayCurrency.preferenceKey)
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.preferenceKey)
        defer {
            if let savedCurrency { defaults.set(savedCurrency, forKey: DisplayCurrency.preferenceKey) }
            else { defaults.removeObject(forKey: DisplayCurrency.preferenceKey) }
            if let savedLanguage { defaults.set(savedLanguage, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }

        let cases: [(ticker: String, price: Double, expected: String)] = [
            ("LOSS", 8, "-$20"),
            ("GAIN", 12, "+$20"),
            ("FLAT", 10, "+$0"),
        ]
        let document = LocalPortfolioDocument(
            source: PublicInvestorAccountAdapter.source,
            updatedAt: .distantPast,
            positions: cases.map {
                LocalPositionRecord(ticker: $0.ticker, name: $0.ticker,
                    shares: 10, averageCost: 10, currency: "USD",
                    quotePrice: $0.price, quoteCurrency: "USD",
                    source: PublicInvestorAccountAdapter.source, openedDate: nil)
            },
            snapshots: []
        )

        let context = try LocalAIClient().portfolioContext(document: document)
        for item in cases {
            let row = try XCTUnwrap(context.split(separator: "\n").first { $0.hasPrefix("\(item.ticker):") })
            XCTAssertTrue(row.hasSuffix("浮动盈亏 \(item.expected)"), String(row))
        }
    }
}
