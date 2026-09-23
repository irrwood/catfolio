import XCTest
@testable import CatfolioIOS

final class SecurityWeeklyRangeTests: XCTestCase {
    private func history(_ rows: [(String, Double)], minutes: [SecurityPricePoint] = []) -> SecurityPriceHistory {
        SecurityPriceHistory(ticker: "META", currency: "USD",
            points: rows.map { .init(dateText: $0.0, close: $0.1) }, intradayPoints: minutes, trades: [])
    }

    private func week(_ history: SecurityPriceHistory) -> SecurityPriceRangeData {
        SecurityPriceRangeData(history: history, range: .oneWeek, averageCost: nil, selectedAccountKeys: [])
    }

    func testExactWeekBoundaryUsesThatDaysClose() throws {
        let data = week(history([("2026-09-11", 648.03), ("2026-09-14", 665.60),
            ("2026-09-15", 670.24), ("2026-09-16", 673.31), ("2026-09-17", 682.31),
            ("2026-09-18", 665.75), ("2026-09-21", 719.25)]))
        XCTAssertEqual(data.points.first?.dateText, "2026-09-14")
        XCTAssertEqual(data.points.count, 6)
        XCTAssertEqual(try XCTUnwrap(data.points.last?.returnPercent), (719.25 / 665.60 - 1) * 100, accuracy: 1e-9)
    }

    func testHolidayBoundaryIncludesPriorCloseInsteadOfStartingAfterTheHoliday() throws {
        let data = week(history([("2026-09-03", 610.68), ("2026-09-04", 616.77),
            ("2026-09-08", 613.48), ("2026-09-09", 653.69), ("2026-09-10", 644.38),
            ("2026-09-11", 648.03), ("2026-09-14", 665.60)]))
        XCTAssertEqual(data.points.first?.dateText, "2026-09-04")
        XCTAssertEqual(data.points.first?.returnPercent, 0)
        XCTAssertEqual(try XCTUnwrap(data.points.last?.returnPercent), (665.60 / 616.77 - 1) * 100, accuracy: 1e-9)
    }

    func testLatestMinuteAndWeeklyReturnUseTheSameEndPrice() throws {
        let minute = SecurityPricePoint(dateText: "latest", close: 720,
            timestamp: ISO8601DateFormatter().date(from: "2026-09-21T15:00:00Z")!)
        let data = week(history([("2026-09-14", 665.60), ("2026-09-18", 665.75),
            ("2026-09-21", 719.25)], minutes: [minute]))
        XCTAssertEqual(data.points.last?.price, 720)
        XCTAssertEqual(data.points.filter { $0.dateText == "2026-09-21" }.count, 1)
        XCTAssertEqual(try XCTUnwrap(data.points.last?.returnPercent), (720 / 665.60 - 1) * 100, accuracy: 1e-9)
    }

    func testNewListingKeepsAvailableHistoryWithoutInventingAWeekEarlierPrice() throws {
        let data = week(history([("2026-09-17", 100), ("2026-09-18", 105), ("2026-09-21", 110)]))
        XCTAssertEqual(data.points.first?.dateText, "2026-09-17")
        XCTAssertEqual(try XCTUnwrap(data.points.last?.returnPercent), 10, accuracy: 1e-9)
    }
}

final class AuditRegressionTests: XCTestCase {
    func testReturnsPercentageTicksRemainDistinctAcrossSmallRanges() {
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "zh_CN")] {
            let values = [2.2, 1.56, 0.92, 0.28, -0.36, -1.0]
            let labels = values.map { ReturnsAxisLabels.percent($0, step: 0.64, locale: locale) }
            XCTAssertEqual(Set(labels).count, values.count)
            XCTAssertEqual(labels[0], "2.2%")
            XCTAssertEqual(labels[4], "-0.4%")
            XCTAssertEqual(ReturnsAxisLabels.percent(-0.001, step: 0.4, locale: locale), "0%")
            XCTAssertEqual(ReturnsAxisLabels.percent(20, step: 5, locale: locale), "20%")
        }
    }

    func testLocalFXDateOnlyTradesDoNotSellBeforeTheirPurchase() {
        let result = LocalFXImpactCalculator.remainingLots(from: [
            trade("a-sell", "2024-01-02", "SELL", 4, 110),
            trade("z-buy", "2024-01-02", "BUY", 10, 100),
        ])
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.lots.map(\.quantity), [6])
    }

    func testLocalFXUsesExecutionTimeInsteadOfTradeIDForSameDayLots() {
        let result = LocalFXImpactCalculator.remainingLots(from: [
            trade("a-buy", "2024-01-02", "BUY", 7, 100, time: "2024-01-02T15:00:00Z"),
            trade("b-sell", "2024-01-02", "SELL", 5, 110, time: "2024-01-02T14:00:00Z"),
            trade("z-buy", "2024-01-02", "BUY", 10, 100, time: "2024-01-02T13:00:00Z"),
        ])
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.lots.map(\.quantity), [5, 7])
    }

    func testLocalFXEqualExecutionTimesKeepBuyBeforeSell() {
        let result = LocalFXImpactCalculator.remainingLots(from: [
            trade("a-sell", "2024-01-02", "SELL", 4, 110, time: "2024-01-02T00:00:00Z"),
            trade("z-buy", "2024-01-02", "BUY", 10, 100, time: "2024-01-02T00:00:00Z"),
        ])
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.lots.map(\.quantity), [6])
    }

    private func date(_ text: String) -> Date { DayDateCodec.date(from: text)! }
    private func trade(_ id: String, _ day: String, _ side: String, _ quantity: Double,
                       _ price: Double, account: String = "A", time: String? = nil) -> LocalTransactionRecord {
        LocalTransactionRecord(date: day, action: side, ticker: "TEST", quantity: quantity,
            price: price, currency: "USD", source: "Moomoo", accountID: account,
            accountName: account, tradeID: id, executedAt: time)
    }
    private func fx() throws -> GBPFXRates {
        try GBPFXRates.decode(Data(#"{"schemaVersion":1,"baseCurrency":"GBP","direction":"GBP_TO_QUOTE","nonObservationDayPolicy":"OMIT_NO_FORWARD_FILL","lookupPolicy":"","status":"VERIFIED","source":"fixture","unsupportedCurrencies":[],"dates":["2024-01-02","2024-01-03"],"rates":{"USD":[1.5,1.2]}}"#.utf8))
    }
    private func position(_ account: String, observedAt: Date? = nil) -> LocalPositionRecord {
        LocalPositionRecord(ticker: "TEST", name: "Test", shares: 10, averageCost: 100,
            currency: "USD", quotePrice: 120, quoteCurrency: "USD", source: "Moomoo",
            openedDate: nil, accountID: account, accountName: account, quoteObservedAt: observedAt)
    }
    private func account(_ id: String) -> PortfolioAccount {
        PortfolioAccount(id: "Moomoo|\(id)", accountID: id, source: "Moomoo", name: id,
            baseCurrency: "USD", positionCount: 0, transactionCount: 0,
            manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0)
    }

    func testPartialHistoryAndAnEmptyAccountCannotDeleteOlderFillsOrAnotherAccount() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalPortfolioStore(fileURL: url)
        let oldA = trade("old-a", "2024-01-02", "BUY", 10, 100)
        let oldB = trade("old-b", "2024-01-02", "BUY", 10, 100, account: "B")
        _ = try await store.replace(positions: [position("A"), position("B")], source: "Moomoo",
            transactions: [oldA, oldB])
        let closed = try await store.replace(positions: [], source: "Moomoo",
            transactions: [], replacingAccountsOnly: true, syncedAccounts: [account("A")],
            mergesTransactionHistory: true)
        XCTAssertEqual(closed.positions.map(\.accountID), ["B"])
        XCTAssertEqual(Set(closed.transactions?.map(\.id) ?? []), [oldA.id, oldB.id])
        XCTAssertTrue(closed.accounts.contains { $0.id == "Moomoo|A" })
        let restated = trade("old-a", "2024-01-02", "BUY", 12, 100)
        let partial = try await store.replace(positions: [], source: "Moomoo",
            transactions: [restated], replacingAccountsOnly: true, syncedAccounts: [account("A")],
            mergesTransactionHistory: true)
        XCTAssertEqual(partial.transactions?.count, 2)
        XCTAssertEqual(partial.transactions?.first { $0.id == oldA.id }?.quantity, 12)
        let reportWithOnlyBTrades = try await store.replace(positions: [], source: "Moomoo",
            transactions: [trade("b-new", "2024-01-03", "BUY", 1, 100, account: "B")],
            replacingAccountsOnly: true, syncedAccounts: [account("A")], mergesTransactionHistory: true)
        XCTAssertEqual(reportWithOnlyBTrades.positions.map(\.accountID), ["B"],
            "trades alone do not assert that an account's positions are empty")
    }

    func testMoomooAuthorizedMarketsIncludeMarketsWithNoOpenPositions() throws {
        let account = try JSONDecoder().decode(MoomooAccount.self, from: Data(#"{"account_id":"A","security_firm":"FUTUINC","acc_type":"cash","account_card_number":"A","enable_market":[1,2,6]}"#.utf8))
        XCTAssertEqual(account.historyMarkets, ["HK", "US", "SG"])
    }

    func testIBKREmptyPositionsAreAuthoritativeButAnOmittedSectionIsNot() throws {
        let client = IBKRFlexClient()
        let empty = Data(#"<FlexQueryResponse><FlexStatements><FlexStatement accountId="U123" toDate="20240103"><OpenPositions /></FlexStatement></FlexStatements></FlexQueryResponse>"#.utf8)
        let snapshot = try client.parseStatement(empty)
        XCTAssertTrue(snapshot.positions.isEmpty)
        XCTAssertEqual(snapshot.syncedPositionAccountIDs, ["U123"])
        XCTAssertEqual(snapshot.quoteObservedAt, date("2024-01-03"))
        let missing = Data(#"<FlexQueryResponse><FlexStatements><FlexStatement accountId="U123"><Trades /></FlexStatement></FlexStatements></FlexQueryResponse>"#.utf8)
        XCTAssertThrowsError(try client.parseStatement(missing))
        XCTAssertThrowsError(try client.parseStatement(Data("<bad>".utf8)))
        let lotsOnly = Data(#"<FlexQueryResponse><FlexStatements><FlexStatement accountId="U123"><OpenPositions><OpenPosition levelOfDetail="LOT" accountId="U123" symbol="TEST" position="10" /></OpenPositions></FlexStatement></FlexStatements></FlexQueryResponse>"#.utf8)
        XCTAssertThrowsError(try client.parseStatement(lotsOnly),
            "a query configured without Summary must not erase positions as if it were empty")
    }

    func testClosedMoomooUSFillHasCurrencyWithoutLookingUpPositions() throws {
        let fill = try JSONDecoder().decode(MoomooFill.self, from: Data(#"{"deal_id":"sale","order_id":"order","trd_side":"SELL","code":"US.TEST","qty":"10","price":"120","create_time":1704240000000000}"#.utf8))
        XCTAssertEqual(fill.quoteCurrency, "USD")
        XCTAssertEqual(fill.orderID, "order")
        let foreign = try JSONDecoder().decode(MoomooFill.self, from: Data(#"{"deal_id":"sale","trd_side":"SELL","code":"HK.01234","qty":"10","price":"120","currency":"CNH"}"#.utf8))
        XCTAssertEqual(foreign.quoteCurrency, "CNH", "do not assume every Hong Kong counter trades in HKD")
    }

    func testCSVRecognizesEveryNewlineAndPreservesQuotedNewlines() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let text = "Date,Action,Ticker,Quantity,Price,Currency,Name" + newline
                + "2024-01-02,BUY,TEST,10,100,USD,\"First\(newline)Second\"" + newline
            let parsed = try LocalCSVImporter.parse(Data(text.utf8))
            XCTAssertEqual(parsed.0.first?.shares, 10)
            XCTAssertEqual(parsed.0.first?.name, "First\(newline)Second")
        }
    }

    func testCSVAppliesSplitToHoldingsButKeepsOriginalFills() throws {
        let splits = StockSplitCatalog(schemaVersion: 1,
            splits: ["TEST": [.init(d: "2024-06-10", f: 1, t: 10)]])
        let text = "Date,Action,Ticker,Quantity,Price,Currency\n2024-06-07,BUY,TEST,10,1000,USD\n2024-06-11,SELL,TEST,50,110,USD\n"
        let (positions, rows, _) = try LocalCSVImporter.parse(Data(text.utf8), splitCatalog: splits)
        XCTAssertEqual(positions.first?.shares, 50)
        XCTAssertEqual(positions.first?.averageCost, 100)
        XCTAssertEqual(rows.map(\.quantity), [10, 50])
        XCTAssertEqual(rows.map(\.price), [1000, 110])
    }

    func testCSVRejectsUnexplainedOversellsAndMixedAccounts() {
        let header = "Date,Action,Ticker,Quantity,Price,Currency"
        XCTAssertThrowsError(try LocalCSVImporter.parse(Data((header + "\n2024-01-02,SELL,TEST,10,100,USD").utf8)))
        let mixed = header + ",Account ID\n2024-01-02,BUY,TEST,10,100,USD,A\n2024-01-03,SELL,TEST,10,100,USD,B\n"
        XCTAssertThrowsError(try LocalCSVImporter.parse(Data(mixed.utf8)))
    }

    func testCSVPreviewIsBoundedAndDoesNotPresentASampleCountAsTheTotal() throws {
        let text = "Date,Action,Ticker,Quantity,Price,Currency\n"
            + String(repeating: "2024-01-02,BUY,TEST,10,100,USD\n", count: 20_000)
        let file = try SelectedCSVFile(url: URL(fileURLWithPath: "/tmp/audit.csv"), data: Data(text.utf8))
        XCTAssertTrue(file.hasDataRows)
        XCTAssertNil(file.dataRowCount, "the full row count belongs to the import result")
        XCTAssertEqual(file.headers.count, 6)
        XCTAssertEqual(LocalCSVImporter.parseRecords(text, maximumRecords: 27).count, 27)
    }

    func testRealPriceJumpsAndFallsAreNeverReclassifiedAsFlows() throws {
        typealias T = DailyTimeWeightedReturn
        let events: [T.Event] = [
            .init(id: "fund", date: "2024-01-02", account: "A", cash: [.init(currency: "USD", amount: 100)], external: true),
            .init(id: "buy", date: "2024-01-02", account: "A", symbol: "TEST", quantity: 1, cash: [.init(currency: "USD", amount: -100)])
        ]
        for price in [Decimal(160), Decimal(40)] {
            let days: [T.Day] = [
                .init(date: "2024-01-02", quotes: ["TEST": .init(price: 100, currency: "USD")], usdRates: [:]),
                .init(date: "2024-01-03", quotes: ["TEST": .init(price: price, currency: "USD")], usdRates: [:])
            ]
            let result = try T.calculate(events: events, days: days, inferUnfundedShareTransfers: true)
            XCTAssertEqual(result.points.last?.nav, price / 100)
            XCTAssertEqual(result.points.last?.inflow, 0)
            XCTAssertEqual(result.points.last?.outflow, 0)
            XCTAssertTrue(result.inferredShareTransfers.isEmpty)
        }
    }

    func testFXAmountDeclaresSterlingAndDoesNotConsumeAnotherAccountsLots() throws {
        let one = try XCTUnwrap(FXImpactCalculator.impact(ticker: "TEST",
            transactions: [trade("a", "2024-01-02", "BUY", 100, 100)], rates: fx(), asOf: date("2024-01-03")))
        XCTAssertEqual(one.currency, "GBP")
        XCTAssertEqual(one.amount, 1666.666666667, accuracy: 1e-6)
        XCTAssertEqual(one.amount * 1.2, 2000, accuracy: 1e-6, "USD result needs GBP-to-USD conversion")
        let multiple = try XCTUnwrap(FXImpactCalculator.impact(ticker: "TEST", transactions: [
            trade("a", "2024-01-02", "BUY", 100, 100),
            trade("b", "2024-01-03", "BUY", 100, 200, account: "B"),
            trade("s", "2024-01-03", "SELL", 100, 200, account: "B")
        ], rates: fx(), asOf: date("2024-01-03")))
        XCTAssertEqual(multiple.cost, 10_000)
        XCTAssertEqual(multiple.amount, one.amount, accuracy: 1e-6)
    }

    func testFXCalendarAgeAndCurrentQuoteFreshness() throws {
        let rates = try fx()
        XCTAssertEqual(rates.quote(currency: "USD", on: "2024-01-10", within: 7)?.match, .carriedForward(daysBack: 7))
        XCTAssertNil(rates.quote(currency: "USD", on: "2024-01-11", within: 7))
        XCTAssertNil(rates.quote(currency: "USD", on: "2026-09-14", within: 7))
        let rows = [trade("a", "2024-01-02", "BUY", 100, 100)]
        XCTAssertFalse(try XCTUnwrap(FXImpactCalculator.impact(ticker: "TEST", transactions: rows,
            rates: rates, asOf: date("2024-01-05"))).isExact)
        XCTAssertNil(FXImpactCalculator.impact(ticker: "TEST", transactions: rows, rates: rates, asOf: date("2024-01-11")))
    }

    func testFIFOUsesExecutionTimeBeforeTradeID() throws {
        let rows = [
            trade("z", "2024-01-02", "BUY", 10, 100, time: "2024-01-02T09:00:00Z"),
            trade("s", "2024-01-02", "SELL", 10, 200, time: "2024-01-02T10:00:00Z"),
            trade("a", "2024-01-02", "BUY", 10, 50, time: "2024-01-02T11:00:00Z")
        ]
        let sales = RealisedProfitCalculator.sales(transactions: rows)
        guard case .estimated(let value) = try XCTUnwrap(sales.first).outcome else { return XCTFail("expected a priced FIFO estimate") }
        XCTAssertEqual(value, 1000)
        let offset = trade("offset", "2024-01-02", "BUY", 10, 80, time: "2024-01-02T10:30:00.000+02:00")
        XCTAssertEqual(LocalTransactionRecord.orderedForLotMatching(rows + [offset]).first?.tradeID, "offset")
    }

    func testDateOnlyAndEqualTimeCSVKeepTheBuyBeforeItsSale() throws {
        for timestamp in ["2024-01-02", "2024-01-02 09:00:00"] {
            let csv = "Date,Action,Ticker,Quantity,Price,Currency,Reference\n"
                + "\(timestamp),BUY,TEST,10,100,USD,z-buy\n"
                + "\(timestamp),SELL,TEST,10,200,USD,a-sell\n"
            let imported = try LocalCSVImporter.parse(Data(csv.utf8))
            XCTAssertTrue(imported.0.isEmpty)
            let sale = try XCTUnwrap(RealisedProfitCalculator.sales(transactions: imported.1).first)
            guard case .estimated(let profit) = sale.outcome else {
                return XCTFail("date-only timestamps must not make a valid sale lose its cost basis")
            }
            XCTAssertEqual(profit, 1000)
        }
        let legacySides = [trade("a-sell", "2024-01-02", "SELL_SHORT", 10, 200),
                           trade("z-buy", "2024-01-02", "BUY_BACK", 10, 100)]
        let legacySale = try XCTUnwrap(RealisedProfitCalculator.sales(transactions: legacySides).first)
        guard case .estimated(let profit) = legacySale.outcome else {
            return XCTFail("legacy buy-side aliases must retain their former tie-break order")
        }
        XCTAssertEqual(profit, 1000)
    }

    func testUKSameDayAcquisitionIsReservedBeforeAnEarlierThirtyDayMatch() {
        let rows = [trade("pool", "2023-01-02", "BUY", 100, 90),
            trade("early", "2024-01-02", "SELL", 10, 100),
            trade("buy", "2024-01-10", "BUY", 10, 110),
            trade("same", "2024-01-10", "SELL", 10, 120)]
        let result = UKShareMatching.disposals(ticker: "TEST", transactions: rows)
        XCTAssertEqual(result.first?.matches.map(\.rule), [.section104])
        XCTAssertEqual(result.last?.matches.map(\.rule), [.sameDay])
    }

    func testEmptyInitialCloudPreservesLocalSettingsButExplicitDeletionWorks() {
        let suite = "audit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("EUR", forKey: "catfolio.displayCurrency")
        defaults.set("saved rules", forKey: "screener.rules")
        let keys: Set<String> = ["catfolio.displayCurrency", "screener.rules"]
        CloudPreferences.applyRemoteValues([:], keys: keys, to: defaults)
        XCTAssertEqual(defaults.string(forKey: "catfolio.displayCurrency"), "EUR")
        XCTAssertEqual(defaults.string(forKey: "screener.rules"), "saved rules")
        CloudPreferences.applyRemoteValues(["catfolio.displayCurrency": "GBP"], keys: keys, to: defaults)
        XCTAssertEqual(defaults.string(forKey: "catfolio.displayCurrency"), "GBP")
        XCTAssertEqual(defaults.string(forKey: "screener.rules"), "saved rules")
        CloudPreferences.applyRemoteValues([:], keys: ["screener.rules"], to: defaults, allowsDeletion: true)
        XCTAssertNil(defaults.object(forKey: "screener.rules"))
    }

    func testAnOlderQuoteCannotOverwriteBrokerPriceAndTimestampUsesObservation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalPortfolioStore(fileURL: url)
        let now = Date()
        let observed = now.addingTimeInterval(-60)
        _ = try await store.replace(positions: [position("A", observedAt: observed)], source: "Moomoo")
        let key = LocalMarketQuoteKey.make(ticker: "TEST", currency: "USD")
        let stale = try await store.updateMarketQuotes([key: .init(price: 80, observedAt: observed.addingTimeInterval(-60))], refreshedAt: now)
        XCTAssertEqual(stale.positions.first?.quotePrice, 120)
        let next = now.addingTimeInterval(-30)
        let fresh = try await store.updateMarketQuotes([key: .init(price: 130, observedAt: next)], refreshedAt: now)
        XCTAssertEqual(fresh.positions.first?.quotePrice, 130)
        XCTAssertEqual(fresh.marketDataUpdatedAt, next)
        XCTAssertEqual(fresh.positions.first?.quoteObservedAt, next)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.positions.first?.quoteObservedAt?.timeIntervalSince1970 ?? 0, next.timeIntervalSince1970, accuracy: 1)

        // Documents saved by older versions have only the aggregate timestamp.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var legacyPositions = try XCTUnwrap(legacy["positions"] as? [[String: Any]])
        legacyPositions[0].removeValue(forKey: "quoteObservedAt")
        legacy["positions"] = legacyPositions
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let guardedLegacy = try await store.updateMarketQuotes(
            [key: .init(price: 70, observedAt: observed.addingTimeInterval(-60))], refreshedAt: now)
        XCTAssertEqual(guardedLegacy.positions.first?.quotePrice, 130)
    }

    func testENRMarketIdentityAndFractionalStrikes() {
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "ENR", currency: "USD"), "ENR")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "ENR", currency: "EUR"), "ENR.DE")
        XCTAssertEqual(LocalMarketDataClient.yahooSymbol(ticker: "RWE", currency: "USD"), "RWE")
        XCTAssertEqual(OIPriceLabel.text(10.1, locale: Locale(identifier: "en_US")), "$10.1")
        XCTAssertEqual(OIPriceLabel.text(10.5, locale: Locale(identifier: "en_US")), "$10.5")
        XCTAssertEqual(CycleComparisonView.axisText(-10), "-10")
        XCTAssertEqual(CycleComparisonView.axisText(0), "0")
    }

    func testAlreadyQueuedFMPRequestHonorsLaterBackoff() async throws {
        let limiter = FMPRequestLimiter(spacing: 0.4)
        try await limiter.waitForTurn()
        let waiting = Task { try await limiter.waitForTurn(); return Date() }
        try await Task.sleep(for: .milliseconds(40))
        let blocked = Date()
        await limiter.backOff(retryAfter: "1")
        let resumed = try await waiting.value
        XCTAssertGreaterThanOrEqual(resumed.timeIntervalSince(blocked), 0.95)
    }
}

@MainActor
final class DetailMarketSyncTests: XCTestCase {
    private func history(price: Double = 130, at time: Date, currency: String = "USD") -> SecurityPriceHistory {
        let day = DayDateCodec.string(from: time)
        let previous = DayDateCodec.string(from: time.addingTimeInterval(-86_400))
        return SecurityPriceHistory(ticker: "TEST", currency: currency,
            points: [.init(dateText: previous, close: 100), .init(dateText: day, close: 120)],
            intradayPoints: [.init(dateText: "minute", close: price, timestamp: time)], trades: [])
    }

    private func model(now: Date, observedAt: Date? = nil) async throws -> AppModel {
        let suite = "DetailMarketSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let position = LocalPositionRecord(ticker: "TEST", name: "Test", shares: 10,
            averageCost: 100, currency: "USD", quotePrice: 120, quoteCurrency: "USD", source: "CSV",
            openedDate: DayDateCodec.string(from: now.addingTimeInterval(-86_400)),
            quoteObservedAt: observedAt)
        let document = LocalPortfolioDocument(source: "CSV", updatedAt: now,
                                              positions: [position], snapshots: [])
        let model = AppModel(defaults: defaults, personalDocumentLoader: { document })
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.holdings.first?.quotePrice, 120)
        return model
    }

    func testDetailPublishesPriceDailyChangeAndPortfolioValueTogether() async throws {
        let now = Date()
        let model = try await model(now: now)
        let cost = model.overview?.summary.totalCost
        try await model.publishSecurityPriceHistory(history(at: now), source: model.portfolioSource, now: now)
        XCTAssertEqual(model.holdings.first?.quotePrice, 130)
        XCTAssertEqual(model.holdings.first?.marketValue, 1300)
        XCTAssertEqual(model.overview?.summary.marketValue, 1300)
        XCTAssertEqual(model.overview?.summary.totalCost, cost)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["TEST"]), 30, accuracy: 1e-9)
    }

    func testDiskRefreshCannotUndoTheDetailQuote() async throws {
        let now = Date()
        let model = try await model(now: now)
        try await model.publishSecurityPriceHistory(history(at: now), source: model.portfolioSource, now: now)
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.holdings.first?.quotePrice, 130)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["TEST"]), 30, accuracy: 1e-9)
    }

    func testOutOfOrderAndOlderBrokerObservationsAreIgnored() async throws {
        let now = Date()
        let model = try await model(now: now, observedAt: now.addingTimeInterval(-60))
        try await model.publishSecurityPriceHistory(history(price: 80, at: now.addingTimeInterval(-120)),
                                             source: model.portfolioSource, now: now)
        XCTAssertEqual(model.holdings.first?.quotePrice, 120)
        XCTAssertNil(model.holdingDailyChanges["TEST"])
        try await model.publishSecurityPriceHistory(history(at: now), source: model.portfolioSource, now: now)
        try await model.publishSecurityPriceHistory(history(price: 90, at: now.addingTimeInterval(-30)),
                                             source: model.portfolioSource, now: now)
        XCTAssertEqual(model.holdings.first?.quotePrice, 130)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["TEST"]), 30, accuracy: 1e-9)
    }

    func testDifferentSourceCurrencyAndExpiredQuotesDoNotChangeHoldings() async throws {
        let now = Date()
        let model = try await model(now: now)
        try await model.publishSecurityPriceHistory(history(at: now), source: .demo, now: now)
        try await model.publishSecurityPriceHistory(history(at: now, currency: "EUR"), source: .personal, now: now)
        try await model.publishSecurityPriceHistory(history(at: now.addingTimeInterval(-8 * 86_400)), source: .personal, now: now)
        try await model.publishSecurityPriceHistory(history(at: now.addingTimeInterval(120)), source: .personal, now: now)
        XCTAssertEqual(model.holdings.first?.quotePrice, 120)
        XCTAssertTrue(model.holdingDailyChanges.isEmpty)
    }

    func testCancellationDoesNotPublish() async throws {
        let now = Date()
        let model = try await model(now: now)
        let value = history(at: now)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await model.publishSecurityPriceHistory(value, source: .personal, now: now)
        }
        try await task.value
        XCTAssertEqual(model.holdings.first?.quotePrice, 120)
    }

    func testETFOnlyConstituentUpdatesHeatmapWithoutInventingAPosition() async throws {
        let now = Date()
        let model = try await model(now: now)
        let original = model.overview?.summary.marketValue
        let prices = history(at: now)
        let constituent = SecurityPriceHistory(ticker: "OTHER", currency: "USD", points: prices.points,
                                               intradayPoints: prices.intradayPoints, trades: [])
        try await model.publishSecurityPriceHistory(constituent, source: .personal, now: now)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["OTHER"]), 30, accuracy: 1e-9)
        XCTAssertEqual(model.holdings.map(\.ticker), ["TEST"])
        XCTAssertEqual(model.overview?.summary.marketValue, original)
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(try XCTUnwrap(model.holdingDailyChanges["OTHER"]), 30, accuracy: 1e-9)
    }

    func testDailyOnlyHistoryRetainsItsRealDateAndIgnoresOlderMinutes() throws {
        let daily = SecurityPriceHistory(ticker: "TEST", currency: "USD",
            points: [.init(dateText: "2026-09-11", close: 100), .init(dateText: "2026-09-14", close: 110)],
            intradayPoints: [.init(dateText: "old", close: 90, timestamp: DayDateCodec.date(from: "2026-09-11"))], trades: [])
        let observation = try XCTUnwrap(daily.latestMarketObservation)
        XCTAssertEqual(observation.price, 110)
        XCTAssertEqual(observation.observedAt, DayDateCodec.date(from: "2026-09-14"))
        XCTAssertEqual(try XCTUnwrap(observation.changePercent), 10, accuracy: 1e-9)
    }
}
