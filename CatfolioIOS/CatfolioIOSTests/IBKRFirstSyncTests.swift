import XCTest
@testable import CatfolioIOS

/// The parts of a new IBKR account's first sync that do not need IBKR.
final class IBKRFirstSyncTests: XCTestCase {
    private func position(_ account: String, _ symbol: String) -> IBKRFlexPosition {
        IBKRFlexPosition(accountID: account, symbol: symbol, name: symbol, currency: "USD", assetCategory: "STK",
                         quantity: 1, markPrice: 10, marketValue: 10, averageCost: 8, costBasis: 8,
                         reportDate: nil, openDate: nil)
    }

    private func trade(_ account: String, _ id: String) -> IBKRFlexTransaction {
        IBKRFlexTransaction(accountID: account, tradeID: id, symbol: "AAPL", name: "Apple", currency: "USD",
                            side: "BUY", quantity: 1, price: 10, tradeDate: "2026-01-02",
                            fxRateToBase: 1, realisedProfitLoss: nil)
    }

    /// A report covering an account already in Catfolio and a new one: the
    /// first sync takes only the new one, whole.
    func testTheFirstSyncLeavesExistingAccountsOut() {
        let report = IBKRFlexSnapshot(
            positions: [position("U1", "AAPL"), position("U2", "NVDA")],
            transactions: [trade("U1", "t1"), trade("U2", "t2")],
            accountCurrencies: ["U1": "USD", "U2": "GBP"],
            accountNames: ["U1": "Old", "U2": "New"],
            reportDate: "2026-09-18",
            positionAccountIDs: ["U1", "U2"]
        )
        let new = report.restricted(excluding: ["U1"])
        XCTAssertEqual(new.positions.map(\.accountID), ["U2"])
        XCTAssertEqual(new.transactions.map(\.accountID), ["U2"])
        XCTAssertEqual(new.accountCurrencies, ["U2": "GBP"])
        XCTAssertEqual(new.accountNames, ["U2": "New"])
        XCTAssertEqual(new.syncedPositionAccountIDs, ["U2"])
        XCTAssertEqual(new.reportDate, "2026-09-18")
    }

    /// Credentials already saved on people's phones are read back under these
    /// names; moving the keys into one place must not rename them.
    func testKeychainKeysKeepTheirNames() {
        XCTAssertEqual(IBKRFlexKeys.token(accountID: "U123"), "ibkr.flex.account.U123.token")
        XCTAssertEqual(IBKRFlexKeys.queryID(accountID: "U123"), "ibkr.flex.account.U123.query-id")
        XCTAssertEqual(IBKRFlexKeys.pendingToken, "ibkr.flex.pending.token")
        XCTAssertEqual(IBKRFlexKeys.pendingQueryID, "ibkr.flex.pending.query-id")
        XCTAssertEqual(IBKRFlexKeys.pendingAccountID, "ibkr-flex-pending")
    }
}
