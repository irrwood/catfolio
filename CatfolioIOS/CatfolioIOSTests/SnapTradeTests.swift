import XCTest
@testable import CatfolioIOS

final class SnapTradeTests: XCTestCase {
    @MainActor func testCancelledSnapTradeOperationCannotOverwriteANewerRequest() async throws {
        let operation = SnapTradeOperation()
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        var firstReply: CheckedContinuation<Void, Error>?
        var secondReply: CheckedContinuation<Void, Error>?
        var errors = 0
        let first = try XCTUnwrap(operation.start({
            try await withCheckedThrowingContinuation { firstReply = $0; firstStarted.fulfill() }
        }, onError: { _ in errors += 1 }))
        await fulfillment(of: [firstStarted], timeout: 2)
        operation.cancel()
        XCTAssertFalse(operation.isRunning)
        let second = try XCTUnwrap(operation.start({
            try await withCheckedThrowingContinuation { secondReply = $0; secondStarted.fulfill() }
        }, onError: { _ in errors += 1 }))
        await fulfillment(of: [secondStarted], timeout: 2)
        firstReply?.resume(throwing: URLError(.timedOut))
        await first.value
        XCTAssertTrue(operation.isRunning)
        XCTAssertEqual(errors, 0)
        secondReply?.resume(returning: ())
        await second.value
        XCTAssertFalse(operation.isRunning)
    }

    @MainActor func testCancellingSnapTradeBeforeItStartsPreventsTheAction() async throws {
        let operation = SnapTradeOperation()
        var calls = 0
        let task = try XCTUnwrap(operation.start({ calls += 1 }, onError: { _ in XCTFail("cancel is not an error") }))
        operation.cancel()
        await task.value
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(operation.isRunning)
    }

    private let accountID = "917c8734-8470-4a3e-a18f-57c3f2ee6631"
    private let connectionID = "87b24961-b51e-4db8-9226-f198f6518a89"

    private func account(ready: Bool = true, unavailable: Bool = false) throws -> SnapTradeAccount {
        try JSONDecoder().decode(SnapTradeAccount.self, from: Data("""
        {"id":"\(accountID)","brokerage_authorization":"\(connectionID)","name":"Main","number":"12345678",
         "institution_name":"Example","balance":{"total":{"currency":"USD"}},
         "sync_status":{"holdings":{"initial_sync_completed":\(ready),"holdings_unavailable":\(unavailable)}}}
        """.utf8))
    }

    private func positions(_ rows: String) throws -> SnapTradePositions {
        try JSONDecoder().decode(SnapTradePositions.self, from: Data("""
        {"results":[\(rows)],"data_freshness":{"as_of":"2026-09-01T12:30:00.000Z"}}
        """.utf8))
    }
    private var stock: String {
        """
        {"instrument":{"kind":"stock","symbol":"AAPL","raw_symbol":"AAPL","exchange":"XNAS","description":"Apple"},
         "units":"2.5","price":"200","cost_basis":"120","currency":"USD"}
        """
    }

    func testPersonalSigningMatchesIndependentHMACVector() throws {
        let request = try SnapTradeClient.request(path: "/accounts",
            credentials: .init(clientID: "client", consumerKey: "secret"), now: Date(timeIntervalSince1970: 1_715_123_456))
        XCTAssertEqual(request.url?.absoluteString, "https://api.snaptrade.com/api/v1/accounts?clientId=client&timestamp=1715123456")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Signature"), "N3/Z6RtmtazB2QjmdcAuwfLq4BhHssSDZX1LNNcC+0o=")
        XCTAssertFalse(request.url!.absoluteString.contains("userId"))
        XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        let portal = try SnapTradeClient.request(path: "/snapTrade/login",
            credentials: .init(clientID: "client +&", consumerKey: "secret"), body: ["connectionType": "read"],
            now: Date(timeIntervalSince1970: 1_715_123_456))
        XCTAssertEqual(portal.httpMethod, "POST")
        XCTAssertEqual(portal.value(forHTTPHeaderField: "Signature"), "FofhFcOUon2/kasPs4patl93KLwT1blqzz+zmObRmR0=")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: portal.httpBody!) as? [String: String], ["connectionType": "read"])
    }

    func testFractionalPositionAndProviderTimestampArePreserved() throws {
        let snapshot = try positions(stock).snapshot(account: account())
        let row = try XCTUnwrap(snapshot.positions.first)
        XCTAssertEqual(row.shares, 2.5)
        XCTAssertEqual(row.averageCost, 120)
        XCTAssertEqual(row.quotePrice, 200)
        XCTAssertEqual(row.accountKey, "SnapTrade|\(accountID)")
        XCTAssertEqual(row.fxPnlStatus, "unavailable")
        XCTAssertNil(row.openedDate)
        XCTAssertEqual(row.quoteObservedAt, snapshot.asOf)
        XCTAssertNotEqual(snapshot.asOf, snapshot.fetchedAt)
    }

    func testNumericJSONAndZeroCostAreSupported() throws {
        let rows = stock.replacingOccurrences(of: "\"2.5\"", with: "2.5")
            .replacingOccurrences(of: "\"120\"", with: "0")
        XCTAssertEqual(try positions(rows).snapshot(account: account()).positions.first?.averageCost, 0)
    }

    func testPartialOrUnsupportedPositionsFailWholeSnapshot() throws {
        for invalid in [
            stock.replacingOccurrences(of: "\"120\"", with: "null"),
            stock.replacingOccurrences(of: "\"200\"", with: "null"),
            stock.replacingOccurrences(of: "\"2.5\"", with: "null"),
            stock.replacingOccurrences(of: "\"2.5\"", with: "\"-2\""),
            stock.replacingOccurrences(of: "\"stock\"", with: "\"option\""),
            stock.replacingOccurrences(of: "\"XNAS\"", with: "\"UNKNOWN\""),
        ] {
            XCTAssertThrowsError(try positions(stock + "," + invalid).snapshot(account: account()))
        }
        XCTAssertThrowsError(try positions(stock + "," + stock).snapshot(account: account()))
        XCTAssertThrowsError(try positions(stock.replacingOccurrences(of: "\"2.5\"", with: "\"NaN\"")))
        XCTAssertThrowsError(try JSONDecoder().decode(SnapTradePositions.self, from: Data("{}".utf8)))
    }

    func testUnreadyAndUnavailableAccountsCannotClearHoldings() throws {
        XCTAssertThrowsError(try positions("").snapshot(account: account(ready: false)))
        XCTAssertThrowsError(try positions("").snapshot(account: account(unavailable: true)))
        XCTAssertEqual(try positions("").snapshot(account: account()).positions.count, 0)
    }

    func testForeignListingsUseExchangeQualifiedSymbols() throws {
        let row = stock.replacingOccurrences(of: "AAPL", with: "VOD").replacingOccurrences(of: "XNAS", with: "XLON")
        XCTAssertEqual(try positions(row).snapshot(account: account()).positions.first?.ticker, "VOD.L")
        let pence = row.replacingOccurrences(of: "USD", with: "GBp")
        XCTAssertEqual(try positions(pence).snapshot(account: account()).positions.first?.currency, "GBX")
    }

    func testAccountIdentityDuplicateAndPreviewExpiry() throws {
        let snapshot = try positions(stock).snapshot(account: account())
        let known = snapshot.portfolioAccount(name: "Saved")
        XCTAssertThrowsError(try snapshot.validate(context: .create, existing: [known]))
        XCTAssertNoThrow(try snapshot.validate(context: .manage(known), existing: [known]))
        XCTAssertThrowsError(try snapshot.validate(context: .create, existing: [], now: snapshot.fetchedAt.addingTimeInterval(901)))
        let other = PortfolioAccount(id: "Other|A", accountID: "A", source: "Other", name: "Other", baseCurrency: "USD",
            positionCount: 0, transactionCount: 0, manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0)
        XCTAssertThrowsError(try snapshot.validate(context: .manage(other), existing: []))
    }

    func testAccountReplacementKeepsOtherAccountsAndTransactionHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalPortfolioStore(fileURL: folder.appendingPathComponent("portfolio.json"))
        let first = try positions(stock).snapshot(account: account())
        let unrelated = LocalPositionRecord(ticker: "MSFT", name: "Microsoft", shares: 3, averageCost: 100,
            currency: "USD", quotePrice: 200, quoteCurrency: "USD", source: "CSV", openedDate: nil, accountID: "other")
        let history = LocalTransactionRecord(date: "2026-01-02", action: "BUY", ticker: "AAPL", quantity: 2.5,
            price: 120, currency: "USD", source: "SnapTrade", accountID: accountID, accountName: "Main")
        _ = try await store.replace(positions: first.positions + [unrelated], source: "SnapTrade", transactions: [history])
        let synced = try await store.replace(positions: first.positions, source: "SnapTrade", replacingAccountsOnly: true,
            syncedAccounts: [first.portfolioAccount(name: "Main")])
        XCTAssertEqual(synced.positions.count, 2)
        XCTAssertEqual(synced.transactions, [history])
        let empty = try positions("").snapshot(account: account())
        let cleared = try await store.replace(positions: [], source: "SnapTrade", replacingAccountsOnly: true,
            syncedAccounts: [empty.portfolioAccount(name: "Main")])
        XCTAssertEqual(cleared.positions, [synced.positions.first { $0.source == "CSV" }!])
        XCTAssertEqual(cleared.transactions, [history])
        XCTAssertTrue(cleared.accounts.contains { $0.id == "SnapTrade|\(accountID)" })
        XCTAssertFalse(empty.portfolioAccount(name: "Main").awaitsFirstSync)
    }

    func testNetworkFlowRequiresActiveConnectionAndCompletePayload() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SnapTradeTestProtocol.self]
        let client = SnapTradeClient(session: URLSession(configuration: config))
        let credentials = try SnapTradeCredentials(clientID: "test", consumerKey: "DO-NOT-EXPOSE")
        let accountJSON = """
        {"id":"\(accountID)","brokerage_authorization":"\(connectionID)","name":"Main","number":"1234",
         "institution_name":"Example","balance":{"total":{"currency":"USD"}},
         "sync_status":{"holdings":{"initial_sync_completed":true}}}
        """
        let base = "/api/v1"
        SnapTradeTestProtocol.responses = [
            base + "/accounts/\(accountID)": (200, accountJSON),
            base + "/authorizations/\(connectionID)": (200, "{\"disabled\":false}"),
            base + "/accounts/\(accountID)/positions/all": (200, "{\"results\":[],\"data_freshness\":{\"as_of\":\"2026-09-01T00:00:00Z\"}}")
        ]
        defer { SnapTradeTestProtocol.responses = [:] }
        let empty = try await client.snapshot(accountID: accountID, credentials: credentials)
        XCTAssertTrue(empty.positions.isEmpty)
        SnapTradeTestProtocol.responses[base + "/authorizations/\(connectionID)"] = (200, "{\"disabled\":true}")
        do {
            _ = try await client.snapshot(accountID: accountID, credentials: credentials)
            XCTFail("Disabled connections must not offer stale snapshots")
        } catch { guard case SnapTradeError.disconnected = error else { return XCTFail("Wrong error") } }
        SnapTradeTestProtocol.responses[base + "/accounts/\(accountID)"] = (429, "DO-NOT-EXPOSE")
        do {
            _ = try await client.snapshot(accountID: accountID, credentials: credentials)
            XCTFail("A failed fetch must not produce an empty snapshot")
        } catch {
            guard case SnapTradeError.http(429) = error else { return XCTFail("Wrong error") }
            XCTAssertFalse(error.localizedDescription.contains("DO-NOT-EXPOSE"))
        }
    }

    func testPortalRejectsUntrustedRedirect() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SnapTradeTestProtocol.self]
        let client = SnapTradeClient(session: URLSession(configuration: config))
        let credentials = try SnapTradeCredentials(clientID: "test", consumerKey: "secret")
        defer { SnapTradeTestProtocol.responses = [:] }
        for uri in ["http://app.snaptrade.com/test", "https://app.snaptrade.com.evil.test/test", "https://evil.test/"] {
            SnapTradeTestProtocol.responses = ["/api/v1/snapTrade/login": (200, "{\"redirectURI\":\"\(uri)\"}")]
            do {
                _ = try await client.portal(credentials: credentials)
                XCTFail("Untrusted portal URL accepted")
            } catch { guard case SnapTradeError.malformed = error else { return XCTFail("Wrong error") } }
        }
    }
}

private final class SnapTradeTestProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let (status, body) = Self.responses[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
