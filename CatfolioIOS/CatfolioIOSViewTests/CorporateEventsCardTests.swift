import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class CorporateEventsCardTests: XCTestCase {
    func testDividendAmountsKeepTotalAndPerShareDistinct() {
        let restore = fixturePreferences()
        defer { restore() }
        let amounts = CorporateEventCardAmounts(event: payment(day: 9), shares: 3.07 / 0.07)
        XCTAssertEqual(amounts.total, "$3.07")
        XCTAssertEqual(amounts.perShare, "$0.07")

        let unheld = CorporateEventCardAmounts(event: payment(day: 9), shares: 0)
        XCTAssertNil(unheld.total)
        XCTAssertEqual(unheld.perShare, "$0.07")
        let earnings = CorporateEventCardAmounts(event: .init(ticker: "NVDA", kind: .earnings,
            date: "2026-10-09", isEstimate: true, amount: nil, currency: nil), shares: 10)
        XCTAssertNil(earnings.total)
        XCTAssertNil(earnings.perShare)
        let unknown = CorporateEventCardAmounts(event: .init(ticker: "NVDA", kind: .dividendPayment,
            date: "2026-10-09", isEstimate: false, amount: nil, currency: nil), shares: 10)
        XCTAssertNil(unknown.total)
        XCTAssertNil(unknown.perShare)
    }

    func testCardMatchesCompactFigmaGeometryAndAdaptsToLargeText() async throws {
        let restore = fixturePreferences()
        defer { restore() }
        for (language, width, size, scheme) in [
            ("en", 370.0, DynamicTypeSize.large, ColorScheme.light),
            ("zh-Hans", 370.0, DynamicTypeSize.large, ColorScheme.dark),
            ("en", 320.0, DynamicTypeSize.accessibility2, ColorScheme.light)
        ] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let card = CorporateEventsCardContent(holdings: [holding], events: [9, 10, 11].map(payment))
                .frame(width: width)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, size)
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
            try await warmLogos(in: card)
            let image = try render(card, name: "calendar-\(language)-\(size)-\(scheme)")
            XCTAssertEqual(image.size.width, width, accuracy: 1)
            if size == .large {
                XCTAssertEqual(image.size.height, 267, accuracy: 2,
                               "The compact header and three 72pt rows must match the Figma card")
            } else {
                XCTAssertGreaterThan(image.size.height, 267,
                                     "Accessibility text must grow the rows instead of clipping")
            }
        }
    }

    func testLoadingEmptyAndEarningsStatesRenderWithoutInventedAmounts() throws {
        let restore = fixturePreferences()
        defer { restore() }
        for loading in [false, true] {
            let card = CorporateEventsCardContent(holdings: [], events: [], isLoading: loading)
                .frame(width: 320)
            let image = try render(card, name: "calendar-\(loading ? "loading" : "empty")")
            XCTAssertEqual(image.size.width, 320, accuracy: 1)
            XCTAssertGreaterThan(image.size.height, 48)
            XCTAssertLessThan(image.size.height, 268)
        }
        let card = CorporateEventsCardContent(holdings: [holding], events: [
            .init(ticker: "NVDA", kind: .earnings, date: "2026-10-09",
                  isEstimate: true, amount: nil, currency: nil)
        ]).frame(width: 370)
        XCTAssertEqual(try render(card, name: "calendar-earnings").size.height, 121, accuracy: 2)
    }

    private func render<V: View>(_ view: V, name: String) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        return image
    }

    private func warmLogos<V: View>(in view: V) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(350))
    }

    private func fixturePreferences() -> () -> Void {
        let defaults = UserDefaults.standard
        let values = [AppLanguage.preferenceKey: "en", DisplayCurrency.preferenceKey: "USD",
                      CompanyNameDisplay.preferenceKey: CompanyNameDisplay.original.rawValue,
                      AssetLogoStyle.preferenceKey: AssetLogoStyle.automatic.rawValue]
        let saved = values.keys.map { ($0, defaults.object(forKey: $0)) }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        return {
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }
    }

    private func payment(day: Int) -> CorporateEvent {
        .init(ticker: "NVDA", kind: .dividendPayment, date: String(format: "2026-10-%02d", day),
              isEstimate: false, amount: 0.07, currency: "USD")
    }

    private var holding: Holding {
        Holding(ticker: "NVDA", logoSymbol: "NVDA", displayName: "NVIDIA", sector: nil, source: nil,
                shares: 3.07 / 0.07, averageCost: 100, costCurrency: "USD", quotePrice: 120,
                quoteCurrency: "USD", todayChangePercent: nil, marketValue: 5000, weight: 1,
                unrealized: 0, unrealizedPercent: 0, fxPnl: nil, fxPnlPercent: nil,
                fxPnlStatus: nil, fxPnlSource: nil)
    }
}
