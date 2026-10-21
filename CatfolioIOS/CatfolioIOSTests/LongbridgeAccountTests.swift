import XCTest
@testable import CatfolioIOS

final class LongbridgeAccountTests: XCTestCase {
    private let credentials = DirectBrokerCredentials(broker: .longbridge, key: "key", secret: "secret", token: "token")
    private func stocks(symbol: String = "700.HK", market: String = "HK", currency: String = "HKD",
                        quantity: String = "2.5", cost: String? = "100", channel: String = "lb") -> [String: Any] {
        var row: [String: Any] = ["symbol": symbol, "symbol_name": "Test", "market": market, "currency": currency,
                                  "quantity": quantity, "available_quantity": "-10"]
        if let cost { row["cost_price"] = cost }
        return ["account_channel": channel, "stock_info": [row]]
    }
    private func client(channels: [[String: Any]], board: String = "HKEquity", includeQuote: Bool = true,
                        quoteCurrency: String = "HKD", code: Int = 0) -> LongbridgeAccountClient {
        LongbridgeAccountClient(http: .init { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "openapi.longbridge.com")
            XCTAssertTrue(["token", "rotated"].contains(request.value(forHTTPHeaderField: "Authorization") ?? ""))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Api-Signature"))
            XCTAssertNil(request.value(forHTTPHeaderField: "App-Secret"))
            let path = try XCTUnwrap(request.url?.path)
            XCTAssertTrue(["/v1/asset/account", "/v1/asset/stock"].contains(path))
            let list: [[String: Any]] = path == "/v1/asset/account" ? [["currency": "USD"]] : channels
            let data = try JSONSerialization.data(withJSONObject: ["code": code, "data": ["list": list]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, quoteRequest: { command, body in
            if command == 4 { return LongbridgeProto.integer(1, 123456) }
            let symbols = try LongbridgeProto(body).fields[1] ?? []
            XCTAssertTrue(command == 10 || command == 11)
            var response = Data()
            for field in symbols {
                guard case .bytes(let raw) = field, let symbol = String(data: raw, encoding: .utf8) else { continue }
                let row: Data
                if command == 10 {
                    row = LongbridgeProto.string(1, symbol) + LongbridgeProto.string(7, quoteCurrency) + LongbridgeProto.string(17, board)
                } else {
                    if !includeQuote { continue }
                    row = LongbridgeProto.string(1, symbol) + LongbridgeProto.string(2, "120")
                        + LongbridgeProto.integer(7, UInt64(Date().timeIntervalSince1970))
                }
                response += LongbridgeProto.bytes(1, row)
            }
            return response
        })
    }
    func testUserIdentitySurvivesTokenRotationAndUsesTotalQuantity() async throws {
        let first = try await client(channels: [stocks()]).snapshot(credentials: credentials)
        XCTAssertEqual(first.accountID, "123456")
        XCTAssertEqual(first.positions[0].ticker, "0700.HK")
        XCTAssertEqual(first.positions[0].shares, 2.5, "Available quantity is not total ownership")
        XCTAssertEqual(first.positions[0].currency, "HKD")
        XCTAssertEqual(first.positions[0].accountCurrency, "USD")
        XCTAssertEqual(first.positions[0].quotePrice, 120)
        XCTAssertNotNil(first.positions[0].quoteObservedAt)
        let second = try await client(channels: [stocks()]).snapshot(credentials:
            .init(broker: .longbridge, key: "new-key", secret: "new-secret", token: "rotated"))
        XCTAssertEqual(first.accountID, second.accountID)
    }
    func testChannelsAggregateSharesAndWeightedCostsWithoutDuplicatingTheSecurity() async throws {
        let snapshot = try await client(channels: [stocks(quantity: "2", cost: "100"),
            stocks(quantity: "3", cost: "200", channel: "second")]).snapshot(credentials: credentials)
        XCTAssertEqual(snapshot.positions.count, 1)
        XCTAssertEqual(snapshot.positions[0].shares, 5)
        XCTAssertEqual(snapshot.positions[0].averageCost, 160)
    }
    func testMissingCostsShortsUnsupportedBoardsQuoteFailuresAndAPIErrorRejectTheWholeSnapshot() async throws {
        let clients = [client(channels: [stocks(cost: nil)]), client(channels: [stocks(quantity: "-1")]),
                       client(channels: [stocks()], board: "HKWarrant"), client(channels: [stocks()], includeQuote: false),
                       client(channels: [stocks()], quoteCurrency: "USD"), client(channels: [stocks()], code: 401003),
                       client(channels: [stocks(), stocks()])]
        for client in clients {
            do { _ = try await client.snapshot(credentials: credentials); XCTFail("Incomplete snapshot must fail") }
            catch { XCTAssertTrue(error is DirectBrokerError) }
        }
    }
    func testEmptyPositionsAreAValidSyncedAccount() async throws {
        let snapshot = try await client(channels: []).snapshot(credentials: credentials)
        XCTAssertTrue(snapshot.positions.isEmpty)
        XCTAssertFalse(snapshot.portfolioAccount(name: "Longbridge").awaitsFirstSync)
    }
    func testSignedAssetQueryMatchesIndependentHMACVector() {
        let request = credentials.longbridge.signedGET(path: "/v1/asset/account",
            query: [.init(name: "currency", value: "USD")], at: Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(request.url?.query, "currency=USD")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Signature"),
            "HMAC-SHA256 SignedHeaders=authorization;x-api-key;x-timestamp, Signature=ff132985e6db81089475ace0d9fc5b42eb19119e10ae5d276ef61e7d45ed5e29")
    }
    func testListingMappingKeepsUSMainlandAndHongKongDistinct() throws {
        XCTAssertEqual(try LongbridgeAccountClient.ticker(symbol: "BRK.B.US", market: "US", currency: "USD"), "BRK-B")
        XCTAssertEqual(try LongbridgeAccountClient.ticker(symbol: "AAPL.US", market: "US", currency: "USD"), "AAPL")
        XCTAssertEqual(try LongbridgeAccountClient.ticker(symbol: "600519.SH", market: "CN", currency: "CNY"), "600519.SS")
        XCTAssertEqual(try LongbridgeAccountClient.ticker(symbol: "000001.SZ", market: "CN", currency: "CNY"), "000001.SZ")
        XCTAssertThrowsError(try LongbridgeAccountClient.ticker(symbol: "700.HK", market: "HK", currency: "USD"))
        XCTAssertThrowsError(try LongbridgeAccountClient.ticker(symbol: "AAPL.US", market: "US", currency: "JPY"))
    }
}
