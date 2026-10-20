import Foundation
import XCTest
@testable import CatfolioIOS

final class TodayBriefTests: XCTestCase {
    private func context(language: String = "zh_CN") -> TodayBriefContext {
        TodayBriefContext(sessionDate: "2026-10-02", total: 42, benchmarkChange: -0.3,
            stocks: [.init(ticker: "NVDA", name: "英伟达", logoSymbol: "NVDA", changePercent: 2, amount: 60),
                     .init(ticker: "AAPL", name: "苹果", logoSymbol: "AAPL", changePercent: -1, amount: -18)],
            sectors: [.init(id: "technology", name: "科技", icon: "cpu", amount: 42, tickers: ["NVDA", "AAPL"])], language: language)
    }

    func testComputedOverviewImmediatelyCoversBreadthBothDirectionsAndSectors() {
        let value = context()
        XCTAssertEqual(value.overviewParagraphs.count, 3)
        XCTAssertTrue(value.seed.contains("2026-10-02"))
        XCTAssertTrue(value.seed.contains("1 项上涨、1 项下跌"))
        XCTAssertTrue(value.seed.contains("主要拉动来自"))
        XCTAssertTrue(value.seed.contains("主要拖累来自"))
        let targets = TodayBriefFragment.parse(value.seed, allowedTargets: value.targets).compactMap(\.target)
        for target in ["portfolio", "benchmark", "stock:NVDA", "stock:AAPL", "sector:technology"] {
            XCTAssertTrue(targets.contains(target))
        }
        XCTAssertTrue(value.seed.contains(DisplayFormat.money(-18, signed: true, fractionDigits: 2)))
        XCTAssertTrue(context(language: "en").seed.contains("1 rose and 1 fell"))
    }

    func testFlatMissingAndOffsettingQuotesDoNotInventDirectionOrPercentShares() {
        let flat = TodayBriefContext(sessionDate: nil, total: 0, benchmarkChange: nil,
            stocks: [.init(ticker: "FLAT", name: "Flat", logoSymbol: nil, changePercent: 0, amount: 0),
                     .init(ticker: "INVALID", name: "Bad", logoSymbol: nil, changePercent: .nan, amount: .nan)],
            sectors: [], language: "en")
        XCTAssertEqual(flat.overviewParagraphs.count, 1)
        XCTAssertTrue(flat.seed.contains("1 unchanged"))
        XCTAssertFalse(flat.seed.contains("Bad"))
        XCTAssertFalse(flat.seed.contains("SPY"))
        XCTAssertFalse(flat.seed.contains("nan"))
        let empty = TodayBriefContext(sessionDate: nil, total: 0, benchmarkChange: nil, stocks: [], sectors: [], language: "zh")
        XCTAssertTrue(empty.seed.isEmpty)
        let original = context()
        let offset = TodayBriefContext(sessionDate: original.sessionDate, total: 0, benchmarkChange: nil,
            stocks: original.stocks, sectors: [], language: "zh")
        XCTAssertTrue(offset.seed.contains("主要拉动"))
        XCTAssertTrue(offset.seed.contains("主要拖累"))
        XCTAssertFalse(offset.seed.contains("100%"))
    }

    func testResearchSelectionIncludesMaterialLoserAndRespectsTopic() {
        let value = TodayBriefContext(sessionDate: "2026-10-02", total: 10, benchmarkChange: nil,
            stocks: [.init(ticker: "BIG", name: "Big", logoSymbol: nil, changePercent: 2, amount: 100),
                     .init(ticker: "NEXT", name: "Next", logoSymbol: nil, changePercent: 2, amount: 90),
                     .init(ticker: "THIRD", name: "Third", logoSymbol: nil, changePercent: 2, amount: 80),
                     .init(ticker: "DOWN", name: "Down", logoSymbol: nil, changePercent: -1, amount: -2)],
            sectors: [.init(id: "one", name: "One", icon: "cpu", amount: -2, tickers: ["DOWN"])], language: "en")
        XCTAssertEqual(value.researchStocks().count, 3)
        XCTAssertTrue(value.researchStocks().contains { $0.ticker == "DOWN" })
        XCTAssertEqual(value.researchStocks(for: "sector:one").map(\.ticker), ["DOWN"])
        XCTAssertEqual(value.researchStocks(for: "stock:NEXT").map(\.ticker), ["NEXT"])
        XCTAssertTrue(value.researchStocks(for: "benchmark").isEmpty)
        XCTAssertTrue(value.researchStocks(for: "sector:missing").isEmpty)
    }

    func testNewsSearchContainsOnlyPublicNamesAndSessionDate() throws {
        let question = try XCTUnwrap(context().newsQuestion(for: "stock:NVDA"))
        XCTAssertTrue(question.contains("NVDA"))
        XCTAssertTrue(question.contains("2026-10-02"))
        XCTAssertTrue(question.contains("including non-trading days"))
        XCTAssertTrue(question.contains("never as causes of that earlier return"))
        for privateFigure in ["AAPL", "$42", "$60", "-18", "observed session return"] {
            XCTAssertFalse(question.contains(privateFigure))
        }
        XCTAssertTrue(context().newsQuestion(for: "benchmark")!.contains("S&P 500"))
        XCTAssertNil(context().newsQuestion(for: "sector:unknown"))
    }

    func testBriefAndArticleHaveDifferentEditorialContracts() {
        let value = context()
        XCTAssertTrue(value.prompt(target: nil, previous: "").contains("1–2 short paragraphs"))
        XCTAssertTrue(value.prompt(target: "stock:NVDA", previous: "Earlier update").contains("3–5 concise paragraphs"))
        XCTAssertTrue(value.prompt(target: "stock:NVDA", previous: "Earlier update").contains("Earlier update"))
        XCTAssertTrue(value.prompt(target: nil, previous: "").contains("never invent a unifying narrative"))
        XCTAssertTrue(value.companyResearchPrompt(for: value.stocks[0]).contains("NVDA"))
        XCTAssertFalse(value.companyResearchPrompt(for: value.stocks[0]).contains("AAPL"))
        let review = value.articleReviewPrompt(draft: "A dated, sourced draft [1]")
        XCTAssertTrue(review.contains("Calculate ratios and elapsed days"))
        XCTAssertTrue(review.contains("A dated, sourced draft [1]"))
        XCTAssertTrue(review.contains("Simplified Chinese"))
    }

    func testStreamedReferencesHideIncompleteMarkupAndRejectUnknownTargets() {
        let targets = context().targets
        XCTAssertEqual(TodayBriefFragment.parse("今日[[stock:NVDA|英伟达", allowedTargets: targets), [.init(text: "今日", target: nil)])
        XCTAssertEqual(TodayBriefFragment.parse("[[stock:FAKE|未知股票]]。", allowedTargets: targets),
                       [.init(text: "未知股票", target: nil), .init(text: "。", target: nil)])
    }

    func testEmptyNewsBoilerplateIsRemovedWithoutDroppingUsefulFacts() {
        let cleaned = TodayBriefEditorial.clean("未找到关联证据。公司上调全年收入指引。没有公开催化因素。")
        XCTAssertEqual(cleaned, "公司上调全年收入指引。")
        XCTAssertEqual(TodayBriefEditorial.clean("No verified relevant news. Revenue grew 10%."), "Revenue grew 10%.")
        XCTAssertEqual(TodayBriefEditorial.clean("公司报告收入没有增长。"), "公司报告收入没有增长。")
        XCTAssertTrue(TodayBriefEditorial.clean("暂无可核实的重要新进展。").isEmpty)
    }

    func testProviderCitationBracketsRemainReadableAlongsideInteractiveLinks() {
        let cleaned = TodayBriefEditorial.clean("[[stock:NVDA|英伟达]]发布业绩。[[1]]\n\n毛利率提高。[2]")
        XCTAssertEqual(cleaned, "[[stock:NVDA|英伟达]]发布业绩。[1]\n\n毛利率提高。[2]")
        let fragments = TodayBriefFragment.parse(cleaned, allowedTargets: context().targets)
        XCTAssertEqual(fragments.first, .init(text: "英伟达", target: "stock:NVDA"))
        XCTAssertTrue(fragments.map(\.text).joined().contains("业绩。[1]"))
    }

    func testContradictoryNumericComparisonsAreOmittedEvenWhenCited() {
        XCTAssertEqual(TodayBriefEditorial.clean("甲预计600万部，不到乙预计1,000万部的一半[1]。公司公布上市日期[2]。"), "公司公布上市日期[2]。")
        XCTAssertTrue(TodayBriefEditorial.clean("销量500万部，超过1,000万部的一半。").isEmpty)
        let valid = "甲预计400万部，不到乙预计1,000万部的一半[1]。"
        XCTAssertEqual(TodayBriefEditorial.clean(valid), valid)
        XCTAssertTrue(TodayBriefEditorial.clean("收入6,000万元，不足1亿元的一半。").isEmpty)
        let unrelated = "售价1,000元，销量超过100万部，约一半来自海外。"
        XCTAssertEqual(TodayBriefEditorial.clean(unrelated), unrelated)
    }

    func testEmptyDailyNoteContractAndQuoteFallbackContainNoNoNewsText() throws {
        let note = try SecurityDailyMoveNote.parse(#"{"text":"","sources":[]}"#)
        XCTAssertTrue(note.text.isEmpty)
        XCTAssertThrowsError(try SecurityDailyMoveNote.parse(#"{"text":"","sources":[{"title":"IR","url":"https://example.com"}]}"#))
        let move = SecurityPriceMoveContext(ticker: "TEST", name: "Test", currency: "USD", rangeLabel: "day",
            startDate: Date(timeIntervalSince1970: 1_760_000_000), endDate: Date(timeIntervalSince1970: 1_760_086_400),
            startPrice: 100, endPrice: 102, isIntraday: false)
        let fallback = SecurityDailyMoveStore.noEvidenceNote(move)
        XCTAssertTrue(fallback.text.contains("Test"))
        XCTAssertTrue(fallback.sources.isEmpty)
        XCTAssertEqual(TodayBriefEditorial.clean(fallback.text), fallback.text)
    }

    func testSourceLinksAcceptOnlyPublicWebURLsAndDeduplicate() {
        let sources = TodayBriefSource.parse("[公告](https://example.com/news) [密码](https://user:password@example.com)")
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(TodayBriefEditorial.sources(sources + sources).count, 1)
        XCTAssertTrue(TodayBriefEditorial.sources([.init(title: "Bad", url: URL(string: "file:///tmp/file")!)]).isEmpty)
    }

    @MainActor
    func testQuoteRefreshUpdatesComputedFactsWithoutRegeneratingNewsOrArticles() async throws {
        let generator = TodayBriefTestGenerator()
        let store = TodayBriefStore(prefetchLimit: 0, generate: { try await generator.generate($0, emit: $1) })
        let value = context()
        let entry = store.entry(for: value)
        store.start(value)
        try await finished { !entry.isGenerating }
        let refreshed = TodayBriefContext(sessionDate: value.sessionDate, total: 55, benchmarkChange: 0.1,
            stocks: value.stocks, sectors: value.sectors, language: value.language)
        XCTAssertTrue(store.entry(for: refreshed) === entry)
        XCTAssertNotEqual(refreshed.seed, value.seed)
        store.start(refreshed)
        let count = await generator.count
        XCTAssertEqual(count, 1)
        XCTAssertFalse(store.entry(for: context(language: "en")) === entry)
        XCTAssertEqual(refreshed.liveLabel("+$42.00", target: "portfolio"), DisplayFormat.money(55, signed: true, fractionDigits: 2))
    }

    @MainActor
    func testArticlesAreIndependentOfTheBriefAndRepeatedTapsReuseThem() async throws {
        let generator = TodayBriefTestGenerator()
        let store = TodayBriefStore(prefetchLimit: 0, generate: { try await generator.generate($0, emit: $1) })
        let value = context()
        let entry = store.entry(for: value)
        store.start(value)
        store.expand(value, target: "stock:NVDA")
        store.expand(value, target: "stock:NVDA")
        XCTAssertTrue(entry.isGenerating)
        XCTAssertTrue(entry.details["stock:NVDA"]?.isGenerating == true)
        XCTAssertTrue(entry.paragraphs.isEmpty, "The first frame uses computed text, never a partial AI paragraph")
        try await finished { !entry.isGenerating && entry.details["stock:NVDA"]?.isGenerating == false }
        let original = entry.paragraphs.map(\.text)
        XCTAssertEqual(entry.details["stock:NVDA"]?.text, "详细事件与财报数据。[1]\n\n公司已公布后续计划。[1]")
        store.expand(value, target: "stock:NVDA")
        store.expand(value, target: "stock:FAKE")
        XCTAssertEqual(entry.paragraphs.map(\.text), original)
        XCTAssertNil(entry.details["stock:FAKE"])
        let count = await generator.count
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testOverviewPreparesAtMostTwoArticlesAfterItHasSourcedContent() async throws {
        let generator = TodayBriefTestGenerator()
        let store = TodayBriefStore(generate: { try await generator.generate($0, emit: $1) })
        let value = context()
        let entry = store.entry(for: value)
        store.start(value)
        try await finished { !entry.isGenerating && entry.details.count == 2 && entry.details.values.allSatisfy { !$0.isGenerating } }
        let count = await generator.count
        XCTAssertEqual(count, 3)
        store.expand(value, target: "stock:NVDA")
        let afterTap = await generator.count
        XCTAssertEqual(afterTap, 3)
    }

    @MainActor
    func testFailedOrUncitedAIOutputCannotReplaceComputedSummary() async throws {
        let value = context()
        let store = TodayBriefStore(generate: { _, emit in
            await emit("Unverified partial news")
            throw URLError(.notConnectedToInternet)
        })
        let entry = store.entry(for: value)
        store.start(value)
        try await finished { !entry.isGenerating }
        XCTAssertTrue(entry.paragraphs.isEmpty)
        XCTAssertNotNil(entry.failure)
        XCTAssertEqual(value.overviewParagraphs.count, 3)
        store.expand(value, target: "stock:NVDA")
        try await finished { entry.details["stock:NVDA"]?.isGenerating == false }
        XCTAssertEqual(entry.details["stock:NVDA"]?.text, "")
        let uncited = TodayBriefStore(generate: { _, _ in .init(text: "Unsupported news", sources: []) })
        uncited.start(value)
        let uncitedEntry = uncited.entry(for: value)
        try await finished { !uncitedEntry.isGenerating }
        XCTAssertTrue(uncitedEntry.paragraphs.isEmpty)
        XCTAssertTrue(uncitedEntry.details.isEmpty)
    }

    func testConcurrentEvidenceRequestsShareOneLoadAndExplicitRetryReloads() async throws {
        let cache = TodayBriefEvidenceCache()
        let loader = TodayBriefEvidenceLoader()
        async let first = cache.note(key: "NVDA|day|zh") { try await loader.load() }
        async let second = cache.note(key: "NVDA|day|zh") { try await loader.load() }
        _ = try await (first, second)
        let initialCount = await loader.count
        XCTAssertEqual(initialCount, 1)
        _ = try await cache.note(key: "NVDA|day|zh") { try await loader.load() }
        let cachedCount = await loader.count
        XCTAssertEqual(cachedCount, 1)
        _ = try await cache.note(key: "NVDA|day|zh", force: true) { try await loader.load() }
        let finalCount = await loader.count
        XCTAssertEqual(finalCount, 2)
    }

    @MainActor private func finished(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Brief generation did not finish")
    }
}

private actor TodayBriefTestGenerator {
    private(set) var count = 0
    func generate(_ request: TodayBriefStore.Request,
                  emit: @escaping @Sendable (String) async -> Void) async throws -> TodayBriefStore.Output {
        count += 1
        try await Task.sleep(for: .milliseconds(40))
        let text = request.target == nil ? "[[stock:NVDA|英伟达]]上调全年收入指引。" : "详细事件与财报数据。[1]\n\n公司已公布后续计划。[1]"
        await emit("Partial unsupported statement")
        return .init(text: text, sources: [.init(title: "Company IR", url: URL(string: "https://example.com/news")!)])
    }
}

private actor TodayBriefEvidenceLoader {
    private(set) var count = 0
    func load() async throws -> SecurityDailyMoveNote {
        count += 1
        try await Task.sleep(for: .milliseconds(30))
        return .init(text: "Company raised guidance.", sources: [.init(title: "IR", url: URL(string: "https://example.com/ir")!)])
    }
}
