import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class HistoryRealisedSummaryCardTests: XCTestCase {
    func testCurrencyArithmeticUsesOneOperatorAndPreservesEachAmount() {
        let values = ["+€2,704.00", "-£1,500.00", "+$420.00", "−CHF200.00"]
        let terms = values.enumerated().map { HistoryCurrencyAmountTerm($0.element, isFirst: $0.offset == 0) }
        XCTAssertEqual(terms.map(\.operation), [nil, "-", "+", "−"])
        XCTAssertEqual(terms.map(\.amount), ["+€2,704.00", "£1,500.00", "$420.00", "CHF200.00"])
        let firstNegative = HistoryCurrencyAmountTerm("-$10.00", isFirst: true)
        XCTAssertNil(firstNegative.operation)
        XCTAssertEqual(firstNegative.amount, "-$10.00")
        XCTAssertEqual(HistoryCurrencyAmountTerm("—", isFirst: true).amount, "—")
    }

    func testCategorySummaryRowsKeepTheSameReferenceHeight() throws {
        let rows: [(String, SettingsIconSource)] = [
            ("Realised P/L", .asset("HistoryRealisedRocket")),
            ("Total dividends", .asset("HistoryDividend")),
            ("Total interest", .symbol("building.columns.circle.fill")),
            ("Annual fee total", .symbol("creditcard.circle.fill"))
        ]
        for dark in [false, true] {
            for (title, icon) in rows {
                let renderer = ImageRenderer(content:
                    HistorySummaryRow(title: title, icon: icon, value: "+$2,704")
                        .environment(\.dynamicTypeSize, .large)
                        .frame(width: 370))
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size, CGSize(width: 370, height: 60), title)
            }
            let renderer = ImageRenderer(content: SettingsCard {
                ForEach(rows.indices, id: \.self) { index in
                    HistorySummaryRow(title: rows[index].0, icon: rows[index].1,
                        value: "+$2,704", valueColor: CatfolioTheme.positive)
                }
            }
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 370))
            renderer.scale = 3
            attach(try XCTUnwrap(renderer.uiImage), name: "History-category-headers-\(dark ? "dark" : "light")")
        }
    }

    func testBrokerCardFitsReferenceSizeInBothAppearances() throws {
        let summary = RealisedProfitSummary(
            brokerTotals: ["EUR": 2704, "GBP": 2704, "USD": 2704],
            brokerCount: 558, brokerUSD: 9000)
        for dark in [false, true] {
            let image = try render(summary, width: 370, dark: dark)
            XCTAssertEqual(image.size.width, 370, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(image.size.height, 130)
            XCTAssertLessThanOrEqual(image.size.height, 145,
                                    "The three currency amounts should fit on one line")
            attach(image, name: "History-summary-\(dark ? "dark" : "light")")
        }
        for name in ["HistoryRealisedRocket", "HistoryBrokerCalculator"] {
            let icon = try XCTUnwrap(UIImage(named: name))
            XCTAssertEqual(icon.size, CGSize(width: 24, height: 24))
        }
    }

    func testNarrowAndLargeTextCardsGrowToKeepAllSourcesReadable() throws {
        let summary = RealisedProfitSummary(
            brokerTotals: ["EUR": -123456.78, "GBP": 98765.43, "USD": 23456.78],
            brokerCount: 558, estimatedUSD: -999.99, estimatedCount: 28,
            unavailableCount: 14, brokerUSD: -12345.67)
        let normal = try render(summary, width: 370, dark: false)
        let narrow = try render(summary, width: 288, dark: false)
        let large = try render(summary, width: 288, dark: true, size: .accessibility2)
        XCTAssertEqual(narrow.size.width, 288, accuracy: 0.5)
        XCTAssertEqual(large.size.width, 288, accuracy: 0.5)
        XCTAssertGreaterThan(narrow.size.height, normal.size.height)
        XCTAssertGreaterThan(large.size.height, narrow.size.height)
        attach(narrow, name: "History-summary-narrow-mixed-sources")
        attach(large, name: "History-summary-accessibility-mixed-sources")

        let empty = try render(RealisedProfitSummary(), width: 288, dark: false)
        XCTAssertEqual(empty.size.width, 288, accuracy: 0.5)
        XCTAssertGreaterThan(empty.size.height, 100)
        attach(empty, name: "History-summary-empty")
    }

    private func render(_ summary: RealisedProfitSummary, width: CGFloat, dark: Bool,
                        size: DynamicTypeSize = .large) throws -> UIImage {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let previousCurrency = UserDefaults.standard.object(forKey: DisplayCurrency.preferenceKey)
        defer {
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            UserDefaults.standard.set(previousCurrency, forKey: DisplayCurrency.preferenceKey)
        }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("USD", forKey: DisplayCurrency.preferenceKey)
        let renderer = ImageRenderer(content: HistoryRealisedSummaryCard(calculation: summary)
            .environment(\.locale, Locale(identifier: "en_GB"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, size)
            .frame(width: width)
            .background(SettingsTemplate.pageBackground))
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
