import XCTest
@testable import CatfolioIOS

final class RobinhoodAccountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var account: RobinhoodAccount { .init(id: "12345678", name: "Individual", currency: "USD") }
    private var stock: [String: Any] {
        ["symbol": "AAPL", "quantity": "2.5", "average_buy_price": "100", "currency": "USD", "asset_type": "stock"]
    }
    private var quotes: [String: RobinhoodMCPClient.Quote] {
        ["AAPL": .init(symbol: "AAPL", price: 125, observedAt: now.addingTimeInterval(-86400))]
    }
    private func snapshot(_ rows: [[String: Any]]) throws -> RobinhoodAccountSnapshot {
        try .decode(["positions": rows], account: account, quotes: quotes, generation: 3, now: now)
    }

    func testAccountDiscoveryRequiresIdentityAndCurrency() throws {
        let valid: [String: Any] = ["account_number": account.id, "currency": "USD", "name": "Individual"]
        let accounts = try RobinhoodAccount.decode(["accounts": [valid]])
        XCTAssertEqual(accounts.first, account)
        XCTAssertEqual(accounts.first?.displayName, "Individual · ••••5678")
        XCTAssertThrowsError(try RobinhoodAccount.decode(["accounts": [valid, valid]]))
        XCTAssertThrowsError(try RobinhoodAccount.decode(["accounts": [["account_number": account.id]]]))
    }

    func testSnapshotPreservesFractionalSharesCostAndActualQuoteTime() throws {
        let result = try snapshot([stock])
        let position = try XCTUnwrap(result.positions.first)
        XCTAssertEqual(position.shares, 2.5)
        XCTAssertEqual(position.averageCost, 100)
        XCTAssertEqual(position.quotePrice, 125)
        XCTAssertEqual(position.quoteObservedAt, now.addingTimeInterval(-86400))
        XCTAssertEqual(position.accountID, account.id)
        XCTAssertEqual(position.source, "Robinhood")
        XCTAssertNil(position.openedDate)
        XCTAssertEqual(result.portfolioAccount(name: "Robinhood").transactionCount, 0)
    }

    func testMalformedOrPartialSnapshotCannotClearExistingHoldings() throws {
        for payload: [String: Any] in [
            ["positions": [], "next": "page-two"], ["positions": [], "has_more": true],
            ["positions": [], "count": 4], ["positions": [], "truncated": true], ["error": "unauthorized"]
        ] {
            XCTAssertThrowsError(try RobinhoodAccountSnapshot.decode(payload, account: account, quotes: quotes, generation: 3, now: now))
        }
        var noCost = stock; noCost.removeValue(forKey: "average_buy_price")
        XCTAssertThrowsError(try snapshot([noCost]))
        XCTAssertThrowsError(try snapshot([stock, stock]))
        var wrongAccount = stock; wrongAccount["account_number"] = "other"
        XCTAssertThrowsError(try snapshot([wrongAccount]))
        for (key, value) in [("quantity", "-1"), ("average_buy_price", "nan"), ("currency", "GBP"), ("asset_type", "option")] {
            var invalid = stock; invalid[key] = value
            XCTAssertThrowsError(try snapshot([invalid]))
        }
    }

    func testPreviewCannotCreateDuplicateOrOverwriteDifferentAccount() throws {
        let result = try snapshot([stock])
        let existing = result.portfolioAccount(name: "Existing")
        XCTAssertNoThrow(try result.validate(context: .manage(existing), existing: [existing], now: now))
        XCTAssertThrowsError(try result.validate(context: .create, existing: [existing], now: now))
        let other = PortfolioAccount(id: "Robinhood|other", accountID: "other", source: "Robinhood", name: "Other",
            baseCurrency: "USD", positionCount: 0, transactionCount: 0, manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0)
        XCTAssertThrowsError(try result.validate(context: .manage(other), existing: [other], now: now))
        XCTAssertThrowsError(try result.validate(context: .create, existing: [], now: now.addingTimeInterval(900)))
    }

    func testEmptySyncOnlyClearsSelectedAccountAndPreservesHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalPortfolioStore(fileURL: folder.appendingPathComponent("portfolio.json"))
        let first = try snapshot([stock])
        let unrelated = LocalPositionRecord(ticker: "MSFT", name: "Microsoft", shares: 1, averageCost: 50, currency: "USD",
            quotePrice: 60, quoteCurrency: "USD", source: "Robinhood", openedDate: nil, accountID: "other", accountName: "Other")
        let history = LocalTransactionRecord(date: "2026-01-02", action: "BUY", ticker: "AAPL", quantity: 2.5,
            price: 100, currency: "USD", source: "Robinhood", accountID: account.id, accountName: "Existing")
        _ = try await store.replace(positions: first.positions + [unrelated], source: "Robinhood", transactions: [history])
        let empty = try snapshot([])
        let result = try await store.replace(positions: [], source: "Robinhood", replacingAccountsOnly: true,
            syncedAccounts: [empty.portfolioAccount(name: "Existing")])
        XCTAssertEqual(result.positions.count, 1)
        XCTAssertEqual(result.positions.first?.accountID, "other")
        XCTAssertEqual(result.transactions?.count, 1)
        XCTAssertTrue(result.accounts.contains { $0.accountID == account.id })
        XCTAssertFalse(empty.portfolioAccount(name: "Empty").awaitsFirstSync)
    }
}
