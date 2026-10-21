import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class SnapTradeActivityPresentationTests: XCTestCase {
    func testImportedActivitiesFeedChartMarkersAmountsAndAccountFilters() throws {
        let account = try JSONDecoder().decode(SnapTradeAccount.self, from: Data("""
        {"id":"917c8734-8470-4a3e-a18f-57c3f2ee6631","brokerage_authorization":"87b24961-b51e-4db8-9226-f198f6518a89",
         "number":"1234","institution_name":"Example","balance":{"total":{"currency":"USD"}},
         "sync_status":{"holdings":{"initial_sync_completed":true}}}
        """.utf8))
        let page = try JSONDecoder().decode(SnapTradeActivityPage.self, from: Data("""
        {"data":[
          {"id":"buy","type":"BUY","units":"2.5","price":"100","currency":{"code":"USD"},
           "trade_date":"2026-09-01T14:30:00Z","symbol":{"raw_symbol":"AAPL","exchange":{"mic_code":"XNAS"},"type":{"code":"cs"}}},
          {"id":"sell","type":"SELL","units":-1.25,"price":120,"currency":{"code":"USD"},
           "trade_date":"2026-09-02T00:00:00Z","symbol":{"raw_symbol":"AAPL","exchange":{"mic_code":"XNAS"},"type":{"code":"cs"}}}
        ],"pagination":{"offset":0,"limit":1000,"total":2}}
        """.utf8))
        let rows = try page.data.compactMap { try $0.transaction(account: account) }
        // The chart and trade readout consume this grouping of the ledger.
        let markers = SecurityTrade.grouped(rows)
        XCTAssertEqual(markers.count, 2)
        let buy = try XCTUnwrap(markers.first { $0.isBuy })
        let sell = try XCTUnwrap(markers.first { $0.isSell })
        XCTAssertEqual(buy.dateText, "2026-09-01")
        XCTAssertEqual(buy.quantity, 2.5)
        XCTAssertEqual(buy.amountTotals, ["USD": 250])
        XCTAssertNotNil(buy.executedAt)
        XCTAssertEqual(sell.dateText, "2026-09-02")
        XCTAssertEqual(sell.quantity, 1.25)
        XCTAssertEqual(sell.amountTotals, ["USD": 150])
        XCTAssertNil(sell.executedAt)
        XCTAssertNil(sell.profitTotals, "Sale proceeds must never be presented as realised profit")
        XCTAssertNotNil(buy.filtered(accounts: ["SnapTrade|\(account.id)"]))
        XCTAssertNil(buy.filtered(accounts: ["CSV|other"]))
        XCTAssertFalse(SecurityTradeReadout.reservationCandidates(for: markers).isEmpty)
        let history = SecurityPriceHistory(ticker: "AAPL", currency: "USD",
            points: [.init(dateText: "2026-09-01", close: 100), .init(dateText: "2026-09-02", close: 120)],
            intradayPoints: [], trades: markers)
        let data = SecurityPriceRangeData(history: history, range: .maximum, averageCost: 100,
            selectedAccountKeys: ["SnapTrade|\(account.id)"])
        XCTAssertEqual(SecurityPricePlotSeriesCache().prepared(for: data, scheme: .light).markers.count, 2)
    }
}
