import XCTest
@testable import CatfolioIOS

/// `LocalPortfolioDocument.accounts` derives its per-account counts from the
/// grouping it already builds.
///
/// It used to re-scan the whole transaction array three times for every account
/// (`transactionCount`, `manualTransactionCount`, `hasCSVImport`), which made the
/// property O(accounts x ledger) — and `HistoryView` reads it several times per
/// body pass. These pin the counts so the grouped rewrite cannot drift.
final class PortfolioAccountAggregationTests: XCTestCase {

    private func position(source: String, accountID: String?) -> LocalPositionRecord {
        LocalPositionRecord(
            ticker: "AAA", name: "AAA", shares: 1, averageCost: 10, currency: "USD",
            quotePrice: 10, quoteCurrency: "USD", source: source, openedDate: nil,
            accountID: accountID, accountName: "acct \(accountID ?? "default")",
            accountCurrency: "USD"
        )
    }

    private func transaction(
        source: String, accountID: String?, entryMethod: String?
    ) -> LocalTransactionRecord {
        LocalTransactionRecord(
            date: "2024-01-10", action: "BUY", ticker: "AAA", quantity: 1, price: 10,
            currency: "USD", source: source, accountID: accountID, accountName: nil,
            entryMethod: entryMethod
        )
    }

    private func document(
        positions: [LocalPositionRecord],
        transactions: [LocalTransactionRecord]?
    ) -> LocalPortfolioDocument {
        LocalPortfolioDocument(
            source: "test", updatedAt: .distantPast,
            positions: positions, snapshots: [], transactions: transactions
        )
    }

    func testCountsAreScopedToTheirOwnAccount() {
        let doc = document(
            positions: [position(source: "A", accountID: "1"), position(source: "B", accountID: "2")],
            transactions: [
                transaction(source: "A", accountID: "1", entryMethod: "manual"),
                transaction(source: "A", accountID: "1", entryMethod: "csv"),
                transaction(source: "A", accountID: "1", entryMethod: nil),
                transaction(source: "B", accountID: "2", entryMethod: "manual"),
            ]
        )

        let byKey = Dictionary(uniqueKeysWithValues: doc.accounts.map { ($0.id, $0) })
        XCTAssertEqual(byKey.count, 2)

        let a = try! XCTUnwrap(byKey["A|1"])
        XCTAssertEqual(a.transactionCount, 3)
        XCTAssertEqual(a.manualTransactionCount, 1)
        XCTAssertTrue(a.hasCSVImport)

        let b = try! XCTUnwrap(byKey["B|2"])
        XCTAssertEqual(b.transactionCount, 1, "one account's ledger must not leak into another")
        XCTAssertEqual(b.manualTransactionCount, 1)
        XCTAssertFalse(b.hasCSVImport)
    }

    func testAccountWithNoTransactionsCountsZeroRatherThanTheWholeLedger() {
        let doc = document(
            positions: [position(source: "A", accountID: "1"), position(source: "Z", accountID: "9")],
            transactions: [transaction(source: "A", accountID: "1", entryMethod: "manual")]
        )

        let z = try! XCTUnwrap(doc.accounts.first { $0.id == "Z|9" })
        XCTAssertEqual(z.transactionCount, 0)
        XCTAssertEqual(z.manualTransactionCount, 0)
        XCTAssertFalse(z.hasCSVImport)
        XCTAssertTrue(z.awaitsFirstSync == false, "it has a position, so it has synced")
    }

    func testNilLedgerIsTreatedAsEmptyNotAsMissingAccounts() {
        let doc = document(positions: [position(source: "A", accountID: "1")], transactions: nil)

        let a = try! XCTUnwrap(doc.accounts.first)
        XCTAssertEqual(a.transactionCount, 0)
        XCTAssertEqual(a.manualTransactionCount, 0)
        XCTAssertFalse(a.hasCSVImport)
    }

    /// A CSV-sourced position sets the flag even with no csv-tagged transaction.
    func testCSVSourcedPositionStillMarksTheAccount() {
        let doc = document(
            positions: [position(source: "CSV", accountID: "1")],
            transactions: [transaction(source: "CSV", accountID: "1", entryMethod: "manual")]
        )

        let a = try! XCTUnwrap(doc.accounts.first)
        XCTAssertTrue(a.hasCSVImport)
    }

    func testAccountsAppearForLedgerOnlyKeysWithNoPositions() {
        let doc = document(
            positions: [],
            transactions: [transaction(source: "A", accountID: "1", entryMethod: "csv")]
        )

        let a = try! XCTUnwrap(doc.accounts.first { $0.id == "A|1" })
        XCTAssertEqual(a.positionCount, 0)
        XCTAssertEqual(a.transactionCount, 1)
        XCTAssertTrue(a.hasCSVImport)
    }
}
