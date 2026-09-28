import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class Holding52WeekLayoutTests: XCTestCase {
    func testRangeRowMatchesFigmaSizeAndSupportsDarkAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }
        let holding = Holding(ticker: "NVDA", logoSymbol: "NVDA", displayName: "iShare MSCI World ex..",
            sector: nil, source: nil, shares: 83.4, averageCost: 283, costCurrency: "USD",
            quotePrice: 173, quoteCurrency: "USD", todayChangePercent: nil,
            marketValue: 14_428.2, weight: 1, unrealized: -9_174, unrealizedPercent: -38.9,
            fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
        let range = Holding52WeekRange(low: 100, high: 300, latestClose: 173, currency: "USD", startPrice: 230)
        let cases: [(String, ColorScheme, DynamicTypeSize, Holding52WeekRange?)] = [
            ("light", .light, .large, range),
            ("dark", .dark, .large, range),
            ("accessible", .light, .accessibility3, range),
            ("gain", .light, .large, .init(low: 100, high: 300, latestClose: 173, currency: "USD", startPrice: 120)),
            ("outside-cost", .light, .large, .init(low: 100, high: 240, latestClose: 173, currency: "USD", startPrice: 150)),
            ("unavailable", .light, .large, nil)
        ]
        for (name, scheme, size, data) in cases {
            let content = HoldingRow(item: .holding(holding, performance: nil), performancePeriod: .holdingPeriod,
                    week52: Holding52WeekPrices(holding: holding, range: data))
                    .frame(width: 328)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.dynamicTypeSize, size).environment(\.colorScheme, scheme)
            let host = UIHostingController(rootView: content)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(200))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 328, accuracy: 1)
            if size == .large { XCTAssertEqual(image.size.height, 64, accuracy: 1) }
            else { XCTAssertGreaterThan(image.size.height, 64) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "holding-52week-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-holding-52week-\(name).png"))
        }
    }
}
