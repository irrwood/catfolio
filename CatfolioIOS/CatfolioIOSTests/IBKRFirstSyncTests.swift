import XCTest
@testable import CatfolioIOS

/// The parts of a new IBKR account's first sync that do not need IBKR.
final class IBKRFirstSyncTests: XCTestCase {
    private enum SaveFailure: Error { case denied }

    private func report(_ statements: String) -> Data {
        Data("<FlexQueryResponse><FlexStatements>\(statements)</FlexStatements></FlexQueryResponse>".utf8)
    }

    func testFirstSyncAcceptsAnIdentifiedAccountWithoutAPositionsSection() throws {
        let data = report("""
            <FlexStatement accountId="U123" toDate="20261022">
                <AccountInformation accountId="U123" currency="GBP" accountAlias="Empty account" />
            </FlexStatement>
            """)
        let snapshot = try IBKRFlexClient().parseStatement(data, newAccountExclusions: [])
        XCTAssertTrue(snapshot.positions.isEmpty)
        XCTAssertTrue(snapshot.transactions.isEmpty)
        XCTAssertEqual(snapshot.syncedPositionAccountIDs, ["U123"])
        XCTAssertEqual(snapshot.accountCurrencies, ["U123": "GBP"])
        XCTAssertEqual(snapshot.accountNames, ["U123": "Empty account"])
        XCTAssertEqual(snapshot.reportDate, "20261022")
        XCTAssertEqual(snapshot.restricted(excluding: []).syncedPositionAccountIDs, ["U123"])
        XCTAssertThrowsError(try IBKRFlexClient().parseStatement(data),
            "An ordinary refresh must still reject missing positions data")
    }

    func testFirstSyncAcceptsAStatementWithOnlyAnAccountID() throws {
        let snapshot = try IBKRFlexClient().parseStatement(
            report("<FlexStatement accountId=\"U123\" />"), newAccountExclusions: [])
        XCTAssertEqual(snapshot.syncedPositionAccountIDs, ["U123"])
        XCTAssertTrue(snapshot.positions.isEmpty)
    }

    func testFirstSyncCannotTreatAnExistingAccountAsEmpty() throws {
        let data = report("<FlexStatement accountId=\"OLD\" /><FlexStatement accountId=\"NEW\" />")
        let snapshot = try IBKRFlexClient().parseStatement(data, newAccountExclusions: ["OLD"])
        XCTAssertEqual(snapshot.syncedPositionAccountIDs, ["NEW"])
        XCTAssertThrowsError(try IBKRFlexClient().parseStatement(
            report("<FlexStatement accountId=\"OLD\" />"), newAccountExclusions: ["OLD"]))
    }

    func testFirstSyncSupportsMixedEmptyAndPopulatedAccounts() throws {
        let data = report("""
            <FlexStatement accountId="EMPTY" />
            <FlexStatement accountId="FUNDED"><OpenPositions>
                <OpenPosition accountId="FUNDED" symbol="AAPL" position="2" costBasisPrice="100" levelOfDetail="SUMMARY" />
            </OpenPositions></FlexStatement>
            """)
        let snapshot = try IBKRFlexClient().parseStatement(data, newAccountExclusions: [])
        XCTAssertEqual(snapshot.syncedPositionAccountIDs, ["EMPTY", "FUNDED"])
        XCTAssertEqual(snapshot.positions.map(\.accountID), ["FUNDED"])
        let new = snapshot.restricted(excluding: ["FUNDED"])
        XCTAssertEqual(new.syncedPositionAccountIDs, ["EMPTY"])
        XCTAssertTrue(new.positions.isEmpty)
    }

    func testFirstSyncStillRejectsMalformedUnidentifiedAndLotOnlyReports() {
        let reports = [
            Data("<bad>".utf8),
            report("<FlexStatement />"),
            report("<FlexStatement accountId=\"   \" />"),
            Data("<Other><FlexStatement accountId=\"U123\" /></Other>".utf8),
            report("""
                <FlexStatement accountId="U123"><OpenPositions>
                    <OpenPosition levelOfDetail="LOT" accountId="U123" symbol="AAPL" position="10" />
                </OpenPositions></FlexStatement>
                """)
        ]
        for data in reports {
            XCTAssertThrowsError(try IBKRFlexClient().parseStatement(data, newAccountExclusions: []))
        }
    }

    func testEmptyAccountStaysSyncedAfterSavingAndReloading() async throws {
        let snapshot = try IBKRFlexClient().parseStatement(
            report("<FlexStatement accountId=\"U123\" />"), newAccountExclusions: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ibkr-empty-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalPortfolioStore(fileURL: url)
        let accounts = snapshot.syncedPositionAccountIDs.map { account(id: "IBKR Flex|\($0)", brokerID: $0) }
        _ = try await store.replace(positions: [], source: IBKRFlexKeys.source,
            transactions: [], replacingAccountsOnly: true, syncedAccounts: accounts, mergesTransactionHistory: true)
        let reloaded = try await LocalPortfolioStore(fileURL: url).load()
        let saved = try XCTUnwrap(reloaded.accounts.first)
        XCTAssertEqual(saved.accountID, "U123")
        XCTAssertEqual(saved.positionCount, 0)
        XCTAssertEqual(saved.transactionCount, 0)
        XCTAssertFalse(saved.awaitsFirstSync)
    }

    func testOnlyIBKRPlaceholderAwaitsItsFirstSync() {
        XCTAssertTrue(account(id: IBKRFlexKeys.pendingAccountID, brokerID: nil).awaitsFirstSync)
        XCTAssertFalse(account(id: "IBKR Flex|U123", brokerID: "U123").awaitsFirstSync)
    }

    private func account(id: String, brokerID: String?) -> PortfolioAccount {
        PortfolioAccount(id: id, accountID: brokerID, source: IBKRFlexKeys.source, name: "IBKR",
            baseCurrency: "USD", positionCount: 0, transactionCount: 0,
            manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0)
    }

    func testSavingExistingAccountUsesItsKeysAndTrimmedCredentials() throws {
        let credentials = try IBKRFlexCredentials(token: " 123456 ", queryID: " 789 ")
        var saved: [String: String] = [:]
        try IBKRFlexKeys.save(credentials, accountID: "U123") { saved[$1] = $0 }
        XCTAssertEqual(saved, ["ibkr.flex.account.U123.token": "123456",
                               "ibkr.flex.account.U123.query-id": "789"])
    }

    func testSavingBeforeFirstSyncUsesPendingKeys() throws {
        let credentials = try IBKRFlexCredentials(token: "123456", queryID: "789")
        var saved: [String: String] = [:]
        try IBKRFlexKeys.save(credentials, accountID: nil) { saved[$1] = $0 }
        XCTAssertEqual(saved, [IBKRFlexKeys.pendingToken: "123456",
                               IBKRFlexKeys.pendingQueryID: "789"])
    }

    func testTokenWriteFailureStopsSaveAndPropagates() throws {
        let credentials = try IBKRFlexCredentials(token: "123456", queryID: "789")
        var attemptedKeys: [String] = []
        XCTAssertThrowsError(try IBKRFlexKeys.save(credentials, accountID: "U123") { _, key in
            attemptedKeys.append(key)
            throw SaveFailure.denied
        }) { XCTAssertTrue($0 is SaveFailure) }
        XCTAssertEqual(attemptedKeys, [IBKRFlexKeys.token(accountID: "U123")])
    }

    func testQueryWriteFailureCannotReportSuccessfulPendingSave() throws {
        let credentials = try IBKRFlexCredentials(token: "123456", queryID: "789")
        var attemptedKeys: [String] = []
        XCTAssertThrowsError(try IBKRFlexKeys.save(credentials, accountID: nil) { _, key in
            attemptedKeys.append(key)
            if key == IBKRFlexKeys.pendingQueryID { throw SaveFailure.denied }
        }) { XCTAssertTrue($0 is SaveFailure) }
        XCTAssertEqual(attemptedKeys, [IBKRFlexKeys.pendingToken, IBKRFlexKeys.pendingQueryID])
    }
    private func position(_ account: String, _ symbol: String) -> IBKRFlexPosition {
        IBKRFlexPosition(accountID: account, symbol: symbol, name: symbol, currency: "USD", assetCategory: "STK",
                         quantity: 1, markPrice: 10, marketValue: 10, averageCost: 8, costBasis: 8,
                         reportDate: nil, openDate: nil)
    }

    private func trade(_ account: String, _ id: String) -> IBKRFlexTransaction {
        IBKRFlexTransaction(accountID: account, tradeID: id, symbol: "AAPL", name: "Apple", currency: "USD",
                            side: "BUY", quantity: 1, price: 10, tradeDate: "2026-01-02",
                            fxRateToBase: 1, realisedProfitLoss: nil)
    }

    /// A report covering an account already in Catfolio and a new one: the
    /// first sync takes only the new one, whole.
    func testTheFirstSyncLeavesExistingAccountsOut() {
        let report = IBKRFlexSnapshot(
            positions: [position("U1", "AAPL"), position("U2", "NVDA")],
            transactions: [trade("U1", "t1"), trade("U2", "t2")],
            accountCurrencies: ["U1": "USD", "U2": "GBP"],
            accountNames: ["U1": "Old", "U2": "New"],
            reportDate: "2026-09-18",
            positionAccountIDs: ["U1", "U2"]
        )
        let new = report.restricted(excluding: ["U1"])
        XCTAssertEqual(new.positions.map(\.accountID), ["U2"])
        XCTAssertEqual(new.transactions.map(\.accountID), ["U2"])
        XCTAssertEqual(new.accountCurrencies, ["U2": "GBP"])
        XCTAssertEqual(new.accountNames, ["U2": "New"])
        XCTAssertEqual(new.syncedPositionAccountIDs, ["U2"])
        XCTAssertEqual(new.reportDate, "2026-09-18")
    }

    /// Credentials already saved on people's phones are read back under these
    /// names; moving the keys into one place must not rename them.
    func testKeychainKeysKeepTheirNames() {
        XCTAssertEqual(IBKRFlexKeys.token(accountID: "U123"), "ibkr.flex.account.U123.token")
        XCTAssertEqual(IBKRFlexKeys.queryID(accountID: "U123"), "ibkr.flex.account.U123.query-id")
        XCTAssertEqual(IBKRFlexKeys.pendingToken, "ibkr.flex.pending.token")
        XCTAssertEqual(IBKRFlexKeys.pendingQueryID, "ibkr.flex.pending.query-id")
        XCTAssertEqual(IBKRFlexKeys.pendingAccountID, "ibkr-flex-pending")
    }
}
