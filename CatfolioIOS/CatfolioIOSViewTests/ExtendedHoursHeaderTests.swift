import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ExtendedHoursHeaderTests: XCTestCase {
    private final class Capture {
        var frames: [String: CGRect] = [:]
    }

    private let holding = Holding(ticker: "AAPL", logoSymbol: nil, displayName: "Apple", sector: nil, source: nil,
        shares: 10, averageCost: 100, costCurrency: "USD", quotePrice: 120, quoteCurrency: "USD",
        todayChangePercent: 2.4, marketValue: 1200, weight: 1, unrealized: 200, unrealizedPercent: 20,
        fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)

    func testExtendedQuoteUsesExistingPriceAreaAndMetadataBadge() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        for scheme in [ColorScheme.light, .dark] {
            for language in ["en", "zh-Hans"] {
                UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
                for size in [DynamicTypeSize.large, .accessibility3] {
                    for session in [USMarketSession.preMarket, .postMarket] {
                        let width: CGFloat = size == .large ? 402 : 320
                        let quote = ExtendedHoursQuote(session: session, price: session == .preMarket ? 123.45 : 116.55,
                            changePercent: session == .preMarket ? 2.875 : -2.875,
                            observedAt: ISO8601DateFormatter().date(from: session == .preMarket
                                ? "2026-10-12T12:00:00Z" : "2026-10-12T21:00:00Z")!)
                        let capture = Capture()
                        let header = HoldingDetailHeader(holding: holding, marketTodayChange: 2.4,
                            selectedPrice: nil, selectedReturn: nil, marketPrice: 120, extendedHoursQuote: quote,
                            marketDate: quote.observedAt.addingTimeInterval(300))
                        XCTAssertEqual(header.displayedPrice, quote.price)
                        XCTAssertEqual(header.displayedChange, quote.changePercent)
                        let measured = try await render(header, width: width, scheme: scheme, language: language, size: size,
                            capture: capture, name: "extended-header-\(session)-\(scheme)-\(language)-\(size)")
                        let mainQuote = try XCTUnwrap(capture.frames["holding-header.quote"])
                        let badge = try XCTUnwrap(capture.frames["holding-header.item.closed"])
                        let metadata = try XCTUnwrap(capture.frames["holding-header.metadata"])
                        let icon = try XCTUnwrap(capture.frames["extended-hours.icon"])
                        XCTAssertTrue(badge.insetBy(dx: -0.5, dy: -0.5).contains(icon))
                        XCTAssertTrue(metadata.insetBy(dx: -0.5, dy: -0.5).contains(badge))
                        XCTAssertGreaterThanOrEqual(mainQuote.minY, metadata.maxY + 11.5)
                        XCTAssertGreaterThanOrEqual(mainQuote.minX, 19.5)
                        XCTAssertLessThanOrEqual(mainQuote.maxX, width - 19.5)
                        XCTAssertLessThan(icon.height, badge.height)
                        XCTAssertEqual(measured.height, mainQuote.maxY + 4, accuracy: 0.5,
                                       "The header must end at the existing quote; no extra quote row")
                    }
                }
            }
        }
    }

    func testScrubbingOverridesExtendedQuoteAndReleaseRestoresIt() {
        let quote = ExtendedHoursQuote(session: .postMarket, price: 126, changePercent: 5, observedAt: .now)
        let selected = HoldingDetailHeader(holding: holding, marketTodayChange: 2.4,
            selectedPrice: 98, selectedReturn: -2, marketPrice: 120, extendedHoursQuote: quote)
        XCTAssertEqual(selected.displayedPrice, 98)
        XCTAssertEqual(selected.displayedChange, -2)
        let released = HoldingDetailHeader(holding: holding, marketTodayChange: 2.4,
            selectedPrice: nil, selectedReturn: nil, marketPrice: 120, extendedHoursQuote: quote)
        XCTAssertEqual(released.displayedPrice, 126)
        XCTAssertEqual(released.displayedChange, 5)
    }

    func testUnknownExtendedReturnDoesNotReuseRegularSessionReturn() {
        let quote = ExtendedHoursQuote(session: .preMarket, price: 126, changePercent: nil, observedAt: .now)
        let extended = HoldingDetailHeader(holding: holding, marketTodayChange: 2.4,
            selectedPrice: nil, selectedReturn: nil, marketPrice: 120, extendedHoursQuote: quote)
        XCTAssertEqual(extended.displayedPrice, 126)
        XCTAssertNil(extended.displayedChange)
        let regular = HoldingDetailHeader(holding: holding, marketTodayChange: 2.4,
            selectedPrice: nil, selectedReturn: nil, marketPrice: 121)
        XCTAssertEqual(regular.displayedPrice, 121)
        XCTAssertEqual(regular.displayedChange, 2.4)
    }

    func testStatusBadgeFollowsCurrentSessionAndReturnsToClosedWhenQuoteIsStale() {
        for (hour, session) in [("08:00:00", USMarketSession.preMarket), ("17:00:00", .postMarket)] {
            let observed = ISO8601DateFormatter().date(from: "2026-10-12T\(hour)-04:00")!
            let quote = ExtendedHoursQuote(session: session, price: 126, changePercent: 5, observedAt: observed)
            XCTAssertEqual(MarketClosedBadge(ticker: "AAPL", extendedHoursQuote: quote,
                date: observed.addingTimeInterval(300)).session, session)
            XCTAssertEqual(MarketClosedBadge(ticker: "AAPL", extendedHoursQuote: quote,
                date: observed.addingTimeInterval(300)).sunMotion, session == .preMarket ? .rising : .setting)
            XCTAssertEqual(MarketClosedBadge(ticker: "AAPL", extendedHoursQuote: quote,
                date: observed.addingTimeInterval(3600)).session, .closed)
        }
        let regular = ISO8601DateFormatter().date(from: "2026-10-12T10:00:00-04:00")!
        XCTAssertEqual(MarketClosedBadge(ticker: "AAPL", date: regular).session, .regular)
        let earlyClose = ISO8601DateFormatter().date(from: "2026-11-27T13:00:00-05:00")!
        let quote = ExtendedHoursQuote(session: .postMarket, price: 126, changePercent: 5,
            observedAt: earlyClose, sessionWindow: .init(session: .postMarket, start: earlyClose,
                end: earlyClose.addingTimeInterval(4 * 3600)))
        XCTAssertEqual(MarketClosedBadge(ticker: "AAPL", extendedHoursQuote: quote,
            date: earlyClose.addingTimeInterval(300)).session, .postMarket)
    }

    func testEveryChartRangeEndsAtExtendedQuoteWithoutChangingRegularCloseOrTradeDay() throws {
        func point(_ iso: String, _ price: Double) -> SecurityPricePoint {
            let time = ISO8601DateFormatter().date(from: iso)!
            return .init(dateText: String(Int(time.timeIntervalSince1970)), close: price, timestamp: time)
        }
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-10-30", close: 100), .init(dateText: "2026-11-02", close: 120)],
            intradayPoints: [point("2026-11-02T15:55:00-05:00", 120)],
            trades: [.init(dateText: "2026-11-02", action: "BUY", quantity: 1, tradeCount: 1, accountKeys: ["test"])],
            extendedHoursPoints: [point("2026-11-02T08:00:00-05:00", 110), point("2026-11-02T19:30:00-05:00", 126)])
        let intraday = SecurityPriceRangeData(history: history, range: .oneDay, averageCost: nil, selectedAccountKeys: ["test"])
        let daily = SecurityPriceRangeData(history: history, range: .oneWeek, averageCost: nil, selectedAccountKeys: ["test"])
        XCTAssertEqual(intraday.points.map(\.price), [110, 120, 126])
        XCTAssertEqual(try XCTUnwrap(intraday.points.last?.returnPercent), 26, accuracy: 1e-9)
        XCTAssertEqual(intraday.trades.count, 1, "A post-market print after UTC midnight still belongs to the Eastern trade date")
        XCTAssertEqual(daily.points.map(\.price), [100, 126])
        XCTAssertEqual(history.chartDailyPoints.map(\.close), [100, 120])
        for range in ChartTimeRange.allCases {
            let data = SecurityPriceRangeData(history: history, range: range, averageCost: nil, selectedAccountKeys: ["test"])
            XCTAssertEqual(data.points.last?.price, 126, "\(range) must include the latest after-hours price")
        }
    }

    @discardableResult
    private func render<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme, language: String,
                                 size: DynamicTypeSize, capture: Capture, name: String) async throws -> CGSize {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: view.frame(width: width)
            .overlayPreferenceValue(ResearchCardLayoutFrames.self) { anchors in
                GeometryReader { geometry in
                    let frames = anchors.mapValues { geometry[$0] }
                    Color.clear.onAppear { capture.frames = frames }
                        .onChange(of: frames) { _, value in capture.frames = value }
                }
            }
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color.black : Color.white))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let measured = host.sizeThatFits(in: CGSize(width: width, height: 3000))
        host.view.bounds = CGRect(origin: .zero, size: measured)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        return measured
    }
}
