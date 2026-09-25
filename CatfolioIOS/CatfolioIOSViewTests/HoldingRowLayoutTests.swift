import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class HoldingRowLayoutTests: XCTestCase {
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
                dailyChangePercent: nil
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

    private func holding(unrealized: Double, shares: Double, ticker: String, displayName: String) -> Holding {
        Holding(ticker: ticker, logoSymbol: "NVDA", displayName: displayName, sector: nil, source: nil,
                shares: shares, averageCost: 184.0, costCurrency: "USD", quotePrice: 217.89,
                quoteCurrency: "USD", todayChangePercent: nil, marketValue: 18_173.72, weight: 1,
                unrealized: unrealized, unrealizedPercent: unrealized > 0 ? 18.1 : -18.1,
                fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }
}
