import XCTest
@testable import CatfolioIOS

/// The security page's content kept between presentations: a bounded set,
/// dropped under memory pressure, and able to tell the page that its lower
/// cards need not step in again.
@MainActor
final class HoldingDetailCacheTests: XCTestCase {
    private func holding(_ ticker: String) -> Holding {
        Holding(ticker: ticker, logoSymbol: nil, displayName: ticker, sector: "Technology", source: nil,
                shares: 10, averageCost: 50, costCurrency: "USD", quotePrice: 60, quoteCurrency: "USD",
                todayChangePercent: 1, marketValue: 600, weight: 0.1, unrealized: 100,
                unrealizedPercent: 20, fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }

    private func model() -> AppModel {
        let defaults = UserDefaults(suiteName: "HoldingDetailCacheTests.\(UUID().uuidString)")!
        return AppModel(defaults: defaults)
    }

    func testReopeningAHoldingReturnsTheSameContent() {
        let model = model()
        let first = model.cachedHoldingDetail(for: holding("AAA"))
        XCTAssertTrue(first === model.cachedHoldingDetail(for: holding("AAA")))
    }

    func testOnlyTheMostRecentPagesAreKept() {
        let model = model()
        let oldest = model.cachedHoldingDetail(for: holding("T0"))
        for index in 1...AppModel.holdingDetailCacheLimit {
            _ = model.cachedHoldingDetail(for: holding("T\(index)"))
        }
        XCTAssertFalse(oldest === model.cachedHoldingDetail(for: holding("T0")),
                       "one past the limit evicts the least recently opened page")
    }

    func testReopeningKeepsAPageFromEviction() {
        let model = model()
        let kept = model.cachedHoldingDetail(for: holding("KEEP"))
        for index in 1..<AppModel.holdingDetailCacheLimit {
            _ = model.cachedHoldingDetail(for: holding("T\(index)"))
        }
        _ = model.cachedHoldingDetail(for: holding("KEEP"))
        _ = model.cachedHoldingDetail(for: holding("NEW"))
        XCTAssertTrue(kept === model.cachedHoldingDetail(for: holding("KEEP")))
    }

    func testMemoryWarningDropsKeptPages() {
        let model = model()
        let kept = model.cachedHoldingDetail(for: holding("AAA"))
        NotificationCenter.default.post(name: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"),
                                        object: nil)
        XCTAssertFalse(kept === model.cachedHoldingDetail(for: holding("AAA")))
    }
}
