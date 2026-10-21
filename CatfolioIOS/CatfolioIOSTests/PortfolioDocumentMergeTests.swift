import XCTest
@testable import CatfolioIOS

/// Combining two devices' copies of the portfolio document.
final class PortfolioDocumentMergeTests: XCTestCase {

    private func tx(_ ticker: String, _ date: String, _ qty: Double, tradeID: String? = nil)
        -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date, action: "BUY", ticker: ticker, quantity: qty,
            price: 10, currency: "GBP", source: "test",
            accountID: "account-1", accountName: "Test", tradeID: tradeID
        )
    }

    private func doc(
        updatedAt: Date,
        transactions: [LocalTransactionRecord] = [],
        positions: [LocalPositionRecord] = [],
        snapshots: [LocalPortfolioSnapshotRecord] = [],
        source: String = "Trading 212"
    ) -> LocalPortfolioDocument {
        LocalPortfolioDocument(
            source: source, updatedAt: updatedAt,
            positions: positions, snapshots: snapshots, transactions: transactions
        )
    }

    private func position(ticker: String) -> LocalPositionRecord {
        LocalPositionRecord(
            ticker: ticker, name: ticker, shares: 1, averageCost: 1, currency: "GBP",
            quotePrice: 1, quoteCurrency: "GBP", source: "test", openedDate: nil,
            accountID: "account-1", accountName: "Test"
        )
    }

    private let earlier = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    /// The failure this whole design exists to prevent. A device that has not
    /// refreshed recently must not be able to delete transactions the other
    /// device already recorded — losing one is invisible afterwards.
    func testTransactionsAreUnionedNeverReplaced() throws {
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(
            local: doc(updatedAt: later, transactions: [tx("AAA", "2026-01-02", 5, tradeID: "a")]),
            remote: doc(updatedAt: earlier, transactions: [tx("BBB", "2026-01-01", 3, tradeID: "b")])
        ))
        XCTAssertEqual(merged.transactions?.count, 2)
        XCTAssertEqual(merged.transactions?.map(\.ticker), ["BBB", "AAA"], "sorted by date")
    }

    /// The same works when the stale device is the local one.
    func testDirectionDoesNotMatterForTransactions() throws {
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(
            local: doc(updatedAt: earlier, transactions: [tx("BBB", "2026-01-01", 3, tradeID: "b")]),
            remote: doc(updatedAt: later, transactions: [tx("AAA", "2026-01-02", 5, tradeID: "a")])
        ))
        XCTAssertEqual(merged.transactions?.count, 2)
    }

    /// One trade seen by both devices is one row, not two.
    func testTheSameTransactionFromBothDevicesIsNotDuplicated() throws {
        let shared = tx("AAA", "2026-01-02", 5, tradeID: "same")
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(
            local: doc(updatedAt: later, transactions: [shared]),
            remote: doc(updatedAt: earlier, transactions: [shared])
        ))
        XCTAssertEqual(merged.transactions?.count, 1)
    }

    /// A broker can restate a fill, so where both hold the same id the later
    /// read wins rather than the arbitrary one.
    func testTheNewerCopyOfARestatedFillWins() throws {
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(
            local: doc(updatedAt: later, transactions: [tx("AAA", "2026-01-02", 7, tradeID: "same")]),
            remote: doc(updatedAt: earlier, transactions: [tx("AAA", "2026-01-02", 5, tradeID: "same")])
        ))
        XCTAssertEqual(merged.transactions?.count, 1)
        XCTAssertEqual(merged.transactions?.first?.quantity, 7)
    }

    /// One account's holdings are a complete snapshot. Its obsolete holdings
    /// must not remain alongside its new holdings after a merge.
    func testSameAccountPositionsComeFromItsNewerSnapshot() throws {
        let stale = position(ticker: "OLD")
        let fresh = position(ticker: "NEW")
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(
            local: doc(updatedAt: earlier, positions: [stale]),
            remote: doc(updatedAt: later, positions: [fresh])
        ))
        XCTAssertEqual(merged.positions.map { $0.ticker }, ["NEW"],
                       "positions must not be unioned")
    }

    func testUpdatedAtTakesTheLater() throws {
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(
            local: doc(updatedAt: earlier), remote: doc(updatedAt: later)
        ))
        XCTAssertEqual(merged.updatedAt, later)
    }

    /// Two shapes this build does not know how to combine are left alone
    /// rather than mixed.
    func testMismatchedSchemasAreRefused() {
        var old = doc(updatedAt: later)
        old.schemaVersion = 99
        XCTAssertNil(PortfolioDocumentMerge.merge(local: doc(updatedAt: earlier), remote: old))
    }

    // MARK: - What must never be uploaded

    /// Demo portfolios are generated in memory and never written to the
    /// store, so they should never reach the uploader. Checked anyway,
    /// because the cost of being wrong is replacing a real portfolio on
    /// another device with invented numbers.
    func testDemoAndInvestorDocumentsAreNotUploadable() {
        for source in ["demo", "Demo Accounts", "fake", "investor-simulation", "Public Investor"] {
            XCTAssertFalse(
                PortfolioDocumentMerge.isUploadable(doc(updatedAt: later, source: source)),
                source
            )
        }
    }

    /// The structural guarantee behind that: the generators build documents
    /// in memory and the persisted store never holds one.
    func testTheGeneratedDemoPortfolioIsNotUploadable() {
        XCTAssertFalse(PortfolioDocumentMerge.isUploadable(FakePortfolioGenerator.make()))
    }

    /// A public-investor document is recognisable by its positions carrying a
    /// disclosure rather than a real holding, whatever its source says.
    func testAPositionWithAPublicDisclosureBlocksUpload() {
        var disclosed = position(ticker: "AAPL")
        disclosed.publicDisclosure = PublicAccountDisclosure(
            value: 1, low: nil, high: nil, currency: "USD",
            reportDates: [], filedDates: [], sourceURLs: [],
            underlyingTicker: nil, instrumentLabel: nil, owners: []
        )
        XCTAssertFalse(PortfolioDocumentMerge.isUploadable(
            doc(updatedAt: later, positions: [disclosed], source: "Trading 212")
        ))
    }

    func testARealBrokerDocumentIsUploadable() {
        XCTAssertTrue(PortfolioDocumentMerge.isUploadable(
            doc(updatedAt: later, transactions: [tx("AAA", "2026-01-02", 5)], source: "Trading 212")
        ))
    }
}

extension PortfolioDocumentMergeTests {
    func testEmptyNewDeviceAcceptsCurrentSchema() throws {
        var current = doc(updatedAt: later, positions: [position(ticker: "AAA")])
        current.schemaVersion = 4
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(local: .empty, remote: current))
        XCTAssertEqual(merged.schemaVersion, 4)
        XCTAssertEqual(merged.positions.map(\.ticker), ["AAA"])
    }

    func testDifferentAccountsKeepTheirOwnLatestPositionsAndSnapshots() throws {
        let first = position(ticker: "AAA")
        let second = position(ticker: "BBB").assignedAccount(id: "account-2", name: "Second")
        let local = doc(updatedAt: later, positions: [first], snapshots: [
            LocalPortfolioSnapshotRecord(date: "2026-01-01", marketValueUSD: 20, costUSD: 10,
                accountTotals: [first.accountKey: LocalAccountSnapshotTotals(marketValueUSD: 20, costUSD: 10)])
        ])
        let remote = doc(updatedAt: earlier, positions: [second], snapshots: [
            LocalPortfolioSnapshotRecord(date: "2026-01-01", marketValueUSD: 30, costUSD: 15,
                accountTotals: [second.accountKey: LocalAccountSnapshotTotals(marketValueUSD: 30, costUSD: 15)])
        ])
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(local: local, remote: remote))
        XCTAssertEqual(Set(merged.positions.map(\.ticker)), ["AAA", "BBB"])
        XCTAssertEqual(merged.snapshots.first?.marketValueUSD, 50)
        XCTAssertEqual(merged.snapshots.first?.accountTotals?.count, 2)
    }

    func testUnrelatedAccountRefreshDoesNotOverwriteNewerHoldings() throws {
        let accountOne = position(ticker: "OLD")
        let accountTwo = position(ticker: "SECOND").assignedAccount(id: "account-2", name: "Second")
        let original = PortfolioDocumentMerge.normalized(doc(updatedAt: earlier, positions: [accountOne, accountTwo]))
        var local = original
        local.positions[1] = position(ticker: "SECOND-NEW").assignedAccount(id: "account-2", name: "Second")
        local.updatedAt = later.addingTimeInterval(10)
        local = PortfolioDocumentMerge.recordingChanges(from: original, to: local, at: local.updatedAt)
        var remote = original
        remote.positions[0] = position(ticker: "FIRST-NEW")
        remote.updatedAt = later
        remote = PortfolioDocumentMerge.recordingChanges(from: original, to: remote, at: later)
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(local: local, remote: remote))
        XCTAssertEqual(Set(merged.positions.map(\.ticker)), ["FIRST-NEW", "SECOND-NEW"])
    }

    func testDeletedAccountAndTransactionsDoNotReturnFromStaleDevice() throws {
        let original = PortfolioDocumentMerge.normalized(doc(updatedAt: earlier,
            transactions: [tx("AAA", "2026-01-02", 1)], positions: [position(ticker: "AAA")]))
        var deleted = doc(updatedAt: later)
        deleted = PortfolioDocumentMerge.recordingChanges(from: original, to: deleted, at: later)
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(local: deleted, remote: original))
        XCTAssertTrue(merged.positions.isEmpty)
        XCTAssertTrue(merged.accounts.isEmpty)
        XCTAssertTrue(merged.transactions?.isEmpty == true)
        XCTAssertEqual(merged.syncMetadata?.deletedAccounts["test|account-1"], later.timeIntervalSince1970)
    }

    func testExplicitTransactionRemovalWinsButUnrelatedTransactionsRemain() throws {
        let first = tx("AAA", "2026-01-01", 1, tradeID: "a")
        let second = tx("BBB", "2026-01-02", 2, tradeID: "b")
        let original = PortfolioDocumentMerge.normalized(doc(updatedAt: earlier,
            transactions: [first, second], positions: [position(ticker: "AAA")]))
        var local = original
        local.transactions = [second]
        local.updatedAt = later
        local = PortfolioDocumentMerge.recordingChanges(from: original, to: local, at: later)
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(local: local, remote: original))
        XCTAssertEqual(merged.transactions?.map(\.id), [second.id])
    }

    func testResetAlsoRemovesAccountsOnlyKnownToOtherDevice() throws {
        var reset = doc(updatedAt: later)
        reset.syncMetadata = LocalPortfolioSyncMetadata(resetAt: later.timeIntervalSince1970)
        let remote = doc(updatedAt: earlier, positions: [position(ticker: "UNKNOWN")])
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(local: reset, remote: remote))
        XCTAssertTrue(merged.positions.isEmpty)
        XCTAssertTrue(merged.accounts.isEmpty)
    }

    func testEqualTimeConflictsConvergeAndRepeatedMergeIsIdempotent() throws {
        let local = doc(updatedAt: later, transactions: [tx("AAA", "2026-01-01", 1, tradeID: "same")],
            positions: [position(ticker: "AAA")])
        let remote = doc(updatedAt: later, transactions: [tx("AAA", "2026-01-01", 2, tradeID: "same")],
            positions: [position(ticker: "BBB")])
        let forward = try XCTUnwrap(PortfolioDocumentMerge.merge(local: local, remote: remote))
        let reverse = try XCTUnwrap(PortfolioDocumentMerge.merge(local: remote, remote: local))
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(PortfolioDocumentMerge.merge(local: forward, remote: reverse), forward)
        XCTAssertEqual(PortfolioDocumentMerge.merge(local: forward, remote: local), forward)
    }

    func testSyntheticDocumentsCannotEnterMergeEitherDirection() {
        let fake = FakePortfolioGenerator.make()
        let real = doc(updatedAt: later, positions: [position(ticker: "AAA")])
        XCTAssertNil(PortfolioDocumentMerge.merge(local: real, remote: fake))
        XCTAssertNil(PortfolioDocumentMerge.merge(local: fake, remote: real))
    }

    func testNewerAccountRenameSurvivesIndependentHoldingsRefresh() throws {
        let original = PortfolioDocumentMerge.normalized(doc(updatedAt: earlier,
            transactions: [tx("AAA", "2026-01-01", 1)], positions: [position(ticker: "AAA")]))
        var renamed = original
        renamed.positions = renamed.positions.map { $0.renamedAccount(to: "My account") }
        renamed.transactions = renamed.transactions?.map { $0.renamedAccount(to: "My account") }
        renamed.updatedAt = later
        renamed = PortfolioDocumentMerge.recordingChanges(from: original, to: renamed, at: later)
        var refreshed = original
        refreshed.positions = [position(ticker: "BBB")]
        refreshed.updatedAt = later.addingTimeInterval(10)
        refreshed = PortfolioDocumentMerge.recordingChanges(from: original, to: refreshed, at: refreshed.updatedAt)
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(local: renamed, remote: refreshed))
        XCTAssertEqual(merged.positions.first?.ticker, "BBB")
        XCTAssertEqual(merged.positions.first?.resolvedAccountName, "My account")
        XCTAssertEqual(merged.transactions?.first?.accountName, "My account")
    }
}

extension PortfolioDocumentMergeTests {
    func testLegacyAggregateHistorySurvivesMultiAccountSync() throws {
        let first = position(ticker: "AAA")
        let second = position(ticker: "BBB").assignedAccount(id: "account-2", name: "Second")
        let legacy = LocalPortfolioSnapshotRecord(date: "2026-01-01", marketValueUSD: 123, costUSD: 100)
        let local = doc(updatedAt: earlier, positions: [first, second], snapshots: [legacy])
        let remote = doc(updatedAt: later, positions: [first])
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(local: local, remote: remote))
        XCTAssertEqual(merged.snapshots, [legacy])
        XCTAssertEqual(PortfolioDocumentMerge.merge(local: merged, remote: local), merged)
    }

    func testLocalReimportAfterFutureDatedResetHasNewerClocks() throws {
        var reset = doc(updatedAt: later.addingTimeInterval(86_400))
        reset.syncMetadata = LocalPortfolioSyncMetadata(resetAt: reset.updatedAt.timeIntervalSince1970)
        var imported = reset
        imported.positions = [position(ticker: "AAA")]
        imported.updatedAt = earlier
        imported = PortfolioDocumentMerge.recordingChanges(from: reset, to: imported, at: earlier)
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(local: imported, remote: reset))
        XCTAssertEqual(merged.positions.map(\.ticker), ["AAA"])
        XCTAssertGreaterThan(try XCTUnwrap(merged.syncMetadata?.positionsUpdatedAt["test|account-1"]),
            try XCTUnwrap(reset.syncMetadata?.resetAt))
    }

    func testContradictoryAccountBindingsBlockGenericMerge() {
        var first = doc(updatedAt: earlier, positions: [position(ticker: "AAA")])
        first.syncMetadata = LocalPortfolioSyncMetadata(accountBindings: ["test|account-1": "first"])
        var second = first
        second.syncMetadata?.accountBindings = ["test|account-1": "second"]
        XCTAssertNil(PortfolioDocumentMerge.merge(local: first, remote: second))
    }
}

extension PortfolioDocumentMergeTests {
    private func reportedSale(result: Double?, currency: String?) -> LocalTransactionRecord {
        LocalTransactionRecord(date: "2026-01-02", action: "SELL", ticker: "AAA", quantity: 2,
            price: 20, currency: "USD", source: "test", accountID: "account-1", accountName: "Test",
            tradeID: "sale", realisedProfitLoss: result, realisedProfitLossCurrency: currency)
    }

    func testNewerPartialBrokerRecordPreservesKnownResultAndCurrency() throws {
        let earlierReport = reportedSale(result: 7.25, currency: "GBP")
        let partialRefresh = reportedSale(result: nil, currency: nil)
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(
            local: doc(updatedAt: earlier, transactions: [earlierReport]),
            remote: doc(updatedAt: later, transactions: [partialRefresh])
        ))
        XCTAssertEqual(merged.transactions?.first?.realisedProfitLoss, 7.25)
        XCTAssertEqual(merged.transactions?.first?.realisedProfitLossCurrency, "GBP")
        XCTAssertEqual(PortfolioDocumentMerge.merge(local: merged,
            remote: doc(updatedAt: later, transactions: [partialRefresh])), merged)
    }

    func testNewerAuthoritativeBrokerCorrectionWins() throws {
        let merged = try XCTUnwrap(PortfolioDocumentMerge.merge(
            local: doc(updatedAt: later, transactions: [reportedSale(result: -3.5, currency: "USD")]),
            remote: doc(updatedAt: earlier, transactions: [reportedSale(result: 7.25, currency: "GBP")])
        ))
        XCTAssertEqual(merged.transactions?.first?.realisedProfitLoss, -3.5)
        XCTAssertEqual(merged.transactions?.first?.realisedProfitLossCurrency, "USD")
    }
}
