import XCTest
@testable import CatfolioIOS

final class SnapTradeActivityTests: XCTestCase {
    private let accountID = "917c8734-8470-4a3e-a18f-57c3f2ee6631"
    private let connectionID = "87b24961-b51e-4db8-9226-f198f6518a89"
    private var accountJSON: String {
        """
        {"id":"\(accountID)","brokerage_authorization":"\(connectionID)","name":"Main","number":"1234",
        "institution_name":"Example","balance":{"total":{"currency":"USD"}},
        "sync_status":{"holdings":{"initial_sync_completed":true},"transactions":{"initial_sync_completed":true}}}
        """
    }
    private func account() throws -> SnapTradeAccount {
        try JSONDecoder().decode(SnapTradeAccount.self, from: Data(accountJSON.utf8))
    }
    private func activity(_ id: String = "fill-1", side: String = "BUY", raw: String = "AAPL",
                          exchange: String = "XNAS", currency: String = "USD", date: String = "2026-09-02T14:30:00Z",
                          units: String = "2.5", price: String = "120", kind: String = "cs") -> String {
        """
        {"id":"\(id)","type":"\(side)","symbol":{"raw_symbol":"\(raw)","exchange":{"mic_code":"\(exchange)"},
        "type":{"code":"\(kind)"}},"units":\(units),"price":\(price),"currency":{"code":"\(currency)"},
        "trade_date":"\(date)","settlement_date":"2026-09-04T00:00:00Z"}
        """
    }
    private func row(_ json: String) throws -> LocalTransactionRecord? {
        try JSONDecoder().decode(SnapTradeActivity.self, from: Data(json.utf8)).transaction(account: account())
    }
    private func page(_ rows: [String], offset: Int = 0, limit: Int = 1000, total: Int? = nil) -> String {
        "{\"data\":[\(rows.joined(separator: ","))],\"pagination\":{\"offset\":\(offset),\"limit\":\(limit),\"total\":\(total ?? rows.count)}}"
    }
    private func client(_ responses: [String: (Int, String)]) -> SnapTradeClient {
        SnapTradeActivityProtocol.responses = responses
        SnapTradeActivityProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SnapTradeActivityProtocol.self]
        return SnapTradeClient(session: URLSession(configuration: configuration))
    }
    override func tearDown() {
        SnapTradeActivityProtocol.responses = [:]
        SnapTradeActivityProtocol.requests = []
        super.tearDown()
    }
    private func fetch(_ client: SnapTradeClient) async throws -> SnapTradeActivityHistory {
        try await client.activities(account: account(), credentials: .init(clientID: "client", consumerKey: "secret"))
    }

    func testCanonicalActivitySigningIncludesPaginationAndFilter() throws {
        let request = try SnapTradeClient.request(path: "/accounts/\(accountID)/activities",
            credentials: .init(clientID: "client", consumerKey: "secret"),
            query: [.init(name: "type", value: "BUY,SELL"), .init(name: "offset", value: "1000"), .init(name: "limit", value: "1000")],
            pathPrefix: "", now: Date(timeIntervalSince1970: 1_715_123_456))
        XCTAssertEqual(request.url?.path, "/accounts/\(accountID)/activities")
        // Independent Python hmac/hashlib vector for this exact canonical query.
        XCTAssertEqual(request.url?.query, "clientId=client&timestamp=1715123456&type=BUY%2CSELL&offset=1000&limit=1000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Signature"), "SAfCRj02FWvODCnaYZYI864jKpbSCqof1bFK1MXZEnQ=")
        XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        XCTAssertFalse(request.url!.absoluteString.contains("userSecret"))
    }

    func testLegacyActivitySignatureMatchesIndependentVectorAndActualURL() throws {
        let request = try SnapTradeClient.request(path: "/accounts/\(accountID)/activities",
            credentials: .init(clientID: "client", consumerKey: "secret"),
            query: [.init(name: "type", value: "BUY,SELL"), .init(name: "offset", value: "1000"), .init(name: "limit", value: "1000")],
            now: Date(timeIntervalSince1970: 1_715_123_456))
        XCTAssertEqual(request.url?.path, "/api/v1/accounts/\(accountID)/activities")
        XCTAssertEqual(request.url?.query, "clientId=client&timestamp=1715123456&type=BUY%2CSELL&offset=1000&limit=1000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Signature"), "AbNTVoy0139VwPD++YvnstSEu78a0NY8/T4set4yTMw=")
    }

    func testQueryEncodingMatchesURLSearchParamsForReservedAndUnicodeCharacters() throws {
        let request = try SnapTradeClient.request(path: "/accounts",
            credentials: .init(clientID: "client +&", consumerKey: "secret"),
            query: [.init(name: "filter", value: "BUY,SELL/~雪*"), .init(name: "filter", value: "a+b c")],
            now: Date(timeIntervalSince1970: 1_715_123_456))
        XCTAssertEqual(request.url?.query,
            "clientId=client+%2B%26&timestamp=1715123456&filter=BUY%2CSELL%2F%7E%E9%9B%AA*&filter=a%2Bb+c")
    }

    func testSignatureRejectionRetriesLegacyReadOnceAndPinsLaterPages() async throws {
        let path = "/accounts/\(accountID)/activities"
        let client = client([
            path + "?offset=0": (401, "{\"code\":\"1076\",\"detail\":\"Unable to verify signature sent\"}"),
            "/api/v1" + path + "?offset=0": (200, page([activity("buy")], limit: 1, total: 2)),
            "/api/v1" + path + "?offset=1": (200, page([activity("sell", side: "SELL")], offset: 1, limit: 1, total: 2))
        ])
        let history = try await fetch(client)
        XCTAssertEqual(Set(history.transactions.compactMap(\.tradeID)), ["buy", "sell"])
        let requests = SnapTradeActivityProtocol.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [path, "/api/v1" + path, "/api/v1" + path])
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotEqual(requests[0].value(forHTTPHeaderField: "Signature"), requests[1].value(forHTTPHeaderField: "Signature"))
        for request in requests {
            XCTAssertTrue(request.url?.query?.contains("type=BUY%2CSELL") == true)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "api.snaptrade.com")
        }
    }

    func testOtherAuthenticationPermissionsAndRateLimitErrorsNeverUseCompatibilityRetry() async throws {
        let path = "/accounts/\(accountID)/activities?offset=0"
        for (status, body) in [(401, "{\"code\":\"0000\"}"), (401, "not JSON"),
                               (403, "{\"code\":\"1076\"}"), (429, "{\"code\":\"1076\"}")] {
            do {
                _ = try await fetch(client([path: (status, body), "/api/v1" + path: (200, page([]))]))
                XCTFail("Must not mask this rejection")
            } catch { XCTAssertTrue(error is SnapTradeError) }
            XCTAssertEqual(SnapTradeActivityProtocol.requests.count, 1)
        }
    }

    func testSignatureFailureOnBothRoutesStopsAfterTwoReadsAndKeepsSpecificAdvice() async throws {
        let path = "/accounts/\(accountID)/activities?offset=0"
        let failure = (401, "{\"code\":\"1076\"}")
        do {
            _ = try await fetch(client([path: failure, "/api/v1" + path: failure]))
            XCTFail("Two failed signatures cannot produce an import")
        } catch {
            guard case let SnapTradeError.rejected(status, step, code) = error else { return XCTFail("Wrong error") }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(step, .activities)
            XCTAssertEqual(code, "1076")
            XCTAssertTrue(error.localizedDescription.contains(L10n.text("请求签名校验失败。现有数据已保留。")))
        }
        XCTAssertEqual(SnapTradeActivityProtocol.requests.count, 2)
    }

    func testBuySellFractionalAndStringNumbersMapIntoLedger() throws {
        let buy = try XCTUnwrap(row(activity(units: "\"2.5\"", price: "\"120\"")))
        XCTAssertEqual(buy.action, "BUY")
        XCTAssertEqual(buy.quantity, 2.5)
        XCTAssertEqual(buy.price, 120)
        XCTAssertEqual(buy.ticker, "AAPL")
        XCTAssertEqual(buy.currency, "USD")
        XCTAssertEqual(buy.date, "2026-09-02")
        XCTAssertEqual(buy.executedAt, "2026-09-02T14:30:00Z")
        XCTAssertEqual(buy.accountKey, "SnapTrade|\(accountID)")
        XCTAssertEqual(buy.tradeID, "fill-1")
        XCTAssertNil(buy.realisedProfitLoss)
        XCTAssertNil(buy.cashPostings)
        XCTAssertNil(buy.brokerFXRate)
        let sell = try XCTUnwrap(row(activity("fill-2", side: "SELL", units: "-1.25", price: "145")))
        XCTAssertEqual(sell.action, "SELL")
        XCTAssertEqual(sell.quantity, 1.25)
        XCTAssertEqual(sell.price, 145)
    }

    func testForeignSymbolsMatchHoldingsAndPenceArePreserved() throws {
        for (raw, exchange, expected) in [("BRK.B", "XNYS", "BRK-B"), ("VOD", "XLON", "VOD.L"),
            ("VAB", "XTSE", "VAB.TO"), ("ABC", "XTSX", "ABC.V"), ("700", "XHKG", "0700.HK")] {
            XCTAssertEqual(try row(activity(raw: raw, exchange: exchange))?.ticker, expected)
        }
        XCTAssertEqual(try row(activity(raw: "VOD", exchange: "XLON", currency: "GBp"))?.currency, "GBX")
    }

    func testDateOnlyAndMidnightDoNotInventIntradayExecution() throws {
        for date in ["2026-09-02", "2026-09-02T00:00:00Z", "2026-09-02T00:00:00.000Z"] {
            let trade = try XCTUnwrap(row(activity(date: date)))
            XCTAssertEqual(trade.date, "2026-09-02")
            XCTAssertNil(trade.executedAt)
        }
        XCTAssertEqual(try row(activity(date: "2026-09-02T15:30:10.123+01:00"))?.executedAt,
                       "2026-09-02T15:30:10.123+01:00")
    }

    func testInvalidEquityFillsFailInsteadOfInventingValues() throws {
        let invalid = [activity(units: "0"), activity(units: "null"), activity(price: "null"),
            activity(price: "-1"), activity(price: "0"), activity(price: "\"NaN\""), activity(currency: ""),
            activity(date: "2026-02-30"), activity(date: "2026-09-02garbage"), activity(date: "not-a-date"),
            activity().replacingOccurrences(of: "\"trade_date\":\"2026-09-02T14:30:00Z\"", with: "\"trade_date\":null")]
        for json in invalid { XCTAssertThrowsError(try row(json), json) }
    }

    func testNonTradesOptionsCryptoAndUnknownSecuritiesAreNotStockFills() throws {
        let nonTrade = "{\"id\":\"cash\",\"type\":\"DIVIDEND\",\"price\":\"unrelated\"}"
        XCTAssertNil(try row(nonTrade))
        for json in [activity(kind: "bnd"), activity(kind: "crypto"), activity(exchange: "UNKNOWN"),
            activity().replacingOccurrences(of: "\"units\":2.5", with: "\"option_symbol\":{\"ticker\":\"AAPL call\"},\"units\":2.5"),
            activity().replacingOccurrences(of: "\"units\":2.5", with: "\"currency_universal_symbol\":{},\"units\":2.5"),
            "{\"id\":\"unmapped\",\"type\":\"BUY\",\"symbol\":null}"] {
            XCTAssertNil(try row(json))
        }
    }

    func testPaginationLoadsAllPagesUsingReturnedCountAndStableIDs() async throws {
        let path = "/accounts/\(accountID)/activities"
        let client = client([path + "?offset=0": (200, page([activity("buy")], limit: 1, total: 2)),
                             path + "?offset=1": (200, page([activity("sell", side: "SELL")], offset: 1, limit: 1, total: 2))])
        let history = try await fetch(client)
        XCTAssertEqual(Set(history.transactions.compactMap(\.tradeID)), ["buy", "sell"])
        XCTAssertEqual(history.skipped, 0)
        XCTAssertEqual(SnapTradeActivityProtocol.requests.count, 2)
        for request in SnapTradeActivityProtocol.requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "type" }?.value, "BUY,SELL")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "1000")
            XCTAssertEqual(request.url?.host, "api.snaptrade.com")
            XCTAssertEqual(request.httpMethod, "GET")
        }
    }

    func testEmptyHistoryIsValidAndSkippedTradesAreCounted() async throws {
        let path = "/accounts/\(accountID)/activities?offset=0"
        let empty = try await fetch(client([path: (200, page([]))]))
        XCTAssertTrue(empty.transactions.isEmpty)
        let mixed = try await fetch(client([path: (200, page([activity(), activity("bond", kind: "bnd"),
            "{\"id\":\"cash\",\"type\":\"DIVIDEND\"}"]))]))
        XCTAssertEqual(mixed.transactions.count, 1)
        XCTAssertEqual(mixed.skipped, 1)
    }

    func testBadPaginationAndRepeatedIDsCannotReturnPartialSuccess() async throws {
        let path = "/accounts/\(accountID)/activities"
        for bad in [page([], offset: 1, total: 2), page([], total: 2), page([activity()], limit: 0),
                    page([activity()], total: 0), page([activity(), activity()]), "[]", "{}"] {
            do { _ = try await fetch(client([path + "?offset=0": (200, bad)])); XCTFail("Accepted \(bad)") }
            catch { XCTAssertTrue(error is SnapTradeError) }
        }
        for second in [page([activity()], offset: 1, limit: 1, total: 2),
                       page([activity("next")], offset: 1, limit: 1, total: 3)] {
            do {
                _ = try await fetch(client([path + "?offset=0": (200, page([activity()], limit: 1, total: 2)),
                                            path + "?offset=1": (200, second)]))
                XCTFail("Repeated ID or changing total must fail")
            } catch { XCTAssertTrue(error is SnapTradeError) }
        }
    }

    func testLaterPageFailureDoesNotOfferAnImportableSnapshot() async throws {
        let activityPath = "/accounts/\(accountID)/activities"
        let client = client([
            "/api/v1/accounts/\(accountID)": (200, accountJSON),
            "/api/v1/authorizations/\(connectionID)": (200, "{\"disabled\":false}"),
            "/api/v1/accounts/\(accountID)/positions/all": (200,
                "{\"results\":[],\"data_freshness\":{\"as_of\":\"2026-09-01T00:00:00Z\"}}"),
            activityPath + "?offset=0": (200, page([activity()], limit: 1, total: 2)),
            activityPath + "?offset=1": (429, "SECRET")])
        do {
            _ = try await client.snapshot(accountID: accountID, credentials: .init(clientID: "client", consumerKey: "secret"))
            XCTFail("Must not return a snapshot with incomplete history")
        } catch {
            guard case SnapTradeError.http(429) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertFalse(error.localizedDescription.contains("SECRET"))
        }
    }

    func testSnapshotIncludesHistoryAndPendingInitialSyncBlocksImport() async throws {
        let client = client([
            "/api/v1/accounts/\(accountID)": (200, accountJSON),
            "/api/v1/authorizations/\(connectionID)": (200, "{\"disabled\":false}"),
            "/api/v1/accounts/\(accountID)/positions/all": (200,
                "{\"results\":[],\"data_freshness\":{\"as_of\":\"2026-09-01T00:00:00Z\"}}"),
            "/accounts/\(accountID)/activities?offset=0": (200, page([activity(), activity("bond", kind: "bnd")]))])
        let credentials = try SnapTradeCredentials(clientID: "client", consumerKey: "secret")
        let snapshot = try await client.snapshot(accountID: accountID, credentials: credentials)
        XCTAssertTrue(snapshot.positions.isEmpty)
        XCTAssertEqual(snapshot.transactions.count, 1)
        XCTAssertEqual(snapshot.portfolioAccount(name: "Main").transactionCount, 1)
        XCTAssertEqual(snapshot.warnings.count, 1)
        SnapTradeActivityProtocol.responses["/api/v1/accounts/\(accountID)"] = (200,
            accountJSON.replacingOccurrences(of: "\"transactions\":{\"initial_sync_completed\":true}",
                                            with: "\"transactions\":{\"initial_sync_completed\":false}"))
        do {
            _ = try await client.snapshot(accountID: accountID, credentials: credentials)
            XCTFail("Initial transaction sync has not completed")
        } catch { guard case SnapTradeError.syncing = error else { return XCTFail("Wrong error") } }
    }

    func testSyncAuthenticationFailuresIdentifyTheExactStepAndDoNotLeakResponseData() async throws {
        let routes: [(String, SnapTradeRequestStep)] = [
            ("/api/v1/accounts/\(accountID)", .account),
            ("/api/v1/authorizations/\(connectionID)", .connection),
            ("/api/v1/accounts/\(accountID)/positions/all", .positions),
            ("/accounts/\(accountID)/activities?offset=0", .activities)
        ]
        let valid: [String: (Int, String)] = [
            routes[0].0: (200, accountJSON),
            routes[1].0: (200, "{\"disabled\":false}"),
            routes[2].0: (200, "{\"results\":[],\"data_freshness\":{\"as_of\":\"2026-09-01T00:00:00Z\"}}"),
            routes[3].0: (200, page([]))
        ]
        for (route, expectedStep) in routes {
            for status in [401, 403] {
                var responses = valid
                responses[route] = (status, "{\"code\":\"1010\",\"detail\":\"DO-NOT-EXPOSE \(accountID)\"}")
                do {
                    _ = try await client(responses).snapshot(accountID: accountID,
                        credentials: .init(clientID: "client", consumerKey: "DO-NOT-EXPOSE"))
                    XCTFail("A rejected request cannot produce a snapshot")
                } catch {
                    guard case let SnapTradeError.rejected(actualStatus, actualStep, code) = error else {
                        return XCTFail("Missing request context: \(error)")
                    }
                    XCTAssertEqual(actualStatus, status)
                    XCTAssertEqual(actualStep, expectedStep)
                    XCTAssertEqual(code, "1010")
                    XCTAssertTrue(error.localizedDescription.contains(expectedStep.title))
                    XCTAssertTrue(error.localizedDescription.contains(String(status)))
                    XCTAssertFalse(error.localizedDescription.contains("DO-NOT-EXPOSE"))
                    XCTAssertFalse(error.localizedDescription.contains(accountID))
                }
            }
        }
    }

    func testProviderErrorCodesNeverSurfaceFreeFormOrMalformedValues() throws {
        for (json, expected) in [
            ("{\"code\":\"0000\",\"detail\":\"secret\"}", "0000"),
            ("{\"code\":1010}", "1010"),
            ("{\"error_code\":\"1140\"}", "1140"),
            ("{\"code\":\"secret\"}", nil), ("{\"code\":\"1010 secret\"}", nil),
            ("{\"detail\":\"secret\"}", nil), ("not JSON", nil),
            ("{\"code\":true}", nil)
        ] as [(String, String?)] {
            XCTAssertEqual(SnapTradeRequestStep.providerCode(from: Data(json.utf8)), expected)
        }
    }

    func testAccountListAuthenticationFailureIsSeparateFromHistoryFailure() async throws {
        do {
            _ = try await client(["/api/v1/accounts": (401, "{\"code\":\"0000\"}")])
                .accounts(credentials: .init(clientID: "client", consumerKey: "secret"))
            XCTFail("Must reject unauthenticated account list")
        } catch {
            guard case let SnapTradeError.rejected(status, step, code) = error else { return XCTFail("Wrong error") }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(step, .accounts)
            XCTAssertEqual(code, "0000")
        }
    }

    func testRepeatedSyncMergesHistoryWithoutDuplicatesOrLosingOtherAccounts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalPortfolioStore(fileURL: folder.appendingPathComponent("portfolio.json"))
        let old = try XCTUnwrap(row(activity("old")))
        let other = old.assignedAccount(id: "other", name: "Other", source: "CSV")
        let manual = LocalTransactionRecord(date: "2026-01-02", action: "BUY", ticker: "MSFT", quantity: 1,
            price: 100, currency: "USD", source: "SnapTrade", accountID: accountID, accountName: "Main", entryMethod: "manual")
        _ = try await store.replace(positions: [], source: "SnapTrade", transactions: [old, other, manual])
        var snapshot = SnapTradeSnapshot(account: try account(), positions: [], asOf: Date(), fetchedAt: Date())
        snapshot.transactions = [try XCTUnwrap(row(activity("new", side: "SELL"))) ]
        for _ in 0..<2 {
            _ = try await store.replace(positions: [], source: "SnapTrade", transactions: snapshot.transactions,
                replacingAccountsOnly: true, syncedAccounts: [snapshot.portfolioAccount(name: "Main")], mergesTransactionHistory: true)
        }
        let saved = try await store.load()
        XCTAssertEqual(saved.transactions?.count, 4)
        XCTAssertTrue(saved.transactions?.contains(other) == true)
        XCTAssertTrue(saved.transactions?.contains(manual) == true)
        XCTAssertEqual(saved.accounts.first { $0.accountID == accountID }?.transactionCount, 3)
        let reopened = try await LocalPortfolioStore(fileURL: folder.appendingPathComponent("portfolio.json")).load()
        XCTAssertEqual(reopened.transactions, saved.transactions)
        let empty = try await store.replace(positions: [], source: "SnapTrade", transactions: [], replacingAccountsOnly: true,
            syncedAccounts: [snapshot.portfolioAccount(name: "Main")], mergesTransactionHistory: true)
        XCTAssertEqual(empty.transactions, saved.transactions)
    }
}

private final class SnapTradeActivityProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard let url = request.url else { return }
        let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value
        let key = url.path + (offset.map { "?offset=\($0)" } ?? "")
        guard let (status, body) = Self.responses[key] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
