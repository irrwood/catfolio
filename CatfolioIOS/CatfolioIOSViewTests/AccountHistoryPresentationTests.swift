import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountHistoryPresentationTests: XCTestCase {
    func testMountedHomeLoadsAndDrawsNewAccountHistoryWithoutPullToRefresh() async throws {
        try await checkHomeHistory(firstVisit: false)
    }

    func testFirstVisitDrawsHistoryAsSoonAsItArrives() async throws {
        try await checkHomeHistory(firstVisit: true)
    }

    private func checkHomeHistory(firstVisit: Bool) async throws {
        let suite = "AccountHistoryPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = LocalPortfolioDocument(source: "CSV", updatedAt: Date(), positions: [
            .init(ticker: "AAPL", name: "Apple", shares: 10, averageCost: 100, currency: "USD",
                  quotePrice: 120, quoteCurrency: "USD", source: "CSV", openedDate: "2026-01-02", accountID: "A"),
            .init(ticker: "MSFT", name: "Microsoft", shares: 20, averageCost: 100, currency: "USD",
                  quotePrice: 90, quoteCurrency: "USD", source: "CSV", openedDate: "2026-01-02", accountID: "B")
        ], snapshots: [])
        let loader = AccountHistoryViewLoader()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input },
            presentationCache: .init(directory: directory),
            portfolioChartLoader: { document, cachedOnly, _ in
                try await loader.load(document, cachedOnly: cachedOnly)
            })
        await model.refreshPortfolio(refreshMarketData: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var chartReady = false
        let host = UIHostingController(rootView: NavigationStack {
            PortfolioView()
        }.environment(model).defaultAppStorage(defaults)
            .onPreferenceChange(PortfolioHeroReadyPreference.self) { chartReady = $0 })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        for key in firstVisit ? ["CSV|A,CSV|B"] : ["CSV|A", "CSV|B"] {
            // On first visit only mounting the view starts the request; no
            // account change, manual refresh or test-only model call does.
            if !firstVisit {
                await model.updateAccountSelection([key], selectsAll: false)
            }
            for _ in 0..<100 {
                if await loader.isPending { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard await loader.isPending else {
                XCTFail("The selected account did not start its history request")
                throw LocalServiceError.noHistoricalPrices
            }
            let task = try XCTUnwrap(model.accountHistoryTask)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(model.isPortfolioChartLoading)
            XCTAssertFalse(chartReady, "A snapshot must not present the plot as finished while history is still loading")
            await loader.complete()
            await task.value
            for _ in 0..<50 {
                if chartReady { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(chartReady, "The mounted home must draw after account history arrives without a refresh gesture")
            XCTAssertEqual(model.selectedAccountKeys, Set(key.split(separator: ",").map(String.init)))
            XCTAssertEqual(model.portfolioChart?.positionHistory.rows.count, 5)
            XCTAssertFalse(model.isPortfolioChartLoading)
            try await Task.sleep(for: .milliseconds(200))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(try blueLinePixels(in: image, window: window), 100,
                                 "The actual blue cost curve must be visible after switching accounts")
            let attachment = XCTAttachment(image: image)
            attachment.name = firstVisit ? "Home first history" : "Home after switching to \(key)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if firstVisit {
                try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-home-first-history.png"))
            }
        }
    }

    private func blueLinePixels(in image: UIImage, window: UIWindow) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let plot = CGRect(x: 0, y: window.safeAreaInsets.top + PortfolioHeroChartLayout.plotTop,
                          width: window.bounds.width, height: PortfolioHeroChartLayout.plotHeight)
        let cropped = try XCTUnwrap(source.cropping(to: plot))
        let width = cropped.width, height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let count = try pixels.withUnsafeMutableBytes { storage -> Int in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = storage.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0] < 110 && bytes[$0 + 1] > 70 && bytes[$0 + 1] < 180 && bytes[$0 + 2] > 200
            }.count
        }
        return count
    }
}

private actor AccountHistoryViewLoader {
    private var pending: CheckedContinuation<PortfolioChartResponse, Never>?
    private var response: PortfolioChartResponse?
    var isPending: Bool { pending != nil }

    func load(_ document: LocalPortfolioDocument, cachedOnly: Bool) async throws -> PortfolioChartResponse {
        if cachedOnly { throw LocalServiceError.noHistoricalPrices }
        let value = document.positions.reduce(0) { $0 + $1.shares * $1.quotePrice }
        let costs = document.positions.reduce(0) { $0 + $1.shares * $1.averageCost }
        let days = ["2026-01-02", "2026-03-02", "2026-05-01", "2026-07-01", DayDateCodec.string(from: Date())]
        let fractions = [0.9, 0.8, 0.95, 0.85, 1.0]
        let rows = zip(days, fractions).map { ChartPoint(dateText: $0, marketValue: value * $1, cost: costs) }
        response = .init(positionCount: document.positions.count, positionHistory: .init(available: true, rows: rows),
                         currentPoint: rows.last!, warning: nil)
        return await withCheckedContinuation { pending = $0 }
    }

    func complete() {
        if let response { pending?.resume(returning: response) }
        pending = nil
    }
}
