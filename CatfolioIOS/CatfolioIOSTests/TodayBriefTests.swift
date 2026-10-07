import Foundation
import XCTest
@testable import CatfolioIOS

final class TodayBriefTests: XCTestCase {
    private func context(language: String = "zh_CN") -> TodayBriefContext {
        TodayBriefContext(sessionDate: "2026-10-02", total: 42, benchmarkChange: -0.3,
            stocks: [.init(ticker: "NVDA", name: "英伟达", logoSymbol: "NVDA", changePercent: 2, amount: 60),
                     .init(ticker: "AAPL", name: "苹果", logoSymbol: "AAPL", changePercent: -1, amount: -18)],
            sectors: [.init(id: "technology", name: "科技", icon: "cpu", amount: 42)], language: language)
    }

    func testStreamedReferencesHideIncompleteMarkupAndRejectUnknownTargets() {
        let targets = context().targets
        XCTAssertEqual(TodayBriefFragment.parse("今日[[stock:NVDA|英伟达", allowedTargets: targets),
                       [.init(text: "今日", target: nil)])
        XCTAssertEqual(TodayBriefFragment.parse("[[stock:NVDA|英伟达]]上涨，[[stock:FAKE|未知股票]]。", allowedTargets: targets),
                       [.init(text: "英伟达", target: "stock:NVDA"), .init(text: "上涨，", target: nil),
                        .init(text: "未知股票", target: nil), .init(text: "。", target: nil)])
    }

    func testNewsSearchContainsOnlyPublicNamesAndSessionDate() throws {
        let question = try XCTUnwrap(context().newsQuestion(for: "stock:NVDA"))
        XCTAssertTrue(question.contains("NVDA"))
        XCTAssertTrue(question.contains("2026-10-02"))
        XCTAssertTrue(question.contains("including non-trading days"))
        XCTAssertTrue(question.contains("never as causes of that earlier return"))
        XCTAssertTrue(question.contains("observed session return 2.0%"), question)
        XCTAssertFalse(question.contains("AAPL"))
        XCTAssertFalse(question.contains("42"))
        XCTAssertFalse(question.contains("60"))
        XCTAssertFalse(question.contains("-18"))
        let benchmark = try XCTUnwrap(context().newsQuestion(for: "benchmark"))
        XCTAssertTrue(benchmark.contains("S&P 500"))
        XCTAssertFalse(benchmark.contains("NVDA"))
        XCTAssertNil(context().newsQuestion(for: "sector:technology"),
                     "A sector without known members must not search unrelated holdings")
        XCTAssertNil(TodayBriefContext(sessionDate: nil, total: 0, benchmarkChange: nil,
            stocks: [], sectors: [], language: "en").newsQuestion(for: "portfolio"))
    }

    func testNewsReadoutUsesSingleCompanyResearchAndSubstantiveInitialStructure() {
        let value = context()
        let research = value.companyResearchPrompt(for: value.stocks[0])
        XCTAssertTrue(research.contains("NVDA"))
        XCTAssertFalse(research.contains("AAPL"))
        XCTAssertFalse(research.contains("contribution" + " 60"))
        XCTAssertTrue(value.prompt(target: nil, previous: "").contains("3–4 short paragraphs"))
        XCTAssertTrue(value.prompt(target: nil, previous: "").contains("never invent a unifying narrative"))
    }

    func testExpansionPromptRequestsOnlyNewSentences() {
        let prompt = context().prompt(target: "stock:NVDA", previous: context().seed)
        XCTAssertTrue(prompt.contains("Output ONLY one or two NEW sentences"))
        XCTAssertTrue(prompt.contains(context().seed))
        XCTAssertTrue(prompt.contains("Never output 今日简报, disclaimers"))
        XCTAssertTrue(context().newsQuestion(for: "stock:NVDA")!.contains("after-hours"))
    }

    func testSeedUsesAvailableQuotesAndActualContributionLeader() {
        let value = context()
        let fragments = TodayBriefFragment.parse(value.seed, allowedTargets: value.targets)
        XCTAssertEqual(fragments.compactMap(\.target), ["portfolio", "stock:NVDA", "sector:technology"])
        XCTAssertTrue(value.facts.contains("daily return"))
        XCTAssertTrue(value.facts.contains("contribution"))
        XCTAssertTrue(context(language: "en").seed.hasPrefix("Today moved"))
    }

    func testCacheIdentityChangesWithDataGroupingAndLanguage() {
        let original = context()
        XCTAssertNotEqual(original, context(language: "en"))
        XCTAssertNotEqual(original, TodayBriefContext(sessionDate: "2026-10-05", total: original.total,
            benchmarkChange: original.benchmarkChange, stocks: original.stocks,
            sectors: original.sectors, language: original.language))
    }

    @MainActor
    func testQuoteRefreshKeepsTheSameBriefAndItsExpansions() async throws {
        let generator = TodayBriefTestGenerator()
        let store = TodayBriefStore(generate: { request, emit in
            try await generator.generate(request, emit: emit)
        })
        let value = context()
        let entry = store.entry(for: value)
        store.start(value)
        try await finished(entry)
        // The same session and holdings at fresher prices: no new request.
        let refreshed = TodayBriefContext(sessionDate: value.sessionDate, total: 55,
            benchmarkChange: 0.1, stocks: value.stocks.map {
                .init(ticker: $0.ticker, name: $0.name, logoSymbol: $0.logoSymbol,
                      changePercent: $0.changePercent + 0.5, amount: $0.amount + 6)
            }, sectors: value.sectors, language: value.language)
        XCTAssertTrue(store.entry(for: refreshed) === entry)
        store.start(refreshed)
        let count = await generator.count
        XCTAssertEqual(count, 1)
        // A new session or language is a new brief.
        XCTAssertFalse(store.entry(for: context(language: "en")) === entry)
    }

    func testPortfolioAmountIsShownAsItIsNow() {
        let value = context()
        XCTAssertEqual(value.liveLabel("+$30.00", target: "portfolio"),
                       DisplayFormat.money(42, signed: true, fractionDigits: 2))
        XCTAssertEqual(value.liveLabel("组合", target: "portfolio"), "组合")
        XCTAssertEqual(value.liveLabel("英伟达", target: "stock:NVDA"), "英伟达")
    }

    func testSourceLinksAcceptOnlyPublicWebURLs() {
        let sources = TodayBriefSource.parse("- [公告](<https://example.com/news>)\n- [坏链接](javascript:alert)\n- [含密码](https://user:password@example.com)")
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.url.absoluteString, "https://example.com/news")
    }

    @MainActor
    func testExpansionPreservesExistingTextAndAddsOnlyNewSentences() async throws {
        let generator = TodayBriefTestGenerator()
        let store = TodayBriefStore(generate: { request, emit in
            try await generator.generate(request, emit: emit)
        })
        let value = context()
        let entry = store.entry(for: value)
        store.start(value)
        store.start(value)
        try await finished(entry)
        XCTAssertEqual(entry.paragraphs.count, 1)
        let original = entry.paragraphs[0].text
        store.expand(value, target: "stock:NVDA")
        store.expand(value, target: "stock:NVDA")
        XCTAssertEqual(entry.paragraphs.count, 2)
        XCTAssertEqual(entry.paragraphs[0].text, original)
        try await finished(entry)
        XCTAssertEqual(entry.paragraphs[0].text, original)
        XCTAssertEqual(entry.paragraphs[1].text, "[[stock:NVDA|英伟达]]贡献了主要涨幅。")
        XCTAssertTrue(store.entry(for: value) === entry)
        let count = await generator.count
        XCTAssertEqual(count, 2)
        store.expand(value, target: "stock:FAKE")
        XCTAssertEqual(entry.paragraphs.count, 2)
    }

    @MainActor
    func testProviderFailureKeepsDataSummaryAndRemovesIncompleteExpansion() async throws {
        let store = TodayBriefStore(generate: { _, emit in
            await emit("Unverified partial news")
            throw URLError(.notConnectedToInternet)
        })
        let value = context()
        let entry = store.entry(for: value)
        store.start(value)
        try await finished(entry)
        XCTAssertEqual(entry.paragraphs.map(\.text), [value.seed])
        XCTAssertNotNil(entry.failure)
        store.expand(value, target: "portfolio")
        try await finished(entry)
        XCTAssertEqual(entry.paragraphs.map(\.text), [value.seed])
        XCTAssertNotNil(entry.failure)
    }

    @MainActor private func finished(_ entry: TodayBriefStore.Entry) async throws {
        for _ in 0..<100 {
            if !entry.isGenerating { return }
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
        let text = request.target == nil ? request.context.seed : "[[stock:NVDA|英伟达]]贡献了主要涨幅。"
        await emit(text)
        return .init(text: text, sources: [])
    }
}
