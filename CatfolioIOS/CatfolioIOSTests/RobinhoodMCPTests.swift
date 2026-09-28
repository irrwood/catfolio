import XCTest
@testable import CatfolioIOS

final class RobinhoodMCPTests: XCTestCase {
    func testWriteToolIsRejectedBeforeAnyNetworkRequest() async {
        let client = RobinhoodMCPClient()
        do {
            _ = try await client.read("place_equity_order", arguments: [:])
            XCTFail("Write tools must never reach the transport")
        } catch {
            guard case RobinhoodMCPClient.Failure.message(let message) = error else {
                return XCTFail("Unexpected failure: \(error)")
            }
            XCTAssertEqual(message, "Robinhood 仅允许读取数据")
        }
    }

    func testPKCEKnownVectorAndFormEncoding() {
        XCTAssertEqual(RobinhoodMCPClient.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(RobinhoodMCPClient.form(["code": "a+b&c ="]), "code=a%2Bb%26c%20%3D")
    }

    func testCallbackBindsExactRedirectStateAndExpiry() throws {
        let now = Date()
        let pending = RobinhoodMCPClient.Pending(clientID: "client", verifier: "secret", state: "expected", createdAt: now)
        let good = "http://localhost:60356/callback?code=ok&state=expected"
        XCTAssertEqual(try RobinhoodMCPClient.authorizationCode(good, pending: pending, now: now), "ok")
        for bad in [
            good.replacingOccurrences(of: "localhost", with: "evil.test"),
            good.replacingOccurrences(of: "60356", with: "60355"),
            good.replacingOccurrences(of: "expected", with: "wrong"),
            good + "&state=expected", good + "&code=other", good + "&error=denied", good + "#fragment"
        ] {
            XCTAssertThrowsError(try RobinhoodMCPClient.authorizationCode(bad, pending: pending, now: now))
        }
        XCTAssertThrowsError(try RobinhoodMCPClient.authorizationCode(good, pending: pending, now: now.addingTimeInterval(1800)))
    }

    func testSSEMatchesRequestAndRejectsErrors() throws {
        let events = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"one\",\"result\":{\"tools\":[]}}\r\n\r\n"
        let result = try RobinhoodMCPClient.rpcResponse(Data(events.utf8), id: "one")
        XCTAssertNotNil(result["result"])
        XCTAssertThrowsError(try RobinhoodMCPClient.rpcResponse(Data(events.utf8), id: "wrong"))
        XCTAssertThrowsError(try RobinhoodMCPClient.rpcResponse(Data("{\"jsonrpc\":\"2.0\",\"id\":\"one\",\"error\":{}}".utf8), id: "one"))
    }

    func testToolErrorsCannotBecomeData() throws {
        XCTAssertThrowsError(try RobinhoodMCPClient.toolPayload(["result": ["isError": true, "structuredContent": ["price": 1]]]))
        let result = try RobinhoodMCPClient.toolPayload(["result": ["content": [["type": "text", "text": "{\"accounts\":[]}"]]]])
        XCTAssertNotNil((result as? [String: Any])?["accounts"])
        XCTAssertFalse(RobinhoodMCPClient.readTools.contains("place_equity_order"))
        XCTAssertFalse(RobinhoodMCPClient.readTools.contains("cancel_option_order"))
        XCTAssertFalse(RobinhoodMCPClient.readTools.contains("create_watchlist"))
    }

    func testChangedToolSchemaFailsClosed() throws {
        let schema: [String: Any] = ["required": ["symbols"], "properties": ["symbols": ["type": "array", "maxItems": 4]]]
        XCTAssertNoThrow(try RobinhoodMCPClient.validate(["symbols": ["AAPL"]], schema: schema))
        XCTAssertThrowsError(try RobinhoodMCPClient.validate([:], schema: schema))
        XCTAssertThrowsError(try RobinhoodMCPClient.validate(["symbols": "AAPL"], schema: schema))
        XCTAssertThrowsError(try RobinhoodMCPClient.validate(["symbols": []], schema: schema))
        XCTAssertThrowsError(try RobinhoodMCPClient.validate(["symbols": Array(repeating: "AAPL", count: 5)], schema: schema))
        XCTAssertThrowsError(try RobinhoodMCPClient.validate(["symbols": ["AAPL"], "unknown": true], schema: schema))
    }

    func testQuotesRequireCurrencyFreshnessAndRequestedIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let row: [String: Any] = ["symbol": "AAPL", "currency": "USD", "last_trade_price": "123.45",
                                  "updated_at": ISO8601DateFormatter().string(from: now)]
        func parse(_ value: [String: Any]) -> [RobinhoodMCPClient.Quote] {
            RobinhoodMCPClient.parseQuotes(["results": [value]], requested: ["AAPL"], now: now)
        }
        XCTAssertEqual(parse(row).first?.price, 123.45)
        for (key, value) in [("currency", "GBP"), ("symbol", "MSFT"), ("last_trade_price", "nan"),
                             ("last_trade_price", "0"), ("updated_at", "2020-01-01T00:00:00Z")] {
            var invalid = row; invalid[key] = value
            XCTAssertTrue(parse(invalid).isEmpty)
        }
        var missing = row; missing.removeValue(forKey: "updated_at")
        XCTAssertTrue(parse(missing).isEmpty)
        XCTAssertNil(RobinhoodMCPClient.number(true))
        XCTAssertFalse(RobinhoodMCPClient.isUSSymbol("VOD.L"))
        XCTAssertTrue(RobinhoodMCPClient.isUSSymbol("BRK.B"))
    }
}
