import XCTest
@testable import CatfolioIOS

/// Every figure on the Holdings tab is funnelled through `usd(_:currency:)` and
/// `totals(for:)`, so the currency handling is pinned here — in particular the
/// pence/pound relationship that an earlier build got wrong for Trading 212
/// positions (see `migrateKnownInstrumentCurrencies`).
final class LocalPortfolioEngineTests: XCTestCase {
    private var previousLanguagePreference: Any?

    override func setUp() {
        super.setUp()
        previousLanguagePreference = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.preferenceKey)
    }

    override func tearDown() {
        if let previousLanguagePreference {
            UserDefaults.standard.set(previousLanguagePreference, forKey: AppLanguage.preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
        }
        super.tearDown()
    }

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

    /// A fill recorded without a price — a takeover's exchange — is valued
    /// at the day's close and listed as a data issue; the chart still draws.
    func testAFillWithoutAPriceIsValuedAtTheCloseAndListed() async throws {
        var document = LocalPortfolioDocument.empty
        document.transactions = [LocalTransactionRecord(date: "2026-09-01", action: "BUY", ticker: "AAPL",
            quantity: 1, price: 0, currency: "USD", source: "CSV", accountID: nil, accountName: nil)]
        document.positions = [LocalPositionRecord(ticker: "AAPL", name: "Apple", shares: 1, averageCost: 100, currency: "USD",
            quotePrice: 100, quoteCurrency: "USD", source: "CSV", openedDate: "2026-09-01")]
        let response = try await LocalMarketDataClient().portfolioChart(document: document)
        XCTAssertTrue(response.positionHistory.available, response.warning ?? "")
        XCTAssertTrue(response.dataIssues?.contains { $0.contains("没有成交价") } == true, "\(response.dataIssues ?? [])")
        XCTAssertTrue(response.warning?.contains("设置") == true, "the basis note points to Settings")
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

    func testTheDividendForecastRepeatsLastYearsRemainingPayments() {
        let today = DayDateCodec.date(from: "2026-09-13")!
        let payments = [
            ("2025-06-10", 0.5), // paid long ago
            ("2025-08-20", 0.5), // ex-date passed a year ago; its payment has already arrived
            ("2025-09-01", 0.5), // ex-date passed, payment still to come
            ("2025-12-01", 0.5), // pays before the year is out
            ("2025-12-20", 0.5), // pays in January
        ].map { DividendForecast.Payment(exDate: $0.0, perShare: $0.1, currency: "USD") }
        let remaining = DividendForecast.remaining(shares: 10, payments: payments, today: today)
        XCTAssertEqual(remaining.amount, 10, accuracy: 1e-9)
        XCTAssertEqual(remaining.currency, "USD")
        XCTAssertEqual(DividendForecast.remaining(shares: 0, payments: payments, today: today).amount, 0)
    }
}

/// Home refresh must value the same observed prices without replacing an
/// account (cash + shares) with a holdings-only total.
@MainActor
final class HomeLiveValuationTests: XCTestCase {
    private func position(_ price: Double, at date: Date?, currency: String = "USD") -> LocalPositionRecord {
        LocalPositionRecord(ticker: "HOME_REFRESH_TEST", name: "Home refresh fixture", shares: 10,
            averageCost: 100, currency: currency, quotePrice: price, quoteCurrency: currency,
            source: "CSV", openedDate: nil, accountID: "A", accountName: "A", quoteObservedAt: date)
    }

    func testObservedQuoteReplacesSameSessionCloseWithoutChangingBaseline() {
        let now = ISO8601DateFormatter().date(from: "2026-09-21T15:00:00Z")!
        let result = LocalMarketDataClient.homeCloses(["2026-09-18": 100, "2026-09-21": 120],
            symbol: "HOME_REFRESH_TEST", currency: "USD", positions: [position(130, at: now)],
            through: "2026-09-21", now: now)
        XCTAssertEqual(result, ["2026-09-18": 100, "2026-09-21": 130])
    }

    func testDailyFallbackTimestampStaysOnItsExchangeSession() throws {
        let observed = try XCTUnwrap(LocalMarketDataClient.marketDayStart("2026-09-21", symbol: "HOME_REFRESH_TEST"))
        let result = LocalMarketDataClient.homeCloses(["2026-09-18": 100], symbol: "HOME_REFRESH_TEST",
            currency: "USD", positions: [position(130, at: observed)], through: "2026-09-21", now: observed)
        XCTAssertEqual(result["2026-09-21"], 130)
        XCTAssertNil(result["2026-09-20"])
    }

    func testWeekendUsesQuoteSessionAndRejectsUnknownExpiredOrFutureObservations() {
        let now = ISO8601DateFormatter().date(from: "2026-09-20T15:00:00Z")!
        let friday = now.addingTimeInterval(-2 * 86_400)
        let result = LocalMarketDataClient.homeCloses(["2026-09-17": 100], symbol: "HOME_REFRESH_TEST",
            currency: "USD", positions: [position(130, at: friday)], through: "2026-09-20", now: now)
        XCTAssertEqual(result, ["2026-09-17": 100, "2026-09-18": 130])
        for observed in [nil, now.addingTimeInterval(-8 * 86_400), now.addingTimeInterval(120)] {
            XCTAssertEqual(LocalMarketDataClient.homeCloses(["2026-09-17": 100], symbol: "HOME_REFRESH_TEST",
                currency: "USD", positions: [position(130, at: observed)], through: "2026-09-20", now: now),
                ["2026-09-17": 100])
        }
    }

    func testLedgerLiveQuotesConvertPenceAndDoNotMixCurrencies() {
        let now = ISO8601DateFormatter().date(from: "2026-09-21T15:00:00Z")!
        let gbp = position(2, at: now, currency: "GBP")
        let symbol = LocalMarketDataClient.yahooSymbol(ticker: gbp.ticker, currency: gbp.quoteCurrency)
        XCTAssertEqual(LocalMarketDataClient.homeCloses(["2026-09-18": 150], symbol: symbol,
            currency: "GBX", positions: [gbp], through: "2026-09-21", now: now)["2026-09-21"], 200)
        XCTAssertNil(LocalMarketDataClient.homeCloses(["2026-09-18": 150], symbol: symbol,
            currency: "USD", positions: [gbp], through: "2026-09-21", now: now)["2026-09-21"])
    }

    func testOneDayUsesActualPreviousSessionAcrossCarriedWeekend() throws {
        let days = ["2026-09-16", "2026-09-17", "2026-09-18", "2026-09-19", "2026-09-20"]
        let values = [900.0, 1000, 1100, 1100, 1100]
        var response = PortfolioChartResponse.accountHistory(ledger: .init(dates: days,
            cashFlows: [900, 0, 0, 0, 0], values: values.map(Optional.some), benchmarkValues: [:]),
            nav: [1, 1.1, 1.21, 1.21, 1.21], positionCount: 1)
        response.marketDates = Array(days.prefix(3))
        let oneDay = CostMarketPreparedData(source: .init(response: response)).data(for: .oneDay)
        XCTAssertEqual(oneDay.rows.first?.dateText, "2026-09-17")
        let result = response.accountPerformance(from: try XCTUnwrap(oneDay.rows.first).dateText,
                                               to: try XCTUnwrap(oneDay.rows.last).dateText)
        XCTAssertEqual(result.amount, 100)
        XCTAssertEqual(result.percentage, 10, accuracy: 1e-8)
    }

    func testCurrentEndpointReplacesCachedDayAndExtendsHistory() {
        for day in ["2026-09-18", "2026-09-21"] {
            let response = PortfolioChartResponse(positionCount: 1,
                positionHistory: .init(available: true, rows: [
                    .init(dateText: "2026-09-17", marketValue: 1000, cost: 900),
                    .init(dateText: "2026-09-18", marketValue: 1100, cost: 900)]),
                currentPoint: .init(dateText: day, marketValue: 1300, cost: 900), warning: nil)
            let source = CostMarketPreparedSource(response: response)
            XCTAssertEqual(source.points.last?.marketValue, 1300)
            XCTAssertEqual(source.points.filter { $0.dateText == day }.count, 1)
        }
    }

    func testYTDIncludesPreviousYearEnd() {
        let rows = [ChartPoint(dateText: "2025-12-31", marketValue: 1000, cost: 900),
                    ChartPoint(dateText: "2026-01-01", marketValue: 1100, cost: 900),
                    ChartPoint(dateText: "2026-09-21", marketValue: 1300, cost: 900)]
        let response = PortfolioChartResponse(positionCount: 1, positionHistory: .init(available: true, rows: rows),
                                              currentPoint: rows.last!, warning: nil)
        let result = CostMarketPreparedData(source: .init(response: response)).data(for: .yearToDate)
        XCTAssertEqual(result.rows.first?.dateText, "2025-12-31")
    }

    private func fixture() throws -> (LocalPortfolioDocument, URL) {
        let now = Date()
        let end = DayDateCodec.string(from: now)
        let start = DayDateCodec.string(from: now.addingTimeInterval(-4 * 86_400))
        let quoteDay = try XCTUnwrap(LocalMarketDataClient.homeCloses([:], symbol: "HOME_REFRESH_TEST",
            currency: "USD", positions: [position(130, at: now)], through: end).keys.first)
        let previous = DayDateCodec.string(from: DayDateCodec.date(from: quoteDay)!.addingTimeInterval(-86_400))
        let key = Data("ledger-v1|HOME_REFRESH_TEST|\(start)|\(end)".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(key + ".json")
        let cache: [String: Any] = ["currency": "USD", "closes": [start: 100, previous: 100, quoteDay: 120],
                                   "splits": [], "fetchedAt": now.timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: cache).write(to: url)
        var document = LocalPortfolioDocument.empty
        document.positions = [position(130, at: now)]
        document.transactions = [
            .init(date: start, action: "DEPOSIT", ticker: "CASH", quantity: 1, price: 2000, currency: "USD",
                  source: "CSV", accountID: "A", accountName: "A", cashPostings: [.init(currency: "USD", amount: 2000)]),
            .init(date: start, action: "BUY", ticker: "HOME_REFRESH_TEST", quantity: 10, price: 100, currency: "USD",
                  source: "CSV", accountID: "A", accountName: "A", cashPostings: [.init(currency: "USD", amount: -1000)]),
            .init(date: end, action: "DEPOSIT", ticker: "CASH", quantity: 1, price: 100, currency: "USD",
                  source: "CSV", accountID: "A", accountName: "A", cashPostings: [.init(currency: "USD", amount: 100)])]
        return (document, url)
    }

    func testLiveRebuildPreservesCashAndExcludesDepositFromProfit() async throws {
        let (document, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let chart = try await LocalMarketDataClient().portfolioChart(document: document, cachedOnly: true)
        XCTAssertEqual(chart.currentPoint.marketValue, 2400, accuracy: 1e-8, "1300 shares + 1100 cash")
        XCTAssertEqual(chart.currentPoint.cost, 2100)
        let rows = CostMarketPreparedData(source: .init(response: chart)).data(for: .oneDay).rows
        let day = chart.accountPerformance(from: try XCTUnwrap(rows.first).dateText, to: chart.currentPoint.dateText)
        XCTAssertEqual(day.amount, 300, accuracy: 1e-8, "The 100 deposit is not profit")
    }

    func testDetailQuoteRebuildsHomeAndPublishesNewRevision() async throws {
        let (input, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "HomeLiveValuation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input },
            presentationCache: PortfolioPresentationCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
        await model.refreshPortfolio(refreshMarketData: false)
        model.portfolioChart = try await LocalMarketDataClient().portfolioChart(document: input, cachedOnly: true)
        let revision = model.portfolioChartRevision
        let now = Date()
        let history = SecurityPriceHistory(ticker: "HOME_REFRESH_TEST", currency: "USD",
            points: [.init(dateText: DayDateCodec.string(from: now.addingTimeInterval(-86_400)), close: 100)],
            intradayPoints: [.init(dateText: "minute", close: 140, timestamp: now)], trades: [])
        try await model.publishSecurityPriceHistory(history, source: .personal, now: now)
        for _ in 0..<100 where model.portfolioChartRevision == revision {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(model.portfolioChartRevision, revision)
        XCTAssertEqual(model.portfolioChart?.currentPoint.marketValue, 2500)
        XCTAssertEqual(model.overview?.summary.marketValue, 1400)
        XCTAssertEqual(model.portfolioChart?.currentPoint.cost, 2100)
    }
}
