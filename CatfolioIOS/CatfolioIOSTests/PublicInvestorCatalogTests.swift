import XCTest
@testable import CatfolioIOS

final class PublicInvestorCatalogTests: XCTestCase {
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

    func testDisclosureNamesRemoveRedundantCodesWithoutAddingTypeLabels() {
        let cases = [
            ("AAPL", "Apple Inc. (AAPL) [ST]", "Apple"),
            ("AAPL", "Apple Inc. - Common Stock (AAPL) [OP]", "Apple"),
            ("MORN", "Morningstar, Inc. (MORN) [ST]", "Morningstar"),
            ("XYZ", "Example Corporation (XYZ) [ST]", "Example"),
            ("NVDA", "Nine Forty Five Battery LLC [OL]", "Nine Forty Five Battery LLC"),
            ("XYZ", "Example [Unknown]", "Example [Unknown]")
        ]
        for (ticker, source, expected) in cases {
            XCTAssertEqual(PublicDisclosureFormat.securityName(ticker: ticker, name: source, mode: .original), expected)
        }
        XCTAssertEqual(PublicDisclosureFormat.securityName(ticker: "AAPL", name: "Apple Inc. (AAPL) [ST]", mode: .chineseShort), "苹果")
    }

    func testPelosiHoldingNamesCleanDisplayAndKeepSourceAndOptionIdentity() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        let document = PublicInvestorAccountAdapter.document(catalog: catalog, selection: "pelosi")
        let holdings = try PublicInvestorAccountAdapter.presentation(for: document).2
        XCTAssertFalse(holdings.isEmpty)
        for holding in holdings {
            XCTAssertFalse(holding.shortName.contains("[ST]"))
            XCTAssertFalse(holding.shortName.contains("[OP]"))
            XCTAssertFalse(holding.shortName.contains("[OL]"))
            if let ticker = holding.publicDisclosure?.underlyingTicker {
                XCTAssertFalse(holding.shortName.contains("(\(ticker))"))
            }
        }
        XCTAssertTrue(holdings.contains { $0.displayName.contains("[ST]") })
        XCTAssertTrue(holdings.contains { $0.ticker.contains("[CALL") && $0.publicDisclosure?.instrumentLabel != nil })
        XCTAssertTrue(holdings.contains { $0.ticker == "AAPL" })
    }

    func testBundledCoreReleasePreservesDisclosureBoundaries() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        XCTAssertEqual(catalog.investors.count, 6)
        let pelosi = try XCTUnwrap(catalog.investors.first { $0.id == "pelosi" })
        XCTAssertEqual(pelosi.snapshot?.effectiveDate, "2025-12-31")
        XCTAssertTrue(try XCTUnwrap(pelosi.snapshot).positions.contains { $0.reportedValue == nil && $0.reportedValueLow != nil })
        for investor in catalog.investors {
            XCTAssertTrue(investor.activities.allSatisfy { $0.filedDate <= catalog.asOf })
            XCTAssertEqual(Set(investor.activities.map(\.id)).count, investor.activities.count)
            if investor.sourceType == "SEC_13F" {
                XCTAssertTrue(investor.activities.allSatisfy { $0.exactDate == nil && $0.amount == nil })
            }
        }
        let musk = try XCTUnwrap(catalog.investors.first { $0.id == "musk" })
        XCTAssertNil(musk.snapshot)
        XCTAssertTrue(musk.activities.isEmpty)
    }

    func testSelectionSupportsMultiplePeopleAndExplicitEmptyState() {
        let two = PublicInvestorPreferences.toggling("hh", in: "pelosi")
        XCTAssertEqual(PublicInvestorPreferences.selectedIDs(two), ["pelosi", "hh"])
        XCTAssertEqual(PublicInvestorPreferences.toggling("pelosi", in: "pelosi"), "")
        XCTAssertEqual(PublicInvestorPreferences.toggling("hh", in: two), "pelosi")
        XCTAssertEqual(PublicInvestorPreferences.selectedIDs("pelosi,pelosi").count, 1)
    }

    func testMissingAmountsAreNotFabricatedAndRangesRemainRanges() {
        XCTAssertEqual(PublicDisclosureFormat.amount(nil, low: nil, high: nil), "未披露")
        XCTAssertTrue(PublicDisclosureFormat.amount(nil, low: 1_001, high: 15_000).contains("–"))
        XCTAssertTrue(PublicDisclosureFormat.amount(nil, low: 1_001, high: nil).hasPrefix("≥"))
    }

    func testInvalidSchemaFailsInsteadOfShowingEmptyCatalog() {
        XCTAssertThrowsError(try PublicInvestorCatalog.decode(Data(#"{"schemaVersion":2,"releaseId":"test","asOf":"2026-09-07","investors":[]}"#.utf8)))
    }
    func testInvestorDocumentsUseTheExistingAccountAndHoldingPipeline() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        let document = PublicInvestorAccountAdapter.document(catalog: catalog, selection: "pelosi,hh")
        XCTAssertEqual(Set(document.accounts.map(\.id)), ["公开披露|pelosi", "公开披露|hh"])
        XCTAssertTrue(document.transactions?.isEmpty == true)
        XCTAssertTrue(document.snapshots.isEmpty)
        let scoped = document.scoped(to: ["公开披露|hh"])
        XCTAssertTrue(scoped.positions.allSatisfy { $0.accountID == "hh" })
        let result = try LocalPortfolioEngine.presentation(for: scoped)
        XCTAssertFalse(result.2.isEmpty)
        XCTAssertTrue(result.0.summary.marketValue.isFinite)
        XCTAssertTrue(result.0.summary.totalCost.isNaN)
        XCTAssertTrue(result.2.allSatisfy { $0.publicDisclosure != nil && $0.unrealized.isNaN })
        XCTAssertEqual(Set(result.2.map(\.id)).count, result.2.count)
    }

    func testPelosiUpperBoundsReachAccountTotalsHoldingsAndWeights() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        let document = PublicInvestorAccountAdapter.document(catalog: catalog, selection: "pelosi")
        let result = try LocalPortfolioEngine.presentation(for: document.scoped(to: Set(document.accounts.map(\.id))))
        XCTAssertFalse(result.2.isEmpty)
        let pelosi = try XCTUnwrap(catalog.investors.first { $0.id == "pelosi" })
        let expected = try XCTUnwrap(pelosi.snapshot).positions.reduce(0) { $0 + ($1.reportedValue ?? $1.reportedValueHigh ?? 0) }
        XCTAssertEqual(result.0.summary.marketValue, expected, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(document.accounts.first).marketValueUSD, expected, accuracy: 0.01)
        XCTAssertEqual(result.2.reduce(0) { $0 + $1.marketValue }, expected, accuracy: 0.01)
        XCTAssertEqual(result.2.reduce(0) { $0 + $1.weight }, 1, accuracy: 0.000001)
        XCTAssertTrue(result.2.contains { $0.shares.isNaN && $0.publicDisclosure?.low != nil })
        XCTAssertTrue(result.2.allSatisfy { !$0.displayedMarketValue.contains("–") })
        XCTAssertTrue(result.2.contains { $0.publicDisclosure?.usesUpperBoundEstimate == true })
        let combined = PublicAccountDisclosure.combining(document.positions.compactMap(\.publicDisclosure))
        XCTAssertEqual(combined.usesUpperBoundEstimate, true)
        XCTAssertLessThan(try XCTUnwrap(combined.low), try XCTUnwrap(combined.value))
        XCTAssertFalse(result.1.positionHistory.available)
    }

    func testOptionsRemainSeparateFromEquityAndHaveNoInventedContractQuantity() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        let document = PublicInvestorAccountAdapter.document(catalog: catalog, selection: "scion")
        let options = document.positions.filter { $0.publicDisclosure?.instrumentLabel != nil }
        XCTAssertFalse(options.isEmpty)
        XCTAssertTrue(options.allSatisfy { $0.shares.isNaN && $0.ticker.contains("[") })
        XCTAssertTrue(options.allSatisfy { $0.publicDisclosure?.value != nil })
    }

    func testEmptySelectionAndUnavailableOwnershipStayEmpty() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        for selection in ["", "musk"] {
            let document = PublicInvestorAccountAdapter.document(catalog: catalog, selection: selection)
            let scoped = document.scoped(to: Set(document.accounts.map(\.id)))
            XCTAssertTrue(scoped.isPublicDisclosure)
            XCTAssertTrue(scoped.positions.isEmpty)
            XCTAssertTrue(try LocalPortfolioEngine.presentation(for: scoped).0.summary.marketValue.isNaN)
        }
    }

    func testUpperBoundPolicyIsLimitedToPelosiAndDoesNotInventMissingBounds() {
        XCTAssertEqual(PublicInvestorAccountAdapter.valuation(investorID: "pelosi", reportedValue: nil, upperBound: 5000), 5000)
        XCTAssertEqual(PublicInvestorAccountAdapter.valuation(investorID: "pelosi", reportedValue: 3000, upperBound: 5000), 3000)
        XCTAssertNil(PublicInvestorAccountAdapter.valuation(investorID: "pelosi", reportedValue: nil, upperBound: nil))
        XCTAssertNil(PublicInvestorAccountAdapter.valuation(investorID: "hh", reportedValue: nil, upperBound: 5000))
    }

    private func ledgerFixture(unresolvedCUSIP: String? = nil) throws -> PublicInvestorCatalog {
        let raw = #"""
        {"schemaVersion":1,"releaseId":"fixture","asOf":"2023-04-04","investors":[
          {"investorId":"hh","displayName":"H&H","managerName":"H&H","sourceType":"SEC_13F","portfolioSource":"PUBLIC_DISCLOSURE","snapshot":null,"activities":[],"history":[
            {"snapshotId":"q1","effectiveDate":"2022-12-31","filedDate":"2023-01-03","currency":"USD","sourceURL":"https://example.test/1","confidence":"VERIFIED","completeReport":true,"positions":[{"positionId":"1","ticker":"TEST","cusip":"known","shares":10,"confidence":"VERIFIED"}]},
            {"snapshotId":"q2","effectiveDate":"2023-03-31","filedDate":"2023-04-03","currency":"USD","sourceURL":"https://example.test/2","confidence":"VERIFIED","completeReport":true,"positions":[{"positionId":"1","ticker":"TEST","shares":8,"confidence":"VERIFIED"}]}
          ]},
          {"investorId":"pelosi","displayName":"Pelosi","managerName":"Household","sourceType":"HOUSE_PTR","portfolioSource":"PUBLIC_DISCLOSURE","snapshot":null,"history":[
            {"snapshotId":"annual","effectiveDate":"2022-12-31","filedDate":"2023-01-03","currency":"USD","sourceURL":"https://example.test/a","confidence":"INCOMPLETE","positions":[{"positionId":"1","ticker":"TEST","reportedValueLow":50,"reportedValueHigh":100,"confidence":"INCOMPLETE"}]}
          ],"activities":[
            {"activityId":"buy","type":"BUY","exactDate":"2023-01-04","filedDate":"2023-01-05","sourceURL":"https://example.test/b","ticker":"TEST","amountHigh":40,"confidence":"VERIFIED"},
            {"activityId":"sell","type":"SELL","exactDate":"2023-01-05","filedDate":"2023-01-06","sourceURL":"https://example.test/c","ticker":"TEST","amountHigh":60,"confidence":"VERIFIED"}
          ]}
        ]}
        """#
        let value = unresolvedCUSIP.map { raw.replacingOccurrences(of: "\"ticker\":\"TEST\",\"shares\":8", with: "\"ticker\":null,\"cusip\":\"\($0)\",\"shares\":8") } ?? raw
        return try PublicInvestorCatalog.decode(Data(value.utf8))
    }

    func testLedgerFillsDriveCostDailySnapshotsAndPerformance() throws {
        let result = PublicInvestorLedger.build(catalog: try ledgerFixture(), selection: "hh,pelosi",
            prices: ["TEST": ["2023-01-03":10,"2023-01-04":20,"2023-01-05":20,"2023-04-03":20,"2023-04-04":20]], splits: nil, asOf:"2023-04-04")
        let doc = result.document
        XCTAssertEqual(doc.transactions?.count, 5)
        XCTAssertEqual(Set(doc.transactions!.map(\.id)).count, 5)
        let hh = doc.scoped(to: ["公开披露|hh"])
        let p = try LocalPortfolioEngine.presentation(for: hh)
        XCTAssertEqual(p.2.first?.shares, 8)
        XCTAssertEqual(p.2.first?.averageCost, 10)
        XCTAssertEqual(p.2.first?.marketValue, 160)
        XCTAssertEqual(p.2.first?.unrealized, 80)
        XCTAssertEqual(hh.snapshots.last?.costUSD, 60)
        XCTAssertEqual(hh.snapshots.last?.marketValueUSD, 160)
        XCTAssertTrue(try LocalPortfolioEngine.comparison(for: hh).available)
        let pelosi = doc.scoped(to: ["公开披露|pelosi"])
        XCTAssertEqual(pelosi.positions.first?.shares, 9)
        XCTAssertEqual(pelosi.snapshots.last?.costUSD, 80)
        XCTAssertTrue(try LocalPortfolioEngine.presentation(for: pelosi).0.summary.unrealized.isFinite)
        XCTAssertNoThrow(try JSONEncoder().encode(doc))
    }

    func testReconstructionAppliesSplitsWithoutCreatingFalseTrades() throws {
        let raw = #"{"schemaVersion":1,"splits":{"TEST":[{"d":"2023-01-04","f":1,"t":2}]}}"#
        let splits = try JSONDecoder().decode(StockSplitCatalog.self, from: Data(raw.utf8))
        let result = PublicInvestorLedger.build(catalog: try ledgerFixture(), selection: "hh",
            prices: ["TEST":["2023-01-03":5,"2023-01-04":5]], splits:splits, asOf:"2023-01-04")
        XCTAssertEqual(result.document.transactions?.count, 1)
        XCTAssertEqual(result.document.transactions?.first?.quantity, 10)
        XCTAssertEqual(result.document.transactions?.first?.price, 10)
        XCTAssertEqual(result.document.positions.first?.shares, 20)
        XCTAssertEqual(result.document.positions.first?.averageCost, 5)
        XCTAssertEqual(result.document.snapshots.last?.marketValueUSD, 100)
    }

    func testMissingPricesDoNotCreateZeroCostOrPlaceholderTrades() throws {
        let result = PublicInvestorLedger.build(catalog: try ledgerFixture(), selection: "hh", prices: [:], splits:nil, asOf:"2023-04-04")
        XCTAssertTrue(result.document.transactions!.isEmpty)
        XCTAssertTrue(result.document.positions.isEmpty)
        XCTAssertTrue(result.document.snapshots.isEmpty)
    }

    func testAnUnresolvedRowDoesNotRetainUnrelatedExitedHoldings() throws {
        let prices = ["TEST":["2023-01-03":10.0,"2023-04-03":20.0]]
        let exited = PublicInvestorLedger.build(catalog: try ledgerFixture(unresolvedCUSIP: "unrelated"), selection:"hh", prices:prices, splits:nil, asOf:"2023-04-03")
        XCTAssertTrue(exited.document.positions.isEmpty)
        XCTAssertEqual(exited.document.transactions?.last?.action, "SELL")
        let retained = PublicInvestorLedger.build(catalog: try ledgerFixture(unresolvedCUSIP: "known"), selection:"hh", prices:prices, splits:nil, asOf:"2023-04-03")
        XCTAssertEqual(retained.document.positions.first?.shares, 10)
        XCTAssertEqual(retained.document.transactions?.count, 1)
    }

    @MainActor
    func testLiveInvestorAccountTodayHistoryAndPerformance() async throws {
        let defaults = UserDefaults.standard
        let oldMode = defaults.object(forKey: PublicInvestorPreferences.enabledKey)
        let oldSelection = defaults.object(forKey: PublicInvestorPreferences.selectionKey)
        defaults.set(true, forKey: PublicInvestorPreferences.enabledKey)
        defaults.set("pelosi", forKey: PublicInvestorPreferences.selectionKey)
        defer {
            if let oldMode { defaults.set(oldMode, forKey: PublicInvestorPreferences.enabledKey) } else { defaults.removeObject(forKey: PublicInvestorPreferences.enabledKey) }
            if let oldSelection { defaults.set(oldSelection, forKey: PublicInvestorPreferences.selectionKey) } else { defaults.removeObject(forKey: PublicInvestorPreferences.selectionKey) }
        }
        for selection in ["pelosi", "hh", "berkshire", "scion", "ark", "pelosi,hh,ark"] {
            defaults.set(selection, forKey: PublicInvestorPreferences.selectionKey)
            let model = AppModel()
            await model.refreshPortfolio()
            XCTAssertNil(model.portfolioError, selection)
            XCTAssertFalse(model.holdings.isEmpty, selection)
            XCTAssertTrue(model.holdings.allSatisfy { $0.shares.isFinite && $0.averageCost.isFinite && $0.quotePrice.isFinite && $0.marketValue.isFinite }, selection)
            XCTAssertFalse(model.holdingDailyChanges.isEmpty, selection)
            XCTAssertGreaterThan(model.portfolioChart?.positionHistory.rows.count ?? 0, 2, selection)
            await model.refreshReturns()
            XCTAssertNil(model.returnsError, selection)
            XCTAssertEqual(model.comparison?.available, true, selection)
            if selection == "pelosi" || selection == "ark" {
                await model.refreshReturnsPage()
                XCTAssertNotNil(model.returnsAnalytics)
                XCTAssertFalse(model.isReturnsLoading)
                XCTAssertFalse(model.isReturnsAnalyticsLoading)
            }
            print("INVESTOR_LIVE: \(selection), holdings=\(model.holdings.count), today=\(model.holdingDailyChanges.count), history=\(model.portfolioChart?.positionHistory.rows.count ?? 0), performance=\(model.comparison?.dates.count ?? 0)")
        }
    }

}
