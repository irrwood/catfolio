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

    /// Positions are a photograph, not a log. Merging two devices' position
    /// lists would invent a portfolio neither device holds.
    func testPositionsComeFromTheNewerDocumentWhole() throws {
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
