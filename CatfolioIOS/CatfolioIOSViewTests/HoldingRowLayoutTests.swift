import SwiftUI
import Vision
import XCTest
@testable import CatfolioIOS

@MainActor
final class HoldingRowLayoutTests: XCTestCase {
    func testPerformanceAmountAndPercentCanBeHiddenIndependently() throws {
        let defaults = UserDefaults.standard
        let previousCurrency = defaults.object(forKey: DisplayCurrency.preferenceKey)
        defaults.set("USD", forKey: DisplayCurrency.preferenceKey)
        defer { defaults.set(previousCurrency, forKey: DisplayCurrency.preferenceKey) }
        let holding = holding(unrealized: -2783.64, shares: 83.4078, ticker: "NVDA", displayName: "NVIDIA", weight: 0.137)
        let performance = HoldingPerformanceValues(amount: -2783.64, percent: -18.1)
        let direct = PortfolioHoldingListItem.holding(holding, performance: performance)
        let exposure = PortfolioHoldingListItem.exposure(
            .init(ticker: "NVDA", logoSymbol: "NVDA", name: "NVIDIA", directUSD: 1000, fromETFUSD: 370,
                  totalUSD: 1370, etfWeightPercent: 5, sector: nil, allocatedCostUSD: 1000),
            direct: holding, portfolioTotal: 10_000, performance: performance)
        for item in [direct, exposure] {
            for size in [DynamicTypeSize.large, .accessibility1] {
                for showsAmount in [true, false] {
                    for showsPercent in [true, false] {
                        let renderer = ImageRenderer(content: HoldingRow(item: item, performancePeriod: .holdingPeriod,
                            showsShares: false, showsPerformanceAmount: showsAmount, showsPerformancePercent: showsPercent)
                            .frame(width: 370).padding(16).background(.white)
                            .environment(\.dynamicTypeSize, size)
                            .environment(\.colorScheme, .light)
                            .environment(\.locale, Locale(identifier: "en_US")))
                        renderer.scale = 3
                        let image = try XCTUnwrap(renderer.uiImage)
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                            .joined().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: "")
                        XCTAssertEqual(text.contains("2783.64"), showsAmount, text)
                        XCTAssertEqual(text.contains("18.1%"), showsPercent, text)
                        XCTAssertTrue(text.contains("NVIDIA"), text)
                        if size == .large { XCTAssertEqual(image.size.height, 96, accuracy: 1) }
                    }
                }
            }
        }
        let hidden = ImageRenderer(content: HoldingPerformanceLabel(performance: nil,
            showsAmount: false, showsPercent: false))
        XCTAssertEqual(hidden.uiImage?.size.height ?? 0, 0)
    }

    func testSharesCanBeToggledIndependentlyOfTickerAndWeight() throws {
        let holding = holding(unrealized: 370, shares: 83.4078, ticker: "NVDA", displayName: "NVIDIA", weight: 0.137)
        for size in [DynamicTypeSize.large, .accessibility1] {
            for showsShares in [true, false] {
                for showsTicker in [true, false] {
                    for showsWeight in [true, false] {
                        let renderer = ImageRenderer(content: HoldingRow(holding: holding,
                            performancePeriod: .holdingPeriod, dailyChangePercent: nil,
                            showsWeight: showsWeight, showsTicker: showsTicker, showsShares: showsShares)
                            .frame(width: 370).padding(16).background(.white)
                            .environment(\.dynamicTypeSize, size)
                            .environment(\.colorScheme, .light)
                            .environment(\.locale, Locale(identifier: "en_US")))
                        renderer.scale = 3
                        let image = try XCTUnwrap(renderer.uiImage)
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                            .joined().replacingOccurrences(of: " ", with: "")
                        XCTAssertEqual(text.contains("83.41"), showsShares, text)
                        XCTAssertEqual(text.contains("NVDA"), showsTicker, text)
                        XCTAssertEqual(text.contains("13.7%"), showsWeight, text)
                        XCTAssertTrue(text.contains("NVIDIA"), text)
                        if size == .large { XCTAssertEqual(image.size.height, 96, accuracy: 1) }
                    }
                }
            }
        }
    }

    func testTickerCanBeHiddenWithoutHidingCompanyOrWeight() throws {
        let holding = holding(unrealized: 370, shares: 83.4078, ticker: "NVDA", displayName: "NVIDIA", weight: 0.137)
        let direct = PortfolioHoldingListItem.holding(holding, performance: .init(amount: 370, percent: 37))
        let exposure = PortfolioHoldingListItem.exposure(
            .init(ticker: "NVDA", logoSymbol: "NVDA", name: "NVIDIA", directUSD: 1000, fromETFUSD: 370,
                  totalUSD: 1370, etfWeightPercent: 5, sector: nil, allocatedCostUSD: 1000),
            direct: holding, portfolioTotal: 10_000, performance: .init(amount: 370, percent: 37))
        for item in [direct, exposure] {
            for size in [DynamicTypeSize.large, .accessibility1] {
                for showsTicker in [true, false] {
                    for showsWeight in [true, false] {
                        let renderer = ImageRenderer(content: HoldingRow(item: item,
                            performancePeriod: .holdingPeriod, showsWeight: showsWeight, showsTicker: showsTicker)
                            .frame(width: 370).padding(16).background(.white)
                            .environment(\.dynamicTypeSize, size)
                            .environment(\.colorScheme, .light)
                            .environment(\.locale, Locale(identifier: "en_US")))
                        renderer.scale = 3
                        let image = try XCTUnwrap(renderer.uiImage)
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                            .joined().replacingOccurrences(of: " ", with: "")
                        XCTAssertEqual(text.contains("NVDA"), showsTicker, text)
                        XCTAssertTrue(text.contains("NVIDIA"), text)
                        XCTAssertEqual(text.contains("13.7%"), showsWeight, text)
                        if size == .large { XCTAssertEqual(image.size.height, 96, accuracy: 1) }
                    }
                }
            }
        }
    }

    func testWeightDisplayCanBeHiddenAndFitsBothRowModesAndAppearances() throws {
        let holding = holding(unrealized: -2783.64, shares: 83.4078, ticker: "NVDA", displayName: "NVIDIA", weight: 0.137)
        let direct = PortfolioHoldingListItem.holding(holding, performance: .init(amount: -2783.64, percent: -18.1))
        let exposure = PortfolioHoldingListItem.exposure(
            .init(ticker: "NVDA", logoSymbol: "NVDA", name: "NVIDIA", directUSD: 1000, fromETFUSD: 370,
                  totalUSD: 1370, etfWeightPercent: 5, sector: nil, allocatedCostUSD: 1000),
            direct: holding, portfolioTotal: 10_000, performance: .init(amount: 370, percent: 37))
        let longTicker = PortfolioHoldingListItem.holding(
            self.holding(unrealized: -2783.64, shares: 83.4078, ticker: "LONGTICKER.L", displayName: "Long ticker", weight: 0.137),
            performance: .init(amount: -2783.64, percent: -18.1))
        for (mode, item) in [("direct", direct), ("lookthrough", exposure), ("long-ticker", longTicker)] {
            for scheme in [ColorScheme.light, .dark] {
                for showsWeight in [true, false] {
                    let renderer = ImageRenderer(content: HoldingRow(item: item, performancePeriod: .holdingPeriod,
                            showsWeight: showsWeight)
                        .frame(width: 328).padding(16)
                        .background(scheme == .dark ? .black : .white)
                        .environment(\.dynamicTypeSize, .large).environment(\.colorScheme, scheme)
                        .environment(\.locale, Locale(identifier: "en_US")))
                    renderer.scale = 3
                    let image = try XCTUnwrap(renderer.uiImage)
                    XCTAssertEqual(image.size.height, 96, accuracy: 1)
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    recognition.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        .joined().replacingOccurrences(of: " ", with: "")
                    XCTAssertEqual(text.contains("13.7%"), showsWeight, "\(mode): \(text)")
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "holding-weight-\(mode)-\(scheme)-\(showsWeight)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testLookThroughUsesTheSameCellAndGrowsForAccessibility() throws {
        let exposure = ETFLookThroughRow(ticker: "NVDA", logoSymbol: "NVDA", name: "NVIDIA",
            directUSD: 18_766.75, fromETFUSD: 1_457.41, totalUSD: 20_224.16,
            etfWeightPercent: 5, sector: nil, allocatedCostUSD: 16_720.01)
        let item = PortfolioHoldingListItem.exposure(exposure, direct: nil, portfolioTotal: 100_000,
            performance: .init(amount: 3_504.15, percent: 21))
        for size: DynamicTypeSize in [.large, .accessibility3] {
            let renderer = ImageRenderer(content: HoldingRow(item: item, performancePeriod: .holdingPeriod)
                .frame(width: 328).background(.white)
                .environment(\.dynamicTypeSize, size).environment(\.colorScheme, .light))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            if size == .large { XCTAssertEqual(image.size.height, 64, accuracy: 1) }
            else { XCTAssertGreaterThan(image.size.height, 64) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "holding-row-lookthrough-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-holding-row-lookthrough-\(size).png"))
        }
    }

    func testHomeHoldingRowFitsFigmaCellWithDistributionMarkers() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }

        let cases: [(amount: Double, shares: Double, ticker: String, displayName: String, snapshotName: String, scheme: ColorScheme)] = [
            (2_783.64, 83.4078, "NVDA", "NVIDIA", "gain", .light),
            (-2_783.64, 83.4078, "NVDA", "NVIDIA", "loss", .light),
            (2_783.64, 83.4078, "FUND.L", "Sample Global UCITS ETF (Acc)", "acc-class", .light),
            (2_783.64, 83.4078, "FUND.L", "Sample Global UCITS ETF (Dist)", "dist-class", .light),
            (2_783.64, 83.4078, "GOOGL", "Alphabet Inc. Class A", "share-class-a", .light),
            (2_783.64, 83.4078, "BRK.B", "Berkshire Hathaway Inc. Class B", "share-class-b", .light),
            (2_783.64, 83.4078, "FUND.L", "Sample Global ETF (Acc) Class C", "combined-class", .light),
            (2_783.64, 83.4078, "FUND.L", "Sample Global ETF (Acc) Class C", "combined-class-dark", .dark),
            (2_783.64, 12_345.678, "NVDA", "NVIDIA", "compact-shares", .light),
            (2_783.64, 83.4078, "NVDA", "NVIDIA", "gain-dark", .dark)
        ]
        for (amount, shares, ticker, displayName, snapshotName, scheme) in cases {
            let row = HoldingRow(
                holding: holding(unrealized: amount, shares: shares, ticker: ticker, displayName: displayName),
                performancePeriod: .holdingPeriod,
                dailyChangePercent: nil,
                showsWeight: false
            )
            let host = UIHostingController(rootView: row
                .frame(width: 328)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.dynamicTypeSize, .large)
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
                .ignoresSafeArea())
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 328, height: 64)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))

            // ImageRenderer measures the SwiftUI cell without the test
            // window's status-bar safe area (which adds 62pt here).
            let renderer = ImageRenderer(content: row
                .frame(width: 328)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.dynamicTypeSize, .large)
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.height, 64, accuracy: 1)
            let attachment = XCTAttachment(image: image)
            attachment.name = "holding-row-\(snapshotName)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-holding-row-\(snapshotName).png"))
            window.isHidden = true
        }
    }

    private func holding(unrealized: Double, shares: Double, ticker: String, displayName: String, weight: Double = 1) -> Holding {
        Holding(ticker: ticker, logoSymbol: "NVDA", displayName: displayName, sector: nil, source: nil,
                shares: shares, averageCost: 184.0, costCurrency: "USD", quotePrice: 217.89,
                quoteCurrency: "USD", todayChangePercent: nil, marketValue: 18_173.72, weight: weight,
                unrealized: unrealized, unrealizedPercent: unrealized > 0 ? 18.1 : -18.1,
                fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }
}
