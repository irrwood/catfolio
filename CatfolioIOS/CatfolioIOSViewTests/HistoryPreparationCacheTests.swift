import XCTest
import SwiftUI
@testable import CatfolioIOS

@MainActor
final class HistoryPreparationCacheTests: XCTestCase {
    func testConcurrentOverviewAndHistoryReusePreparedResult() async throws {
        let cache = HistoryPreparationCache()
        let ledger = PortfolioActivityLedger(accounts: [], transactions: [], securityNames: [:])
        async let overview = cache.prepared(ledger: ledger, accountIDs: [], locale: Locale(identifier: "en_US"))
        async let history = cache.prepared(ledger: ledger, accountIDs: [], locale: Locale(identifier: "en_US"))
        let (a, b) = try await (overview, history)
        let revisit = try await cache.prepared(ledger: ledger, accountIDs: [], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(a.contentID, b.contentID)
        XCTAssertEqual(a.contentID, revisit.contentID)
    }

    func testSnapshotScopeLocaleAndTickerInvalidatePreparation() async throws {
        let cache = HistoryPreparationCache()
        let ledger = PortfolioActivityLedger(accounts: [], transactions: [], securityNames: [:])
        let original = try await cache.prepared(ledger: ledger, accountIDs: [], locale: Locale(identifier: "en_US"))
        let account = try await cache.prepared(ledger: ledger, accountIDs: ["other"], locale: Locale(identifier: "en_US"))
        let locale = try await cache.prepared(ledger: ledger, accountIDs: [], locale: Locale(identifier: "zh_CN"))
        let ticker = try await cache.prepared(ledger: ledger, accountIDs: [], locale: Locale(identifier: "en_US"), ticker: "AAPL")
        let changed = PortfolioActivityLedger(accounts: [], transactions: [], securityNames: ["AAPL": "Apple"])
        let refreshed = try await cache.prepared(ledger: changed, accountIDs: [], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(Set([original.contentID, account.contentID, locale.contentID, ticker.contentID, refreshed.contentID]).count, 5)
    }
}
