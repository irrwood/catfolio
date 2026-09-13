import XCTest
@testable import CatfolioIOS

/// Every figure on the Holdings tab is funnelled through `usd(_:currency:)` and
/// `totals(for:)`, so the currency handling is pinned here — in particular the
/// pence/pound relationship that an earlier build got wrong for Trading 212
/// positions (see `migrateKnownInstrumentCurrencies`).
final class LocalPortfolioEngineTests: XCTestCase {
    func testHomeChartUsesAccountCashAndNetDeposits() throws {
        let ledger = AccountMWRLedger(dates: ["2026-01-01", "2026-01-02", "2026-01-03"],
            cashFlows: [0, 1000, -500], values: [0, 1000, 600], benchmarkValues: [:])
        let response = PortfolioChartResponse.accountHistory(ledger: ledger, nav: [1, 1, 1.1], positionCount: 0)
        XCTAssertEqual(response.positionHistory.rows.map(\.cost), [0, 1000, 500])
        XCTAssertEqual(response.currentPoint.marketValue, 600)
        let all = response.accountPerformance(from: "2026-01-01", to: "2026-01-03")
        XCTAssertEqual(all.amount, 100, accuracy: 1e-9)
        XCTAssertEqual(all.percentage, 10, accuracy: 1e-9)
        let selected = response.accountPerformance(from: "2026-01-02", to: "2026-01-03")
        XCTAssertEqual(selected.amount, 100, accuracy: 1e-9)
        XCTAssertEqual(selected.percentage, 10, accuracy: 1e-9)
    }

    func testHomeNetDepositCanBeNegativeAfterProfitableWithdrawal() {
        let ledger = AccountMWRLedger(dates: ["2026-01-01", "2026-01-02"], cashFlows: [100, -120], values: [100, 0], benchmarkValues: [:])
        let response = PortfolioChartResponse.accountHistory(ledger: ledger, nav: [1, 1.2], positionCount: 0)
        XCTAssertEqual(response.currentPoint.cost, -20)
        XCTAssertEqual(response.accountPerformance(from: "2026-01-01", to: "2026-01-02").amount, 20)
    }

    func testHomeMissingLedgerDoesNotShowSnapshotAsAccountNAV() throws {
        let chart = try LocalPortfolioEngine.presentation(for: .empty).1
        XCTAssertFalse(chart.positionHistory.available)
        XCTAssertTrue(chart.positionHistory.rows.isEmpty)
        XCTAssertTrue(chart.currentPoint.marketValue.isNaN)
        XCTAssertNotNil(chart.accountNAV)
    }

    func testCashOnlyHomeWorksFromLocalLedgerWithoutMarketRequests() async throws {
        var document = LocalPortfolioDocument.empty
        document.transactions = [LocalTransactionRecord(date: "2026-09-01", action: "DEPOSIT", ticker: "CASH",
            quantity: 1, price: 1000, currency: "USD", source: "CSV", accountID: "A", accountName: "A",
            cashPostings: [.init(currency: "USD", amount: 1000)])]
        let response = try await LocalMarketDataClient().portfolioChart(document: document, cachedOnly: true)
        XCTAssertTrue(response.positionHistory.available)
        XCTAssertEqual(response.currentPoint.marketValue, 1000)
        XCTAssertEqual(response.currentPoint.cost, 1000)
        XCTAssertEqual(response.accountNAV?[response.currentPoint.dateText], 1)
    }

    /// A trade imported without its cash legs is funded from its fill and
    /// says so, rather than taking the whole account's history down.
    func testTradesWithoutCashAreFundedFromTheirFillsOnHome() async throws {
        var document = LocalPortfolioDocument.empty
        document.transactions = [LocalTransactionRecord(date: "2026-09-01", action: "BUY", ticker: "AAPL",
            quantity: 1, price: 100, currency: "USD", source: "CSV", accountID: nil, accountName: nil)]
        document.positions = [LocalPositionRecord(ticker: "AAPL", name: "Apple", shares: 1, averageCost: 100, currency: "USD",
            quotePrice: 100, quoteCurrency: "USD", source: "CSV", openedDate: "2026-09-01")]
        let response = try await LocalMarketDataClient().portfolioChart(document: document)
        XCTAssertTrue(response.positionHistory.available, response.warning ?? "")
        XCTAssertTrue(response.warning?.contains("资金流水不完整") == true)
        XCTAssertEqual(response.positionHistory.rows.last?.cost ?? 0, 100, accuracy: 0.0001, "the fill is the implied deposit")
    }

    func testMalformedHomeSeriesDoesNotPartiallyPublish() {
        let ledger = AccountMWRLedger(dates: ["2026-01-01", "2026-01-02"], cashFlows: [100, 0], values: [100, nil], benchmarkValues: [:])
        let response = PortfolioChartResponse.accountHistory(ledger: ledger, nav: [1, 1], positionCount: 1)
        XCTAssertFalse(response.positionHistory.available)
        XCTAssertTrue(response.currentPoint.marketValue.isNaN)
    }
    func testCashOnlyCSVRetainsFundingAndWithdrawal() throws {
        let csv = "Action,Time,Total,Currency (Total)\nDeposit,2026-01-01,1000,USD\nWithdrawal,2026-01-02,200,USD\n"
        let (positions, rows, _) = try LocalCSVImporter.parse(Data(csv.utf8))
        XCTAssertTrue(positions.isEmpty)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].cashPostings?.first?.amount, 1000)
        XCTAssertEqual(rows[1].cashPostings?.first?.amount, -200)
        XCTAssertEqual(rows[0].assignedAccount(id: "A", name: "A").cashPostings, rows[0].cashPostings)
        let encoded = try JSONEncoder().encode(rows)
        XCTAssertEqual(try JSONDecoder().decode([LocalTransactionRecord].self, from: encoded), rows)
    }

    func testFeeBearingCSVRequiresExplicitNetCash() throws {
        let header = "Action,Time,Ticker,No. of shares,Price / share,Currency (Price / share),Total,Currency (Total),Currency conversion fee,Net cash amount,Cash currency\n"
        let ambiguous = header + "Market buy,2026-01-01,AAPL,1,100,USD,100,USD,1,,\n"
        XCTAssertNil(try LocalCSVImporter.parse(Data(ambiguous.utf8)).1[0].cashPostings)
        let explicit = header + "Market buy,2026-01-01,AAPL,1,100,USD,100,USD,1,-101,USD\n"
        XCTAssertEqual(try LocalCSVImporter.parse(Data(explicit.utf8)).1[0].cashPostings?.first?.amount, -101)
    }

    func testUnsupportedCashEventIsRetained() throws {
        let csv = "Action,Time,Total,Currency (Total)\nDeposit,2026-01-01,100,USD\nCurrency conversion,2026-01-02,50,GBP\n"
        let rows = try LocalCSVImporter.parse(Data(csv.utf8)).1
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[1].action.hasPrefix("UNSUPPORTED"))
    }

    func testMalformedRowInvalidatesCashLedger() throws {
        let csv = "Action,Time,Total,Currency (Total)\nDeposit,2026-01-01,100,USD\nWithdrawal,invalid,10,USD\n"
        let (_, rows, report) = try LocalCSVImporter.parse(Data(csv.utf8))
        XCTAssertFalse(report.warnings.isEmpty)
        XCTAssertNil(rows[0].cashPostings)
    }

    func testLegacyTransactionsDoNotInventSettlementCash() throws {
        let row = LocalTransactionRecord(date: "2026-01-01", action: "BUY", ticker: "X", quantity: 1, price: 100,
            currency: "USD", source: "CSV", accountID: nil, accountName: nil)
        let restored = try JSONDecoder().decode(LocalTransactionRecord.self, from: JSONEncoder().encode(row))
        XCTAssertNil(restored.cashPostings)
    }

    func testReimportDoesNotReuseObsoleteCashAmount() throws {
        var old = LocalTransactionRecord(date: "2026-01-01", action: "BUY", ticker: "X", quantity: 1, price: 100,
            currency: "USD", source: "CSV", accountID: nil, accountName: nil, tradeID: "1", entryMethod: "csv")
        old.cashPostings = [.init(currency: "USD", amount: -100)]
        var corrected = old
        corrected.cashPostings = nil
        XCTAssertNil(corrected.preservingBrokerResult(from: old).cashPostings)
    }

    private func position(
        ticker: String = "TEST",
        shares: Double,
        averageCost: Double,
        currency: String,
        quotePrice: Double,
        quoteCurrency: String? = nil
    ) -> LocalPositionRecord {
        LocalPositionRecord(
            ticker: ticker,
            name: ticker,
            shares: shares,
            averageCost: averageCost,
            currency: currency,
            quotePrice: quotePrice,
            quoteCurrency: quoteCurrency ?? currency,
            source: "test",
            openedDate: nil
        )
    }

    // MARK: - Currency conversion

    func testUSDIsIdentity() throws {
        XCTAssertEqual(try LocalPortfolioEngine.usd(1_234.56, currency: "USD"), 1_234.56)
    }

    /// GBX is pence. Any drift between these two entries silently rescales every
    /// London holding by 100x, which is exactly the class of bug the Trading 212
    /// currency migration exists to repair.
    func testPenceIsExactlyOneHundredthOfAPound() throws {
        let pound = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBP"))
        let pence = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBX"))

        XCTAssertEqual(pence, pound / 100, accuracy: 1e-9)
    }

    func testOneHundredPoundsEqualsTenThousandPence() throws {
        XCTAssertEqual(
            try LocalPortfolioEngine.usd(100, currency: "GBP"),
            try LocalPortfolioEngine.usd(10_000, currency: "GBX"),
            accuracy: 1e-9
        )
    }

    func testCurrencyLookupIsCaseInsensitive() throws {
        XCTAssertEqual(
            try LocalPortfolioEngine.usd(100, currency: "gbp"),
            try LocalPortfolioEngine.usd(100, currency: "GBP")
        )
    }

    /// An unknown currency must fail loudly. Falling back to 1.0 would quietly
    /// report a JPY holding as if it were dollars.
    func testUnsupportedCurrencyThrowsRatherThanAssumingParity() {
        XCTAssertNil(LocalPortfolioEngine.usdRate(for: "ZZZ"))
        XCTAssertThrowsError(try LocalPortfolioEngine.usd(100, currency: "ZZZ"))
    }

    func testEverySupportedRateIsPositiveAndFinite() {
        for code in ["USD", "GBP", "GBX", "EUR", "HKD", "CAD", "AUD", "SGD", "JPY", "CNY", "CNH"] {
            let rate = LocalPortfolioEngine.usdRate(for: code)
            XCTAssertNotNil(rate, "\(code) must be convertible")
            if let rate {
                XCTAssertTrue(rate.isFinite, "\(code) rate must be finite")
                XCTAssertGreaterThan(rate, 0, "\(code) rate must be positive")
            }
        }
    }

    // MARK: - Totals

    func testTotalsSumSharesTimesPrice() throws {
        let totals = try LocalPortfolioEngine.totals(for: [
            position(shares: 10, averageCost: 100, currency: "USD", quotePrice: 150)
        ])

        XCTAssertEqual(totals.cost, 1_000, accuracy: 1e-9)
        XCTAssertEqual(totals.marketValue, 1_500, accuracy: 1e-9)
    }

    func testTotalsConvertEachPositionFromItsOwnCurrency() throws {
        let gbpRate = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBP"))
        let totals = try LocalPortfolioEngine.totals(for: [
            position(ticker: "AAA", shares: 10, averageCost: 100, currency: "USD", quotePrice: 100),
            position(ticker: "BBB", shares: 10, averageCost: 100, currency: "GBP", quotePrice: 100),
        ])

        XCTAssertEqual(totals.cost, 1_000 + 1_000 * gbpRate, accuracy: 1e-6)
    }

    /// A pence-quoted holding and the equivalent pound-quoted holding must value
    /// identically once converted.
    func testPenceQuotedHoldingMatchesEquivalentPoundQuotedHolding() throws {
        let pence = try LocalPortfolioEngine.totals(for: [
            position(shares: 100, averageCost: 1_200, currency: "GBX", quotePrice: 1_500)
        ])
        let pounds = try LocalPortfolioEngine.totals(for: [
            position(shares: 100, averageCost: 12, currency: "GBP", quotePrice: 15)
        ])

        XCTAssertEqual(pence.cost, pounds.cost, accuracy: 1e-6)
        XCTAssertEqual(pence.marketValue, pounds.marketValue, accuracy: 1e-6)
    }

    /// Cost and market value are converted through separate currency fields, so
    /// a position bought in one currency and quoted in another must use both.
    func testCostAndQuoteCurrenciesAreAppliedIndependently() throws {
        let gbpRate = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "GBP"))
        let totals = try LocalPortfolioEngine.totals(for: [
            position(
                shares: 10, averageCost: 100, currency: "GBP",
                quotePrice: 200, quoteCurrency: "USD"
            )
        ])

        XCTAssertEqual(totals.cost, 1_000 * gbpRate, accuracy: 1e-6)
        XCTAssertEqual(totals.marketValue, 2_000, accuracy: 1e-6)
    }

    func testEmptyPortfolioTotalsToZero() throws {
        let totals = try LocalPortfolioEngine.totals(for: [])

        XCTAssertEqual(totals.cost, 0)
        XCTAssertEqual(totals.marketValue, 0)
    }

    func testTotalsPropagateUnsupportedCurrencyAsAnError() {
        XCTAssertThrowsError(
            try LocalPortfolioEngine.totals(for: [
                position(shares: 1, averageCost: 1, currency: "ZZZ", quotePrice: 1)
            ])
        )
    }
}
