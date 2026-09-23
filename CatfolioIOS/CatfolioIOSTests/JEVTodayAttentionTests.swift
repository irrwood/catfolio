import XCTest
@testable import CatfolioIOS

/// What JEV 今日关注 sends to Jev, and how it reads the answers back.
final class JEVTodayAttentionTests: XCTestCase {
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

    private func holding(price: Double) -> Holding {
        Holding(ticker: "TEST", logoSymbol: nil, displayName: "Test Co", sector: "Technology", source: nil,
                shares: 10, averageCost: 50, costCurrency: "USD", quotePrice: price, quoteCurrency: "USD",
                todayChangePercent: 1.5, marketValue: price * 10, weight: 0.25, unrealized: 0,
                unrealizedPercent: 40, fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }

    /// A steady climb of 1 a day from 100: every return and average is known.
    private func bars(_ count: Int, start: Double = 100) -> [PortfolioAttentionDailyBar] {
        (0..<count).map { index in
            let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: index, to: Date(timeIntervalSince1970: 1_700_000_000))!
            let close = start + Double(index)
            return PortfolioAttentionDailyBar(date: DayDateCodec.string(from: day), close: close,
                                              high: close + 0.5, low: close - 0.5, volume: index == count - 1 ? 3_000 : 1_000)
        }
    }

    func testFactsFromASteadyClimb() throws {
        let series = bars(260)
        let price = series.last!.close
        let facts = JEVHoldingFacts.make(holding: holding(price: price), bars: series, spy: bars(260, start: 200))
        XCTAssertEqual(facts.weightPercent, 25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(facts.return20D), (price / (price - 20) - 1) * 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(facts.return60D), (price / (price - 60) - 1) * 100, accuracy: 1e-9)
        // Only ever rising: RSI at its ceiling, above every average, no drawdown.
        XCTAssertEqual(try XCTUnwrap(facts.rsi14), 100, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(facts.versusMA200), 0)
        XCTAssertEqual(facts.ma50AboveMA200, true)
        XCTAssertEqual(try XCTUnwrap(facts.maxDrawdown1Y), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(facts.volumeVersus20DAverage), 3, accuracy: 1e-9)
        // The high of the year is the last bar's, half a point over the close.
        XCTAssertEqual(try XCTUnwrap(facts.fromHigh52W), (price / (price + 0.5) - 1) * 100, accuracy: 1e-9)
    }

    /// Too little history leaves the long measures empty rather than guessed.
    func testShortHistoryLeavesLongMeasuresOut() {
        let facts = JEVHoldingFacts.make(holding: holding(price: 129), bars: bars(30), spy: [])
        XCTAssertNil(facts.versusMA200)
        XCTAssertNil(facts.return60D)
        XCTAssertNil(facts.ma50AboveMA200)
        XCTAssertNil(facts.relativeTo60DSPY)
        XCTAssertNotNil(facts.return20D)
    }

    /// The state carries no amounts: no market value, shares or cost.
    func testStateSendsNoAmounts() throws {
        let facts = JEVHoldingFacts.make(holding: holding(price: 359), bars: bars(260), spy: [])
        let data = try JSONSerialization.data(withJSONObject: facts.state)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("3590"))
        XCTAssertFalse(text.contains("shares"))
        XCTAssertTrue(text.contains("portfolio_weight_pct"))
    }

    /// Cloudflare's documented reply, in its REST envelope and bare.
    func testAnswersParseInsideAndOutsideCloudflaresEnvelope() throws {
        let bare: [String: Any] = [
            "model": "jev-1.13.0",
            "answers": [
                "action": ["type": "choice", "choice": "hold", "confidence": 0.8,
                           "probabilities": ["buy": 0.1, "hold": 0.85, "sell": 0.05]],
                "outlook": ["type": "score", "score": 2.4, "confidence": 0.7,
                            "legend": ["0": "a", "1": "b"], "probabilities": ["0": 0.1, "1": 0.9]],
                "uptrend": ["type": "noul", "noul": 0.95],
            ],
        ]
        for body in [bare, ["success": true, "errors": [], "result": bare]] as [[String: Any]] {
            let answers = try JEVClient.answers(from: body)
            XCTAssertEqual(answers.choices["action"]?.choice, "hold")
            XCTAssertEqual(try XCTUnwrap(answers.choices["action"]?.probabilities["hold"]), 0.85, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(answers.scores["outlook"]?.score), 2.4, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(answers.nouls["uptrend"]), 0.95, accuracy: 1e-9)
        }
        XCTAssertThrowsError(try JEVClient.answers(from: ["success": true, "result": ["text": "no answers"]]))
    }

    private func call(_ values: [Double], confidence: Double = 0.8, weight: Double = 0.05) -> JEVCall {
        var owned = holding(price: 129)
        owned = Holding(ticker: owned.ticker, logoSymbol: nil, displayName: owned.displayName, sector: nil, source: nil,
                        shares: 1, averageCost: 1, costCurrency: "USD", quotePrice: 129, quoteCurrency: "USD",
                        todayChangePercent: nil, marketValue: 129, weight: weight, unrealized: 0, unrealizedPercent: 0,
                        fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
        let scores = Dictionary(uniqueKeysWithValues: zip(JEVDimension.allCases, values).map {
            ($0.rawValue, JEVScore(score: $1, confidence: confidence))
        })
        return JEVCall(ticker: values.map { String($0) }.joined(), name: "T", logoSymbol: nil,
                       facts: JEVHoldingFacts.make(holding: owned, bars: bars(30), spy: []),
                       scores: scores, error: nil)
    }

    /// Trend and momentum set the view on five steps; stretch and risk are
    /// qualifiers beside it, not part of it.
    func testScoresCombineIntoAView() {
        XCTAssertEqual(call([0.4, 0.6, 2.0, 2.0]).state, .strongBearish)
        XCTAssertEqual(call([1.2, 1.4, 2.0, 2.0]).state, .bearish)
        XCTAssertEqual(call([2.0, 2.1, 2.0, 2.0]).state, .neutral)
        XCTAssertEqual(call([2.8, 3.0, 2.0, 2.0]).state, .bullish)
        XCTAssertEqual(call([3.6, 3.4, 3.8, 3.5]).state, .strongBullish)
        XCTAssertEqual(JEVState.qualifiers(call([3.6, 3.4, 3.8, 3.5]).scores), ["过热", "高风险"])
        XCTAssertEqual(JEVState.qualifiers(call([0.4, 0.6, 0.5, 2.0]).scores), ["超跌"])
        XCTAssertEqual(JEVState.qualifiers(call([2, 2, 2, 2]).scores), [])
    }

    /// When Jev cannot tell the direction, the card says so.
    func testLowConfidenceOnDirectionIsUnclear() {
        XCTAssertEqual(call([3.6, 3.2, 2.2, 1.5], confidence: 0.3).state, .unclear)
        XCTAssertEqual(JEVState.make([:]), .unclear)
    }

    /// A clear or extreme picture comes first; an unclear one last.
    func testSalienceOrdersClearPicturesFirst() {
        let strongHot = call([3.8, 3.6, 3.8, 2.0])
        let flat = call([2.0, 2.0, 2.0, 1.5])
        let unclear = call([3.8, 3.6, 3.8, 2.0], confidence: 0.2)
        XCTAssertGreaterThan(strongHot.salience, flat.salience)
        XCTAssertGreaterThan(flat.salience, unclear.salience)
    }

    /// Position size is read from the weight, not asked of the model.
    func testConcentrationComesFromTheWeight() {
        XCTAssertEqual(call([2, 2, 2, 2], weight: 0.56).concentration, "很重")
        XCTAssertEqual(call([2, 2, 2, 2], weight: 0.15).concentration, "较重")
        XCTAssertEqual(call([2, 2, 2, 2], weight: 0.01).concentration, "较轻")
    }

    /// Every dimension is asked as a Score with five described levels.
    func testEachDimensionIsAScoreWithFiveLevels() throws {
        let questions = JEVQuestions.all
        XCTAssertEqual(Set(questions.keys), Set(JEVDimension.allCases.map(\.rawValue)))
        for dimension in JEVDimension.allCases {
            let question = try XCTUnwrap(questions[dimension.rawValue] as? [String: Any])
            XCTAssertEqual(question["type"] as? String, "score")
            XCTAssertEqual((question["criteria"] as? [String])?.count, 5)
        }
    }

    func testTheTallyCountsStates() {
        let report = JEVReport(generatedAt: Date(), model: "m", calls: [
            call([3.6, 3.2, 2.2, 1.5]), call([0.6, 0.8, 1.8, 1.5]), call([2, 2, 2, 2]),
            call([3.6, 3.2, 2.2, 1.5], confidence: 0.2),
        ])
        let counts = report.counts
        XCTAssertEqual(counts.bullish, 1)
        XCTAssertEqual(counts.bearish, 1)
        XCTAssertEqual(counts.neutral, 1)
        XCTAssertEqual(counts.unclear, 1)
    }

    /// Options and valuation are asked only of holdings that have them.
    func testOptionalDimensionsAreAskedOnlyWithData() {
        var facts = JEVHoldingFacts.make(holding: holding(price: 129), bars: bars(30), spy: [])
        XCTAssertEqual(Set(JEVQuestions.questions(for: facts).keys), Set(JEVDimension.core.map(\.rawValue)))
        facts.options = JEVOptionsFacts(callWall: 140, putWall: 120, callWallDistance: 8.5, putWallDistance: -7,
                                        putCallRatio: 0.8, asOf: "2026-09-18")
        facts.valuation = JEVValuationFacts(pe: 30, ps: 8, growthPercent: 20, growthBasis: "net income", peg: 1.5,
                                            throughPeriod: "2026-06-30")
        XCTAssertEqual(Set(JEVQuestions.questions(for: facts).keys), Set(JEVDimension.allCases.map(\.rawValue)))
        let state = facts.state
        XCTAssertNotNil(state["options_open_interest"])
        XCTAssertNotNil(state["valuation"])
    }

    /// The backdrop: VIX against its year, the S&P against its 200-day
    /// average, and ^TNX's tenfold quote read back as a yield.
    func testMarketFactsFromTheirSeries() throws {
        var vix: [String: Double] = [:]
        var tnx: [String: Double] = [:]
        for day in 0..<260 {
            let date = DayDateCodec.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400))
            vix[date] = 20 + Double(day % 10)
            tnx[date] = 40 + Double(day) * 0.01
        }
        let market = JEVMarketFacts.make(vix: vix, tenYear: tnx, sp500: bars(260))
        XCTAssertNotNil(market.vix)
        XCTAssertEqual(try XCTUnwrap(market.tenYearYield), (40 + 2.59) * 0.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(market.tenYearChange20DBasisPoints), 0.2 * 0.1 * 100, accuracy: 1e-6)
        XCTAssertGreaterThan(try XCTUnwrap(market.sp500VersusMA200), 0)
        let percentile = try XCTUnwrap(market.vixPercentile1Y)
        XCTAssertTrue((0...100).contains(percentile))
    }

    func testOptionsAndValuationBecomeQualifiers() {
        var scores = call([3.6, 3.4, 2, 2]).scores
        scores[JEVDimension.options.rawValue] = JEVScore(score: 0.8, confidence: 0.8)
        scores[JEVDimension.valuation.rawValue] = JEVScore(score: 3.5, confidence: 0.8)
        XCTAssertEqual(JEVState.qualifiers(scores), ["期权偏空", "估值偏贵"])
    }

    private func period(_ end: String, _ kind: FinancialPeriodKind, revenue: Double, net: Double?) -> IncomeStatementPeriod {
        IncomeStatementPeriod(periodEnd: end, filedDate: nil, fiscalYear: Int(end.prefix(4))!, fiscalPeriod: kind == .annual ? "FY" : "Q",
                              kind: kind, currency: "USD", revenue: revenue, costOfRevenue: 0, grossProfit: revenue,
                              operatingExpenses: 0, operatingIncome: revenue, netIncome: net)
    }

    /// Twelve months to June 2026: fiscal 2025, plus the two quarters since,
    /// less the same two quarters of 2025. The year before, the same way.
    func testTrailingTwelveMonthsFromFilings() throws {
        let income = [
            period("2025-12-31", .annual, revenue: 400, net: 100),
            period("2024-12-31", .annual, revenue: 300, net: 80),
            period("2026-06-30", .quarterly, revenue: 130, net: 35),
            period("2026-03-31", .quarterly, revenue: 120, net: 30),
            period("2025-06-30", .quarterly, revenue: 100, net: 25),
            period("2025-03-31", .quarterly, revenue: 90, net: 22),
            period("2024-06-30", .quarterly, revenue: 75, net: 20),
            period("2024-03-31", .quarterly, revenue: 70, net: 18),
        ]
        let revenue = try XCTUnwrap(JEVValuationFacts.trailing(income, \.revenue))
        XCTAssertEqual(revenue.current, 400 + 130 + 120 - 100 - 90, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(revenue.prior), 300 + 100 + 90 - 75 - 70, accuracy: 1e-9)
        XCTAssertEqual(revenue.through, "2026-06-30")
    }

    /// P/E on market value over trailing net income; growth on net income
    /// while it is positive both years, and a loss leaves no P/E.
    func testValuationFromFilingsAndPrice() throws {
        let income = [
            period("2025-12-31", .annual, revenue: 400, net: 100),
            period("2024-12-31", .annual, revenue: 300, net: 80),
        ]
        var filing = CompanyFinancialsData(ticker: "T", entityName: "T", cik: 1, source: "SEC", income: income,
                                           balance: [], cashFlow: [], warnings: [])
        filing.sharesOutstanding = 10
        let valuation = try XCTUnwrap(JEVValuationFacts.make(filing, price: 200))
        XCTAssertEqual(try XCTUnwrap(valuation.pe), 2000.0 / 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(valuation.ps), 2000.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(valuation.growthPercent), 25, accuracy: 1e-9)
        XCTAssertEqual(valuation.growthBasis, "net income")
        XCTAssertEqual(try XCTUnwrap(valuation.peg), 20.0 / 25, accuracy: 1e-9)

        let losing = CompanyFinancialsData(ticker: "L", entityName: "L", cik: 1, source: "SEC",
                                           income: [period("2025-12-31", .annual, revenue: 400, net: -50),
                                                    period("2024-12-31", .annual, revenue: 320, net: -80)],
                                           balance: [], cashFlow: [], warnings: [], sharesOutstanding: 10)
        let loss = try XCTUnwrap(JEVValuationFacts.make(losing, price: 200))
        XCTAssertNil(loss.pe)
        XCTAssertEqual(loss.growthBasis, "revenue")
        XCTAssertEqual(try XCTUnwrap(loss.growthPercent), 25, accuracy: 1e-9)
        XCTAssertNil(loss.peg)
    }

    // MARK: Management delivery from SEC

    /// NVIDIA's fiscal year ends in late January and is named for that year:
    /// the quarter ending October 2025 is Q3 of fiscal 2026.
    func testFiscalCalendarNamesQuartersByTheYearTheyEndIn() {
        let income = [
            period("2025-01-26", .annual, revenue: 130, net: 73),
            period("2025-04-27", .quarterly, revenue: 44, net: 19),
            period("2025-07-27", .quarterly, revenue: 47, net: 26),
            period("2025-10-26", .quarterly, revenue: 57, net: 32),
            period("2026-01-25", .annual, revenue: 216, net: 120),
            period("2026-04-26", .quarterly, revenue: 82, net: 58),
        ]
        let calendar = ManagementDeliveryClient.fiscalCalendar(income)
        XCTAssertEqual(calendar["2025-10-26"], .init(year: 2026, quarter: 3))
        XCTAssertEqual(calendar["2025-04-27"], .init(year: 2026, quarter: 1))
        XCTAssertEqual(calendar["2026-01-25"], .init(year: 2026, quarter: 4))
        // Past the latest annual report: the next fiscal year.
        XCTAssertEqual(calendar["2026-04-26"], .init(year: 2027, quarter: 1))
        // A release filed a month after a quarter reports that quarter; one
        // filed after the year closed but before its 10-K reports Q4.
        XCTAssertEqual(ManagementDeliveryClient.quarterReported(filed: "2025-11-19", calendar: calendar), .init(year: 2026, quarter: 3))
        XCTAssertEqual(ManagementDeliveryClient.quarterReported(filed: "2026-05-20", calendar: calendar), .init(year: 2027, quarter: 1))
        let beforeTenK = calendar.filter { $0.key != "2026-01-25" && $0.key != "2026-04-26" }
        XCTAssertEqual(ManagementDeliveryClient.quarterReported(filed: "2026-02-25", calendar: beforeTenK), .init(year: 2026, quarter: 4))
    }

    /// Q4 is the year less its first three quarters.
    func testFourthQuarterIsDerivedFromTheYear() throws {
        let income = [
            period("2024-12-31", .annual, revenue: 400, net: 100),
            period("2024-03-31", .quarterly, revenue: 90, net: 20),
            period("2024-06-30", .quarterly, revenue: 100, net: 25),
            period("2024-09-30", .quarterly, revenue: 105, net: 27),
        ]
        let data = CompanyFinancialsData(ticker: "T", entityName: "T", cik: 1, source: "SEC", income: income,
                                         balance: [], cashFlow: [], warnings: [])
        let documents = ManagementDeliveryClient.secFinancialDocuments(
            data, calendar: ManagementDeliveryClient.fiscalCalendar(income), symbol: "T", cik: 1, today: "2026-01-01")
        let q4 = try XCTUnwrap(documents.first { $0.period == "Q4" && $0.fiscalYear == 2024 })
        XCTAssertEqual(try XCTUnwrap(q4.facts.first { $0.metric == "revenue" }).value, 105, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(q4.facts.first { $0.metric == "netIncome" }).value, 28, accuracy: 1e-9)
        XCTAssertNotNil(documents.first { $0.period == "FY" && $0.fiscalYear == 2024 })
    }

    /// The release is found by its exhibit type, whatever the file is called.
    func testExhibitIsFoundByType() {
        let html = """
        <table><tr><td>1</td><td>8-K</td><td><a href="/ix?doc=/Archives/edgar/data/1/x/main.htm">main.htm</a></td><td>8-K</td></tr>
        <tr><td>2</td><td>Press release</td><td><a href="/Archives/edgar/data/1/x/q2fy27pr.htm">q2fy27pr.htm</a></td><td>EX-99.1</td></tr></table>
        """
        XCTAssertEqual(ManagementDeliveryClient.exhibitPath(inIndex: html), "/Archives/edgar/data/1/x/q2fy27pr.htm")
        XCTAssertNil(ManagementDeliveryClient.exhibitPath(inIndex: "<table><tr><td>8-K</td></tr></table>"))
    }
}
