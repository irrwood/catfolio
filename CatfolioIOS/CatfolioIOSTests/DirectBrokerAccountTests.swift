import XCTest
@testable import CatfolioIOS

final class DirectBrokerAccountTests: XCTestCase {
    private let uuid = "a9edfb74-2c90-4d6d-b793-74b4598ecb61"
    private var account: Data { Data("{\"id\":\"\(uuid)\",\"account_number\":\"12345678\",\"currency\":\"USD\",\"status\":\"ACTIVE\"}".utf8) }
    private func positions(_ overrides: [String: Any] = [:]) throws -> Data {
        var row: [String: Any] = ["symbol": "AAPL", "asset_class": "us_equity", "qty": "1.25",
            "avg_entry_price": "100", "current_price": "125.5", "side": "long"]
        row.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: [row])
    }
    func testAlpacaFractionalPositionAndSeparatePaperIdentity() throws {
        let live = try AlpacaAccountClient.decode(account: account, positions: positions(), environment: .live)
        let paper = try AlpacaAccountClient.decode(account: account, positions: positions(), environment: .paper)
        XCTAssertNotEqual(live.accountKey, paper.accountKey)
        XCTAssertNotEqual(DirectBrokerCredentials.storageKey(broker: .alpaca, accountID: live.accountID),
                          DirectBrokerCredentials.storageKey(broker: .alpaca, accountID: paper.accountID))
        XCTAssertEqual(live.positions[0].shares, 1.25)
        XCTAssertEqual(live.positions[0].quotePrice, 125.5)
        XCTAssertEqual(live.positions[0].averageCost, 100)
        XCTAssertNil(live.positions[0].quoteObservedAt)
        XCTAssertEqual(try AlpacaAccountClient.decode(account: account, positions: positions(["symbol": "BRK.B"]),
            environment: .live).positions.first?.ticker, "BRK-B")
        XCTAssertEqual(paper.portfolioAccount(name: "Test").accountType, "模拟盘")
        XCTAssertFalse(live.accountLabel.contains(uuid))
    }
    func testAlpacaRejectsOptionsShortsCryptoMissingPricesAndMalformedAmounts() throws {
        for overrides: [String: Any] in [
            ["asset_class": "us_option"], ["asset_class": "crypto"], ["side": "short", "qty": "-2"],
            ["current_price": NSNull()], ["qty": "NaN"], ["avg_entry_price": "-1"],
            ["current_price": "Infinity"], ["current_price": "0"], ["avg_entry_price": "unavailable"]
        ] {
            XCTAssertThrowsError(try AlpacaAccountClient.decode(account: account, positions: positions(overrides), environment: .live))
        }
        let duplicate = try JSONSerialization.jsonObject(with: positions()) as! [[String: Any]]
        XCTAssertThrowsError(try AlpacaAccountClient.decode(account: account,
            positions: JSONSerialization.data(withJSONObject: duplicate + duplicate), environment: .live))
        XCTAssertThrowsError(try AlpacaAccountClient.decode(account: account, positions: Data("{}".utf8), environment: .live))
        XCTAssertThrowsError(try AlpacaAccountClient.decode(account: Data(String(decoding: account, as: UTF8.self)
            .replacingOccurrences(of: "USD", with: "JPY").utf8), positions: positions(), environment: .live))
    }
    func testPreviewExpiryDuplicateWrongAccountAndDeletedAccountAreRejected() throws {
        let snapshot = try AlpacaAccountClient.decode(account: account, positions: positions(), environment: .live)
        let saved = snapshot.portfolioAccount(name: "Existing")
        XCTAssertNoThrow(try snapshot.validate(context: .create, existing: []))
        XCTAssertNoThrow(try snapshot.validate(context: .manage(saved), existing: [saved]))
        XCTAssertThrowsError(try snapshot.validate(context: .create, existing: [saved]))
        XCTAssertThrowsError(try snapshot.validate(context: .manage(saved), existing: []))
        XCTAssertThrowsError(try snapshot.validate(context: .create, existing: [], now: snapshot.fetchedAt.addingTimeInterval(901)))
        let paper = try AlpacaAccountClient.decode(account: account, positions: positions(), environment: .paper)
        XCTAssertThrowsError(try paper.validate(context: .manage(saved), existing: [saved]))
    }
    func testAlpacaClientUsesOnlySelectedHostsAndReadEndpoints() async throws {
        for environment in AlpacaEnvironment.allCases {
            let account = account, positions = try positions()
            let client = AlpacaAccountClient(http: .init { request in
                XCTAssertEqual(request.url?.host, environment.host)
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.httpBody)
                XCTAssertEqual(request.value(forHTTPHeaderField: "APCA-API-KEY-ID"), "key")
                XCTAssertEqual(request.value(forHTTPHeaderField: "APCA-API-SECRET-KEY"), "secret")
                let path = try XCTUnwrap(request.url?.path)
                XCTAssertTrue(["/v2/account", "/v2/positions"].contains(path))
                return (path == "/v2/account" ? account : positions,
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let snapshot = try await client.snapshot(credentials: .init(broker: .alpaca, key: "key", secret: "secret", environment: environment))
            XCTAssertTrue(snapshot.accountID.hasPrefix(environment.rawValue + ":"))
        }
    }
    func testHTTPRejectsUnauthorizedPartialResponsesAndNextPages() async throws {
        for status in [200, 206, 301, 401, 403, 429, 500] {
            let http = DirectBrokerHTTP { request in
                (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: status == 200 ? ["Link": "<next>; rel=\"next\""] : nil)!)
            }
            do { _ = try await http.data(URLRequest(url: URL(string: "https://api.alpaca.markets/v2/positions")!)); XCTFail("Must reject \(status)") }
            catch { XCTAssertTrue(error is DirectBrokerError) }
        }
    }
    func testEmptySnapshotClearsOnlyItsAccountAndPreservesHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalPortfolioStore(fileURL: root.appendingPathComponent("portfolio.json"))
        let live = try AlpacaAccountClient.decode(account: account, positions: positions(), environment: .live)
        let paper = try AlpacaAccountClient.decode(account: account, positions: positions(), environment: .paper)
        let trade = LocalTransactionRecord(date: "2026-10-01", action: "BUY", ticker: "AAPL", quantity: 1.25,
            price: 100, currency: "USD", source: "Alpaca", accountID: live.accountID, accountName: "Live", tradeID: "trade")
        _ = try await store.replace(positions: live.positions + paper.positions, source: "Alpaca", transactions: [trade])
        let empty = try AlpacaAccountClient.decode(account: account, positions: Data("[]".utf8), environment: .live)
        let result = try await store.replace(positions: empty.positions, source: "Alpaca", replacingAccountsOnly: true,
                                             syncedAccounts: [empty.portfolioAccount(name: "Live")])
        XCTAssertEqual(result.positions.map(\.accountKey), [paper.accountKey])
        XCTAssertEqual(result.transactions, [trade])
        XCTAssertEqual(Set(result.accounts.map(\.id)), [live.accountKey, paper.accountKey])
        XCTAssertFalse(empty.portfolioAccount(name: "Live").awaitsFirstSync)
    }
}
