import XCTest
@testable import CatfolioIOS

/// Opt-in read-only acceptance. Uses device Keychain credentials and never changes the portfolio.
final class DirectBrokerLiveTests: XCTestCase {
    func testLongbridgeAccountWithSavedDeviceCredentials() async throws {
        guard ProcessInfo.processInfo.environment["CATFOLIO_TEST_BROKER_ACCOUNTS_LIVE"] == "1" else {
            throw XCTSkip("Live account acceptance is opt-in")
        }
        let credentials = try XCTUnwrap(DirectBrokerCredentials.load(broker: .longbridge, accountID: nil),
                                       "Save Longbridge API credentials on this device first")
        let snapshot = try await LongbridgeAccountClient().snapshot(credentials: credentials)
        XCTAssertEqual(snapshot.broker, .longbridge)
        XCTAssertFalse(snapshot.accountID.isEmpty)
        XCTAssertTrue(snapshot.positions.allSatisfy { $0.shares > 0 && $0.quotePrice > 0 && $0.averageCost >= 0 })
        try snapshot.validate(context: .create, existing: [])
    }
}
