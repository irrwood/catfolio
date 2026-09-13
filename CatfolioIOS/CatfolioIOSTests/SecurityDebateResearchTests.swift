import XCTest
@testable import CatfolioIOS

/// Parsing of the three keyless research feeds.
///
/// Fixtures are trimmed from live responses rather than invented, so the shapes
/// are the ones the services actually return — including the details that cost
/// time to discover: Google appends " - Publisher" to every headline and wraps
/// links in its own redirect, and EDGAR addresses a document as
/// "<accession>:<file>" while naming the filer "NVIDIA CORP  (NVDA)  (CIK 000…)".
final class SecurityDebateResearchTests: XCTestCase {

    // MARK: Google News

    private let rss = """
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel>
    <item><title>Nvidia&#39;s Q2 beat lifts the AI trade - Reuters</title>
    <link>https://news.google.com/rss/articles/CBMiabc?oc=5</link>
    <pubDate>Wed, 27 Aug 2026 13:04:00 GMT</pubDate>
    <source url="https://www.reuters.com">Reuters</source></item>
    <item><title>NVDA price target raised to $515 - Stocktwits</title>
    <link>https://news.google.com/rss/articles/CBMidef?oc=5</link>
    <pubDate>Thu, 28 Aug 2026 09:00:00 GMT</pubDate>
    <source url="https://stocktwits.com">Stocktwits</source></item>
    </channel></rss>
    """

    func testHeadlinesLoseTheAppendedPublisher() throws {
        let items = SecurityDebateResearch.parseRSS(Data(rss.utf8), ticker: "NVDA", limit: 20)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Nvidia's Q2 beat lifts the AI trade",
                       "the ' - Reuters' suffix duplicates the publisher field")
        XCTAssertEqual(items[0].publisher, "Reuters")
        XCTAssertEqual(items[1].title, "NVDA price target raised to $515")
    }

    func testEntitiesAreDecodedAndDatesParsed() throws {
        let items = SecurityDebateResearch.parseRSS(Data(rss.utf8), ticker: "NVDA", limit: 20)

        XCTAssertTrue(items[0].title.contains("Nvidia's"), "&#39; must decode to an apostrophe")
        let published = try XCTUnwrap(items[0].publishedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(calendar.component(.year, from: published), 2026)
        XCTAssertEqual(calendar.component(.day, from: published), 27)
    }

    func testIdsAreStableAndNamespacedPerFeed() {
        let items = SecurityDebateResearch.parseRSS(Data(rss.utf8), ticker: "NVDA", limit: 20)
        XCTAssertEqual(items.map(\.id), ["nvda-gnews-1", "nvda-gnews-2"])
    }

    func testLimitIsRespected() {
        XCTAssertEqual(SecurityDebateResearch.parseRSS(Data(rss.utf8), ticker: "NVDA", limit: 1).count, 1)
    }

    func testMalformedFeedYieldsNothingRatherThanThrowing() {
        XCTAssertTrue(SecurityDebateResearch.parseRSS(Data("not xml".utf8), ticker: "X", limit: 5).isEmpty)
        XCTAssertTrue(SecurityDebateResearch.parseRSS(Data(), ticker: "X", limit: 5).isEmpty)
    }

    // MARK: SEC

    func testCIKIsReadFromTheFilerLabel() {
        // Two spaces and a nested parenthesis, exactly as EDGAR writes it.
        XCTAssertEqual(SecurityDebateResearch.cik(from: "NVIDIA CORP  (NVDA)  (CIK 0001045810)"), "1045810")
        XCTAssertNil(SecurityDebateResearch.cik(from: "NVIDIA CORP  (NVDA)"))
        XCTAssertNil(SecurityDebateResearch.cik(from: "CIK notanumber"))
    }

    // MARK: Tiers

    func testPublishersAreTieredForTrust() {
        XCTAssertEqual(SecurityDebateResearch.tier(for: "Reuters"), "wire")
        XCTAssertEqual(SecurityDebateResearch.tier(for: "Bloomberg"), "wire")
        XCTAssertEqual(SecurityDebateResearch.tier(for: "The Wall Street Journal"), "wire")
        XCTAssertEqual(SecurityDebateResearch.tier(for: "GlobeNewswire"), "primary")
        XCTAssertEqual(SecurityDebateResearch.tier(for: "SEC EDGAR"), "primary")
        XCTAssertEqual(SecurityDebateResearch.tier(for: "Some Blog"), "media")
    }

    // MARK: Deduplication

    private func source(_ id: String, _ title: String, _ url: String) -> PortfolioAttentionSource {
        PortfolioAttentionSource(id: id, title: title, publisher: "p",
                                 url: URL(string: url)!, publishedAt: nil, tier: "media")
    }

    func testTheSameStoryFromTwoFeedsIsKeptOnce() {
        // Google rewrites every link, so the same article never shares a URL
        // across feeds — the headline is the only thing that matches.
        let deduped = SecurityDebateResearch.deduplicated([
            source("a", "Nvidia Q2 beat lifts the AI trade", "https://news.google.com/rss/articles/X"),
            source("b", "Nvidia Q2 beat lifts the AI trade!", "https://reuters.com/a"),
            source("c", "A different story entirely about margins", "https://reuters.com/b"),
        ])
        XCTAssertEqual(deduped.map(\.id), ["b", "c"], "Prefer the publisher URL over Google's wrapper")
    }

    func testHeadlinesThatOnlyShareAPrefixAreBothKept() {
        let deduped = SecurityDebateResearch.deduplicated([
            source("a", "Nvidia beats on revenue and raises guidance for the fourth quarter", "https://x.com/1"),
            source("b", "Nvidia beats on revenue and raises guidance for the fourth time this year", "https://x.com/2"),
            source("c", "Nvidia beats on revenue", "https://x.com/3"),
        ])
        // The first nine words decide, so the two long ones collapse and the
        // short one survives on its own.
        XCTAssertEqual(deduped.map(\.id), ["a", "c"])
    }

    func testDedupFallsBackToTheURLWhenAHeadlineIsEmpty() {
        let deduped = SecurityDebateResearch.deduplicated([
            source("a", "", "https://x.com/1"),
            source("b", "", "https://x.com/2"),
        ])
        XCTAssertEqual(deduped.count, 2, "two untitled sources are not the same source")
    }

    // MARK: Evidence gate

    private var document: SecurityResearchDocument {
        SecurityResearchDocument(source: source("s1", "Results", "https://example.com/results"),
            text: "On September 1 the company reduced its full year revenue guidance because orders were delayed.")
    }

    private func payload(quote: String, id: String = "s1") -> String {
        let item = SecurityDebateQuestion(question: "Guidance reduced", whatChanged: "The company reduced guidance.",
            whyItMatters: "Lower sales could reduce profit.", watchNext: "Watch reported orders next quarter.",
            uncertainty: "Order recovery is uncertain.", evidence: [SecurityResearchCitation(sourceID: id, quote: quote)])
        return String(decoding: try! JSONEncoder().encode(["questions": [item]]), as: UTF8.self)
    }

    func testFabricatedOrUnknownCitationsRejectWholeItem() throws {
        for json in [payload(quote: document.text, id: "invented"),
                     payload(quote: "The company raised its full year guidance to a record high."),
                     payload(quote: "guidance")] {
            let result = try XCTUnwrap(SecurityDebateResearch.parse(json, ticker: "X", name: "X", documents: [document]))
            XCTAssertTrue(result.questions.isEmpty)
            XCTAssertTrue(result.sources.isEmpty)
        }
    }

    func testOnlyCitedSourcesAreCountedAndQuotesAreRetained() throws {
        var other = document
        other.source = source("s2", "Other", "https://example.com/other")
        let result = try XCTUnwrap(SecurityDebateResearch.parse(payload(quote: document.text),
            ticker: "X", name: "X", documents: [document, other]))
        XCTAssertEqual(result.sources.map(\.id), ["s1"])
        XCTAssertEqual(result.sources(for: result.questions[0]).map(\.id), ["s1"])
        XCTAssertEqual(result.questions[0].evidence[0].quote, document.text)
    }

    func testEmptyEvidenceAndLegacyDebatesCannotBecomeDevelopments() {
        XCTAssertNil(SecurityDebateResearch.parse(#"{"questions":[{"question":"Q","bull":{"claim":"up","sourceIDs":[]},"bear":{"claim":"down","sourceIDs":[]}}]}"#,
            ticker: "X", name: "X", documents: []))
        let json = payload(quote: document.text).replacingOccurrences(of: "\"sourceID\":\"s1\"", with: "\"sourceID\":\"missing\"")
        XCTAssertTrue(SecurityDebateResearch.parse(json, ticker: "X", name: "X", documents: [])!.questions.isEmpty)
        XCTAssertTrue(SecurityDebateResearch.parse(#"{"questions":[]}"#, ticker: "X", name: "X", documents: [])!.questions.isEmpty)
    }

    func testAuditRejectsUnsupportedClaimsAndPrunesTheirSources() throws {
        let debate = try XCTUnwrap(SecurityDebateResearch.parse(payload(quote: document.text),
            ticker: "X", name: "X", documents: [document]))
        let rejected = try XCTUnwrap(SecurityDebateResearch.applyingAudit(#"{"acceptedIndices":[]}"#, to: debate))
        XCTAssertTrue(rejected.questions.isEmpty)
        XCTAssertTrue(rejected.sources.isEmpty)
        XCTAssertEqual(SecurityDebateResearch.applyingAudit(#"{"acceptedIndices":[0,0]}"#, to: debate)?.questions.count, 1)
        XCTAssertNil(SecurityDebateResearch.applyingAudit(#"{"acceptedIndices":[9]}"#, to: debate))
        XCTAssertNil(SecurityDebateResearch.applyingAudit("not json", to: debate))
    }

    func testArticleExtractionRejectsNavigationAndReadsJSONLD() throws {
        XCTAssertNil(SecurityDebateResearch.articleText("<html><nav>Headlines only</nav></html>"))
        XCTAssertNil(SecurityDebateResearch.articleText("<article>Subscribe to continue reading.</article>"))
        let body = String(repeating: document.text + " ", count: 5).trimmingCharacters(in: .whitespaces)
        let data = try JSONSerialization.data(withJSONObject: ["@graph": [["articleBody": body]]])
        let html = "<html><script type=\"application/ld+json\">" + String(decoding: data, as: UTF8.self) + "</script></html>"
        XCTAssertEqual(SecurityDebateResearch.articleText(html), body)
    }

    func testStaleFutureAndUndatedSourcesAreNotEvidenceCandidates() {
        let now = Date()
        func dated(_ id: String, _ age: Double) -> PortfolioAttentionSource {
            PortfolioAttentionSource(id: id, title: id, publisher: "Reuters", url: URL(string: "https://example.com/" + id)!,
                publishedAt: now.addingTimeInterval(-age * 86400), tier: "wire")
        }
        let selected = SecurityDebateResearch.candidates([dated("recent", 2), dated("stale", 46),
            dated("future", -2), document.source], now: now)
        XCTAssertEqual(selected.map(\.id), ["recent"])
    }

    func testYahooSearchUsesOnlyTheSymbolAndPreservesExchangeSuffixes() throws {
        for (ticker, query) in [(" nvda ", "NVDA"), ("BRK.B", "BRK-B"), ("VWRL.L", "VWRL.L")] {
            let url = SecurityDebateResearch.yahooNewsURL(ticker: ticker)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, query)
        }
    }

    func testYahooRejectsGeneralNewsAndIncidentalTickerTags() {
        let data = Data(#"{"news":[{"title":"Nvidia announces a new product","link":"https://example.com/nvda","relatedTickers":["NVDA"]},{"title":"Jewellery sector news","link":"https://example.com/unrelated","relatedTickers":["OTHER"]},{"title":"Chewy shares fall","link":"https://example.com/incidental","relatedTickers":["CHWY","NVDA"]},{"title":"Nvidia earnings","link":"https://example.com/fallback"},{"title":"Nvidia supplier results","link":"https://example.com/supplier","relatedTickers":["OTHER"]}]}"#.utf8)
        let result = SecurityDebateResearch.parseYahooNews(data, ticker: "NVDA", name: "Nvidia")
        XCTAssertEqual(result.map(\.title), ["Nvidia announces a new product", "Nvidia earnings"])
    }

    func testCompanyMatchingDoesNotTreatCommonShortTickersAsEvidence() {
        XCTAssertFalse(SecurityDebateResearch.mentionsCompany("AI is changing the economy", ticker: "AI", name: "C3.ai"))
        XCTAssertFalse(SecurityDebateResearch.mentionsCompany("NVDAX fund results", ticker: "NVDA", name: "Nvidia"))
        XCTAssertTrue(SecurityDebateResearch.mentionsCompany("NASDAQ: AI results", ticker: "AI", name: "C3.ai"))
        XCTAssertTrue(SecurityDebateResearch.mentionsCompany("NVIDIA reported results", ticker: "NVDA", name: "Nvidia"))
    }

    func testWrapperOnlyFollowsAnExplicitPublisherURL() {
        XCTAssertEqual(SecurityDebateResearch.publisherURL(in: #"<link rel="canonical" href="https://example.com/story?a=1&amp;b=2">"#)?.absoluteString,
                       "https://example.com/story?a=1&b=2")
        XCTAssertNil(SecurityDebateResearch.publisherURL(in: #"<link rel="canonical" href="https://news.google.com/articles/id"><a href="https://example.com/ad">Ad</a>"#))
        XCTAssertNil(SecurityDebateResearch.publisherURL(in: #"<meta property="og:url" content="file:///private/data">"#))
    }

    func testSECEntitiesAreReadableBeforeQuoteMatching() throws {
        let paragraph = String(repeating: "NVIDIA reported revenue&#58; &#36;10 billion &#8212; up 20&#37;. ", count: 8)
        let body = try XCTUnwrap(SecurityDebateResearch.articleText("<article>\(paragraph)</article>"))
        XCTAssertTrue(body.contains("revenue: $10 billion — up 20%."))
        XCTAssertFalse(body.contains("&#"))
    }

    func testFiscalYearCannotContradictItsOwnHeadline() throws {
        var question = try XCTUnwrap(SecurityDebateResearch.parse(payload(quote: document.text),
            ticker: "NVDA", name: "Nvidia", documents: [document])?.questions.first)
        question.question = "Q2 FY27 results"
        question.whatChanged = "2026财年第二季度业绩公布。"
        XCTAssertFalse(SecurityDebateResearch.hasConsistentFiscalYears(question))
        let json = String(decoding: try JSONEncoder().encode(["questions": [question]]), as: UTF8.self)
        XCTAssertTrue(try XCTUnwrap(SecurityDebateResearch.parse(json,
            ticker: "NVDA", name: "Nvidia", documents: [document])).questions.isEmpty)
        question.whatChanged = "2026年8月公布2027财年第二季度业绩。"
        XCTAssertTrue(SecurityDebateResearch.hasConsistentFiscalYears(question))
        question.whatChanged = "Fiscal year 2027 results, compared with fiscal 2026."
        XCTAssertTrue(SecurityDebateResearch.hasConsistentFiscalYears(question))
        question.question = "Results published in 2026"
        XCTAssertTrue(SecurityDebateResearch.hasConsistentFiscalYears(question), "A publication year isn't a fiscal-year claim")
    }
}

@MainActor
final class SecurityDebatePipelineTests: XCTestCase {
    private var document: SecurityResearchDocument {
        SecurityResearchDocument(source: PortfolioAttentionSource(id: "nvda-fixture", title: "Nvidia results",
            publisher: "Fixture", url: URL(string: "https://example.com/nvda")!, publishedAt: .now, tier: "primary"),
            text: "NVIDIA reported quarterly revenue of ten billion dollars and increased its next quarter revenue guidance.")
    }

    private func result() -> SecurityDebate {
        SecurityDebate(ticker: "NVDA", name: "Nvidia", generatedAt: .now, questions: [
            SecurityDebateQuestion(question: "Guidance increased", whatChanged: "NVIDIA increased its next quarter revenue guidance.",
                whyItMatters: "Higher sales could support earnings.", watchNext: "Watch next quarter revenue.", uncertainty: "",
                evidence: [SecurityResearchCitation(sourceID: document.source.id, quote: document.text)])
        ], sources: [document.source], language: AppLanguage.currentIdentifier)
    }

    private func answer() throws -> String {
        String(decoding: try JSONEncoder().encode(["questions": result().questions]), as: UTF8.self)
    }

    private actor ModelStub {
        var calls = 0
        let answers: [String]
        init(_ answers: [String]) { self.answers = answers }
        func answer() throws -> String {
            let index = calls
            calls += 1
            guard answers.indices.contains(index) else { throw URLError(.cannotConnectToHost) }
            return answers[index]
        }
    }

    private func dependencies(_ documents: [SecurityResearchDocument], _ model: ModelStub) -> SecurityDebateStore.Dependencies {
        .init(documents: { _, _ in documents }, answer: { _ in try await model.answer() })
    }

    func testNoReadableBodyIsFailureAndNeverCallsTheModel() async {
        let model = ModelStub([])
        let state = await SecurityDebateStore.run(ticker: "NVDA", name: "Nvidia",
            dependencies: dependencies([], model), report: { _ in })
        guard case .failed = state else { return XCTFail("Unreadable sources must not become cached success") }
        let calls = await model.calls
        XCTAssertEqual(calls, 0)
    }

    func testNoQualifyingChangesIsRetryableEmptyNotSuccessfulCache() async {
        let model = ModelStub([#"{"questions":[]}"#])
        let state = await SecurityDebateStore.run(ticker: "NVDA", name: "Nvidia",
            dependencies: dependencies([document], model), report: { _ in })
        guard case .empty = state else { return XCTFail("An evidence-backed empty search needs its own state") }
        XCTAssertNil(state.debate)
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testInvalidCitationsAreFailureNotNoDevelopments() async throws {
        let invalid = try answer().replacingOccurrences(of: "nvda-fixture", with: "invented")
        let model = ModelStub([invalid])
        let state = await SecurityDebateStore.run(ticker: "NVDA", name: "Nvidia",
            dependencies: dependencies([document], model), report: { _ in })
        guard case .failed = state else { return XCTFail("Failed provenance must be visible") }
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testReviewRejectionAndMalformedReviewCannotBecomeSuccess() async throws {
        for audit in [#"{"acceptedIndices":[]}"#, "invalid", #"{"acceptedIndices":[9]}"#] {
            let model = ModelStub([try answer(), audit])
            let state = await SecurityDebateStore.run(ticker: "NVDA", name: "Nvidia",
                dependencies: dependencies([document], model), report: { _ in })
            guard case .failed = state else { return XCTFail("Audit rejection must not overwrite results") }
        }
    }

    func testValidGenerationAndReviewReturnOnlyCitedResults() async throws {
        let model = ModelStub([try answer(), #"{"acceptedIndices":[0]}"#])
        let state = await SecurityDebateStore.run(ticker: "NVDA", name: "Nvidia",
            dependencies: dependencies([document], model), report: { _ in })
        let debate = try XCTUnwrap(state.debate)
        XCTAssertEqual(debate.questions.count, 1)
        XCTAssertEqual(debate.sources.map(\.id), [document.source.id])
        let calls = await model.calls
        XCTAssertEqual(calls, 2)
    }

    func testEmptySaveCannotOverwriteValidCachedResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SecurityDebateFile(url: directory.appendingPathComponent("results.json"))
        let valid = result()
        await file.save(valid)
        var empty = valid
        empty.questions = []
        empty.sources = []
        await file.save(empty)
        let saved = await file.load()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.questions.count, 1)
    }

    func testLegacyEmptyCacheIsRetryableWithoutDeletingTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("results.json")
        var empty = result()
        empty.questions = []
        empty.sources = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([empty])
        try data.write(to: url)
        let store = SecurityDebateStore(file: SecurityDebateFile(url: url), dependencies: dependencies([], ModelStub([])))
        await store.restore()
        guard case .empty = store.progress(for: "NVDA") else { return XCTFail("Legacy empty should offer retry") }
        XCTAssertTrue(store.recent.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), data)
        store.start(ticker: "NVDA", name: "Nvidia")
        await waitUntilFinished(store)
        guard case .failed = store.progress(for: "NVDA") else { return XCTFail("Retry must actually run") }
    }

    func testFailedRefreshRetainsPriorResultAndRepeatedTapsJoinTheRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SecurityDebateFile(url: directory.appendingPathComponent("results.json"))
        await file.save(result())
        let model = ModelStub([])
        let store = SecurityDebateStore(file: file, dependencies: dependencies([document], model))
        await store.restore()
        store.start(ticker: "NVDA", name: "Nvidia", force: true)
        store.start(ticker: "NVDA", name: "Nvidia", force: true)
        XCTAssertNotNil(store.lastResult(for: "NVDA"))
        XCTAssertEqual(store.recent.count, 1)
        await waitUntilFinished(store)
        guard case .failed = store.progress(for: "NVDA") else { return XCTFail("Provider failure must surface") }
        XCTAssertEqual(store.lastResult(for: "NVDA")?.questions.count, 1)
        XCTAssertEqual(store.recent.count, 1)
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
        let saved = await file.load()
        XCTAssertEqual(saved.first?.questions.count, 1)
    }

    private func waitUntilFinished(_ store: SecurityDebateStore) async {
        for _ in 0..<100 {
            if !store.progress(for: "NVDA").isWorking { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture pipeline did not finish")
    }

    func testLiveNVDAWithConfiguredProvider() async throws {
        guard ProcessInfo.processInfo.environment["CATFOLIO_LIVE_SECURITY_DEVELOPMENTS"] == "1" else {
            throw XCTSkip("Opt-in: fetch public NVDA documents and run the configured AI provider without saving app cache")
        }
        let started = Date()
        let dependencies = SecurityDebateStore.Dependencies(documents: { ticker, name in
            let documents = await SecurityDebateStore.Dependencies.live.documents(ticker, name)
            print("NVDA live: \(documents.count) usable documents after \(Date().timeIntervalSince(started)) seconds")
            return documents
        }, answer: { prompt in
            print("NVDA live: model request (\(prompt.count) characters)")
            let answer = try await SecurityDebateStore.Dependencies.live.answer(prompt)
            print("NVDA live: model returned \(answer.count) characters after \(Date().timeIntervalSince(started)) seconds")
            return answer
        })
        let state = await ContentLanguage.$requested.withValue("zh-Hans") {
            await SecurityDebateStore.run(ticker: "NVDA", name: "Nvidia", dependencies: dependencies, report: { _ in })
        }
        let debate = try XCTUnwrap(state.debate, "Live pipeline outcome: \(state)")
        XCTAssertFalse(debate.questions.isEmpty)
        XCTAssertFalse(debate.sources.isEmpty)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(debate), uniformTypeIdentifier: "public.json")
        attachment.name = "NVDA-public-evidence-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum ResearchMoversProbeError: Error, Sendable {
    case failed
}

private actor ResearchMoversRequestProbe {
    private(set) var calls = 0
    private var responses: [Result<String, ResearchMoversProbeError>]
    private let delay: Duration
    private let ignoresCancellation: Bool

    init(
        responses: [Result<String, ResearchMoversProbeError>],
        delay: Duration = .zero,
        ignoresCancellation: Bool = false
    ) {
        self.responses = responses
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
    }

    func request() async throws -> String {
        calls += 1
        if delay > .zero {
            do {
                try await Task.sleep(for: delay)
            } catch where !ignoresCancellation {
                throw error
            } catch {
                // Simulate a provider that returns even after cancellation.
            }
        }
        let response = responses.isEmpty ? .success("fallback") : responses.removeFirst()
        return try response.get()
    }
}

@MainActor
final class SecurityPriceMoveTests: XCTestCase {
    private func context(ticker: String = "NVDA", range: String = "1Y", start: Double = 100, end: Double = 120,
                         offset: TimeInterval = 0, intraday: Bool = false) -> SecurityPriceMoveContext {
        SecurityPriceMoveContext(ticker: ticker, name: "Nvidia", currency: "USD", rangeLabel: range,
            startDate: Date(timeIntervalSince1970: 1_788_220_800.125 + offset),
            endDate: Date(timeIntervalSince1970: 1_788_307_200.125 + offset),
            startPrice: start, endPrice: end, isIntraday: intraday)
    }

    private func document(_ scope: SecurityPriceMoveContext) -> SecurityResearchDocument {
        SecurityResearchDocument(source: PortfolioAttentionSource(id: "nvda-move-fixture", title: "Nvidia results",
            publisher: "Fixture", url: URL(string: "https://example.com/nvda-move")!,
            publishedAt: scope.endDate, tier: "primary"),
            text: "NVIDIA reported quarterly revenue of ten billion dollars and increased its next quarter revenue guidance.")
    }

    private func result(_ scope: SecurityPriceMoveContext) -> SecurityDebate {
        let article = document(scope)
        return SecurityDebate(ticker: scope.ticker, name: scope.name, generatedAt: .now,
            questions: [SecurityDebateQuestion(question: "Guidance increased",
                whatChanged: article.text, whyItMatters: "Higher sales could support earnings.",
                watchNext: "Watch the next reported quarter.", uncertainty: "This does not prove price causation.",
                evidence: [SecurityResearchCitation(sourceID: article.source.id, quote: article.text)])],
            sources: [article.source], language: AppLanguage.currentIdentifier)
    }

    private actor Probe {
        var fetches = 0
        var prompts: [String] = []
        let documents: [SecurityResearchDocument]
        let answers: [String]
        var delay: Duration
        init(_ documents: [SecurityResearchDocument], answers: [String] = [], delay: Duration = .zero) {
            self.documents = documents; self.answers = answers; self.delay = delay
        }
        func fetch() async -> [SecurityResearchDocument] {
            fetches += 1
            // Deliberately return even after cancellation: the store must reject late delivery.
            try? await Task.sleep(for: delay)
            return documents
        }
        func answer(_ prompt: String) throws -> String {
            prompts.append(prompt)
            guard answers.indices.contains(prompts.count - 1) else { throw URLError(.cannotConnectToHost) }
            return answers[prompts.count - 1]
        }
    }

    private func dependencies(_ probe: Probe) -> SecurityDebateStore.Dependencies {
        .init(documents: { _, _ in await probe.fetch() }, answer: { try await probe.answer($0) })
    }
    private func wait(_ store: SecurityPriceMoveStore, _ scope: SecurityPriceMoveContext) async {
        for _ in 0..<150 {
            if !store.progress(for: scope).isWorking { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture did not settle")
    }

    func testDirectionUsesTheQuotedIntervalAndHandlesZeroOrInvalidPrices() {
        XCTAssertEqual(context().changePercent, 20, accuracy: 0.00001)
        XCTAssertEqual(context().title, L10n.text("为什么涨了？"))
        XCTAssertEqual(context(start: 120, end: 100).title, L10n.text("为什么跌了？"))
        for value in [Double.nan, .infinity, 0, 0.0001] {
            XCTAssertEqual(SecurityPriceMoveContext.title(changePercent: value), L10n.text("为什么变动？"))
        }
        XCTAssertFalse(context(start: 0).isValid)
        XCTAssertFalse(context(end: .nan).isValid)
        XCTAssertTrue(context(range: "YTD").researchInstruction.contains("not automatically today"))
    }

    func testScopeKeysSeparateInstrumentIntervalPriceAndLanguageAndContainNoPrivateHoldingFields() throws {
        let value = context()
        for other in [context(ticker: "AAPL"), context(range: "1M"), context(end: 121), context(offset: 86400)] {
            XCTAssertNotEqual(value.key(language: "en"), other.key(language: "en"))
        }
        XCTAssertNotEqual(value.key(language: "en"), value.key(language: "zh-Hans"))
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        for field in ["account", "shares", "averageCost", "unrealized", "apiKey", "transactions"] {
            XCTAssertFalse(json.contains(field))
        }
        XCTAssertTrue(value.researchInstruction.contains("temporal coincidence does not prove"))
    }

    func testEvidenceMustHaveAPublicationDateInsideTheActualWindow() {
        let value = context()
        XCTAssertFalse(value.includes(nil))
        XCTAssertFalse(value.includes(value.startDate.addingTimeInterval(-1)))
        XCTAssertTrue(value.includes(value.startDate))
        XCTAssertTrue(value.includes(value.endDate.addingTimeInterval(3600)))
        XCTAssertFalse(value.includes(value.endDate.addingTimeInterval(86400)))
        let intraday = context(intraday: true)
        XCTAssertTrue(intraday.includes(intraday.endDate))
        XCTAssertFalse(intraday.includes(intraday.endDate.addingTimeInterval(1)))
    }

    func testMissingOrOutOfWindowEvidenceNeverCallsTheModel() async {
        let scope = context()
        let probe = Probe([document(context(offset: -86400 * 30))])
        let progress = await SecurityDebateStore.run(ticker: scope.ticker, name: scope.name,
            dependencies: dependencies(probe), movement: scope, report: { _ in })
        guard case .empty = progress else { return XCTFail("No evidence is not a causal explanation") }
        let prompts = await probe.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testTapDeduplicationFrozenPromptAndPersistentCache() async throws {
        let scope = context()
        let answer = String(decoding: try JSONEncoder().encode(["questions": result(scope).questions]), as: UTF8.self)
        let probe = Probe([document(scope)], answers: [answer, #"{"acceptedIndices":[0]}"#], delay: .milliseconds(30))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SecurityPriceMoveFile(url: directory.appendingPathComponent("moves.json"))
        let store = SecurityPriceMoveStore(file: file, dependencies: dependencies(probe))
        await store.restore()
        let initialFetches = await probe.fetches
        XCTAssertEqual(initialFetches, 0)
        store.start(scope); store.start(scope); store.start(scope, force: true)
        await wait(store, scope)
        XCTAssertNotNil(store.lastResult(for: scope))
        let prompts = await probe.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts.allSatisfy { $0.contains(scope.researchInstruction) })
        // Wait for the actor's atomic save, then restore into a fresh store.
        for _ in 0..<50 {
            if !(await file.load()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = SecurityPriceMoveStore(file: file, dependencies: dependencies(probe))
        await restored.restore()
        XCTAssertNotNil(restored.lastResult(for: scope), "Subsecond date precision must not change cache identity")
        restored.start(scope)
        let fetches = await probe.fetches
        XCTAssertEqual(fetches, 1)
        XCTAssertNil(restored.lastResult(for: context(range: "1M")))
    }

    func testFailedRefreshKeepsCachedAnalysisAndOtherIntervals() async throws {
        let scope = context()
        let other = context(range: "1M")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SecurityPriceMoveFile(url: directory.appendingPathComponent("moves.json"))
        await file.save(context: scope, debate: result(scope))
        await file.save(context: other, debate: result(other))
        let probe = Probe([document(scope)])
        let store = SecurityPriceMoveStore(file: file, dependencies: dependencies(probe))
        await store.restore()
        store.start(scope, force: true)
        await wait(store, scope)
        guard case .failed = store.progress(for: scope) else { return XCTFail("Failure must remain retryable") }
        XCTAssertNotNil(store.lastResult(for: scope))
        XCTAssertNotNil(store.lastResult(for: other))
        let saved = await file.load()
        XCTAssertEqual(saved.count, 2)
    }

    func testCancellationRejectsLateDeliveryAndStopsBeforeModel() async throws {
        let scope = context()
        let probe = Probe([document(scope)], delay: .milliseconds(60))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SecurityPriceMoveStore(file: SecurityPriceMoveFile(url: directory.appendingPathComponent("moves.json")),
            dependencies: dependencies(probe))
        store.start(scope)
        await Task.yield()
        store.cancel(scope)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(store.progress(for: scope), .idle)
        XCTAssertNil(store.lastResult(for: scope))
        let prompts = await probe.prompts
        XCTAssertTrue(prompts.isEmpty)
    }
}
