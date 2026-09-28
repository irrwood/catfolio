import XCTest
@testable import CatfolioIOS

final class DCASimulationTests: XCTestCase {
    private func settings() -> DCASettings {
        var c = DCASettings()
        c.start = DayDateCodec.date(from: "2023-10-09")!
        c.end = DayDateCodec.date(from: "2024-02-29")!
        return c
    }
    private func prices(_ value: (Int) -> Double = { _ in 100 }) -> [PolicyPricePoint] {
        var day = DayDateCodec.date(from: "2023-01-02")!, result: [PolicyPricePoint] = []
        while result.count < 340 {
            if ![1,7].contains(DCASimulation.calendar.component(.weekday, from: day)) {
                result.append(.init(day: DayDateCodec.string(from: day), close: value(result.count)))
            }
            day = DCASimulation.calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }
    private func historyDependentPlan() -> DCAConditionPlan {
        .init(rules: [.init(id: "sma", enabled: true, join: .all,
            conditions: [.init(metric: .smaRatio, window: 200, comparison: .lt, threshold: 0.85)], multiplier: 2)])
    }
    func testFixedDCAInvestsEveryDollarWithoutPositionOrReserveLimits() throws {
        let c = settings()
        let result = try DCASimulation.run(settings: c, prices: prices())
        XCTAssertTrue(result.trades.allSatisfy { $0.amount == 500 && $0.deposit == 500 })
        XCTAssertEqual(result.final.holdings, result.final.contributed, accuracy: 1e-8)
        XCTAssertEqual(result.final.baseline, result.final.contributed, accuracy: 1e-8)
    }
    func testVisibleThreeTimesRuleHasNoCooldown() throws {
        var c = settings(); c.start = DayDateCodec.date(from: "2023-10-16")!
        c.end = DayDateCodec.date(from: "2023-10-24")!
        c.conditionPlan = .init(fallbackMultiplier: 3)
        let input = prices().filter { $0.day != "2023-10-16" }
        let result = try DCASimulation.run(settings: c, prices: input)
        XCTAssertEqual(result.trades.map(\.date), ["2023-10-17", "2023-10-23"])
        XCTAssertEqual(result.trades.map(\.amount), [1500, 1500])
    }
    func testExtraBuyingIsFundedDirectlyWithoutCashPool() throws {
        var c = settings()
        c.end = DayDateCodec.date(from: "2023-10-20")!
        c.conditionPlan = .init(fallbackMultiplier: 3)
        let result = try DCASimulation.run(settings: c, prices: prices())
        XCTAssertEqual(result.trades.map(\.amount), [1500, 1500])
        XCTAssertEqual(result.trades.map(\.deposit), [1500, 1500])
        XCTAssertEqual(result.final.contributed, 3000)
        XCTAssertEqual(result.final.baselineContributed, 1000)
        XCTAssertEqual(result.final.value, 3000)
        XCTAssertEqual(result.final.baseline, 1000)
        XCTAssertEqual(result.profit, 0)
        XCTAssertEqual(result.baselineProfit, 0)
        XCTAssertEqual(result.excessProfit, 0, "Extra principal is not extra profit")
        XCTAssertTrue(result.warnings.isEmpty)
    }
    func testDifferentPrincipalUsesSeparateProfitDenominators() throws {
        var c = settings(); c.start = DayDateCodec.date(from: "2024-01-08")!
        c.end = DayDateCodec.date(from: "2024-01-16")!
        c.conditionPlan = .init(fallbackMultiplier: 2)
        let input: [PolicyPricePoint] = [.init(day: "2024-01-08", close: 100),
            .init(day: "2024-01-15", close: 200), .init(day: "2024-01-16", close: 150)]
        let result = try DCASimulation.run(settings: c, prices: input)
        XCTAssertEqual(result.final.contributed, 2000)
        XCTAssertEqual(result.final.baselineContributed, 1000)
        XCTAssertEqual(result.profit, 250)
        XCTAssertEqual(result.baselineProfit, 125)
        XCTAssertEqual(result.excessProfit, 125)
        XCTAssertEqual(result.returnRatio, 0.125)
        XCTAssertEqual(result.baselineReturnRatio, 0.125)
        XCTAssertEqual(result.excessReturnRatio, 0)
    }
    func testAnnualizationStartsAtFirstActualPurchaseAfterPause() throws {
        var c = settings(); c.start = DayDateCodec.date(from: "2023-01-02")!
        c.end = DayDateCodec.date(from: "2023-03-10")!
        c.conditionPlan = .init(rules: [.init(id: "pause", enabled: true, join: .all,
            conditions: [.init(metric: .price, window: 1, comparison: .lt, threshold: 100)], multiplier: 0)])
        let input = prices().map { PolicyPricePoint(day: $0.day, close: $0.day < "2023-02-10" ? 90 : 110) }
        let result = try DCASimulation.run(settings: c, prices: input)
        XCTAssertEqual(result.trades.first(where: { $0.amount > 0 })?.date, "2023-02-13")
        XCTAssertNil(result.annualizedReturn, "Only 25 days since actual investment")
        XCTAssertNotNil(result.baselineAnnualizedReturn)
    }
    func testVariableInvestmentsXIRRDiscountsEachSeriesOwnFlows() throws {
        var c = settings(); c.conditionPlan = .init(rules: [.init(id: "double", enabled: true, join: .all,
            conditions: [.init(metric: .price, window: 1, comparison: .lt, threshold: 100)], multiplier: 2)], fallbackMultiplier: 0.5)
        let result = try DCASimulation.run(settings: c, prices: prices { 100 * exp(0.2 * sin(Double($0) / 12)) })
        let first = result.curve[0].date
        for strategy in [true, false] {
            let rate = try XCTUnwrap(strategy ? result.annualizedReturn : result.baselineAnnualizedReturn)
            var npv = 0.0
            for trade in result.trades {
                let years = DayDateCodec.date(from: trade.date)!.timeIntervalSince(first) / (365.25 * 86400)
                npv -= (strategy ? trade.amount : trade.scheduledAmount) / pow(1 + rate, years)
            }
            let terminal = strategy ? result.final.value : result.final.baseline
            npv += terminal / pow(1 + rate, result.final.date.timeIntervalSince(first) / (365.25 * 86400))
            XCTAssertEqual(npv, 0, accuracy: 0.0001)
        }
    }
    func testVisiblePauseAndQuarterBuyingHaveNoHiddenMinimum() throws {
        var c = settings(); c.conditionPlan = .init(fallbackMultiplier: 0)
        let paused = try DCASimulation.run(settings: c, prices: prices())
        XCTAssertTrue(paused.trades.allSatisfy { $0.amount == 0 && $0.deposit == 0 })
        XCTAssertEqual(paused.final.contributed, 0)
        XCTAssertEqual(paused.final.value, 0)
        XCTAssertNil(paused.annualizedReturn)
        c.conditionPlan?.fallbackMultiplier = 0.25
        let reduced = try DCASimulation.run(settings: c, prices: prices())
        XCTAssertTrue(reduced.trades.allSatisfy { $0.amount == 125 })
    }
    func testFixedPurchasesAndProfitMatchHandCalculatedLedger() throws {
        var c = settings()
        c.start = DayDateCodec.date(from: "2024-01-08")!
        c.end = DayDateCodec.date(from: "2024-01-16")!
        let input: [PolicyPricePoint] = [.init(day: "2024-01-08", close: 100),
            .init(day: "2024-01-15", close: 200), .init(day: "2024-01-16", close: 150)]
        let result = try DCASimulation.run(settings: c, prices: input)
        // $500 / $100 + $500 / $200 = 7.5 shares; 7.5 * $150 = $1,125.
        XCTAssertEqual(result.shares, 7.5)
        XCTAssertEqual(result.final.value, 1125)
        XCTAssertEqual(result.profit, 125)
        XCTAssertEqual(result.returnRatio, 0.125)
        XCTAssertEqual(result.final.baseline, 1125)
        XCTAssertEqual(result.maxDrawdown, -0.25, accuracy: 1e-10)
    }
    @MainActor func testRetiredSavedRulesAreIgnoredAndNotSavedAgain() throws {
        let name = "DCA-retired-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var c = settings(); c.baseAmount = 750
        c.conditionPlan = .init(fallbackMultiplier: 2)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        let retired: [String: Any] = ["initialCash": 100_000, "maxPosition": 1, "cashReserve": 99, "cooldown": 365,
            "maxMultiplier": 0, "minMultiplier": 99, "smaEnabled": true, "priceLow": 0.85,
            "priceHigh": 1.15, "rvEnabled": true, "rvThreshold": 0, "erEnabled": true,
            "erThreshold": 99, "drawdownEnabled": true, "drawdownThreshold": 99,
            "gateJoin": "all", "boostJoin": "any", "rvOperator": "LTE", "erOperator": "GTE"]
        old.merge(retired) { _, new in new }
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "catfolio.dca.ios.v1")
        let store = DCAStore(defaults: defaults)
        XCTAssertEqual(store.settings, c, "Visible settings and custom rules survive old hidden values")
        let result = try DCASimulation.run(settings: store.settings, prices: prices())
        XCTAssertTrue(result.trades.allSatisfy { $0.amount == 1500 })
        store.save()
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "catfolio.dca.ios.v1"))) as? [String: Any])
        XCTAssertTrue(Set(saved.keys).isDisjoint(with: Set(retired.keys)))
    }
    func testFlatMarketConservesCashAndNoFlowDrivenReturn() throws {
        let result = try DCASimulation.run(settings: settings(), prices: prices())
        XCTAssertEqual(result.returnRatio, 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.annualizedReturn), 0, accuracy: 1e-9)
        XCTAssertEqual(result.maxDrawdown, 0)
        for p in result.curve {
            XCTAssertEqual(p.value, p.contributed, accuracy: 1e-8)
            XCTAssertEqual(p.value, p.holdings, accuracy: 1e-8)
            XCTAssertEqual(p.value, p.baseline, accuracy: 1e-8)
        }
    }
    func testWarmupSkipsInvestment() throws {
        var c = settings(); c.start = DayDateCodec.date(from: "2023-01-02")!; c.end = DayDateCodec.date(from: "2023-02-01")!; c.conditionPlan = historyDependentPlan()
        let result = try DCASimulation.run(settings: c, prices: prices())
        XCTAssertEqual(result.buyCount, 0)
        XCTAssertEqual(result.final.contributed, 0)
        XCTAssertFalse(result.warnings.isEmpty)
    }
    func testMonthEndAnchorAndWeekendRollForward() throws {
        let start = DayDateCodec.date(from: "2024-01-31")!
        XCTAssertEqual((0...3).map { DayDateCodec.string(from: DCASimulation.scheduledDate(start: start, period: $0, frequency: .monthly)) }, ["2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30"])
        var c = settings(); c.start = DayDateCodec.date(from: "2023-10-07")!; c.end = DayDateCodec.date(from: "2023-10-23")!
        XCTAssertEqual(try DCASimulation.run(settings: c, prices: prices()).trades.map(\.date), ["2023-10-09", "2023-10-16", "2023-10-23"])
    }
    func testInvalidParametersAndDuplicatePricesRejected() throws {
        var c = settings(); c.baseAmount = .nan
        XCTAssertThrowsError(try DCASimulation.run(settings: c, prices: prices()))
        c = settings(); c.symbol = "BP.L"; XCTAssertNotNil(c.validationError)
        c.symbol = "brk.b"; XCTAssertEqual(c.normalizedSymbol, "BRK-B"); XCTAssertNil(c.validationError)
        let input = prices()
        XCTAssertThrowsError(try DCASimulation.run(settings: settings(), prices: input + [input[0]]))
    }
    func testUnavailableStartDoesNotInventCatchupDeposits() throws {
        var c = settings(); c.start = DayDateCodec.date(from: "2022-01-01")!
        let result = try DCASimulation.run(settings: c, prices: prices())
        XCTAssertEqual(result.trades[0].deposit, 500)
        XCTAssertEqual(result.curve[0].day, "2023-01-02")
    }
    func testDepositsDoNotEraseMarketDrawdown() throws {
        var c = settings()
        c.end = DayDateCodec.date(from: "2023-10-20")!
        let input = prices().map { PolicyPricePoint(day: $0.day, close: $0.day <= "2023-10-09" ? 100 : 50) }
        let result = try DCASimulation.run(settings: c, prices: input)
        XCTAssertEqual(result.trades[0].amount, 500)
        XCTAssertEqual(result.maxDrawdown, -0.5, accuracy: 1e-9)
        XCTAssertEqual(result.final.drawdown, -0.5, accuracy: 1e-9)
        XCTAssertEqual(result.baselineMaxDrawdown, -0.5, accuracy: 1e-9)
        XCTAssertNil(result.baselineAnnualizedReturn)
        XCTAssertEqual(result.final.contributed, 1000)
        XCTAssertEqual(result.profit, -250, accuracy: 1e-9)
        XCTAssertNil(result.annualizedReturn, "Do not annualize periods under 30 days")
    }
    func testAnnualizedReturnDiscountsActualDepositDates() throws {
        let c = settings()
        let result = try DCASimulation.run(settings: c, prices: prices { 100 * pow(1.002, Double($0)) })
        let rate = try XCTUnwrap(result.annualizedReturn)
        let first = result.curve[0].date
        let secondsPerYear = 365.25 * 86400
        var npv = 0.0
        for trade in result.trades {
            let years = DayDateCodec.date(from: trade.date)!.timeIntervalSince(first) / secondsPerYear
            npv -= trade.deposit / pow(1 + rate, years)
        }
        npv += result.final.value / pow(1 + rate, result.final.date.timeIntervalSince(first) / secondsPerYear)
        XCTAssertEqual(npv, 0, accuracy: 0.0001)
    }
    func testUnconditionalStrategyMatchesBaselineComparisonMetrics() throws {
        let result = try DCASimulation.run(settings: settings(), prices: prices { 100 * exp(0.2 * sin(Double($0) / 12)) })
        XCTAssertEqual(result.profit, result.baselineProfit, accuracy: 1e-8)
        XCTAssertEqual(result.returnRatio, result.baselineReturnRatio, accuracy: 1e-10)
        XCTAssertEqual(result.maxDrawdown, result.baselineMaxDrawdown, accuracy: 1e-10)
        XCTAssertEqual(result.buyCount, result.baselineBuyCount)
        XCTAssertEqual(try XCTUnwrap(result.annualizedReturn), try XCTUnwrap(result.baselineAnnualizedReturn), accuracy: 1e-10)
        XCTAssertEqual(result.excessProfit, 0, accuracy: 1e-8)
        XCTAssertEqual(result.excessReturnRatio, 0, accuracy: 1e-10)
    }
    func testBaselineComparisonRemainsIndependentOfUnknownStrategySignals() throws {
        var c = settings()
        c.start = DayDateCodec.date(from: "2023-01-02")!
        c.end = DayDateCodec.date(from: "2023-06-30")!
        c.conditionPlan = historyDependentPlan()
        let input = prices { 100 * pow(1.001, Double($0)) }
        let result = try DCASimulation.run(settings: c, prices: input)
        XCTAssertEqual(result.buyCount, 0)
        XCTAssertEqual(result.returnRatio, 0, accuracy: 1e-10)
        XCTAssertGreaterThan(result.baselineBuyCount, 0)
        XCTAssertGreaterThan(result.baselineProfit, 0)
        XCTAssertLessThan(result.excessProfit, 0)
        XCTAssertEqual(result.excessProfit, -result.baselineProfit, accuracy: 1e-8)
        c.conditionPlan = nil
        let unconditional = try DCASimulation.run(settings: c, prices: input)
        XCTAssertEqual(result.final.baselineContributed, unconditional.final.contributed)
        XCTAssertEqual(result.final.baseline, unconditional.final.value, accuracy: 1e-8)
        // Independently discount the baseline's terminal asset with the shared actual cash-flow dates.
        let rate = try XCTUnwrap(result.baselineAnnualizedReturn)
        let first = result.curve[0].date
        var npv = 0.0
        for trade in result.trades {
            let years = DayDateCodec.date(from: trade.date)!.timeIntervalSince(first) / (365.25 * 86400)
            npv -= trade.scheduledAmount / pow(1 + rate, years)
        }
        npv += result.final.baseline / pow(1 + rate, result.final.date.timeIntervalSince(first) / (365.25 * 86400))
        XCTAssertEqual(npv, 0, accuracy: 0.0001)
    }
    func testDefaultStrategyMatchesFixedDCA() throws {
        let c = settings()
        let result = try DCASimulation.run(settings: c, prices: prices { 100 * exp(0.15 * sin(Double($0) / 9)) })
        XCTAssertEqual(result.excessProfit, 0, accuracy: 1e-8)
        XCTAssertEqual(result.maxDrawdown, result.baselineMaxDrawdown, accuracy: 1e-10)
        XCTAssertEqual(result.buyCount, result.baselineBuyCount)
        XCTAssertTrue(result.trades.allSatisfy { $0.decision.multiplier == 1 })
    }
    func testDefaultAmountDoesNotReactToRisingOrFallingPrices() throws {
        for frequency in DCAFrequency.allCases {
            var c = settings(); c.frequency = frequency; c.baseAmount = 50
            for slope in [-0.2, 0.2] {
                let result = try DCASimulation.run(settings: c, prices: prices { 200 + Double($0) * slope })
                XCTAssertTrue(result.trades.allSatisfy { abs($0.amount - 50) < 1e-8 })
                XCTAssertEqual(result.final.value, result.final.baseline, accuracy: 1e-8)
            }
        }
    }
    @MainActor func testSavedECDAFlagIsIgnoredWithoutLosingVisibleSettingsOrConditions() throws {
        let name = "DCA-migration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var c = settings(); c.symbol = "QQQ"; c.baseAmount = 750; c.frequency = .monthly
        c.conditionPlan = historyDependentPlan()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        old["ecdaEnabled"] = true
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "catfolio.dca.ios.v1")
        let store = DCAStore(defaults: defaults)
        XCTAssertEqual(store.settings, c)
        store.save()
        let saved = try XCTUnwrap(defaults.data(forKey: "catfolio.dca.ios.v1"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNil(json["ecdaEnabled"])
        XCTAssertEqual(DCAStore(defaults: defaults).settings, c)

        old.removeValue(forKey: "conditionPlan")
        let migrated = try JSONDecoder().decode(DCASettings.self, from: JSONSerialization.data(withJSONObject: old))
        let result = try DCASimulation.run(settings: migrated, prices: prices { 200 - Double($0) * 0.2 })
        XCTAssertTrue(result.trades.allSatisfy { $0.decision.multiplier == 1 })
        XCTAssertEqual(result.final.value, result.final.baseline, accuracy: 1e-8)
    }
    @MainActor func testConfigurationPersistsAndResultsStaySeparate() throws {
        let name = "DCA-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DCAStore(defaults: defaults)
        store.settings = settings(); store.settings.conditionPlan = historyDependentPlan()
        store.save()
        let restored = DCAStore(defaults: defaults)
        XCTAssertEqual(restored.settings, store.settings)
        XCTAssertNil(restored.result)
    }
}

final class DCAInstrumentSearchTests: XCTestCase {
    func testPresetsAndOtherStocksAndETFsAreSelectable() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        for symbol in DCAInstrumentSearch.presets + ["AMD", "VOO", "BRK-B"] {
            let result = try XCTUnwrap(DCAInstrumentSearch.search(symbol, in: catalog).first, symbol)
            XCTAssertEqual(result.ticker, symbol)
            XCTAssertEqual(result.currency, "USD")
            var settings = DCASettings(); settings.symbol = result.ticker
            XCTAssertNil(settings.validationError)
        }
        XCTAssertTrue(try XCTUnwrap(DCAInstrumentSearch.search("VOO", in: catalog).first).isFund)
    }
    func testTickerEnglishAndChineseCompanyNames() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        XCTAssertEqual(DCAInstrumentSearch.search("  aapl  ", in: catalog).first?.ticker, "AAPL")
        XCTAssertTrue(DCAInstrumentSearch.search("Apple", in: catalog).contains { $0.ticker == "AAPL" })
        XCTAssertTrue(DCAInstrumentSearch.search("苹果", in: catalog).contains { $0.ticker == "AAPL" })
        XCTAssertTrue(DCAInstrumentSearch.search("伯克希尔", in: catalog).contains { $0.ticker == "BRK-B" })
        XCTAssertEqual(DCAInstrumentSearch.search("brk.b", in: catalog).first?.ticker, "BRK-B")
    }
    func testSearchKeepsMarketsAndCurrencyWithinEngineScope() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        for query in ["Toyota", "Shell", "a", "ETF", "7203", "VOD.L"] {
            let results = DCAInstrumentSearch.search(query, in: catalog)
            XCTAssertLessThanOrEqual(results.count, 40)
            XCTAssertEqual(Set(results.map(\.ticker)).count, results.count)
            XCTAssertTrue(results.allSatisfy { $0.market == "US" && $0.currency == "USD" })
            for result in results {
                var settings = DCASettings(); settings.symbol = result.ticker
                XCTAssertNil(settings.validationError)
            }
        }
        XCTAssertTrue(DCAInstrumentSearch.search("7203", in: catalog).isEmpty)
    }
    func testEmptyAndNoMatchDoNotInventTickers() throws {
        let catalog = try CompanyReferenceCatalog.bundled.get()
        XCTAssertTrue(DCAInstrumentSearch.search("  ", in: catalog).isEmpty)
        XCTAssertTrue(DCAInstrumentSearch.search("a company that is not in this directory 93852", in: catalog).isEmpty)
    }
}
