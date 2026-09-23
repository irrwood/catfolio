import SwiftUI
import XCTest
@testable import CatfolioIOS

final class HoldingDetailLayoutAuditTests: XCTestCase {
    @MainActor
    func testChartAccountsAndResearchEntriesAtLargeType() async throws {
        let old = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(old, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        let h = Self.holding(price: 100)
        let history = SecurityPriceHistory(ticker: "TEST", currency: "USD", points: (0..<90).map { index in
            SecurityPricePoint(dateText: DayDateCodec.string(from: Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 86400)),
                close: 80 + Double(index) * 0.4 + sin(Double(index) * 0.25) * 12)
        }, intradayPoints: [], trades: [])
        let accounts = [HoldingDetailAccountOption(id: "isa", displayName: "Investment ISA",
            marketValue: 1_234_567, currency: "USD", marketValueUSD: 1_234_567, unrealized: 12_345)]
        _ = try await capture(HoldingDetailPriceSection(holding: h, marketTodayChange: 12.34,
            priceHistory: history, priceHistoryError: nil, averageCost: 100,
            selectedAccountKeys: ["isa"], accountOptions: accounts),
            language: "en", width: 320, large: true, dark: true, name: "detail-chart-accounts-large")
        _ = try await capture(VStack(spacing: 16) {
            SecurityDebateCardContent(progress: .idle, onStart: {}, onRegenerate: {})
            HoldingDetailActionCardLabel(title: L10n.text("分析师一致预期"),
                subtitle: L10n.text("分析师覆盖 · 按需读取"), symbol: "chevron.down")
            HoldingDetailActionCardLabel(title: L10n.text("Financial"),
                subtitle: L10n.text("Profit and Loss Statement, Balance Sheet and Cash Flow"))
            HoldingPredictionMarketsCard(holding: h, initialMarkets: [PolymarketRelatedMarket(
                id: "layout-test", question: "Will Example International Holdings report record annual revenue this year?",
                eventTitle: "Example annual revenue", eventSlug: "", outcome: "Yes", probability: 0.62,
                volume24Hours: 12_500, totalVolume: 220_000, endDate: nil)], usesCachedContentOnlyInitially: true)
        }.padding(.horizontal, 16), language: "en", width: 320, large: true, dark: true,
            name: "detail-research-entries-large")
    }

    @MainActor
    func testHeaderAndPositionRowsAtNarrowWidthsAndLargeType() async throws {
        let old = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(old, forKey: AppLanguage.preferenceKey) }
        for (language, width, large, dark) in [("zh-Hans", 393.0, false, false),
                                               ("en", 320.0, false, false),
                                               ("en", 320.0, true, true)] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let h = Self.holding(price: 1_234.56)
            let trades = SecurityTrade.grouped([
                LocalTransactionRecord(date: "2026-09-10", action: "SELL", ticker: "TEST", quantity: 100,
                    price: 1_234.56, currency: "USD", source: "test", accountID: "usd", accountName: nil,
                    realisedProfitLoss: 12_345.67, realisedProfitLossCurrency: "USD"),
                LocalTransactionRecord(date: "2026-09-10", action: "SELL", ticker: "TEST", quantity: 100,
                    price: 987.65, currency: "GBP", source: "test", accountID: "gbp", accountName: nil,
                    realisedProfitLoss: 9_876.54, realisedProfitLossCurrency: "GBP")
            ])
            _ = try await capture(VStack(spacing: 24) {
                HoldingDetailHeader(holding: h, marketTodayChange: 12.34,
                    selectedPrice: h.quotePrice, selectedReturn: 12.34, selectedTrades: trades)
                HoldingPositionDetails(holding: h).padding(.horizontal, 16)
            }, language: language, width: width, large: large, dark: dark,
                name: "detail-header-data-\(language)-\(Int(width))-\(large ? "large" : "regular")")
        }
    }

    @MainActor
    func testOptionsControlsAtNarrowWidths() async throws {
        let old = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(old, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        for large in [false, true] {
            // Unsupported market renders the real controls without requesting a chain.
            _ = try await capture(OptionsOIView(symbol: "TEST.L", currency: "GBP", price: 100, costUSD: nil)
                .padding(.horizontal, 16), language: "en", width: 320, large: large, dark: large,
                name: "detail-options-controls-\(large ? "large" : "regular")")
        }
    }

    @MainActor
    func testOverlappingVolumeMarkersAndRangeLabels() async throws {
        let old = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(old, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        let h = Self.holding(price: 100)
        let profile = VolumeProfile(ticker: "TEST", currency: "USD", available: true,
            valueAreaHigh: 108, pointOfControl: 100, valueAreaLow: 92,
            sessions: 60, valueAreaPercent: 70, asOf: "2026-09-21",
            fiftyTwoWeekHigh: 110, fiftyTwoWeekLow: 90, fiftyTwoWeekStartPrice: 95,
            todayChangePercent: 1, bins: (0..<20).map { index in
                VolumeProfileBin(priceLow: 90 + Double(index), priceHigh: 91 + Double(index),
                    volume: Double(12 - abs(index - 10)) * 1_000)
            })
        for large in [false, true] {
            _ = try await capture(VStack(spacing: 16) {
                VolumePriceChart(profile: profile, holding: h, showsHoldingCost: true)
                FiftyTwoWeekRange(low: 12_345.67, high: 98_765.43, current: 50_000,
                    periodStart: 30_000, currency: "USD")
            }.padding(.horizontal, 16), language: "en", width: 320,
                large: large, dark: large, name: "detail-volume-range-\(large ? "large" : "regular")")
        }
    }

    static func holding(price: Double) -> Holding {
        Holding(ticker: "TEST", logoSymbol: nil, displayName: "Example International Holdings Corporation",
            sector: nil, source: "test", shares: 12_345.6789, averageCost: 100, costCurrency: "USD",
            quotePrice: price, quoteCurrency: "USD", todayChangePercent: 12.34,
            marketValue: 15_241_481.34, weight: 0.123456, unrealized: 1_234_567.89,
            unrealizedPercent: 12.34, fxPnl: 123_456.78, fxPnlPercent: 12.34,
            fxPnlStatus: "broker_reported", fxPnlSource: nil)
    }

    @MainActor
    private func capture<V: View>(_ content: V, language: String, width: CGFloat,
                                 large: Bool, dark: Bool, name: String) async throws -> CGSize {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content
            .frame(width: width).padding(.vertical, 2)
            .background(Color(uiColor: .systemGroupedBackground))
            .fontDesign(.rounded)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, large ? .accessibility2 : .large)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let size = host.sizeThatFits(in: CGSize(width: width, height: 8_000))
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(size.width, width, accuracy: 0.5)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return size
    }
}
