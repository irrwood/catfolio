import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ExtendedHoursChartTests: XCTestCase {
    private final class Capture { var frames: [String: CGRect] = [:] }

    private func point(_ time: String, _ price: Double) -> SecurityPricePoint {
        let date = ISO8601DateFormatter().date(from: "2026-10-12T\(time)-04:00")!
        return .init(dateText: String(Int(date.timeIntervalSince1970)), close: price, timestamp: date)
    }

    private func history(regular: [SecurityPricePoint] = [], extended: [SecurityPricePoint]) -> SecurityPriceHistory {
        .init(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-10-08", close: 98), .init(dateText: "2026-10-09", close: 100)],
            intradayPoints: regular, trades: [], extendedHoursPoints: extended)
    }

    func testPremarketOnlyLineSupportsSelectionAndEveryRangeEndsAtLatestPrice() {
        let history = history(extended: [point("04:00:00", 102), point("06:00:00", 101), point("08:00:00", 105)])
        let prepared = SecurityPricePreparedData(history: history, averageCost: nil, selectedAccountKeys: [])
        for range in ChartTimeRange.allCases {
            XCTAssertEqual(prepared.data(for: range).points.last?.price, 105, "\(range)")
        }
        let intraday = prepared.data(for: .oneDay)
        XCTAssertEqual(intraday.points.map(\.price), [102, 101, 105])
        XCTAssertEqual(intraday.nearest(to: point("06:00:00", 0).date)?.price, 101)
        XCTAssertEqual(intraday.points.last!.returnPercent, 5, accuracy: 1e-9)
        let series = SecurityPricePlotSeriesCache().prepared(for: intraday, scheme: .dark)
        XCTAssertEqual(series.priceSeries.points.map(\.value), [102, 101, 105])
        XCTAssertEqual(series.interactionDates, intraday.points.map(\.date))
    }

    func testPreRegularAndPostMarketUseOneChronologicalLineAndRefreshItsEndpoint() {
        let regular = [point("09:30:00", 103), point("15:55:00", 106)]
        let earlier = history(regular: regular,
            extended: [point("08:00:00", 102), point("17:00:00", 110)])
        let later = history(regular: regular,
            extended: [point("08:00:00", 102), point("17:00:00", 110), point("19:55:00", 108)])
        let cache = SecurityPricePlotSeriesCache()
        let before = SecurityPriceRangeData(history: earlier, range: .oneDay, averageCost: nil, selectedAccountKeys: [])
        let after = SecurityPriceRangeData(history: later, range: .oneDay, averageCost: nil, selectedAccountKeys: [])
        let first = cache.prepared(for: before, scheme: .dark)
        let updated = cache.prepared(for: after, scheme: .dark)
        XCTAssertEqual(updated.priceSeries.points.map(\.value), [102, 103, 106, 110, 108])
        XCTAssertEqual(updated.interactionDates.last, point("19:55:00", 108).date)
        XCTAssertNotEqual(first.geometryFingerprint, updated.geometryFingerprint)
        XCTAssertEqual(after.nearest(to: point("17:00:00", 0).date)?.price, 110)
        XCTAssertEqual(after.points.last!.returnPercent, 8, accuracy: 1e-9)
    }

    func testSinglePremarketAndAfterHoursPrintsRenderAPlotInsteadOfNoData() async throws {
        for (session, time) in [("premarket", "04:00:00"), ("after-hours", "17:00:00")] {
            let history = history(extended: [point(time, 105)])
            let data = SecurityPriceRangeData(history: history, range: .oneDay, averageCost: nil, selectedAccountKeys: [])
            XCTAssertEqual(data.points.count, 1)
            XCTAssertEqual(data.nearest(to: point(time, 0).date)?.price, 105)
            let rendered = try await render(history, name: "extended-chart-single-\(session)")
            XCTAssertGreaterThan(try XCTUnwrap(rendered.frames["security-price.plot"]).height, 300)
            let endpoint = try whiteEndpointBounds(in: rendered.image)
            XCTAssertGreaterThan(endpoint.minX, 100, "A lone print must sit inside the plot")
            XCTAssertGreaterThan(endpoint.width, 8, "The full 10pt endpoint ring must be visible")
            XCTAssertLessThan(endpoint.width, 12)
            XCTAssertLessThan(endpoint.maxX, 250)
        }
    }

    func testFullExtendedSessionRendersInTheExistingChart() async throws {
        let history = history(regular: [point("09:30:00", 103), point("12:00:00", 106), point("15:55:00", 104)],
            extended: [point("04:00:00", 101), point("06:00:00", 102), point("08:00:00", 100),
                       point("16:00:00", 105), point("18:00:00", 109), point("19:55:00", 108)])
        let rendered = try await render(history, name: "extended-chart-full-session")
        XCTAssertGreaterThan(try XCTUnwrap(rendered.frames["security-price.plot"]).height, 300)
    }

    private func whiteEndpointBounds(in image: UIImage) throws -> CGRect {
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height, scale = image.scale
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var left = width, right = -1, top = height, bottom = -1
        // A single price is vertically centered. Omit the axis and picker.
        for y in Int(80 * scale)..<min(height, Int(280 * scale)) {
            for x in 0..<min(width, Int(350 * scale)) {
                let index = (y * width + x) * 4
                if pixels[index] > 220, pixels[index + 1] > 220, pixels[index + 2] > 220 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(right, left, "The price plot must draw its endpoint")
        return CGRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale,
            width: CGFloat(max(0, right - left + 1)) / scale, height: CGFloat(max(0, bottom - top + 1)) / scale)
    }

    private func render(_ history: SecurityPriceHistory, name: String) async throws -> (frames: [String: CGRect], image: UIImage) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let capture = Capture()
        let host = UIHostingController(rootView:
            SecurityPriceChart(history: history, averageCost: nil, selectedAccountKeys: [])
                .frame(width: 402)
                .overlayPreferenceValue(ResearchCardLayoutFrames.self) { anchors in
                    GeometryReader { geometry in
                        let frames = anchors.mapValues { geometry[$0] }
                        Color.clear.onAppear { capture.frames = frames }
                            .onChange(of: frames) { _, value in capture.frames = value }
                    }
                }
                .environment(\.colorScheme, .dark)
                .background(Color.black))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.bounds = CGRect(x: 0, y: 0, width: 402, height: SecurityPriceChartState.fixedHeight)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        return (capture.frames, image)
    }
}
