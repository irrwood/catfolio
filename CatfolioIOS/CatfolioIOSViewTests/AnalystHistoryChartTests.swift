import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AnalystHistoryChartTests: XCTestCase {
    private func point(_ date: String, price: Double?, ratings: Bool = true,
                       counts: [Int] = [1, 2, 3, 4]) -> AnalystHistoryPoint {
        .init(date: date, price: price, low: nil, mean: nil, high: nil,
              sell: ratings ? counts[0] : nil, hold: ratings ? counts[1] : nil,
              buy: ratings ? counts[2] : nil, strongBuy: ratings ? counts[3] : nil)
    }

    func testRecommendationPriceUsesTheSameDatesWithAnIndependentScale() throws {
        let rows = [point("2026-01-01", price: 500), point("2026-02-01", price: 1000)]
        let data = AnalystHistoryChartData(points: rows, ratings: true)
        XCTAssertTrue(data.hasDualAxes)
        XCTAssertEqual(data.countCeiling, 10)
        XCTAssertEqual(data.priceCeiling, 1000)
        let price = try XCTUnwrap(data.series.last)
        XCTAssertTrue(price.id.hasPrefix("price|"), "The curve must paint above every rating area")
        XCTAssertEqual(price.points.map(\.date), data.dates)
        XCTAssertEqual(price.points.map(\.value), [5, 10])
        XCTAssertEqual(price.points.map { data.priceAtTick($0.value) }, [500, 1000])
        XCTAssertEqual(data.lines.last?.text(rows[0]), AnalystHistoryChartData.money(500))
        XCTAssertEqual(data.series.first?.points.map(\.value), [10, 10])
    }

    func testRangesKeepPriceAndRecommendationsOnTheSameObservations() {
        let rows = [point("2026-03-01", price: 30), point("2026-01-01", price: 10),
                    point("2026-04-09", price: 999, ratings: false), point("2026-02-01", price: 20)]
        let data = AnalystHistoryChartData(points: rows, ratings: true, months: 2)
        XCTAssertEqual(data.points.map(\.date), ["2026-02-01", "2026-03-01"])
        XCTAssertEqual(data.series.last?.points.map { DayDateCodec.string(from: $0.date) }, data.points.map(\.date))
        XCTAssertEqual(data.priceCeiling, 50, "A price-only snapshot outside the rating window cannot stretch its scale")
    }

    func testMissingPricesBreakTheCurveAndDoNotCreateQuotes() {
        let rows = [point("2026-01-01", price: 10), point("2026-02-01", price: nil),
                    point("2026-03-01", price: 30), point("2026-04-01", price: 40)]
        let data = AnalystHistoryChartData(points: rows, ratings: true)
        let prices = data.series.filter { $0.id.hasPrefix("price|") }
        XCTAssertEqual(prices.count, 2)
        XCTAssertEqual(prices.map { $0.points.count }, [1, 2])
        XCTAssertEqual(prices.first?.latestPointRadius, 3, "An isolated real quote remains a dot")
        XCTAssertFalse(prices.flatMap(\.points).contains { DayDateCodec.string(from: $0.date) == "2026-02-01" })
        let missing = AnalystHistoryChartData(points: [rows[1]], ratings: true)
        XCTAssertFalse(missing.hasDualAxes)
        XCTAssertFalse(missing.series.contains { $0.id.hasPrefix("price|") })
        XCTAssertEqual(missing.legendLines.first?.text(rows[1]), "—")
    }

    func testLegendTogglesKeepThePriceScaleAndRawRatingCounts() throws {
        let rows = [point("2026-01-01", price: 100), point("2026-02-01", price: 200)]
        let all = AnalystHistoryChartData(points: rows, ratings: true)
        let noPrice = AnalystHistoryChartData(points: rows, ratings: true, hidden: ["price"])
        XCTAssertFalse(noPrice.series.contains { $0.id.hasPrefix("price|") })
        XCTAssertEqual(noPrice.series.flatMap { $0.points.map(\.value) },
                       all.series.filter { $0.areaFill != nil }.flatMap { $0.points.map(\.value) })
        let noHold = AnalystHistoryChartData(points: rows, ratings: true, hidden: ["rating-1"])
        XCTAssertEqual(noHold.series.last?.points.map(\.value), all.series.last?.points.map(\.value))
        XCTAssertEqual(noHold.countCeiling, all.countCeiling)
        XCTAssertEqual(noHold.series.first?.points.map(\.value), [8, 8])
        XCTAssertEqual(noHold.points.first?.counts, [1, 2, 3, 4])
        XCTAssertEqual(all.legendLines.map(\.id), ["price", "rating-0", "rating-1", "rating-2", "rating-3"])
    }

    func testTargetModeKeepsDollarValuesAndIncludesPricesAboveTheHighTarget() throws {
        let row = AnalystHistoryPoint(date: "2026-01-01", price: 600, low: 100, mean: 200, high: 300,
                                      sell: 1, hold: 2, buy: 3, strongBuy: 4)
        let data = AnalystHistoryChartData(points: [row], ratings: false)
        XCTAssertFalse(data.hasDualAxes)
        XCTAssertEqual(data.ceiling, 600)
        XCTAssertEqual(data.series.map { $0.points.first?.value }, [600, 200, 300, 100])
        XCTAssertEqual(data.priceAtTick(300), 300)
    }

    func testBundledAAPLPricesRoundTripInEveryTimeRange() throws {
        let snapshot = try XCTUnwrap(AnalystHistorySnapshot.load(symbol: "AAPL"))
        for months in [0, 12, 24] {
            let data = AnalystHistoryChartData(points: snapshot.points, ratings: true, months: months)
            let quotes = data.series.filter { $0.id.hasPrefix("price|") }.flatMap(\.points)
            XCTAssertEqual(quotes.count, data.points.count)
            for (drawn, original) in zip(quotes, data.points) {
                XCTAssertEqual(DayDateCodec.string(from: drawn.date), original.date)
                XCTAssertEqual(data.priceAtTick(drawn.value), try XCTUnwrap(original.price), accuracy: 0.000_001)
            }
        }
    }

    func testPriceActuallyRendersAboveTheStackAndHidesInBothAppearances() async throws {
        let snapshot = try XCTUnwrap(AnalystHistorySnapshot.load(symbol: "AAPL"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(Color.clear))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let appearance = "analyst-chart-render-\(UUID())"
        ChartAppearanceHistory.record("analyst-history|\(appearance)")
        for scheme in [ColorScheme.light, .dark] {
            for hidden: Set<String> in [[], ["price"]] {
                let data = AnalystHistoryChartData(points: snapshot.points, ratings: true, hidden: hidden)
                host.rootView = AnyView(AnalystHistoryPlot(data: data, symbol: appearance,
                    transitionKey: "\(scheme)-\(hidden)", selectedDate: nil, onSelect: { _ in },
                    onInteractionEnded: {})
                    .padding(20).background(scheme == .light ? Color.white : Color.black)
                    .environment(\.colorScheme, scheme))
                try await Task.sleep(for: .milliseconds(600))
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let blue = try bluePixels(image)
                if hidden.isEmpty { XCTAssertGreaterThan(blue, 150) }
                else { XCTAssertEqual(blue, 0) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "analyst-ratings-price-\(scheme)-\(hidden.isEmpty ? "visible" : "hidden")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        // Capture the real page, including the range controls and legend.
        for scheme in [ColorScheme.light, .dark] {
            host.rootView = AnyView(NavigationStack { AnalystHistoryView(symbol: "AAPL", initialRatings: true) }
                .environment(\.colorScheme, scheme))
            try await Task.sleep(for: .milliseconds(600))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-analyst-history-\(scheme).png"))
        }
    }

    private func bluePixels(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: bytes.count, by: 4).filter {
            Int(bytes[$0 + 2]) > Int(bytes[$0 + 1]) + 50 && Int(bytes[$0 + 2]) > Int(bytes[$0]) + 70
        }.count
    }
}
