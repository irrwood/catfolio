import XCTest
@testable import CatfolioIOS

/// Whether the ledger adds up to the holdings it claims to explain.
final class LedgerReconciliationTests: XCTestCase {

    private func tx(_ action: String, _ ticker: String, _ qty: Double, _ date: String = "2024-01-10")
        -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: date, action: action, ticker: ticker, quantity: qty,
            price: 10, currency: "GBP", source: "test", accountID: nil, accountName: nil
        )
    }

    func testACompleteLedgerReconciles() {
        let report = LedgerReconciliation.report(
            transactions: [tx("BUY", "AAA", 100), tx("SELL", "AAA", 40)],
            holdings: [(ticker: "AAA", shares: 60)]
        )
        XCTAssertTrue(report.reconciles)
        XCTAssertEqual(report.securities, 1)
        XCTAssertEqual(report.transactionCount, 2)
    }

    /// The shape this app's own ledger was in: purchases only, nothing held.
    /// Every row is well formed and the total is nonsense.
    func testMissingDisposalsAreCaught() {
        let report = LedgerReconciliation.report(
            transactions: [tx("BUY", "AAA", 100)],
            holdings: [(ticker: "AAA", shares: 0)]
        )
        XCTAssertFalse(report.reconciles)
        XCTAssertTrue(report.hasUnexplainedDisposals)
        XCTAssertFalse(report.hasUnexplainedHoldings)
        XCTAssertEqual(report.fullyDisposed, 1)
    }

    /// Held but never bought reads differently even though the remedy is the
    /// same — a transfer in, or an acquisition the sync missed.
    func testMissingAcquisitionsReadTheOtherWay() {
        let report = LedgerReconciliation.report(
            transactions: [],
            holdings: [(ticker: "AAA", shares: 25)]
        )
        XCTAssertTrue(report.hasUnexplainedHoldings)
        XCTAssertFalse(report.hasUnexplainedDisposals)
        XCTAssertEqual(report.fullyDisposed, 0)
    }

    /// One security in two accounts is one history. Comparing per account
    /// would report a mismatch on every cross-account holding.
    func testHoldingsAreSummedAcrossAccounts() {
        let report = LedgerReconciliation.report(
            transactions: [tx("BUY", "AAA", 100)],
            holdings: [(ticker: "AAA", shares: 40), (ticker: "AAA", shares: 60)]
        )
        XCTAssertTrue(report.reconciles)
    }

    /// Only trades move shares. A dividend in the ledger is not a purchase.
    func testNonTradeRowsAreIgnored() {
        let report = LedgerReconciliation.report(
            transactions: [tx("BUY", "AAA", 100), tx("DIVIDEND", "AAA", 1), tx("INTEREST", "CASH", 1)],
            holdings: [(ticker: "AAA", shares: 100)]
        )
        XCTAssertTrue(report.reconciles)
    }

    /// A split recorded at the old basis is not a discrepancy. Without
    /// normalising, every security that ever split would be reported broken.
    func testSplitsAreNormalisedBeforeComparing() throws {
        let splits = try StockSplitCatalog.bundled.get()
        let report = LedgerReconciliation.report(
            transactions: [LocalTransactionRecord(
                date: "2024-01-10", action: "BUY", ticker: "NVDA", quantity: 10,
                price: 500, currency: "USD", source: "test", accountID: nil, accountName: nil
            )],
            // The 2024 ten-for-one makes those ten shares a hundred today.
            holdings: [(ticker: "NVDA", shares: 100)],
            splits: splits
        )
        XCTAssertTrue(report.reconciles, "the split was treated as a discrepancy")
    }

    /// Fractional shares are ordinary, so the comparison is relative — but
    /// not so loose that a real disposal slips through.
    func testToleratesRoundingButNotARealDisposal() {
        XCTAssertTrue(LedgerReconciliation.report(
            transactions: [tx("BUY", "AAA", 33.0386)],
            holdings: [(ticker: "AAA", shares: 33.03860001)]
        ).reconciles)
        XCTAssertFalse(LedgerReconciliation.report(
            transactions: [tx("BUY", "AAA", 33.0386)],
            holdings: [(ticker: "AAA", shares: 33.0)]
        ).reconciles)
    }

    /// Worst offenders first, so a summary can name one without ranking by
    /// something arbitrary.
    func testMismatchesAreOrderedBySize() {
        let report = LedgerReconciliation.report(
            transactions: [tx("BUY", "SMALL", 10), tx("BUY", "BIG", 500)],
            holdings: []
        )
        XCTAssertEqual(report.mismatches.first?.ticker, "BIG")
    }

    func testAnEmptyLedgerReconcilesTrivially() {
        let report = LedgerReconciliation.report(transactions: [], holdings: [])
        XCTAssertTrue(report.reconciles)
        XCTAssertEqual(report.securities, 0)
    }
}
