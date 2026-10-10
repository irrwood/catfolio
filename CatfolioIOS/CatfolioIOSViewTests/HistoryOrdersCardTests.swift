import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class HistoryOrdersCardTests: XCTestCase {
    private var breakdown: HistoryOrdersBreakdown {
        .init(rows: [row("AAA", name: "First company", amount: 100),
                     row("BBB", name: "Second company", amount: -25),
                     row("TINY", name: "Tiny result", amount: 0.01)],
              magnitudeUSD: 125.01)
    }

    private func row(_ ticker: String, name: String, amount: Double) -> HistoryOrdersBreakdown.Row {
        .init(ticker: ticker, name: name,
              calculation: .init(brokerTotals: ["USD": Decimal(amount)], brokerCount: 1, brokerUSD: amount), dates: [])
    }

    func testOrdersCardKeepsBrokerSourcesBelowTheRingInBothAppearances() async throws {
        let summary = RealisedProfitSummary(brokerTotals: ["USD": 75.01], brokerCount: 3, brokerUSD: 75.01)
        for dark in [false, true] {
            let image = try await render(HistoryRealisedSummaryCard(calculation: summary, ordersBreakdown: breakdown), dark: dark)
            XCTAssertEqual(image.size.width, 370, accuracy: 0.5)
            XCTAssertGreaterThan(image.size.height, 400)
            attach(image, "Orders-ring-with-broker-sources-\(dark ? "dark" : "light")")
        }
    }

    func testSelectedLossAndTinySourcesUseTheSameRingGeometryAsDividends() async throws {
        let layout = HistoryRingLayout(rows: breakdown.rows) { breakdown.share(for: $0) ?? 0 }
        XCTAssertEqual(layout.segments.count, 3)
        XCTAssertEqual(layout.segments.last?.fraction, HistoryDividendRingLayout.minimumFraction)
        let small = try XCTUnwrap(layout.segments.last)
        XCTAssertEqual(layout.row(at: 1 - small.fraction / 2)?.id, "TINY")
        for selection in ["BBB", "TINY"] {
            let image = try await render(HistoryOrdersProportion(breakdown: breakdown, initialSelection: selection)
                .settingsCardSurface())
            XCTAssertEqual(image.size.width, 370, accuracy: 0.5)
            attach(image, "Orders-ring-selected-\(selection)")
        }
    }

    func testEmptyRingAndLongNamesRemainReadableAtLargeTextSizes() async throws {
        let empty = try await render(HistoryRealisedSummaryCard(calculation: .init(), ordersBreakdown: .init()))
        attach(empty, "Orders-empty-ring")
        let long = HistoryOrdersBreakdown(rows: [row("LONG", name: "Invesco EQQQ Nasdaq-100 (Acc)", amount: -10)],
                                          magnitudeUSD: 10)
        let normal = try await render(HistoryOrdersProportion(breakdown: long, initialSelection: "LONG")
            .settingsCardSurface(), width: 288)
        let large = try await render(HistoryOrdersProportion(breakdown: long, initialSelection: "LONG")
            .settingsCardSurface(), width: 288, size: .accessibility2)
        XCTAssertEqual(large.size.width, 288, accuracy: 0.5)
        XCTAssertGreaterThan(large.size.height, normal.size.height)
        attach(large, "Orders-ring-long-name-large-text")
    }

    func testSelectionOutsideCurrentAccountOrYearScopeShowsTheOverview() async throws {
        let overview = try await render(HistoryOrdersProportion(breakdown: breakdown))
        let removed = try await render(HistoryOrdersProportion(breakdown: breakdown, initialSelection: "REMOVED"))
        XCTAssertEqual(overview.pngData(), removed.pngData(),
                       "A stock absent from the new scope must not leave every arc dimmed")
    }

    func testSelectingLongNamesKeepsTheRingAtTheSameHeight() async throws {
        let sources = HistoryOrdersBreakdown(rows: [
            row("SHORT", name: "Short", amount: 100),
            row("LONG", name: "Invesco EQQQ Nasdaq-100 UCITS ETF (Accumulating)", amount: -25)
        ], magnitudeUSD: 125)
        for size in [DynamicTypeSize.large, .accessibility2] {
            let overview = try await render(HistoryOrdersProportion(breakdown: sources), width: 288, size: size)
            for selection in ["SHORT", "LONG"] {
                let selected = try await render(HistoryOrdersProportion(breakdown: sources,
                    initialSelection: selection), width: 288, size: size)
                // The fixed-size ring is the last child: an unchanged card height
                // keeps its center and angle hit-testing under the same finger.
                XCTAssertEqual(selected.size.height, overview.size.height, accuracy: 0.5,
                    "Changing the selected name must not move the ring")
            }
        }
    }

    private func render<Content: View>(_ content: Content, width: CGFloat = 370, dark: Bool = false,
                                       size: DynamicTypeSize = .large) async throws -> UIImage {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let previousCurrency = UserDefaults.standard.object(forKey: DisplayCurrency.preferenceKey)
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("USD", forKey: DisplayCurrency.preferenceKey)
        defer {
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            UserDefaults.standard.set(previousCurrency, forKey: DisplayCurrency.preferenceKey)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let host = UIHostingController(rootView: content
            .environment(\.locale, Locale(identifier: "en_GB"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, size).frame(width: width))
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(150))
        let measured = host.sizeThatFits(in: CGSize(width: width, height: 2000))
        host.view.bounds = CGRect(origin: .zero, size: measured)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: measured, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
