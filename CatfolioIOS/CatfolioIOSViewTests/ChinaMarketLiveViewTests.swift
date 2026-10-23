import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

/// Opt-in acceptance on a real iPhone or Simulator, using live public
/// quotes and the production history loader without fixture prices.
final class ChinaMarketLiveViewTests: XCTestCase {
    @MainActor
    func testLiveShanghaiShenzhenAndETFRenderRealPriceCharts() async throws {
        guard ProcessInfo.processInfo.environment["CATFOLIO_TEST_CN_LIVE"] == "1" else {
            throw XCTSkip("Live A-share view acceptance is opt-in")
        }
        try await renderLiveCharts(sources: [.akshare])
    }

    @MainActor
    func testLiveLongbridgeAKShareAndSwitchBack() async throws {
        guard ProcessInfo.processInfo.environment["CATFOLIO_TEST_CN_SWITCHING"] == "1" else {
            throw XCTSkip("Live source-switching acceptance is opt-in")
        }
        guard LongbridgeCredentials.stored != nil else {
            XCTFail("Save Longbridge credentials on the iPhone before source-switching acceptance")
            return
        }
        try await renderLiveCharts(sources: [.longbridge, .akshare, .longbridge])
    }

    @MainActor
    private func renderLiveCharts(sources: [ChinaMarketSource]) async throws {
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
        let scene = try await ChinaMarketViewTestHost.foregroundScene()
        let defaults = UserDefaults.standard
        let originalSource = defaults.object(forKey: ChinaMarketSource.preferenceKey)
        let originalLanguage = defaults.object(forKey: AppLanguage.preferenceKey)
        defaults.set("zh-Hans", forKey: AppLanguage.preferenceKey)
        defer {
            defaults.set(originalSource, forKey: ChinaMarketSource.preferenceKey)
            defaults.set(originalLanguage, forKey: AppLanguage.preferenceKey)
        }
        let modelSuite = "ChinaMarketLiveViewTests.\(UUID().uuidString)"
        let modelDefaults = try XCTUnwrap(UserDefaults(suiteName: modelSuite))
        defer { modelDefaults.removePersistentDomain(forName: modelSuite) }
        let model = AppModel(defaults: modelDefaults, personalDocumentLoader: { .empty })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        // A person keeping the device awake must not open another sheet
        // between the chart's render and its snapshot.
        window.isUserInteractionEnabled = false
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        for (index, source) in sources.enumerated() {
        defaults.set(source.rawValue, forKey: ChinaMarketSource.preferenceKey)
        for symbol in ["600519.SH", "000001.SZ", "510300.SH"] {
            let security = try XCTUnwrap(ChinaSecurity(symbol))
            let results = try await AKShareMarketDataClient().search(security.code)
            let holding = try XCTUnwrap(results.first { $0.ticker == security.ticker }?.holding)
            XCTAssertEqual(holding.quoteCurrency, "CNY")
            let history = try await LocalMarketDataClient().securityPriceHistory(
                ticker: holding.ticker, currency: "CNY", document: .empty, forceRefresh: true)
            XCTAssertGreaterThan(history.points.count, 640, "MAX must load past one history page")
            XCTAssertGreaterThan(history.intradayPoints.count, 0)
            XCTAssertGreaterThan(try XCTUnwrap(history.latestAvailablePrice), 0)
            XCTAssertEqual(history.chinaMarketAttribution?.source, source)
            XCTAssertEqual(history.chinaMarketConfiguration, .current)
            XCTAssertFalse(history.chinaMarketAttribution?.cached ?? true)
            let expectedQuote = try await ChinaMarketDataClient(selection: source).quote(security)
            // The latest regular minute and snapshot may differ while trading,
            // but must be the same security and CNY unit, never 100x apart.
            let ratio = try XCTUnwrap(history.latestAvailablePrice) / expectedQuote.price
            XCTAssertTrue((0.8...1.2).contains(ratio))
            try await model.publishSecurityPriceHistory(history, source: model.portfolioSource)
            XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges[holding.ticker]),
                expectedQuote.changePercent, accuracy: 0.1)

            let controller = UIHostingController(rootView: ScrollView {
                VStack(spacing: 12) {
                    HoldingDetailPriceSection(holding: holding, priceHistory: history, priceHistoryError: nil,
                        averageCost: nil, selectedAccountKeys: [])
                }
                .padding(.top, 24)
            }.environment(model).environment(\.locale, Locale(identifier: "zh-Hans")).preferredColorScheme(.light))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(1000))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(try chartPixels(image), 150, "The production price chart must actually draw")
            let attachment = XCTAttachment(image: image)
            attachment.name = "live-ashare-\(index)-\(source.rawValue)-\(security.tencentSymbol)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        }
    }

    private func chartPixels(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: bytes.count, by: 4).filter {
            Int(bytes[$0 + 2]) > Int(bytes[$0 + 1]) + 35 && Int(bytes[$0 + 2]) > Int(bytes[$0]) + 40
        }.count
    }
}
