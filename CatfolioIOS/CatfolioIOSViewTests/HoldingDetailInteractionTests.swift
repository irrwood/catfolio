import SwiftUI
import XCTest
@testable import CatfolioIOS

private func visibilityHolding(_ ticker: String, name: String = "Test security", currency: String = "USD",
                               shares: Double = 10, source: String? = nil) -> Holding {
    Holding(ticker: ticker, logoSymbol: nil, displayName: name, sector: nil, source: source,
        shares: shares, averageCost: 80, costCurrency: currency, quotePrice: 100, quoteCurrency: currency,
        todayChangePercent: 1, marketValue: shares * 100, weight: 1, unrealized: shares * 20,
        unrealizedPercent: 25, fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil)
}

final class HoldingResearchVisibilityTests: XCTestCase {
    func testKnownETFsDoNotDependOnDisplayNamesOrShares() {
        for ticker in ["SPY", "QQQ", "IWM", "ACWI", "VUAG.L", "EQQQ.L", "XS2D.L"] {
            XCTAssertEqual(HoldingSecurityKind.classify(visibilityHolding(ticker)), .fund, ticker)
        }
    }

    func testUCITSAndClosedEndFundsAreRecognizedWithoutSubstringGuessing() {
        for name in ["Global Equity UCITS ETF", "Global UCITS (Acc)", "Example Index Fund", "Example Closed-End Fund", "Example Investment Trust PLC"] {
            XCTAssertEqual(HoldingSecurityKind.classify(instrumentType: nil, names: [name]), .fund, name)
        }
        XCTAssertEqual(HoldingSecurityKind.classify(visibilityHolding("FUND")), .fund, "The actual FUND listing is a closed-end fund")
    }

    func testCompanyMetadataWinsOverMisleadingDisplayNames() {
        XCTAssertEqual(HoldingSecurityKind.classify(visibilityHolding("NVDA", name: "Index Fund")), .company)
        XCTAssertEqual(HoldingSecurityKind.classify(visibilityHolding("MSCI", name: "Index analytics")), .company)
        XCTAssertEqual(HoldingSecurityKind.classify(instrumentType: "COMPANY_SECURITY", names: ["Fund Management Inc."]), .company)
    }

    func testUnknownIsNotAFundAndGenericWordsCannotHideCompanies() {
        for name in ["Fundtech", "Index Systems Inc.", "Index Fund Advisors Inc.", "Fund Management PLC", "ETFCORP", "Investment Trust Bank"] {
            XCTAssertEqual(HoldingSecurityKind.classify(instrumentType: "UNCLASSIFIED", names: [name]), .unknown, name)
        }
        XCTAssertEqual(HoldingSecurityKind.classify(visibilityHolding("TESTFUNDINDEX")), .unknown)
    }

    func testLookThroughConstituentKeepsCompanyResearch() {
        let holding = visibilityHolding("NVDA", name: "Nvidia / Vanguard ETF", shares: 0, source: "ETF look-through")
        let kind = HoldingSecurityKind.classify(holding)
        XCTAssertEqual(kind, .company)
        let policy = HoldingResearchVisibility(kind: kind, currency: holding.quoteCurrency)
        XCTAssertTrue(policy.shows(.developments))
        XCTAssertTrue(policy.shows(.consensus))
        XCTAssertTrue(policy.shows(.financials))
    }

    func testFundOnlyShowsTheIndividualModulesWithRealContent() {
        for module in HoldingResearchModule.allCases {
            var policy = HoldingResearchVisibility(kind: .fund, currency: "USD")
            XCTAssertFalse(policy.hasVisibleModules)
            policy.record(.available, for: module)
            XCTAssertEqual(HoldingResearchModule.allCases.filter { policy.shows($0) }, [module])
        }
    }

    func testUnknownAndTemporaryFailureDoNotBecomePermanentAbsence() {
        for kind in [HoldingSecurityKind.company, .unknown] {
            var policy = HoldingResearchVisibility(kind: kind, currency: "USD")
            policy.record(.failed, for: .financials)
            XCTAssertTrue(policy.shows(.financials))
            policy.record(.empty, for: .financials)
            XCTAssertFalse(policy.shows(.financials))
            XCTAssertTrue(policy.shows(.consensus))
            policy.record(.available, for: .financials)
            XCTAssertTrue(policy.shows(.financials))
        }
        var fund = HoldingResearchVisibility(kind: .fund, currency: "USD")
        fund.record(.failed, for: .earnings)
        XCTAssertFalse(fund.shows(.earnings))
        fund.record(.available, for: .earnings)
        XCTAssertTrue(fund.shows(.earnings))
    }

    func testFailedOrEmptyRefreshKeepsTheLastAvailableFundModule() {
        var policy = HoldingResearchVisibility(kind: .fund, currency: "USD")
        policy.record(.available, for: .earnings)
        policy.record(.failed, for: .earnings)
        policy.record(.empty, for: .earnings)
        XCTAssertTrue(policy.shows(.earnings))
        XCTAssertEqual(policy.availability[.earnings], .available)
    }

    func testUnsupportedTargetCurrencyDoesNotHideOtherRealFundData() {
        var policy = HoldingResearchVisibility(kind: .fund, currency: "GBP")
        policy.record(.available, for: .consensus)
        policy.record(.available, for: .earnings)
        XCTAssertFalse(policy.shows(.consensus))
        XCTAssertTrue(policy.shows(.earnings))
    }

    @MainActor func testHistoryEntryRequiresAnActualAnalystSnapshot() {
        XCTAssertTrue(AnalystConsensusView.hasHistory(symbol: "NVDA"))
        XCTAssertFalse(AnalystConsensusView.hasHistory(symbol: "QQQ"))
        XCTAssertFalse(AnalystConsensusView.hasHistory(symbol: "NOT-COLLECTED"))
        XCTAssertFalse(HoldingResearchVisibility(kind: .unknown, currency: "USD").shows(.analystHistory))
    }

    func testRealDataChecksDoNotMistakeQuoteOnlyOrBlankPeriodsForAnalysis() {
        let quoteOnly = AnalystConsensusData(ratings: nil, consensus: nil, low: nil, mean: nil, high: nil,
            current: 100, source: "Fixture", fetchedAt: .now, warnings: [])
        XCTAssertFalse(quoteOnly.hasContent)
        let rated = AnalystConsensusData(ratings: RatingSpread(bearish: 0, neutral: 0, bullish: 1), consensus: nil,
            low: nil, mean: nil, high: nil, current: nil, source: "Fixture", fetchedAt: .now, warnings: [])
        XCTAssertTrue(rated.hasContent)
        let blank = EarningsSnapshot(observations: [EarningsObservation(date: "2026-09-01", period: nil,
            epsActual: nil, epsEstimated: nil, revenueActual: nil, revenueEstimated: nil)], source: "Fixture", fetchedAt: .now, note: nil)
        XCTAssertFalse(blank.hasUsableObservations)
        let zero = EarningsSnapshot(observations: [EarningsObservation(date: "2026-09-01", period: nil,
            epsActual: 0, epsEstimated: nil, revenueActual: nil, revenueEstimated: nil)], source: "Fixture", fetchedAt: .now, note: nil)
        XCTAssertTrue(zero.hasUsableObservations, "A reported zero is a value, not missing data")
        XCTAssertFalse(CompanyFinancialsData(ticker: "QQQ", entityName: "Test", cik: nil, source: "Fixture",
            income: [], balance: [], cashFlow: [], warnings: []).hasUsableStatements)
    }

    func testProviderFailureIsNotConfirmedNoCoverage() throws {
        XCTAssertFalse(CompanyFinancialsClient.confirmsNoStatements(URLError(.timedOut)))
        XCTAssertFalse(CompanyFinancialsClient.confirmsNoStatements(CompanyFinancialsError.invalidResponse))
        XCTAssertTrue(CompanyFinancialsClient.confirmsNoStatements(CompanyFinancialsError.noStatements))
        let failed = try JSONDecoder().decode(CompanyFinancialsClient.NasdaqFinancialsResponse.self,
            from: Data(#"{"data":null,"status":{"rCode":500}}"#.utf8))
        let empty = try JSONDecoder().decode(CompanyFinancialsClient.NasdaqFinancialsResponse.self,
            from: Data(#"{"data":null,"status":{"rCode":200}}"#.utf8))
        XCTAssertFalse(failed.allowsStatementRead)
        XCTAssertTrue(empty.allowsStatementRead)
        XCTAssertThrowsError(try EarningsObservation.nasdaq(Data(#"{"data":null,"status":{"rCode":500}}"#.utf8)))
        XCTAssertTrue(try EarningsObservation.nasdaq(Data(#"{"data":null,"status":{"rCode":200}}"#.utf8)).isEmpty)
    }

    func testCachedFundContentSurvivesWhileExpiredNegativeLookupsBecomeUnknown() async throws {
        struct Entry: Encodable { let fetchedAt: Date; let markets: [PolymarketRelatedMarket] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fund-markets.json")
        let market = PolymarketRelatedMarket(id: "public-fixture", question: "Will this fund launch?", eventTitle: "Fund launch",
            eventSlug: "fund-launch", outcome: "Yes", probability: 0.5, volume24Hours: 1, totalVolume: 10, endDate: nil)
        let old = Date().addingTimeInterval(-86400)
        let encoded = try JSONEncoder().encode([
            "en|qqq|test": Entry(fetchedAt: old, markets: [market]),
            "en|spy|test": Entry(fetchedAt: old, markets: []),
            "en|ivv|test": Entry(fetchedAt: .now, markets: [])
        ])
        try encoded.write(to: url)
        let client = PolymarketClient(cacheURL: url)
        let available = await client.cachedRelatedMarkets(ticker: "QQQ", companyName: "Test", language: "en")
        let expiredEmpty = await client.cachedRelatedMarkets(ticker: "SPY", companyName: "Test", language: "en")
        let confirmedEmpty = await client.cachedRelatedMarkets(ticker: "IVV", companyName: "Test", language: "en")
        let unknown = await client.cachedRelatedMarkets(ticker: "NONE", companyName: "Test", language: "en")
        XCTAssertEqual(available?.map(\.id), ["public-fixture"])
        XCTAssertNil(expiredEmpty)
        XCTAssertEqual(confirmedEmpty?.count, 0)
        XCTAssertNil(unknown)
        XCTAssertEqual(try Data(contentsOf: url), encoded, "Visibility reads must not delete or rewrite user caches")
    }
}

final class HoldingDetailInteractionTests: XCTestCase {
    @MainActor
    func testInitialLoadingSectionsRenderWithoutDataOrPresentationCallbacks() async throws {
        // Mount only the first-frame sections: no parent appearance callback
        // or data-loading task can replace the placeholders during capture.
        let holding = visibilityHolding("NVDA")
        let content = VStack(spacing: 0) {
            HoldingDetailPriceSection(holding: holding,
                priceHistory: nil, priceHistoryError: nil, averageCost: nil, selectedAccountKeys: [])
            HoldingDetailLowerLoadingPlaceholder(ticker: holding.ticker, showsPosition: true)
        }
        .frame(width: 402, alignment: .top)
        .background(SecurityDetailPresentation.ground)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .environment(\.colorScheme, .dark)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        let size = host.sizeThatFits(in: CGSize(width: 402, height: 2400))
        XCTAssertGreaterThan(size.height, SecurityPriceChartState.fixedHeight + 397,
                             "Reserve both price and lower-card loading layouts immediately")
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "security-detail-first-frame-skeletons"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-detail-first-frame.png"))
    }

    @MainActor
    func testDetailIsIsolatedOnFirstPresentation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let probe = DetailRefreshProbe()
        probe.isIsolated = true
        let controller = UIHostingController(rootView: DetailRefreshProbeView(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        try await waitUntil { self.scrollView(in: controller.view)?.refreshControl != nil }
        probe.showsDetail = true
        try await waitUntil {
            controller.presentedViewController.map { self.scrollView(in: $0.view) != nil } ?? false
        }
        let detailController = try XCTUnwrap(controller.presentedViewController)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(scrollView(in: detailController.view)?.refreshControl)
        XCTAssertNotNil(scrollView(in: controller.view)?.refreshControl)
        let sheet = try XCTUnwrap(detailController.sheetPresentationController)
        XCTAssertNil(sheet.largestUndimmedDetentIdentifier, "Native sheet must dim and block the presenting screen")
        XCTAssertFalse(detailController.isModalInPresentation, "Keep the native swipe-down dismissal")
        XCTAssertFalse(SecurityDetailSnapshotTransition.shared.isAnimating)
        probe.showsDetail = false
        try await waitUntil { controller.presentedViewController == nil }
        XCTAssertNotNil(scrollView(in: controller.view)?.refreshControl)
    }

    @MainActor
    func testDetailRemovesInheritedRefreshWithoutDisablingParentOrChildRefresh() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let probe = DetailRefreshProbe()
        let controller = UIHostingController(rootView: DetailRefreshProbeView(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }

        try await waitUntil { self.scrollView(in: controller.view)?.refreshControl != nil }
        let parentScroll = try XCTUnwrap(scrollView(in: controller.view))
        let parentRefresh = try XCTUnwrap(parentScroll.refreshControl)
        probe.showsDetail = true
        try await waitUntil {
            controller.presentedViewController.map { self.scrollView(in: $0.view)?.refreshControl != nil } ?? false
        }
        let detailController = try XCTUnwrap(controller.presentedViewController)
        let detailScroll = try XCTUnwrap(scrollView(in: detailController.view))
        // Reproduce the actual inherited native control before isolating it.
        XCTAssertNotNil(detailScroll.refreshControl)
        probe.isIsolated = true
        try await waitUntil { detailScroll.refreshControl == nil }
        XCTAssertTrue(detailScroll.isScrollEnabled)
        XCTAssertTrue(detailScroll.panGestureRecognizer.isEnabled)
        XCTAssertTrue(parentScroll.refreshControl === parentRefresh)

        // An environment/layout update must not restore inherited refresh.
        probe.revision += 1
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(detailScroll.refreshControl)

        // A nested analyst/financial-style sheet owns its own refresh action.
        probe.showsChild = true
        try await waitUntil {
            detailController.presentedViewController.map { self.scrollView(in: $0.view)?.refreshControl != nil } ?? false
        }
        let childController = try XCTUnwrap(detailController.presentedViewController)
        let childRefresh = try XCTUnwrap(scrollView(in: childController.view)?.refreshControl)
        childRefresh.sendActions(for: .valueChanged)
        try await waitUntil { probe.childRefreshes == 1 }
        XCTAssertEqual(probe.parentRefreshes, 0)
        XCTAssertNil(detailScroll.refreshControl)
        XCTAssertTrue(parentScroll.refreshControl === parentRefresh)
    }

    @MainActor
    func testBoundaryOnlyTouchesItsNearestScrollView() {
        let parent = UIScrollView()
        let detail = UIScrollView()
        let boundary = HoldingDetailScrollBoundary.BoundaryView()
        let parentRefresh = UIRefreshControl()
        parent.refreshControl = parentRefresh
        detail.refreshControl = UIRefreshControl()
        parent.addSubview(detail)
        detail.addSubview(boundary)
        boundary.removeInheritedRefreshControl()
        XCTAssertNil(detail.refreshControl)
        XCTAssertTrue(parent.refreshControl === parentRefresh)
        XCTAssertTrue(detail.panGestureRecognizer.isEnabled)
    }

    @MainActor
    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native presentation / refresh state did not settle")
    }
}

final class HoldingResearchCardLayoutTests: XCTestCase {
    @MainActor
    func testMETAWeeklyBaselineRemainsVisible() async throws {
        let rows: [(String, Double)] = [("2026-09-14", 665.60), ("2026-09-15", 670.24),
            ("2026-09-16", 673.31), ("2026-09-17", 682.31), ("2026-09-18", 665.75),
            ("2026-09-21", 719.25)]
        let history = SecurityPriceHistory(ticker: "META", currency: "USD",
            points: rows.map { .init(dateText: $0.0, close: $0.1) }, intradayPoints: [], trades: [])
        let data = SecurityPriceRangeData(history: history, range: .oneWeek,
            averageCost: nil, selectedAccountKeys: [])
        for dark in [false, true] {
            _ = try await capture(VStack(alignment: .leading, spacing: 12) {
                Text("META · 1W · 2026-09-14 – 2026-09-21").font(.caption)
                Text("$719.25  +8.06%").font(.title2)
                SecurityPricePlot(data: data, currency: "USD", appearanceID: "meta-week",
                    transitionKey: "week", selectedPoint: data.points.first,
                    measuredRange: nil, selectionIndicatorLabel: "2026-09-14",
                    onSelect: { _ in }, onMeasure: { _ in }, onInteractionEnded: { _ in })
                    .frame(height: 360)
            }, width: 402, dark: dark,
                name: "meta-week-baseline-\(dark ? "dark" : "light")", settle: .milliseconds(1200))
        }
    }

    @MainActor
    func testTradeReadoutMatchesFigmaInBothAppearances() async throws {
        let trades = SecurityTrade.grouped([
            LocalTransactionRecord(date: "2026-09-10", action: "SELL", ticker: "NVDA",
                quantity: 1, price: 216.52, currency: "USD", source: "test", accountID: "isa",
                accountName: nil, realisedProfitLoss: 14.56, realisedProfitLossCurrency: "USD")
        ])
        for dark in [false, true] {
            let header = HoldingDetailHeader(holding: visibilityHolding("NVDA", name: "NVIDIA", shares: 83.4078),
                marketTodayChange: -2, selectedPrice: 216.52, selectedReturn: 18.1, selectedTrades: trades)
            let size = try await capture(header.background(Color(uiColor: .systemBackground)), width: 402,
                dark: dark, name: "stock-trade-readout-\(dark ? "dark" : "light")")
            XCTAssertLessThan(size.height, 155)
            _ = try await capture(header, width: 320, dark: dark, name: "stock-trade-readout-narrow-\(dark)")
        }
    }

    private var previousLanguage: Any?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("zh-Hans", forKey: AppLanguage.preferenceKey)
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
        }
        super.tearDown()
    }

    @MainActor
    func testFigmaStockHeaderInLightDarkAndLargeType() async throws {
        let history = SecurityPriceHistory(ticker: "NVDA", currency: "USD", points: (0..<90).map { index in
            let date = Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 86400)
            return SecurityPricePoint(dateText: DayDateCodec.string(from: date),
                close: 180 + Double(index) * 0.4 + sin(Double(index) * 0.25) * 12)
        }, intradayPoints: [], trades: [SecurityTrade(dateText: "2025-07-03", action: "BUY", quantity: 10,
            tradeCount: 1, accountKeys: ["isa"])])
        let accounts = [
            HoldingDetailAccountOption(id: "isa", displayName: "ISA", marketValue: 12_923,
                currency: "USD", marketValueUSD: 12_923, unrealized: 349),
            HoldingDetailAccountOption(id: "invest", displayName: "Invest", marketValue: 5000,
                currency: "USD", marketValueUSD: 5000, unrealized: -180)
        ]
        for dark in [false, true] {
            let size = try await capture(HoldingDetailPriceSection(holding: visibilityHolding("NVDA", name: "NVIDIA", shares: 83.4078),
                priceHistory: history, priceHistoryError: nil,
                averageCost: 160, selectedAccountKeys: ["isa", "invest"], accountOptions: accounts)
                .background(Color(uiColor: .systemGroupedBackground)),
                width: 402, dark: dark, name: "stock-header-figma-\(dark ? "dark" : "light")", settle: .milliseconds(700))
            XCTAssertLessThan(size.height, 710)
            XCTAssertGreaterThan(size.height, 610)
        }
        let header = HoldingDetailHeader(holding: visibilityHolding("NVDA", name: "NVIDIA", shares: 83.4078),
            marketTodayChange: -2, selectedPrice: 216.52, selectedReturn: 18.1)
        let regular = try await capture(header, width: 320, dark: true, name: "stock-header-narrow")
        let large = try await capture(header.environment(\.dynamicTypeSize, .accessibility2),
            width: 320, dark: true, name: "stock-header-large-type")
        XCTAssertGreaterThan(large.height, regular.height)
    }

    @MainActor
    func testPriceMoveNativeSheetKeepsWindowAndHonestEmptyStateVisible() async throws {
        let scope = SecurityPriceMoveContext(ticker: "NVDA", name: "NVIDIA", currency: "USD", rangeLabel: "1M",
            startDate: Date(timeIntervalSince1970: 1_780_000_000), endDate: Date(timeIntervalSince1970: 1_782_000_000),
            startPrice: 220, endPrice: 200, isIntraday: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SecurityPriceMoveStore(file: SecurityPriceMoveFile(url: directory.appendingPathComponent("moves.json")),
            dependencies: .init(documents: { _, _ in [] }, answer: { _ in
                XCTFail("No model request is allowed when no public evidence exists")
                return ""
            }))
        for dark in [false, true] {
            _ = try await capture(NavigationStack { SecurityPriceMoveSheet(context: scope, store: store) }
                .frame(height: 780), width: 402, dark: dark, name: "stock-move-empty-\(dark)", settle: .milliseconds(350))
            guard case .empty = store.progress(for: scope) else { return XCTFail("An empty interval must explain the limitation") }
        }
    }

    @MainActor
    func testResearchCardsMatchFinancialInLightAndDark() async throws {
        let snapshot = EarningsSnapshot(observations: (0..<4).map { index in
            EarningsObservation(date: "2026-0\(index + 1)-25", period: nil,
                epsActual: 1.2 + Double(index) * 0.1, epsEstimated: 1.3,
                revenueActual: 4e9, revenueEstimated: 3.8e9)
        }, source: "UI test fixture", fetchedAt: .now, note: nil)
        var requests = 0
        for dark in [false, true] {
            let size = try await capture(
                VStack(spacing: HoldingDetailCardStyle.spacing) {
                    SecurityDebateCardContent(progress: .idle, onStart: { requests += 1 }, onRegenerate: { requests += 1 })
                    HoldingDetailActionCardLabel(title: "分析师一致预期", subtitle: "分析师覆盖 · 按需读取", symbol: "arrow.down.circle")
                    HoldingDetailActionCardLabel(title: "分析师历史回顾", subtitle: "目标价、推荐建议与股价 · 本地快照")
                    EarningsHistoryView(symbol: "UI-TEST", initialSnapshot: snapshot)
                    HoldingDetailActionCardLabel(title: "财务", subtitle: "损益表、资产负债表和现金流")
                }
                .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                .padding(.vertical, 16),
                width: 402, dark: dark, name: "holding-research-\(dark ? "dark" : "light")"
            )
            XCTAssertEqual(size.width, 402, accuracy: 0.5)
            XCTAssertLessThan(size.height, 1100, "Card spacing must not revert to the chart's 64pt gaps")
        }
        XCTAssertEqual(requests, 0, "Drawing the AI entry must never start or regenerate research")
    }

    @MainActor
    func testAIProgressFailureAndCachedResultKeepTheirCardSurface() async throws {
        let debate = SecurityDebate(ticker: "UI-TEST", name: "UI test fixture", generatedAt: .now,
            questions: [SecurityDebateQuestion(question: "收入增长，下一季需求如何？",
                whatChanged: "这是用于布局检查的示例内容。", whyItMatters: "保留事实与分析的区分。",
                watchNext: "关注下一次披露。", uncertainty: "", evidence: [])], sources: [])
        for dark in [false, true] {
            let size = try await capture(
                VStack(spacing: HoldingDetailCardStyle.spacing) {
                    SecurityDebateCardContent(progress: .collecting, onStart: {}, onRegenerate: {})
                    SecurityDebateCardContent(progress: .failed("暂时无法读取来源，请稍后重试。"), onStart: {}, onRegenerate: {})
                    SecurityDebateCardContent(progress: .ready(debate), onStart: {}, onRegenerate: {})
                }
                .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                .padding(.vertical, 16),
                width: 402, dark: dark, name: "holding-ai-states-\(dark ? "dark" : "light")"
            )
            XCTAssertEqual(size.width, 402, accuracy: 0.5)
            XCTAssertGreaterThan(size.height, HoldingDetailCardStyle.minimumRowHeight * 3)
            XCTAssertLessThan(size.height, 1300)
        }
    }

    @MainActor
    func testActionCardGrowsForLargeTypeInsteadOfClippingDescription() async throws {
        let label = HoldingDetailActionCardLabel(title: "AI 关键变化",
            subtitle: "阅读新闻与申报正文，提取重要变化、影响和观察项", symbol: "sparkles")
        let normal = try await capture(label, width: 288, dark: false, name: "holding-card-narrow")
        let large = try await capture(label.environment(\.dynamicTypeSize, .accessibility2),
            width: 288, dark: false, name: "holding-card-large-type")
        XCTAssertEqual(large.width, normal.width, accuracy: 0.5)
        XCTAssertGreaterThan(large.height, normal.height)
    }

    @MainActor
    func testFundResearchHasNoCardsOrTopGapBeforeOrAfterCacheCheck() async throws {
        for ticker in ["QQQ", "VUAG.L"] {
            for dark in [false, true] {
                let size = try await capture(HoldingResearchSection(holding: visibilityHolding(ticker), price: 100,
                    restoresCache: false), width: 402, dark: dark, name: "fund-\(ticker)-empty-\(dark)")
                XCTAssertEqual(size.height, 4, accuracy: 0.5, "Only the capture helper's 2pt + 2pt padding may remain")
            }
        }
        _ = try await capture(VStack(alignment: .leading, spacing: 0) {
            Text("QQQ · 基金详情研究区").font(.title2.bold()).padding(.bottom, 16)
            Text("布局验证：没有已缓存的分析内容").font(.caption).foregroundStyle(.secondary)
            HoldingResearchSection(holding: visibilityHolding("QQQ"), price: 100, restoresCache: false)
            Divider().padding(.top, 16)
            Text("研究区高度 0 · 无入口、空卡或额外顶间距").font(.caption).padding(.top, 12)
        }.padding(16), width: 402, dark: false, name: "fund-research-zero-height-context")
    }

    @MainActor
    func testFundWithRealEarningsKeepsOnlyThatCard() async throws {
        let snapshot = EarningsSnapshot(observations: [EarningsObservation(date: "2026-09-01", period: nil,
            epsActual: 1, epsEstimated: 1.1, revenueActual: nil, revenueEstimated: nil)],
            source: "UI test fixture", fetchedAt: .now, note: nil)
        for dark in [false, true] {
            let size = try await capture(HoldingResearchSection(holding: visibilityHolding("QQQ"), price: 100,
                restoresCache: false, initialEarnings: snapshot), width: 402, dark: dark, name: "fund-real-content-\(dark)")
            // Earnings is folded until tapped: its row, the gap above it and
            // the caveat paragraph below.
            XCTAssertGreaterThan(size.height, HoldingDetailCardStyle.minimumRowHeight + 40)
            XCTAssertLessThan(size.height, 520, "Only the actual earnings card should occupy space")
        }
    }

    @MainActor
    func testStockAndLookThroughKeepOnDemandEntriesWithoutStartingAnalysis() async throws {
        // Suppress only automatic chart loaders for this layout fixture. The
        // AI, consensus, real history and Financial entry views are production views.
        let holding = visibilityHolding("NVDA", shares: 0, source: "ETF look-through")
        for dark in [false, true] {
            let size = try await capture(HoldingResearchSection(holding: holding, price: 100,
                restoresCache: false, initialAvailability: [.earnings: .empty, .predictionMarkets: .empty]),
                width: 402, dark: dark, name: "stock-look-through-research-\(dark)")
            XCTAssertGreaterThan(size.height, 450)
            // Two more on-demand entries than before: insider trades and
            // management follow-through.
            XCTAssertLessThan(size.height, 650 + 2 * (HoldingDetailCardStyle.minimumRowHeight + HoldingDetailCardStyle.spacing))
        }
    }

    @MainActor
    func testDailyPaperLayout() async throws {
        let context = SecurityPriceMoveContext(ticker: "TEST", name: "示例公司", currency: "USD",
            rangeLabel: "2026-09-10", startDate: Date(timeIntervalSince1970: 1788912000),
            endDate: Date(timeIntervalSince1970: 1788998400), startPrice: 100, endPrice: 105, isIntraday: false)
        let store = SecurityDailyMoveStore { _ in
            SecurityDailyMoveNote(text: "公司公布的月度营收创下新高，AI 芯片需求强劲。市场报道将当天上涨与这份业绩联系起来。", sources: [])
        }
        for width in [320.0, 402.0] {
            _ = try await capture(SecurityDailyMovePaper(context: context, store: store)
                .frame(height: 874),
                width: width, dark: true, name: "daily-paper-\(width)", settle: .seconds(2))
        }
    }

    @MainActor
    func testFundIntroductionPaperLayout() async throws {
        let context = SecurityPriceMoveContext(ticker: "TESTETF", name: "示例全球股票 UCITS ETF (Acc)", currency: "GBP",
            rangeLabel: "2026-09-10", startDate: Date(timeIntervalSince1970: 1788912000),
            endDate: Date(timeIntervalSince1970: 1788998400), startPrice: 100, endPrice: 106, isIntraday: false,
            fundIntroduction: true)
        let store = SecurityDailyMoveStore { _ in
            SecurityDailyMoveNote(text: "这只示例 ETF 跟踪全球股票指数，投资发达市场和新兴市场的大中型公司。它采用累积份额，将收到的股息继续投入基金。", sources: [])
        }
        for width in [320.0, 402.0] {
            _ = try await capture(SecurityDailyMovePaper(context: context, store: store)
                .frame(height: 874), width: width, dark: false, name: "fund-introduction-\(width)", settle: .seconds(2))
        }
    }

    @MainActor
    func testDailyPaperBlursPresentingScreen() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: DailyPaperBackdropFixture())
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        for _ in 0..<50 where host.presentedViewController == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let presented = try XCTUnwrap(host.presentedViewController)
        try await Task.sleep(for: .milliseconds(100))
        let frame = presented.view.convert(presented.view.bounds, to: window)
        XCTAssertEqual(frame.minY, 0, accuracy: 1, "The blur host must not slide up from the bottom")
        XCTAssertEqual(frame.height, window.bounds.height, accuracy: 1)
        try await Task.sleep(for: .seconds(2))
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "daily-paper-blurred-stock-background"
        attachment.lifetime = .keepAlways
        add(attachment)
        func findBlur(_ view: UIView) -> SecurityPaperBlur.BlurView? {
            if let blur = view as? SecurityPaperBlur.BlurView { return blur }
            return view.subviews.lazy.compactMap { findBlur($0) }.first
        }
        let blur = try XCTUnwrap(findBlur(presented.view))
        XCTAssertNil(blur.blurAnimator, "The fully open paper must be idle")
        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(blur.window)
        XCTAssertNil(blur.blurAnimator, "Returning to stock detail must leave no paused blur animation")
        XCTAssertNil(blur.effect)
    }

    @MainActor
    private func capture<V: View>(_ content: V, width: CGFloat, dark: Bool, name: String,
                                 settle: Duration = .milliseconds(120)) async throws -> CGSize {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content
            .frame(width: width)
            .padding(.vertical, 2)
            .background(Color(uiColor: .systemBackground))
            .fontDesign(.rounded)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: settle)
        let size = host.sizeThatFits(in: CGSize(width: width, height: 2500))
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return size
    }
}

@Observable
private final class DetailRefreshProbe {
    var showsDetail = false
    var showsChild = false
    var isIsolated = false
    var revision = 0
    var parentRefreshes = 0
    var childRefreshes = 0
}

private struct DetailRefreshProbeView: View {
    @Bindable var probe: DetailRefreshProbe

    var body: some View {
        ScrollView { Text("Parent").frame(height: 1800) }
            .sheet(isPresented: $probe.showsDetail) {
                NavigationStack {
                    ScrollView {
                        Text("Detail \(probe.revision)").frame(height: 1800)
                            .background {
                                if probe.isIsolated { HoldingDetailScrollBoundary() }
                            }
                    }
                }
                .securityDetailSheet()
                .sheet(isPresented: $probe.showsChild) {
                    ScrollView { Text("Child").frame(height: 1800) }
                        .refreshable { probe.childRefreshes += 1 }
                }
            }
            // Deliberately outside sheet to reproduce the original bug and
            // the refresh inherited through a nested heatmap presentation.
            .refreshable { probe.parentRefreshes += 1 }
    }
}

final class LineChartMotionTests: XCTestCase {
    private func points(_ dates: [Double], value: (Double) -> Double) -> [StandardLineChartPoint] {
        dates.map { StandardLineChartPoint(date: Date(timeIntervalSinceReferenceDate: $0), value: value($0)) }
    }

    func testRangeHistoryZoomOutUsesRealNewValuesBeyondOldWindow() {
        let old = points([4, 6, 8, 10]) { 1_000 + $0 }
        let new = points([0, 2, 4, 6, 8, 10]) { 100 + $0 }
        let history = StandardLineChartRangeHistory(from: old, to: new)
        let visible = history.samples(from: new[0].date, to: new[new.count - 1].date)

        XCTAssertEqual(visible.map(\.date), new.map(\.date))
        XCTAssertEqual(visible.map(\.value), new.map(\.value))
        XCTAssertEqual(history.points.count, new.count)
    }

    func testRangeHistoryDoesNotExtendFlatLineBeforeFirstObservation() throws {
        let old = points([4, 6, 8]) { $0 * 10 }
        let new = points([2, 4, 6, 8]) { $0 * 10 }
        let history = StandardLineChartRangeHistory(from: old, to: new)
        let requestedStart = Date(timeIntervalSinceReferenceDate: -20)
        let requestedEnd = Date(timeIntervalSinceReferenceDate: 3)
        let visible = history.samples(from: requestedStart, to: requestedEnd)

        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible.first?.date, new[0].date)
        XCTAssertEqual(visible.first?.value, 20)
        XCTAssertEqual(visible.last?.date, requestedEnd)
        XCTAssertEqual(visible.last?.value, 30)
        XCTAssertTrue(history.samples(
            from: requestedStart,
            to: Date(timeIntervalSinceReferenceDate: 1)
        ).isEmpty)
    }

    func testRangeHistoryInterpolatesOnlyCutSegmentsAndSettlesAtExactVertices() {
        let old = points([0, 10, 20]) { $0 * 2 }
        let new = points([10, 20]) { $0 * 2 }
        let history = StandardLineChartRangeHistory(from: old, to: new)
        let cut = history.samples(
            from: Date(timeIntervalSinceReferenceDate: 5),
            to: Date(timeIntervalSinceReferenceDate: 15)
        )

        XCTAssertEqual(cut.map { $0.date.timeIntervalSinceReferenceDate }, [5, 10, 15])
        XCTAssertEqual(cut.map(\.value), [10, 20, 30])
        let settled = history.samples(from: new[0].date, to: new[1].date)
        XCTAssertEqual(settled.map(\.date), new.map(\.date))
        XCTAssertEqual(settled.map(\.value), new.map(\.value))
    }

    func testRebasedInterleavedDatesCannotCreateSpikes() {
        let old = points([0, 2, 4, 6, 8, 10]) { _ in 10 }
        let new = points([1, 3, 5, 7, 9, 10]) { _ in 100 }
        let path = StandardLineChartViewportPath(from: old, to: new)
        for tick in 0...60 {
            let progress = CGFloat(tick) / 60
            let samples = path.samples(progress: progress)
            for point in samples { XCTAssertEqual(point.value, 10 + 90 * Double(progress), accuracy: 0.000_001) }
            XCTAssertEqual(samples.map(\.date), samples.map(\.date).sorted())
            XCTAssertEqual(Set(samples.map(\.date)).count, samples.count)
        }
    }

    func testTransitionEndsAtExactOriginalVerticesInBothDirections() {
        let a = points([0, 1, 4, 8, 10]) { sin($0) * 300 }
        let b = points([2, 3, 5, 9, 10]) { cos($0) * 80 }
        for (old, new) in [(a, b), (b, a)] {
            let path = StandardLineChartViewportPath(from: old, to: new)
            XCTAssertEqual(path.samples(progress: 0).map(\.value), old.map(\.value))
            XCTAssertEqual(path.samples(progress: 1).map(\.value), new.map(\.value))
            XCTAssertEqual(path.samples(progress: 1).map(\.date), new.map(\.date))
            XCTAssertEqual(path.samples(progress: -0.1).map(\.value), old.map(\.value))
            XCTAssertEqual(path.samples(progress: 1.1).map(\.value), new.map(\.value))
        }
    }

    func testRapidRetargetStartsAtCurrentGeometryNotPreviousDestination() {
        let a = points([0, 2, 4, 6, 8, 10]) { 100 + $0 }
        let b = points([1, 3, 5, 7, 9, 10]) { 10 - $0 }
        let c = points([0, 1, 5, 8, 10]) { 500 + $0 * 10 }
        let visible = StandardLineChartViewportPath(from: a, to: b).samples(progress: 0.35)
        let next = StandardLineChartViewportPath(from: visible, to: c)
        XCTAssertEqual(next.samples(progress: 0).map(\.value), visible.map(\.value))
        XCTAssertEqual(next.samples(progress: 0).map(\.date), visible.map(\.date))
        XCTAssertNotEqual(visible.map(\.value), b.map(\.value))
        for point in next.samples(progress: 0.7) { XCTAssertTrue(point.value.isFinite) }
    }

    func testMarkerValueRidesTheSameAnimatedPolyline() {
        let a = points([0, 2, 4, 6, 8, 10]) { $0 * $0 }
        let b = points([0, 1, 3, 5, 7, 9, 10]) { $0 * 3 + 20 }
        let path = StandardLineChartViewportPath(from: a, to: b)
        for tick in 0...60 {
            let t = CGFloat(tick) / 60
            let date = Date(timeIntervalSinceReferenceDate: 5)
            let drawn = path.samples(progress: t)
            let markerValue = StandardLineChartViewportPath.value(at: date, in: drawn)
            let expected = StandardLineChartViewportPath.value(at: date, in: a) * Double(1 - t)
                + StandardLineChartViewportPath.value(at: date, in: b) * Double(t)
            XCTAssertEqual(markerValue, expected, accuracy: 0.000_001)
        }
    }

    func testSharedEntranceUsesTemplateThenExactRealValue() {
        let domain = -20.0...120.0
        for index in 0...30 {
            let x = Double(index) / 30
            let target = sin(x * 9) * 50
            XCTAssertEqual(StandardLineChartEntrancePhase(progress: 0).value(target, fraction: x, domain: domain),
                StandardLineChartLoadingTemplate.value(at: x, domain: domain), accuracy: 0.000_001)
            XCTAssertEqual(StandardLineChartEntrancePhase(progress: 1).value(target, fraction: x, domain: domain),
                target, accuracy: 0.000_001)
        }
    }

    func testDenseNineSeriesFramesStayFinite() {
        for index in 0..<9 {
            let old = points((0..<1600).map(Double.init)) { sin($0 / 37) * Double(index + 1) }
            let new = points((300..<1600).filter { $0 % 3 == 0 }.map(Double.init)) { cos($0 / 43) * 100 + 200 }
            let path = StandardLineChartViewportPath(from: old, to: new)
            for tick in 0...20 {
                XCTAssertTrue(path.samples(progress: CGFloat(tick) / 20).allSatisfy { $0.value.isFinite })
            }
        }
    }

    @MainActor
    func testCaptureEntranceRebaseRapidSwitchAndReducedMotion() async throws {
        let expectsReducedMotion = ProcessInfo.processInfo.environment["CATFOLIO_EXPECT_REDUCED_MOTION"] == "1"
        XCTAssertEqual(UIAccessibility.isReduceMotionEnabled, expectsReducedMotion)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for dark in [false, true] {
            let model = LineMotionFixtureState()
            let host = UIHostingController(rootView: LineMotionFixture(model: model)
                .environment(\.colorScheme, dark ? .dark : .light))
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 340)
            func capture(_ name: String) {
                host.view.bounds = CGRect(x: 0, y: 0, width: 402, height: 340)
                host.view.layoutIfNeeded()
                let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                })
                attachment.name = "line-motion-\(name)-\(dark)-reduced-\(expectsReducedMotion)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            try await Task.sleep(for: .milliseconds(40)); capture("entrance")
            try await Task.sleep(for: .milliseconds(550)); capture("rest")
            model.phase = 1
            try await Task.sleep(for: .milliseconds(120)); capture("rebase")
            model.phase = 2
            try await Task.sleep(for: .milliseconds(90)); capture("rapid-switch")
            try await Task.sleep(for: .milliseconds(550)); capture("settled")
        }
    }
}

@Observable private final class LineMotionFixtureState {
    var phase = 0
}

private struct LineMotionFixture: View {
    @Bindable var model: LineMotionFixtureState
    private var series: [StandardLineChartSeries] {
        let days: [Double] = model.phase == 0 ? [0, 2, 4, 6, 8, 10]
            : model.phase == 1 ? [1, 3, 5, 7, 9, 10] : [0, 1, 4, 6, 7, 10]
        return (0..<9).map { index in
            let points = days.map { day in
                let value = model.phase == 2 ? 20 + Double(index) * 7 + sin(day) * 3
                    : (model.phase == 0 ? 10 : -40) + Double(index) * 10 + 1.5 * day
                return StandardLineChartPoint(date: Date(timeIntervalSinceReferenceDate: day * 86400), value: value)
            }
            return StandardLineChartSeries(id: "line-\(index)", points: points,
                color: Color(hue: Double(index) / 10, saturation: 0.75, brightness: 0.85),
                latestPointRadius: index == 0 ? 4 : nil, latestPointUsesGlass: false)
        }
    }
    var body: some View {
        let data = series
        let domain = StandardLineChartEntrancePhase.domain(data.flatMap { $0.points.map(\.value) })
        let date = Date(timeIntervalSinceReferenceDate: 5 * 86400)
        VStack(alignment: .leading, spacing: 12) {
            Text("Nine series · rebase / trade alignment · UI fixture").font(.caption)
            StandardLineChart(series: data, interactionDates: data[0].points.map(\.date), domain: domain,
                yTicks: [domain.lowerBound, domain.upperBound], axisWidth: 40, topInset: 10,
                transitionKey: String(model.phase), dataTransition: .viewportZoom,
                markers: [StandardLineChartMarker(id: "trade", point: .init(date: date,
                    value: StandardLineChartViewportPath.value(at: date, in: data[0].points)), color: .green,
                    radius: 6, style: .ring, seriesID: "line-0")],
                referenceLines: [.init(id: "cost", value: 30, color: .green, label: "Cost 30")],
                yAxisLabel: { String(format: "%.0f", $0) }, xAxisLabel: { _ in "Date" })
        }.padding(16).background(Color(uiColor: .systemBackground))
    }
}

final class SecurityDailyMoveTests: XCTestCase {
    func testFundIntroductionOverridesMoveRoutingAndSeparatesCache() throws {
        let history = SecurityPriceHistory(ticker: "VWRP.L", currency: "GBP",
            points: [.init(dateText: "2026-09-09", close: 100), .init(dateText: "2026-09-10", close: 106)],
            intradayPoints: [], trades: [])
        let fund = try XCTUnwrap(SecurityPriceMoveContext.latestSession(history: history,
            name: "Vanguard FTSE All-World UCITS ETF Acc", isFund: true))
        let stock = try XCTUnwrap(SecurityPriceMoveContext.latestSession(history: history, name: fund.name))
        XCTAssertTrue(fund.isFundIntroduction)
        XCTAssertEqual(fund.noteTitle, L10n.text("最近有什么动静？"))
        XCTAssertNotEqual(fund.noteTitle, stock.noteTitle)
        XCTAssertTrue(fund.notePrompt.contains("ETF/fund"))
        XCTAssertTrue(fund.notePrompt.contains("exact listing and share class"))
        XCTAssertFalse(fund.notePrompt.contains("selected_focus:"))
        XCTAssertTrue(stock.notePrompt.contains("selected_focus:"))
        XCTAssertNotEqual(fund.key(language: "en"), stock.key(language: "en"))
        XCTAssertNotEqual(fund.key(language: "en"), fund.key(language: "zh-Hans"))
        XCTAssertNotEqual(SecurityDailyMoveStore.noEvidenceNote(fund).text,
                          SecurityDailyMoveStore.noEvidenceNote(stock).text)
    }

    func testLegacyContextDecodesAndFundContextRoundTrips() throws {
        let legacy = SecurityPriceMoveContext(ticker: "TEST", name: "Test", currency: "USD", rangeLabel: "day",
            startDate: Date(timeIntervalSince1970: 100), endDate: Date(timeIntervalSince1970: 200),
            startPrice: 100, endPrice: 101, isIntraday: false)
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fundIntroduction"))
        XCTAssertFalse(try JSONDecoder().decode(SecurityPriceMoveContext.self, from: data).isFundIntroduction)
        var fund = legacy
        fund.fundIntroduction = true
        let decoded = try JSONDecoder().decode(SecurityPriceMoveContext.self, from: JSONEncoder().encode(fund))
        XCTAssertEqual(decoded, fund)
        XCTAssertTrue(decoded.isFundIntroduction)
    }

    func testRelativeSessionDatesAcrossWeekAndYearBoundaries() throws {
        let now = try XCTUnwrap(DayDateCodec.date(from: "2026-09-11"))
        for (date, label) in [("2026-09-11", "今天"), ("2026-09-10", "昨天"),
                              ("2026-09-09", "前天"), ("2026-09-04", "上周")] {
            XCTAssertEqual(SecurityNoteRelativeDate.label(try XCTUnwrap(DayDateCodec.date(from: date)),
                now: now, locale: Locale(identifier: "zh_CN")), label)
        }
        XCTAssertEqual(SecurityNoteRelativeDate.label(try XCTUnwrap(DayDateCodec.date(from: "2025-12-31")),
            now: try XCTUnwrap(DayDateCodec.date(from: "2026-01-01")), locale: Locale(identifier: "en")), "Yesterday")
    }

    func testDailyContextUsesPriorCloseRegardlessOfChartSelection() throws {
        let history = SecurityPriceHistory(ticker: "TEST", currency: "USD",
            points: [.init(dateText: "2026-09-08", close: 80), .init(dateText: "2026-09-09", close: 100),
                     .init(dateText: "2026-09-10", close: 105)], intradayPoints: [], trades: [])
        let context = try XCTUnwrap(SecurityPriceMoveContext.latestSession(history: history, name: "Test"))
        XCTAssertEqual(context.startPrice, 100)
        XCTAssertEqual(context.changePercent, 5, accuracy: 0.001)
        XCTAssertEqual(context.rangeLabel, "2026-09-10")
    }

    func testSearchMustActuallyComplete() {
        XCTAssertFalse(CodexOAuthClient.containsCompletedWebSearch(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"web_search_call\"}".utf8)))
        XCTAssertTrue(CodexOAuthClient.containsCompletedWebSearch(Data("data: {\"type\":\"response.web_search_call.completed\"}".utf8)))
    }

    func testRejectsLongAnswerAndUnsafeSourceSchemes() throws {
        let raw = #"{"text":"消息已核对。","sources":[{"title":"bad","url":"javascript:alert(1)"}]}"#
        XCTAssertTrue(try SecurityDailyMoveNote.parse(raw).sources.isEmpty)
        XCTAssertThrowsError(try SecurityDailyMoveNote.parse(#"{"text":"一。二。三。","sources":[]}"#))
    }

    @MainActor
    func testRepeatedTapsReuseOneRequest() async throws {
        let counter = DailyMoveCounter()
        let store = SecurityDailyMoveStore { _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return SecurityDailyMoveNote(text: "没有明确消息。", sources: [])
        }
        let context = SecurityPriceMoveContext(ticker: "TEST", name: "Test", currency: "USD", rangeLabel: "day",
            startDate: Date(timeIntervalSince1970: 100), endDate: Date(timeIntervalSince1970: 200),
            startPrice: 100, endPrice: 100.01, isIntraday: false)
        store.start(context); store.start(context)
        try await Task.sleep(for: .milliseconds(100))
        store.start(context)
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }
}
private actor DailyMoveCounter {
    var count = 0
    func increment() { count += 1 }
}

private struct DailyPaperBackdropFixture: View {
    @State private var presented = false
    private let context = SecurityPriceMoveContext(ticker: "TEST", name: "示例公司", currency: "USD",
        rangeLabel: "2026-09-10", startDate: Date(timeIntervalSince1970: 1788912000),
        endDate: Date(timeIntervalSince1970: 1788998400), startPrice: 100, endPrice: 105, isIntraday: false)
    private let store = SecurityDailyMoveStore { _ in
        SecurityDailyMoveNote(text: "昨天，公司公布的月度营收创下新高，AI 芯片需求强劲。",
            sources: [.init(title: "公司公告 · 月度营收", url: URL(string: "https://example.com/revenue")!)])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HoldingDetailHeader(holding: visibilityHolding("TEST", name: "示例公司"), marketTodayChange: 5,
                selectedPrice: 105, selectedReturn: 5)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<14) { index in
                    RoundedRectangle(cornerRadius: 4).fill(CatfolioTheme.accent.opacity(0.65))
                        .frame(height: CGFloat(40 + (index * 29) % 160))
                }
            }.frame(height: 210)
            Text("持仓账户").font(.title2)
            ForEach(0..<4) { _ in
                HStack { Text("示例账户"); Spacer(); Text("$12,500") }
                    .padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            }
            Spacer()
        }
        .padding(20)
        .background(Color(uiColor: .systemGroupedBackground))
        .fullScreenCover(isPresented: $presented) { SecurityDailyMovePaper(context: context, store: store) }
        .task { SecurityDailyMovePresentation.withoutSystemTransition { presented = true } }
    }
}

final class SecurityPaperProjectionTests: XCTestCase {
    func testSharedHingeAndLocalNormalSeparation() {
        let size = CGSize(width: 340, height: 250)
        func point(_ amount: Double, upper: Bool, depth: Double, y: CGFloat) -> CGPoint {
            let t = SecurityPaperPlane(amount: amount, upper: upper, depth: depth, halfHeight: 250).effectValue(size: size)
            let x: CGFloat = 170
            let w = t.m13 * x + t.m23 * y + t.m33
            return CGPoint(x: (t.m11 * x + t.m21 * y + t.m31) / w,
                           y: (t.m12 * x + t.m22 * y + t.m32) / w)
        }
        for p in [0.0, 0.25, 0.5, 0.75, 1.0, 1.12, 1.2] {
            let upperHinge = point(p, upper: true, depth: 0, y: 0)
            let lowerHinge = point(p, upper: false, depth: 0, y: 0)
            XCTAssertEqual(upperHinge.x, lowerHinge.x, accuracy: 0.001)
            XCTAssertEqual(upperHinge.y, lowerHinge.y, accuracy: 0.001)
            XCTAssertTrue(point(p, upper: true, depth: 1.9, y: 250).y.isFinite)
        }
        let closedA = point(0, upper: true, depth: 0, y: 125)
        let closedB = point(0, upper: true, depth: 1.9, y: 125)
        XCTAssertGreaterThan(abs(closedA.y - closedB.y), 0.5, "Depth must separate closed pages along their local normal")
        XCTAssertLessThan(point(1, upper: true, depth: 0, y: 250).y, 0)
        XCTAssertGreaterThan(point(1, upper: false, depth: 0, y: 250).y, 0)
    }
}

final class SecurityPaperMotionTests: XCTestCase {
    func testOpenPaperIsSymmetricAndEveryHorizontalEdgeStaysLevel() {
        let size = CGSize(width: 300, height: 225)
        func point(upper: Bool, x: CGFloat, y: CGFloat) -> CGPoint {
            let t = SecurityPaperPlane(amount: 1, upper: upper, depth: 0, halfHeight: 225).effectValue(size: size)
            let w = t.m13 * x + t.m23 * y + t.m33
            return CGPoint(x: (t.m11 * x + t.m21 * y + t.m31) / w,
                           y: (t.m12 * x + t.m22 * y + t.m32) / w)
        }
        for y: CGFloat in [0, 100, 225] {
            let topLeft = point(upper: true, x: 0, y: y)
            let topRight = point(upper: true, x: 300, y: y)
            let bottomLeft = point(upper: false, x: 0, y: y)
            let bottomRight = point(upper: false, x: 300, y: y)
            XCTAssertEqual(topLeft.y, topRight.y, accuracy: 0.001)
            XCTAssertEqual(bottomLeft.y, bottomRight.y, accuracy: 0.001)
            XCTAssertEqual(topLeft.x, bottomLeft.x, accuracy: 0.001)
            XCTAssertEqual(topRight.x, bottomRight.x, accuracy: 0.001)
            XCTAssertEqual(topLeft.y, -bottomLeft.y, accuracy: 0.001)
        }
    }

    func testDownwardDragFoldsBeforeDismissalAndUpwardDragKeepsPaperOpen() {
        XCTAssertEqual(SecurityPaperMotion.fold(start: 1, offset: 145), 0)
        XCTAssertFalse(SecurityPaperMotion.shouldDismiss(offset: 145))
        XCTAssertTrue(SecurityPaperMotion.shouldDismiss(offset: 190))
        XCTAssertEqual(SecurityPaperMotion.fold(start: 1, offset: -169), 1)
        XCTAssertFalse(SecurityPaperMotion.shouldDismiss(offset: -169))
        XCTAssertTrue(SecurityPaperMotion.shouldDismiss(offset: -170))
    }
    func testBlurTracksEntryAndBothExitDirectionsContinuously() {
        XCTAssertEqual(SecurityPaperMotion.visibility(entrance: 0, offset: 0, travel: 600), 0)
        XCTAssertEqual(SecurityPaperMotion.visibility(entrance: 0.5, offset: 0, travel: 600), 0.5)
        for direction: CGFloat in [-1, 1] {
            XCTAssertEqual(SecurityPaperMotion.visibility(entrance: 1, offset: direction * 300, travel: 600), 0.5)
            XCTAssertEqual(SecurityPaperMotion.visibility(entrance: 1, offset: direction * 600, travel: 600), 0)
        }
    }
    func testLowerPageHasVisiblePerspectiveAtRest() {
        let t = SecurityPaperPlane(amount: 1, upper: false, depth: 0, halfHeight: 225)
            .effectValue(size: CGSize(width: 300, height: 225))
        let hingeWidth = 300 / t.m33
        let farWidth = 300 / (t.m23 * 225 + t.m33)
        XCTAssertGreaterThan(abs(farWidth - hingeWidth), 15)
        XCTAssertEqual(t.m12, 0, accuracy: 0.001, "The hinge remains horizontal")
    }
}

@MainActor
final class SecurityPaperBlurLifecycleTests: XCTestCase {
    func testRepeatedOpenCloseLeavesNoAnimatorOrBlur() {
        let view = SecurityPaperBlur.BlurView()
        for _ in 0..<10 {
            view.setAmount(0.4)
            XCTAssertNotNil(view.blurAnimator)
            view.setAmount(1)
            XCTAssertNil(view.blurAnimator, "Resting paper must not retain an interactive animation")
            XCTAssertNotNil(view.effect)
            view.setAmount(0.6)
            XCTAssertNotNil(view.blurAnimator)
            view.setAmount(0)
            XCTAssertNil(view.blurAnimator)
            XCTAssertNil(view.effect)
        }
    }

    func testDetachDuringAnimationReleasesBlurAndAnimator() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let view = SecurityPaperBlur.BlurView()
        window.addSubview(view)
        view.setAmount(0.5)
        XCTAssertNotNil(view.blurAnimator)
        view.removeFromSuperview()
        XCTAssertNil(view.blurAnimator)
        XCTAssertNil(view.effect)
        weak var released: SecurityPaperBlur.BlurView?
        autoreleasepool {
            let temporary = SecurityPaperBlur.BlurView()
            released = temporary
            temporary.setAmount(0.5)
            temporary.tearDown()
        }
        XCTAssertNil(released)
    }
}

@MainActor
final class SecurityPaperSourceAnchorTests: XCTestCase {
    func testTapReadsCurrentScrollPositionWithoutKeepingTheViewAlive() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 300, height: 2000)
        window.addSubview(scroll)
        let anchor = SecurityPaperSourceAnchor()
        var button: UIView? = UIView(frame: CGRect(x: 24, y: 800, width: 160, height: 44))
        scroll.addSubview(try XCTUnwrap(button))
        anchor.view = button
        window.layoutIfNeeded()
        scroll.layoutIfNeeded()
        let initial = anchor.frame
        scroll.contentOffset.y = 250
        XCTAssertEqual(anchor.frame.minY, initial.minY - 250, accuracy: 0.001)
        let capturedAtTap = anchor.frame
        scroll.contentOffset.y = 400
        XCTAssertEqual(capturedAtTap.minY, initial.minY - 250, accuracy: 0.001)
        XCTAssertEqual(anchor.frame.minY, initial.minY - 400, accuracy: 0.001)
        button?.removeFromSuperview()
        button = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(anchor.view)
        XCTAssertEqual(anchor.frame, .zero)
    }
}

final class SecurityPaperEntranceTests: XCTestCase {
    func testEntranceStartsAndEndsSlowWithSymmetricAcceleration() {
        XCTAssertEqual(SecurityPaperMotion.entranceEase(0), 0)
        XCTAssertEqual(SecurityPaperMotion.entranceEase(1), 1)
        XCTAssertEqual(SecurityPaperMotion.entranceEase(0.5), 0.5)
        XCTAssertLessThan(SecurityPaperMotion.entranceEase(0.1), 0.02)
        XCTAssertGreaterThan(SecurityPaperMotion.entranceEase(0.9), 0.98)
        for t in [0.1, 0.25, 0.4] {
            XCTAssertEqual(SecurityPaperMotion.entranceEase(t), 1 - SecurityPaperMotion.entranceEase(1 - t), accuracy: 0.00001)
        }
    }
    func testEachPresentationKeepsItsOwnButtonOriginAndRejectsMissingOrigin() throws {
        let context = SecurityPriceMoveContext(ticker: "TEST", name: "Test", currency: "USD", rangeLabel: "day",
            startDate: Date(timeIntervalSince1970: 100), endDate: Date(timeIntervalSince1970: 200),
            startPrice: 100, endPrice: 105, isIntraday: false)
        XCTAssertNil(SecurityPaperRequest(context: context, sourceFrame: .zero))
        let first = try XCTUnwrap(SecurityPaperRequest(context: context, sourceFrame: CGRect(x: 24, y: 400, width: 150, height: 44)))
        let second = try XCTUnwrap(SecurityPaperRequest(context: context, sourceFrame: CGRect(x: 24, y: 200, width: 150, height: 44)))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.sourceFrame.midY, 422)
        XCTAssertEqual(second.sourceFrame.midY, 222)
    }
}

final class SecurityDailyMoveSkillTests: XCTestCase {
    func testMissingEvidenceUsesFocusSpecificHonestFallback() {
        let quiet = SecurityPriceMoveContext(ticker: "TEST", name: "Test", currency: "USD", rangeLabel: "day",
            startDate: Date(timeIntervalSince1970: 100), endDate: Date(timeIntervalSince1970: 200),
            startPrice: 100, endPrice: 100.1, isIntraday: false)
        let moving = SecurityPriceMoveContext(ticker: "TEST", name: "Test", currency: "USD", rangeLabel: "day",
            startDate: quiet.startDate, endDate: quiet.endDate, startPrice: 100, endPrice: 106, isIntraday: false)
        let quietNote = SecurityDailyMoveStore.noEvidenceNote(quiet)
        let movingNote = SecurityDailyMoveStore.noEvidenceNote(moving)
        XCTAssertTrue(quietNote.sources.isEmpty)
        XCTAssertTrue(movingNote.sources.isEmpty)
        XCTAssertNotEqual(quietNote.text, movingNote.text)
    }

    struct Scenario: Decodable {
        let changePercent: Double
        let medianAbsoluteMovePercent: Double?
        let expectedFocus: String
    }
    func testBundledSkillAndRoutingScenarios() throws {
        XCTAssertFalse(SecurityDailyMoveSkill.instructions.isEmpty)
        XCTAssertNotEqual(SecurityDailyMoveSkill.routing.version, "fallback")
        let url = try XCTUnwrap(SecurityDailyMoveSkill.resource("cases", extension: "json", references: true))
        let cases = try JSONDecoder().decode([Scenario].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(cases.count, 10)
        for item in cases {
            XCTAssertEqual(SecurityDailyMoveSkill.focus(changePercent: item.changePercent,
                baseline: item.medianAbsoluteMovePercent).rawValue, item.expectedFocus)
        }
    }
    func testBaselineRequiresHistoryAndIsRobustToOneLargeReturn() throws {
        XCTAssertNil(SecurityDailyMoveSkill.baseline(closes: [100, 101, 102]))
        var closes = [100.0]
        for day in 0..<20 { closes.append(try XCTUnwrap(closes.last) * (day == 10 ? 2 : 1.01)) }
        XCTAssertEqual(try XCTUnwrap(SecurityDailyMoveSkill.baseline(closes: closes)), 1, accuracy: 0.000001)
    }
    func testSessionBaselineExcludesTheMoveBeingExplained() throws {
        let points = (0..<22).map { day in
            SecurityPricePoint(dateText: DayDateCodec.string(from: Date(timeIntervalSince1970: Double(day) * 86400)),
                close: 100 * pow(1.001, Double(day)) * (day == 21 ? 1.04 : 1))
        }
        let history = SecurityPriceHistory(ticker: "TEST", currency: "USD", points: points, intradayPoints: [], trades: [])
        let context = try XCTUnwrap(SecurityPriceMoveContext.latestSession(history: history, name: "Test"))
        XCTAssertEqual(try XCTUnwrap(context.typicalDailyMovePercent), 0.1, accuracy: 0.000001)
        XCTAssertEqual(context.noteFocus, .priceMove)
    }
}

final class SecurityTradeSelectionTests: XCTestCase {
    private func row(_ action: String = "SELL", account: String = "isa", currency: String = "USD",
                     profit: Double? = 14.56, profitCurrency: String? = "USD") -> LocalTransactionRecord {
        .init(date: "2026-09-10", action: action, ticker: "NVDA", quantity: 2, price: 100,
              currency: currency, source: "test", accountID: account, accountName: nil,
              realisedProfitLoss: profit, realisedProfitLossCurrency: profitCurrency)
    }

    func testAccountSelectionKeepsOnlyThatAccountsAmountAndResult() throws {
        let grouped = try XCTUnwrap(SecurityTrade.grouped([row(), row(account: "invest", profit: -5)]).first)
        XCTAssertEqual(grouped.amountTotals, ["USD": 400])
        let selected = try XCTUnwrap(grouped.filtered(accounts: ["test|invest"]))
        XCTAssertEqual(selected.quantity, 2)
        XCTAssertEqual(selected.tradeCount, 1)
        XCTAssertEqual(selected.amountTotals, ["USD": 200])
        XCTAssertEqual(selected.profitTotals, ["USD": -5])
        XCTAssertNil(grouped.filtered(accounts: ["another"]))
    }

    func testUnknownProfitIsNotReportedAsZeroOrPartialSum() throws {
        let trade = try XCTUnwrap(SecurityTrade.grouped([row(), row(profit: nil)]).first)
        XCTAssertNil(trade.profitTotals)
        XCTAssertEqual(trade.amountTotals, ["USD": 400])
        XCTAssertNil(SecurityTrade.grouped([row(profitCurrency: nil)]).first?.profitTotals)
        XCTAssertEqual(SecurityTrade.grouped([row(profit: 0)]).first?.profitTotals, ["USD": 0])
    }

    func testDifferentCurrenciesAndBuySellStaySeparate() throws {
        let grouped = SecurityTrade.grouped([row(), row(currency: "GBP", profit: -3, profitCurrency: "GBP"), row("BUY")])
        XCTAssertEqual(grouped.count, 2)
        let sell = try XCTUnwrap(grouped.first(where: \.isSell))
        XCTAssertEqual(sell.amountTotals, ["USD": 200, "GBP": 200])
        XCTAssertEqual(sell.profitTotals, ["USD": 14.56, "GBP": -3])
        XCTAssertNil(grouped.first(where: \.isBuy)?.profitTotals)
    }

    func testReadoutMatchesMarkerVertexAndClearsAtAdjacentPoint() throws {
        let trades = SecurityTrade.grouped([row(), row("BUY"), row(account: "invest")])
        let history = SecurityPriceHistory(ticker: "NVDA", currency: "USD", points: [
            .init(dateText: "2026-09-09", close: 95), .init(dateText: "2026-09-10", close: 103),
            .init(dateText: "2026-09-11", close: 105)], intradayPoints: [], trades: trades)
        let data = SecurityPriceRangeData(history: history, range: .maximum, averageCost: 80,
                                         selectedAccountKeys: ["test|isa"])
        let date = try XCTUnwrap(DayDateCodec.date(from: "2026-09-10"))
        XCTAssertEqual(data.trades(at: date).count, 2)
        XCTAssertTrue(data.trades(at: date).allSatisfy { $0.amountTotals == ["USD": 200] })
        XCTAssertTrue(data.trades(at: date.addingTimeInterval(86400)).isEmpty)
        XCTAssertTrue(SecurityPriceRangeData(history: history, range: .maximum, averageCost: nil,
            selectedAccountKeys: ["another"]).trades(at: date).isEmpty)
    }

    func testInferredEntryDoesNotInventAnExecutionAmount() {
        let inferred = SecurityTrade(dateText: "2026-09-10", action: "BUY", quantity: 10,
                                     tradeCount: 1, accountKeys: ["isa"])
        XCTAssertNil(inferred.amountTotals)
        XCTAssertNil(inferred.profitTotals)
    }
}

final class SecurityTradeMagnetTests: XCTestCase {
    private let buy = Date(timeIntervalSince1970: 100)
    private let sell = Date(timeIntervalSince1970: 200)

    func testOnlyAttractsWithinSmallScreenDistance() {
        let targets = [(date: buy, x: CGFloat(100))]
        XCTAssertEqual(ChartMarkerMagnet.date(at: 105, targets: targets, currentDate: nil, radius: 6), buy)
        XCTAssertNil(ChartMarkerMagnet.date(at: 107, targets: targets, currentDate: nil, radius: 6))
        XCTAssertNil(ChartMarkerMagnet.date(at: 100, targets: targets, currentDate: nil, radius: 0))
    }

    func testReleaseMarginPreventsBoundaryJitterButLetsGo() {
        let targets = [(date: buy, x: CGFloat(100))]
        XCTAssertEqual(ChartMarkerMagnet.date(at: 107, targets: targets, currentDate: buy, radius: 6), buy)
        XCTAssertNil(ChartMarkerMagnet.date(at: 109, targets: targets, currentDate: buy, radius: 6))
        XCTAssertNil(ChartMarkerMagnet.date(at: 107, targets: targets, currentDate: sell, radius: 6))
    }

    func testNearbyBuyAndSellSelectClosestMarkerInsteadOfStickingToOldOne() {
        let targets = [(date: buy, x: CGFloat(100)), (date: sell, x: CGFloat(108))]
        XCTAssertEqual(ChartMarkerMagnet.date(at: 106, targets: targets, currentDate: buy, radius: 6), sell)
        XCTAssertEqual(ChartMarkerMagnet.date(at: 104, targets: Array(targets.reversed()), currentDate: nil, radius: 6), buy)
    }

    func testNoTradesOrRemovedAccountMarkerCannotKeepSelectionAttached() {
        XCTAssertNil(ChartMarkerMagnet.date(at: 100, targets: [], currentDate: buy, radius: 6))
        XCTAssertNil(ChartMarkerMagnet.date(at: 100, targets: [(date: sell, x: CGFloat(150))], currentDate: buy, radius: 6))
    }
}
