import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class HistoryDividendCardTests: XCTestCase {
    private let breakdown = HistoryDividendBreakdown(rows: [
        .init(ticker: "FIRST", name: "First company", amountUSD: 82.5),
        .init(ticker: "VANGUARD", name: "Vanguard", amountUSD: 17.5)
    ], positiveTotalUSD: 100)

    func testTinySourcesHaveVisibleSelectableArcsWithoutChangingTheirRealShares() throws {
        let tiny = HistoryDividendBreakdown(rows: [
            .init(ticker: "LARGE", name: "Large", amountUSD: 999.98),
            .init(ticker: "SMALL1", name: "Small one", amountUSD: 0.01),
            .init(ticker: "SMALL2", name: "Small two", amountUSD: 0.01),
            .init(ticker: "ZERO", name: "Zero", amountUSD: 0),
            .init(ticker: "REVERSAL", name: "Reversal", amountUSD: -10)
        ], positiveTotalUSD: 1000)
        let layout = HistoryDividendRingLayout(breakdown: tiny)
        XCTAssertEqual(layout.segments.map(\.id), ["LARGE", "SMALL1", "SMALL2"])
        XCTAssertEqual(layout.segments[0].fraction, 0.96, accuracy: 1e-12)
        XCTAssertEqual(layout.segments[1].fraction, 0.02, accuracy: 1e-12)
        XCTAssertEqual(layout.segments[2].fraction, 0.02, accuracy: 1e-12)
        XCTAssertEqual(layout.row(at: 0.97)?.id, "SMALL1")
        XCTAssertEqual(layout.row(at: 0.99)?.id, "SMALL2")
        XCTAssertEqual(try XCTUnwrap(tiny.share(for: tiny.rows[1])), 0.00001, accuracy: 1e-12)
        XCTAssertEqual(layout.segments[1].row.amountUSD, 0.01)
        XCTAssertEqual(layout.segments.map(\.fraction).reduce(0, +), 1, accuracy: 1e-12)
    }

    func testMinimumArcsPreserveTheRelativeSizesOfLargerSources() {
        let chart = HistoryDividendBreakdown(rows: [
            .init(ticker: "A", name: "A", amountUSD: 80),
            .init(ticker: "B", name: "B", amountUSD: 19.9),
            .init(ticker: "C", name: "C", amountUSD: 0.1)
        ], positiveTotalUSD: 100)
        let segments = HistoryDividendRingLayout(breakdown: chart).segments
        XCTAssertEqual(segments[0].fraction / segments[1].fraction, 80 / 19.9, accuracy: 1e-12)
        XCTAssertEqual(segments[2].fraction, 0.02, accuracy: 1e-12)
        let unchanged = HistoryDividendRingLayout(breakdown: breakdown).segments
        XCTAssertEqual(unchanged[0].fraction, 0.825, accuracy: 1e-12)
        XCTAssertEqual(unchanged[1].fraction, 0.175, accuracy: 1e-12)
    }

    func testCrowdedRingsRetainEverySourceAndGapsCannotEraseTheirArcs() {
        let rows = [HistoryDividendBreakdown.Row(ticker: "LARGE", name: "Large", amountUSD: 1_000_000)]
            + (0..<60).map { HistoryDividendBreakdown.Row(ticker: "TINY\($0)", name: "Tiny \($0)", amountUSD: 0.01) }
        let chart = HistoryDividendBreakdown(rows: rows, positiveTotalUSD: 1_000_000.6)
        let layout = HistoryDividendRingLayout(breakdown: chart)
        XCTAssertEqual(layout.segments.count, rows.count)
        XCTAssertEqual(layout.segments.map(\.fraction).reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertGreaterThan(layout.segments[0].fraction, 0.5)
        var edge = 0.0
        for segment in layout.segments {
            XCTAssertGreaterThan(segment.fraction, 0)
            XCTAssertEqual(layout.row(at: edge + segment.fraction / 2)?.id, segment.id)
            let innerArc = segment.fraction * .pi * Double(HistoryDividendRingLayout.diameter * HistoryDividendRingLayout.innerRadiusRatio)
            XCTAssertGreaterThan(innerArc, Double(layout.angularInset * 2))
            edge += segment.fraction
        }
    }

    func testTinySourcesRenderInBothAppearances() async throws {
        let chart = HistoryDividendBreakdown(rows: [
            .init(ticker: "LARGE", name: "Large source", amountUSD: 999.98),
            .init(ticker: "SMALL1", name: "Small source", amountUSD: 0.01),
            .init(ticker: "SMALL2", name: "Tiny source", amountUSD: 0.01)
        ], positiveTotalUSD: 1000)
        for dark in [false, true] {
            attach(try await render(chart, dark: dark), name: "Dividend-tiny-arcs-\(dark ? "dark" : "light")")
            attach(try await render(chart, selection: "SMALL1", dark: dark),
                   name: "Dividend-tiny-selected-\(dark ? "dark" : "light")")
        }
    }

    func testSelectionMovesToHeadingAndKeepsBothPortfolioAmountsUnchanged() async throws {
        for dark in [false, true] {
            let overview = try await render(breakdown, dark: dark)
            let selected = try await render(breakdown, selection: "VANGUARD", dark: dark)
            XCTAssertEqual(overview.size.width, 370, accuracy: 0.5)
            XCTAssertEqual(overview.size.height, 343, accuracy: 3)
            XCTAssertEqual(selected.size, overview.size)
            let before = try XCTUnwrap(overview.cgImage)
            let after = try XCTUnwrap(selected.cgImage)
            let footer = CGRect(x: 0, y: before.height - 70 * 3, width: before.width, height: 70 * 3)
            XCTAssertEqual(try pixelData(before, in: footer), try pixelData(after, in: footer),
                           "Selecting a company must not replace the portfolio total or annual forecast")
            let heading = CGRect(x: 0, y: 0, width: before.width, height: 60 * 3)
            XCTAssertNotEqual(try pixelData(before, in: heading), try pixelData(after, in: heading),
                              "Selection must replace Proportion with the company and share")
            attach(overview, name: "Dividend-overview-\(dark ? "dark" : "light")")
            attach(selected, name: "Dividend-selected-\(dark ? "dark" : "light")")
        }
    }

    func testLongNamesAndLargeTextGrowWithoutWideningTheCard() async throws {
        let longName = HistoryDividendBreakdown(rows: [
            .init(ticker: "LONG", name: "Invesco EQQQ Nasdaq-100 (Acc)", amountUSD: 100)
        ], positiveTotalUSD: 100)
        let normal = try await render(longName, selection: "LONG", width: 288)
        let large = try await render(longName, selection: "LONG", width: 288, size: .accessibility2)
        XCTAssertEqual(normal.size.width, 288, accuracy: 0.5)
        XCTAssertEqual(large.size.width, 288, accuracy: 0.5)
        XCTAssertGreaterThan(normal.size.height, 343)
        XCTAssertGreaterThan(large.size.height, normal.size.height)
        attach(normal, name: "Dividend-long-name")
        attach(large, name: "Dividend-large-text")
    }

    func testUnknownAndEmptyAmountsKeepBothMetricSlots() async throws {
        let empty = try await render(HistoryDividendBreakdown(), forecast: nil)
        let unavailable = HistoryDividendBreakdown(rows: [
            .init(ticker: "UNKNOWN", name: "Unknown", amountUSD: nil)
        ], isComplete: false)
        let unknown = try await render(unavailable, forecast: .nan)
        XCTAssertEqual(empty.size, unknown.size)
        XCTAssertEqual(empty.size.height, 343, accuracy: 3)
        attach(empty, name: "Dividend-empty")
        attach(unknown, name: "Dividend-unavailable")
    }

    func testSelectingLongNamesKeepsTheRingAndFooterStationary() async throws {
        let sources = HistoryDividendBreakdown(rows: [
            .init(ticker: "SHORT", name: "Short", amountUSD: 75),
            .init(ticker: "LONG", name: "Invesco EQQQ Nasdaq-100 UCITS ETF (Accumulating)", amountUSD: 25)
        ], positiveTotalUSD: 100)
        for size in [DynamicTypeSize.large, .accessibility2] {
            let overview = try await render(sources, width: 288, size: size)
            for selection in ["SHORT", "LONG"] {
                let selected = try await render(sources, selection: selection, width: 288, size: size)
                XCTAssertEqual(selected.size.height, overview.size.height, accuracy: 0.5,
                    "Name wrapping must not move the ring or summary amounts")
            }
        }
    }

    private func render(_ breakdown: HistoryDividendBreakdown, selection: String? = nil,
                        forecast: Double? = 284.82, width: CGFloat = 370, dark: Bool = false,
                        size: DynamicTypeSize = .large) async throws -> UIImage {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let previousCurrency = UserDefaults.standard.object(forKey: DisplayCurrency.preferenceKey)
        defer {
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            UserDefaults.standard.set(previousCurrency, forKey: DisplayCurrency.preferenceKey)
        }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("USD", forKey: DisplayCurrency.preferenceKey)
        // Menus have a native backing view, so capture a live host rather
        // than ImageRenderer's unsupported-view placeholder.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let host = UIHostingController(rootView:
            HistoryDividendCard(breakdown: breakdown, totalUSD: 314.83, forecastUSD: forecast,
                                initialSelection: selection)
                .environment(\.locale, Locale(identifier: "en_GB"))
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.dynamicTypeSize, size)
                .frame(width: width))
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

    private func pixelData(_ image: CGImage, in rect: CGRect) throws -> Data {
        let crop = try XCTUnwrap(image.cropping(to: rect))
        return try XCTUnwrap(crop.dataProvider?.data) as Data
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
