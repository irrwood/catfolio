import SwiftUI
import XCTest
@testable import CatfolioIOS

final class HoldingHeaderLayoutTests: XCTestCase {
    private var previousLanguage: Any?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
        }
        super.tearDown()
    }

    private var holding: Holding {
        Holding(ticker: "NVDA", logoSymbol: nil, displayName: "NVIDIA", sector: nil, source: nil,
                shares: 83.4078, averageCost: 80, costCurrency: "USD", quotePrice: 216.52,
                quoteCurrency: "USD", todayChangePercent: 1.2, marketValue: 18_059, weight: 1,
                unrealized: 100, unrealizedPercent: 18.1, fxPnl: nil, fxPnlPercent: nil,
                fxPnlStatus: nil, fxPnlSource: nil)
    }

    private func trade(_ action: String, date: String = "2026-09-10", large: Bool = true,
                       currency: String = "USD") -> LocalTransactionRecord {
        .init(date: date, action: action, ticker: "NVDA", quantity: large ? 1_000 : 1,
              price: large ? 123.45678 : 216.52, currency: currency, source: "test",
              accountID: currency, accountName: nil, realisedProfitLoss: 12_345.67,
              realisedProfitLossCurrency: currency)
    }

    private var mixedTrades: [SecurityTrade] {
        SecurityTrade.grouped([trade("BUY"), trade("SELL"), trade("SELL", currency: "GBP")])
    }

    @MainActor
    func testHeaderHeightStaysStableBeforeDuringAndAfterSameDayBuySellSelection() async throws {
        let trades = mixedTrades
        let reservations = SecurityTradeReadout.reservationCandidates(for: trades)
        for language in ["zh-Hans", "en"] {
            for width: CGFloat in [320, 393] {
                for size in [DynamicTypeSize.large, .accessibility3] {
                    var heights: [CGFloat] = []
                    for (index, selected) in [[], trades, []].enumerated() {
                        let view = HoldingDetailHeader(holding: holding, marketTodayChange: 1.2,
                            selectedPrice: selected.isEmpty ? nil : 216.52,
                            selectedReturn: selected.isEmpty ? nil : 18.1, selectedTrades: selected,
                            tradeReadoutReservations: reservations)
                        let result = try await measure(view, width: width, language: language, size: size,
                            screenshot: index == 1 ? "header-trades-\(language)-\(Int(width))-\(size)" : nil)
                        heights.append(result.height)
                        XCTAssertEqual(result.width, width, accuracy: 0.5)
                    }
                    XCTAssertEqual(heights[0], heights[1], accuracy: 0.5, "\(language) \(width) \(size)")
                    XCTAssertEqual(heights[1], heights[2], accuracy: 0.5)
                }
            }
        }
    }

    @MainActor
    func testDefaultSingleCurrencyHeaderKeepsCompactHeightAndEmptyHistoryAddsNoSpace() async throws {
        let trades = SecurityTrade.grouped([trade("SELL", large: false)])
        let compact = HoldingDetailHeader(holding: holding, marketTodayChange: 1.2,
            selectedPrice: 216.52, selectedReturn: 18.1, selectedTrades: trades)
        let compactSize = try await measure(compact, width: 393, language: "zh-Hans", size: .large,
                                            screenshot: "header-single-currency-default")
        XCTAssertLessThan(compactSize.height, 155)
        let plain = HoldingDetailHeader(holding: holding, marketTodayChange: 1.2,
                                         selectedPrice: nil, selectedReturn: nil)
        let explicitlyEmpty = HoldingDetailHeader(holding: holding, marketTodayChange: 1.2,
            selectedPrice: nil, selectedReturn: nil, tradeReadoutReservations: [])
        let plainSize = try await measure(plain, width: 393, language: "en", size: .large)
        let emptySize = try await measure(explicitlyEmpty, width: 393, language: "en", size: .large)
        XCTAssertEqual(plainSize.height, emptySize.height, accuracy: 0.5)
        XCTAssertLessThan(emptySize.height, 155)
    }

    @MainActor
    func testTradeReadoutScalesAndGivesNarrowMulticurrencyAmountsMoreVerticalSpace() async throws {
        let readout = SecurityTradeReadout(trades: mixedTrades)
        for language in ["zh-Hans", "en"] {
            let regular = try await measure(readout, width: 280, language: language, size: .large)
            let narrow = try await measure(readout, width: 140, language: language, size: .large)
            let accessible = try await measure(readout, width: 280, language: language, size: .accessibility3,
                screenshot: "trade-readout-large-text-\(language)")
            XCTAssertGreaterThan(narrow.height, regular.height)
            XCTAssertGreaterThan(accessible.height, regular.height * 1.3)
        }
    }

    @MainActor
    func testDataRowsGrowForLongLabelsAndAmountsInBothLanguages() async throws {
        for language in ["zh-Hans", "en"] {
            let title = language == "en" ? "REALISED P&L · KNOWN" : "已实现盈亏 · 已知部分"
            let row = HoldingDataRow(model: .init(title: title, icon: .unrealisedProfitLoss,
                value: "+$123,456.78 · +£98,765.43", color: .primary), isAlternating: true)
            for width: CGFloat in [320, 393] {
                let regular = try await measure(row, width: width, language: language, size: .large,
                    screenshot: "data-row-\(language)-\(Int(width))-regular")
                let accessible = try await measure(row, width: width, language: language, size: .accessibility3,
                    screenshot: "data-row-\(language)-\(Int(width))-large-text")
                XCTAssertGreaterThan(regular.height, 48, "Long content needs more than one row")
                XCTAssertGreaterThan(accessible.height, regular.height)
                XCTAssertEqual(accessible.width, width, accuracy: 0.5)
            }
        }
    }

    @MainActor
    func testReservationCandidatesRetainDistinctMulticurrencyAndBuySellShapes() {
        let small = SecurityTrade.grouped([trade("SELL", date: "2026-09-09", large: false)])
        let candidates = SecurityTradeReadout.reservationCandidates(for: small + mixedTrades)
        XCTAssertTrue(candidates.contains { $0.id.contains("|") })
        XCTAssertTrue(candidates.contains { $0.id.contains("GBP,USD") })
        XCTAssertTrue(SecurityTradeReadout.reservationCandidates(for: []).isEmpty)
    }

    @MainActor
    private func measure<V: View>(_ view: V, width: CGFloat, language: String, size: DynamicTypeSize,
                                  screenshot: String? = nil) async throws -> CGSize {
        UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: view
            .frame(width: width)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .light)
            .background(Color(uiColor: .systemBackground)))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let measured = host.sizeThatFits(in: CGSize(width: width, height: 3000))
        host.view.bounds = CGRect(origin: .zero, size: measured)
        host.view.layoutIfNeeded()
        if let screenshot {
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            })
            attachment.name = screenshot
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return measured
    }
}
