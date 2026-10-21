import XCTest
@testable import CatfolioIOS

final class BrokerCredentialPrefillTests: XCTestCase {
    func testTrading212UsesOnlyTheSelectedCompleteSlot() throws {
        let values = [
            "trading212.account-1.api-key": "one", "trading212.account-1.api-secret": "one-secret",
            "trading212.account-2.api-key": "two", "trading212.account-2.api-secret": "two-secret",
            "trading212.account-3.api-key": "incomplete",
        ]
        XCTAssertEqual(BrokerCredentialPrefill.trading212(slot: 2, values: values),
                       try Trading212Credentials(apiKey: "two", apiSecret: "two-secret"))
        XCTAssertNil(BrokerCredentialPrefill.trading212(slot: 3, values: values))
        XCTAssertNil(BrokerCredentialPrefill.trading212(slot: 4, values: values))
        XCTAssertNil(BrokerCredentialPrefill.trading212(slot: 0, values: values))
    }

    func testTrading212RejectsInvalidSavedPairs() {
        XCTAssertNil(BrokerCredentialPrefill.trading212(slot: 1, values: [
            "trading212.account-1.api-key": "bad:key", "trading212.account-1.api-secret": "secret"
        ]))
        XCTAssertNil(BrokerCredentialPrefill.trading212(slot: 1, values: [
            "trading212.account-1.api-key": "key", "trading212.account-1.api-secret": "  "
        ]))
    }

    func testIBKRUsesSingleDistinctBoundPairAndDeduplicatesMultiAccountReport() throws {
        let values = [
            IBKRFlexKeys.token(accountID: "U111"): "123456789", IBKRFlexKeys.queryID(accountID: "U111"): "123",
            IBKRFlexKeys.token(accountID: "U222"): "123456789", IBKRFlexKeys.queryID(accountID: "U222"): "123",
        ]
        XCTAssertEqual(BrokerCredentialPrefill.ibkr(pendingToken: "", pendingQueryID: "", values: values),
                       try IBKRFlexCredentials(token: "123456789", queryID: "123"))
    }

    func testIBKRDoesNotGuessBetweenDifferentConnections() {
        let values = [
            IBKRFlexKeys.token(accountID: "U111"): "123456789", IBKRFlexKeys.queryID(accountID: "U111"): "123",
            IBKRFlexKeys.token(accountID: "U222"): "987654321", IBKRFlexKeys.queryID(accountID: "U222"): "456",
        ]
        XCTAssertNil(BrokerCredentialPrefill.ibkr(pendingToken: "", pendingQueryID: "", values: values))
    }

    func testIBKRPreservesEvenPartialPendingInput() {
        let values = [
            IBKRFlexKeys.token(accountID: "U111"): "123456789", IBKRFlexKeys.queryID(accountID: "U111"): "123"
        ]
        XCTAssertNil(BrokerCredentialPrefill.ibkr(pendingToken: "draft", pendingQueryID: "", values: values))
        XCTAssertNil(BrokerCredentialPrefill.ibkr(pendingToken: "", pendingQueryID: "456", values: values))
    }

    func testIBKRIgnoresDraftsLegacyUnboundAndIncompleteCredentials() {
        let values = [
            IBKRFlexKeys.pendingToken: "123456789", IBKRFlexKeys.pendingQueryID: "123",
            "ibkr.flex.token": "123456789", "ibkr.flex.query-id": "123",
            IBKRFlexKeys.token(accountID: "U111"): "123456789",
            IBKRFlexKeys.token(accountID: "U222"): "invalid", IBKRFlexKeys.queryID(accountID: "U222"): "123",
            IBKRFlexKeys.token(accountID: "bad.account"): "123456789", IBKRFlexKeys.queryID(accountID: "bad.account"): "123"
        ]
        XCTAssertNil(BrokerCredentialPrefill.ibkr(pendingToken: "", pendingQueryID: "", values: values))
    }
}
