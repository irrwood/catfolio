import XCTest
@testable import CatfolioIOS

/// Uses only the credentials already saved by the user on the test device.
/// No credential values are attached, logged or passed through launch arguments.
final class LongbridgeLiveTests: XCTestCase {
    func testDeviceCredentialsReadShanghaiShenzhenAndETF() async throws {
        guard ProcessInfo.processInfo.environment["CATFOLIO_TEST_LONGBRIDGE_LIVE"] == "1" else {
            throw XCTSkip("Longbridge production acceptance is opt-in")
        }
        guard let credentials = LongbridgeCredentials.stored else {
            XCTFail("Longbridge credentials are not saved on this device. Save them in Settings → Providers → China A-share data.")
            return
        }
        let client = LongbridgeMarketDataClient(credentials: credentials)
        for symbol in ["600519.SH", "000001.SZ", "510300.SH"] {
            let security = try XCTUnwrap(ChinaSecurity(symbol))
            let quote = try await client.quote(security)
            XCTAssertGreaterThan(quote.price, 0, symbol)
            XCTAssertGreaterThan(quote.previousClose, 0, symbol)
            let bars = try await client.daily(security,
                from: ChinaSecurity.day(Date().addingTimeInterval(-60 * 86400)),
                to: ChinaSecurity.day(.now), adjusted: false)
            XCTAssertGreaterThan(bars.count, 2, symbol)
            let minutes = try await client.intraday(security)
            XCTAssertFalse(minutes.isEmpty, symbol)
            XCTAssertTrue(minutes.allSatisfy { $0.close > 0 && $0.timestamp <= .now.addingTimeInterval(60) })
        }
    }
}
