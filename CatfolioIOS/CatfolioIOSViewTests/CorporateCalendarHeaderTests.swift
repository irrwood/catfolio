import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class CorporateCalendarHeaderTests: XCTestCase {
    func testMonthAndSummaryShareCompactHeaderInBothLanguages() throws {
        for language in ["en", "zh-Hans"] {
            for width in [320.0, 370.0] {
                let image = try render(language: language, width: width, size: .large)
                XCTAssertEqual(image.size.width, width, accuracy: 1)
                XCTAssertLessThan(image.size.height, 60,
                                  "The summary must sit under the month beside the navigation buttons")
            }
        }
    }

    func testLargeTextCanGrowHeaderInsteadOfClipping() throws {
        let compact = try render(language: "en", width: 320, size: .large)
        let accessible = try render(language: "en", width: 320, size: .accessibility2)
        XCTAssertEqual(accessible.size.width, 320, accuracy: 1)
        XCTAssertGreaterThan(accessible.size.height, compact.size.height)
    }

    private func render(language: String, width: CGFloat, size: DynamicTypeSize) throws -> UIImage {
        let month = try XCTUnwrap(Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 10, day: 1)))
        let header = CorporateCalendarHeader(month: month, items: [
            .init(text: "≈ $28.17", symbol: nil, accessibilityText: "Approximately $28.17"),
            .init(text: "31", symbol: "calendar.badge.minus", accessibilityText: "31 ex-dividend dates"),
            .init(text: "22", symbol: "banknote", accessibilityText: "22 payments")
        ], previous: {}, next: {})
            .frame(width: width)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, size)
        let renderer = ImageRenderer(content: header)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "calendar-header-\(language)-\(width)-\(size)"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(attachment.name!).png"))
        return image
    }
}
