import SwiftUI
import XCTest
import Vision
@testable import CatfolioIOS

@MainActor
final class WatchlistViewTests: XCTestCase {
    func testQuoteRowsFitLightDarkCompactAndAccessibilityLayouts() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store()
        for holding in samples.reversed() { store.toggle(holding) }
        let model = AppModel(defaults: fixture.defaults, watchlist: store)
        for width: CGFloat in [320, 402] {
            for dark in [false, true] {
                for large in [false, true] {
                    let capture = Frames()
                    try await fixture.show(NavigationStack {
                        WatchlistView(store: store)
                    }.environment(model)
                        .environment(\.scenePhase, .inactive)
                        .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                        .preferredColorScheme(dark ? .dark : .light), width: width, frames: capture)
                    let identities = capture.values.filter { $0.key.hasPrefix("watchlist.identity.") }
                    XCTAssertFalse(identities.isEmpty)
                    let cells = capture.values.filter { $0.key.hasPrefix("watchlist.cell.") }
                        .values.sorted { $0.minY < $1.minY }
                    XCTAssertGreaterThanOrEqual(cells.count, 2)
                    for cell in cells {
                        if !large {
                            XCTAssertEqual(cell.height, 64, accuracy: 1,
                                           "Quote rows should retain the home holdings list's row height")
                        }
                    }
                    for (previous, next) in zip(cells, cells.dropFirst()) {
                        XCTAssertEqual(next.minY - previous.maxY, 4, accuracy: 1,
                                       "Rows should have one consistent gap without extra outer padding")
                    }
                    for (key, identity) in identities {
                        let id = String(key.dropFirst("watchlist.identity.".count))
                        let metrics = try XCTUnwrap(capture.values["watchlist.metrics.\(id)"])
                        XCTAssertGreaterThanOrEqual(metrics.minX, 19)
                        XCTAssertLessThanOrEqual(metrics.maxX, width - 19, "Figures must stay inside the page at \(width) / \(large)")
                        if large {
                            XCTAssertGreaterThanOrEqual(metrics.minY, identity.maxY)
                        } else {
                            XCTAssertLessThanOrEqual(identity.maxX, metrics.minX - 7)
                        }
                    }
                    try fixture.capture(name: "watchlist-\(Int(width))-\(dark ? "dark" : "light")-\(large ? "large" : "regular")")
                }
            }
        }
    }

    func testDetailStarBesideAIReflectsPersistedMembership() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store()
        let model = AppModel(defaults: fixture.defaults, watchlist: store)
        let holding = samples[0]
        let frames = Frames()
        try await fixture.show(ScrollView {
            HoldingDetailPriceSection(holding: holding, priceHistory: nil, priceHistoryError: "Fixture",
                averageCost: nil, selectedAccountKeys: [], refreshError: nil)
        }.environment(model).preferredColorScheme(.light), width: 402, frames: frames)
        let ai = try XCTUnwrap(frames.values["holding-detail.ai-action"])
        let star = try XCTUnwrap(frames.values["holding-detail.watchlist-action"])
        XCTAssertEqual(star.width, 52, accuracy: 1)
        XCTAssertEqual(star.height, 52, accuracy: 1)
        XCTAssertEqual(ai.maxX + 12, star.minX, accuracy: 1)
        XCTAssertEqual(ai.midY, star.midY, accuracy: 1)
        let before = try fixture.darkPixels(in: star)
        XCTAssertGreaterThan(before, 50)
        store.toggle(holding)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(try fixture.darkPixels(in: star), Int(Double(before) * 1.3), "The star must visibly fill when saved")
        XCTAssertTrue(WatchlistStore(defaults: fixture.defaults).contains(holding))
        try fixture.capture(name: "detail-star-saved")
        store.toggle(holding)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(store.contains(holding))
        XCTAssertEqual(Double(before), Double(try fixture.darkPixels(in: star)), accuracy: Double(before) * 0.08,
                       "Unsave returns to the outlined star; material pixels may vary slightly")
    }

    func testPerformanceShowsWatchlistEntryBelowItsAnalysisCards() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: "catfolio.fakeDataMode")
        let model = AppModel(defaults: fixture.defaults, watchlist: fixture.store())
        await model.refreshPortfolio(refreshMarketData: false)
        try await fixture.show(RootPageNavigation { ReturnsView() }
            .environment(model).preferredColorScheme(.light), width: 402)
        try await Task.sleep(for: .milliseconds(300))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(fixture.image().cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("Watchlist"), "The second tab's entry should be visible without scrolling: \(text)")
        let watchlist = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.contains("Watchlist") == true
        })
        let comparisonTitles = (request.results ?? []).filter {
            ["RETURN", "CYCLE"].contains($0.topCandidates(1).first?.string.uppercased() ?? "")
        }
        XCTAssertEqual(comparisonTitles.count, 2, "Both lower cards should be visible: \(text)")
        for title in comparisonTitles {
            // Vision's normalized coordinates start at the bottom.
            XCTAssertLessThan(watchlist.boundingBox.maxY, title.boundingBox.minY)
        }
        try fixture.capture(name: "performance-watchlist-entry")
    }

    func testRemovingLastSecurityShowsEmptyInstructions() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store()
        store.toggle(samples[0])
        let model = AppModel(defaults: fixture.defaults, watchlist: store)
        try await fixture.show(NavigationStack {
            WatchlistView(store: store)
        }.environment(model).environment(\.scenePhase, .inactive).preferredColorScheme(.light), width: 402)
        store.toggle(samples[0])
        try await Task.sleep(for: .milliseconds(250))
        let image = fixture.image()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("Your watchlist is empty"), text)
        try fixture.capture(name: "watchlist-empty")
    }

    private var samples: [Holding] {
        [("NVDA", "NVIDIA", "USD", 182.45, 2.47),
         ("AAPL", "Apple", "USD", 248.32, -1.18),
         ("600519.SS", "Kweichow Moutai", "CNY", 1486.50, 1.72),
         ("VUAG.L", "Vanguard S&P 500 (Acc)", "GBP", 102.36, 0.0),
         ("9988.HK", "Alibaba", "HKD", 132.80, -2.12),
         ("NEW", "No quote yet", "USD", 0.0, 0.0)].map {
            Holding(ticker: $0.0, logoSymbol: $0.0, displayName: $0.1, sector: nil, source: nil,
                    shares: 0, averageCost: 0, costCurrency: nil, quotePrice: $0.3, quoteCurrency: $0.2,
                    todayChangePercent: $0.3 == 0 ? nil : $0.4, marketValue: 0, weight: 0,
                    unrealized: 0, unrealizedPercent: 0, fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
        }
    }

    @MainActor private final class Frames { var values: [String: CGRect] = [:] }

    @MainActor private final class Fixture {
        let suite = "WatchlistViewTests.\(UUID())"
        let defaults: UserDefaults
        let window: UIWindow
        let previous: UIWindow?
        let language: Any?

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            language = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
            UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        }
        func store() -> WatchlistStore { WatchlistStore(defaults: defaults, loader: { _, _ in [:] }) }

        func show<V: View>(_ content: V, width: CGFloat, frames: Frames? = nil) async throws {
            let host = UIHostingController(rootView: content
                .overlayPreferenceValue(ResearchCardLayoutFrames.self) { anchors in
                    GeometryReader { geometry in
                        let values = anchors.mapValues { geometry[$0] }
                        Color.clear.onAppear { frames?.values = values }
                            .onChange(of: values) { _, value in frames?.values = value }
                    }.allowsHitTesting(false)
                }
                .environment(\.locale, Locale(identifier: "en")))
            window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
        }

        func image() -> UIImage {
            UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }

        func darkPixels(in frame: CGRect) throws -> Int {
            let image = image()
            let crop = CGRect(x: frame.minX * image.scale, y: (frame.minY + window.safeAreaInsets.top) * image.scale,
                              width: frame.width * image.scale, height: frame.height * image.scale)
            let bitmap = try XCTUnwrap(image.cgImage?.cropping(to: crop))
            var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: bitmap.width, height: bitmap.height,
                bitsPerComponent: 8, bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
            return stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] < 100 && pixels[$0 + 1] < 100 && pixels[$0 + 2] < 100 && pixels[$0 + 3] > 200
            }.count
        }

        func capture(name: String) throws {
            let image = image()
            // Stable local paths for visual review.
            let directory = URL(fileURLWithPath: "/tmp/catfolio-watchlist", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
        }
    }
}
