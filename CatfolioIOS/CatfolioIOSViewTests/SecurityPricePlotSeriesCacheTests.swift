import XCTest
import SwiftUI
@testable import CatfolioIOS

@MainActor
final class SecurityPricePlotSeriesCacheTests: XCTestCase {
    private func range(latestPrice: Double, middlePrice: Double? = nil) -> SecurityPriceRangeData {
        let trades = SecurityTrade.grouped([
            LocalTransactionRecord(date: "2026-09-21", action: "BUY", ticker: "TEST",
                quantity: 1, price: 100, currency: "USD", source: "test", accountID: "isa",
                accountName: nil, realisedProfitLoss: nil, realisedProfitLossCurrency: nil),
        ])
        let history = SecurityPriceHistory(
            ticker: "TEST",
            currency: "USD",
            points: [.init(dateText: "2026-09-21", close: 100)]
                + (middlePrice.map { [.init(dateText: "2026-09-22", close: $0)] } ?? [])
                + [.init(dateText: "2026-09-23", close: latestPrice)],
            intradayPoints: [],
            trades: trades
        )
        return SecurityPriceRangeData(history: history, range: .maximum,
            averageCost: 100, selectedAccountKeys: trades.first?.accountKeys ?? [])
    }

    func testSelectionReusesGeometryAndNewHistoryOrAppearanceInvalidatesIt() {
        let cache = SecurityPricePlotSeriesCache()
        let initialData = range(latestPrice: 120)
        let initial = cache.prepared(for: initialData, scheme: .light)
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(initial.priceSeries.points.map(\.value), [100, 120])
        XCTAssertEqual(initial.markers.count, 1)

        _ = initialData.nearest(to: initialData.points[0].date)
        let afterSelection = cache.prepared(for: initialData, scheme: .light)
        XCTAssertEqual(cache.rebuildCount, 1)
        XCTAssertEqual(afterSelection.interactionDates, initial.interactionDates)
        XCTAssertEqual(afterSelection.geometryFingerprint, initial.geometryFingerprint)

        let refreshed = range(latestPrice: 140)
        XCTAssertNotEqual(initialData.id, refreshed.id)
        let updated = cache.prepared(for: refreshed, scheme: .light)
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertEqual(updated.priceSeries.points.last?.value, 140)
        XCTAssertNotEqual(updated.geometryFingerprint, initial.geometryFingerprint)

        _ = cache.prepared(for: refreshed, scheme: .dark)
        XCTAssertEqual(cache.rebuildCount, 3)
    }

    func testReloadingIdenticalHistoryKeepsTransitionIdentity() {
        let cache = SecurityPricePlotSeriesCache()
        let initial = cache.prepared(for: range(latestPrice: 120), scheme: .light)
        let reloaded = cache.prepared(for: range(latestPrice: 120), scheme: .light)
        XCTAssertEqual(reloaded.geometryFingerprint, initial.geometryFingerprint)
    }

    func testBackfilledAndCorrectedInteriorPointsTriggerMorphWithoutEndpointOrScaleChange() {
        let cache = SecurityPricePlotSeriesCache()
        let initial = cache.prepared(for: range(latestPrice: 120), scheme: .light)
        let backfilled = cache.prepared(for: range(latestPrice: 120, middlePrice: 105), scheme: .light)
        let corrected = cache.prepared(for: range(latestPrice: 120, middlePrice: 110), scheme: .light)
        XCTAssertNotEqual(backfilled.geometryFingerprint, initial.geometryFingerprint)
        XCTAssertNotEqual(corrected.geometryFingerprint, backfilled.geometryFingerprint)
        let path = StandardLineChartViewportPath(from: backfilled.priceSeries.points, to: corrected.priceSeries.points)
        XCTAssertEqual(path.samples(progress: 0).map(\.value), [100, 105, 120])
        XCTAssertEqual(path.samples(progress: 0.5).map(\.value), [100, 107.5, 120])
        XCTAssertEqual(path.samples(progress: 1).map(\.value), [100, 110, 120])
    }

}
