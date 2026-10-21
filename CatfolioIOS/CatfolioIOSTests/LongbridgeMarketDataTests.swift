import XCTest
@testable import CatfolioIOS

final class LongbridgeMarketDataTests: XCTestCase {
    private let security = ChinaSecurity("600519.SH")!
    func testSignatureMatchesIndependentOfficialSDKVector() {
        let credentials = LongbridgeCredentials(appKey: "key", appSecret: "secret", accessToken: "token")
        let request = credentials.tokenRequest(at: .init(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Timestamp"), "1700000000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Signature"),
            "HMAC-SHA256 SignedHeaders=authorization;x-api-key;x-timestamp, Signature=75f687d31f68344e3eae5a6d987c587c778ffbfe51e11c9ac491bb4164a953ec")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "App-Secret"))
    }
    func testPacketFramingGzipAndTruncation() throws {
        XCTAssertEqual(Array(LongbridgePacket.request(command: 11, id: 42, body: Data([10, 2, 111, 107]))),
                       [1, 11, 0, 0, 0, 42, 39, 16, 0, 0, 4, 10, 2, 111, 107])
        let compressed = Data(base64Encoded: "H4sIAAAAAAAC/+Niys8GAK4keHUEAAAA")!
        let wire = Data([34, 11, 0, 0, 0, 42, 0]) + LongbridgePacket.bigEndian(UInt32(compressed.count), count: 3) + compressed
        let packet = try LongbridgePacket.decode(wire)
        XCTAssertEqual(packet.requestID, 42)
        XCTAssertEqual(try LongbridgeProto(packet.body).string(1), "ok")
        XCTAssertThrowsError(try LongbridgePacket.decode(wire.dropLast()))
        XCTAssertThrowsError(try LongbridgeProto(Data([10, 100, 1])))
        XCTAssertThrowsError(try LongbridgeProto(Data(repeating: 255, count: 11)))
    }
    func testQuoteValidatesIdentityPriceAndProviderTimestamp() throws {
        let row = LongbridgeProto.string(1, "600519.SH") + LongbridgeProto.string(2, "100.5")
            + LongbridgeProto.string(3, "100") + LongbridgeProto.integer(7, 1700000000)
        let wire = LongbridgeProto.bytes(1, row)
        let quote = try LongbridgeMarketDataClient.parseQuote(wire, security: security)
        XCTAssertEqual(quote.price, 100.5)
        XCTAssertEqual(quote.changePercent, 0.5, accuracy: 0.00001)
        XCTAssertEqual(quote.observedAt.timeIntervalSince1970, 1700000000)
        XCTAssertThrowsError(try LongbridgeMarketDataClient.parseQuote(wire, security: ChinaSecurity("000001.SZ")!))
        XCTAssertThrowsError(try LongbridgeMarketDataClient.parseQuote(wire, security: security,
            now: Date(timeIntervalSince1970: 1600000000)))
    }
    func testDailyRequestUsesRawAndForwardAdjustmentSeparately() async throws {
        let security = security
        let client = LongbridgeMarketDataClient { command, request in
            XCTAssertEqual(command, 27)
            let input = try LongbridgeProto(request)
            XCTAssertEqual(input.string(1), "600519.SH")
            XCTAssertEqual(input.integer(2), 1000)
            XCTAssertEqual(input.integer(4), 1)
            let offset = try XCTUnwrap(input.messages(5).first)
            XCTAssertEqual(offset.integer(4), 1000)
            XCTAssertEqual(offset.string(2), "20261009")
            let price = input.integer(3) == 0 ? "100" : "90"
            let bar = LongbridgeProto.string(1, price) + LongbridgeProto.string(3, "80")
                + LongbridgeProto.string(4, "110") + LongbridgeProto.integer(5, 1234)
                + LongbridgeProto.integer(7, UInt64(ChinaSecurity.date("2026-10-08")!.timeIntervalSince1970))
            return LongbridgeProto.string(1, security.longbridgeSymbol) + LongbridgeProto.bytes(2, bar)
        }
        let raw = try await client.daily(security, from: "2026-10-01", to: "2026-10-09", adjusted: false)
        let forward = try await client.daily(security, from: "2026-10-01", to: "2026-10-09", adjusted: true)
        XCTAssertEqual(raw[0].close, 100)
        XCTAssertEqual(forward[0].close, 90)
        XCTAssertEqual(raw[0].volume, 1234, "Longbridge volume is already in shares")
    }

    func testHistoryPagesBeyondOneThousandBarsWithoutRepeatingBoundary() async throws {
        let end = ChinaSecurity.date("2026-10-09")!
        let oldest = end.addingTimeInterval(-1000 * 86400)
        let probe = LongbridgePagingProbe(end: end)
        let client = LongbridgeMarketDataClient { command, request in
            XCTAssertEqual(command, 27)
            return try await probe.respond(request)
        }
        let bars = try await client.daily(security, from: ChinaSecurity.day(oldest), to: "2026-10-09", adjusted: false)
        XCTAssertEqual(bars.count, 1001)
        XCTAssertEqual(bars.first?.date, ChinaSecurity.day(oldest))
        let cursors = await probe.cursors
        XCTAssertEqual(cursors, ["20261009", ChinaSecurity.day(oldest).replacingOccurrences(of: "-", with: "")])
    }
}

private actor LongbridgePagingProbe {
    let end: Date
    var cursors: [String] = []
    init(end: Date) { self.end = end }
    func respond(_ request: Data) throws -> Data {
        let query = try LongbridgeProto(request)
        let offset = try XCTUnwrap(query.messages(5).first)
        cursors.append(try XCTUnwrap(offset.string(2)))
        let days = cursors.count == 1 ? Array(0..<1000) : [1000]
        var body = LongbridgeProto.string(1, "600519.SH")
        for day in days {
            let timestamp = UInt64(end.addingTimeInterval(-Double(day) * 86400).timeIntervalSince1970)
            let bar = LongbridgeProto.string(1, "100") + LongbridgeProto.string(3, "95")
                + LongbridgeProto.string(4, "105") + LongbridgeProto.integer(5, 100)
                + LongbridgeProto.integer(7, timestamp)
            body += LongbridgeProto.bytes(2, bar)
        }
        return body
    }
}
