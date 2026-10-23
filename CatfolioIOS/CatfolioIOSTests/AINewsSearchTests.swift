import XCTest
@testable import CatfolioIOS

final class AINewsSearchTests: XCTestCase {
    private let query = NewsQuery(ticker: "AAPL", name: "Apple", language: "en")

    private func source(date: Date = Date(), title: String = "Apple announces results") -> PortfolioAttentionSource {
        .init(id: "article", title: title, publisher: "Reuters",
              url: URL(string: "https://example.com/apple")!, publishedAt: date, tier: "wire")
    }

    private struct Feed: NewsSourceProvider {
        var kind = NewsProvider.googleNews
        var rows: [PortfolioAttentionSource] = []
        var outcome: DataSourceOutcome = .success
        func sources(for query: NewsQuery) async -> [PortfolioAttentionSource] {
            NewsSearchTrace.current?.record(outcome, source: DataSource.named("google-news")!)
            return rows
        }
    }

    func testSearchBuildsCitedEvidenceFromNewsWithoutAnAIOrOpenRouterCall() async throws {
        let article = source()
        let search = AINewsSearch(hub: NewsSourceHub(providers: [Feed(rows: [article])]), readsArticles: true,
            readDocuments: { sources, query in
                XCTAssertEqual(query.ticker, "AAPL")
                return [.init(source: sources[0], text: "Apple reported revenue growth in its published results.")]
            })
        let result = try await search.evidence(for: [query])
        XCTAssertTrue(result.text.contains("Read article excerpt:"))
        XCTAssertTrue(result.text.contains("revenue growth"))
        XCTAssertTrue(result.sources.contains("https://example.com/apple"))
        XCTAssertTrue(result.text.contains("Published:"))
    }

    func testUnavailableArticleIsLabelledAsHeadlineOnly() async throws {
        let search = AINewsSearch(hub: NewsSourceHub(providers: [Feed(rows: [source()])]),
                                 readsArticles: true, readDocuments: { _, _ in [] })
        let result = try await search.evidence(for: [query])
        XCTAssertTrue(result.text.contains("article body was not read"))
        XCTAssertFalse(result.sources.isEmpty)
    }

    func testDisabledArticleReadingDoesNotFetchBodies() async throws {
        let search = AINewsSearch(hub: NewsSourceHub(providers: [Feed(rows: [source()])]), readsArticles: false,
            readDocuments: { _, _ in XCTFail("Article reading is disabled"); return [] })
        _ = try await search.evidence(for: [query])
    }

    func testPartialProviderFailureDoesNotDiscardUsableNews() async throws {
        let feeds: [any NewsSourceProvider] = [Feed(rows: [source()]), Feed(kind: .yahooFinance, outcome: .timedOut)]
        let search = AINewsSearch(hub: NewsSourceHub(providers: feeds), readsArticles: false)
        let result = try await search.evidence(for: [query])
        XCTAssertFalse(result.sources.isEmpty)
    }

    func testEmptyResultsDifferFromNetworkFailureAndDisabledSources() async throws {
        for (feeds, expected) in [
            ([Feed()] as [any NewsSourceProvider], "empty"),
            ([Feed(outcome: .timedOut)], "failed"),
            ([], "disabled")
        ] {
            do {
                _ = try await AINewsSearch(hub: NewsSourceHub(providers: feeds), readsArticles: false).evidence(for: [query])
                XCTFail("Expected \(expected)")
            } catch let error as AINewsSearchError {
                switch error {
                case .noResults: XCTAssertEqual(expected, "empty")
                case .sourcesFailed(let messages):
                    XCTAssertEqual(expected, "failed")
                    XCTAssertEqual(messages.count, 1)
                    XCTAssertTrue(messages[0].contains("Google News"))
                case .noProviders: XCTAssertEqual(expected, "disabled")
                default: XCTFail("Unexpected \(error)")
                }
            }
        }
    }

    func testStaleNewsIsNotPresentedAsCurrentEvidence() async throws {
        let search = AINewsSearch(hub: NewsSourceHub(providers: [Feed(rows: [source(date: Date().addingTimeInterval(-90 * 86400))])]), readsArticles: false)
        do {
            _ = try await search.evidence(for: [query])
            XCTFail("Stale news should be excluded")
        } catch AINewsSearchError.noResults { }
    }

    func testTopicQueriesKeepSeparateResultsAndSkipCompanyFeeds() async throws {
        let queries = [NewsQuery(ticker: "", name: "Federal Reserve", language: "en"),
                       NewsQuery(ticker: "", name: "oil prices", language: "en")]
        struct TopicFeed: NewsSourceProvider {
            let kind = NewsProvider.googleNews
            func sources(for query: NewsQuery) async -> [PortfolioAttentionSource] {
                [.init(id: query.key, title: query.name, publisher: "Reuters", url: URL(string: "https://example.com/" + (query.name == "oil prices" ? "oil" : "fed"))!, publishedAt: Date(), tier: "wire")]
            }
        }
        struct CompanyFeed: NewsSourceProvider {
            let kind = NewsProvider.yahooFinance
            func sources(for query: NewsQuery) async -> [PortfolioAttentionSource] {
                XCTFail("A market topic is not a ticker"); return []
            }
        }
        let hub = NewsSourceHub(providers: [TopicFeed(), CompanyFeed()])
        let found = await hub.sources(for: queries)
        XCTAssertEqual(found[queries[0].key]?.first?.title, "Federal Reserve")
        XCTAssertEqual(found[queries[1].key]?.first?.title, "oil prices")
        let url = GoogleNewsProvider.url(for: queries[1], language: "en")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "oil prices")
    }

    func testFreeformQuestionsPrepareSearchWithoutAModelOrJSON() async throws {
        for (question, topic) in [("最近英伟达有什么新闻？", "英伟达"),
                                  ("今天美股有什么新闻？", "美股"),
                                  ("What happened to Apple?", "Apple"),
                                  ("美联储降息有什么消息？", "美联储降息")] {
            let queries = try await AINewsQueryPlanner.queries(for: question, language: "zh-Hans")
            XCTAssertEqual(queries.count, 1)
            XCTAssertEqual(queries[0].name, topic)
        }
    }

    func testGenericNewsQuestionUsesMarketFeedInsteadOfRejectingTheQuestion() throws {
        let query = try XCTUnwrap(AINewsQueryPlanner.localQueries(for: "今天有什么新闻？", language: "zh-Hans").first)
        XCTAssertEqual(query.name, "股市 财经")
        XCTAssertThrowsError(try AINewsQueryPlanner.localQueries(for: "  ", language: "en"))
    }

    func testExplicitTickerUsesCompanyFeedsButOrdinaryWordsDoNot() throws {
        let query = try XCTUnwrap(AINewsQueryPlanner.localQueries(for: "AAPL 最近有什么新闻？", language: "en").first)
        XCTAssertEqual(query.ticker, "AAPL")
        XCTAssertFalse(query.name.isEmpty)
        let topic = try XCTUnwrap(AINewsQueryPlanner.localQueries(for: "AI news in the US", language: "en").first)
        XCTAssertEqual(topic.ticker, "")
    }

    func testSearchPreparationRemovesCredentialsAmountsAndAccountDetails() throws {
        let text = AINewsQueryPlanner.publicSearchText("我有100股 AAPL，账号 123456789，API Key: sk-sensitive-value，password=private-value，邮箱 me@example.com，https://example.com/?token=secret，成本$12000，最近有什么新闻？")
        XCTAssertTrue(text.contains("AAPL"))
        for secret in ["100", "123456789", "sensitive", "private-value", "example.com", "token=", "12000"] {
            XCTAssertFalse(text.contains(secret), "Must remove \(secret)")
        }
    }

    func testDefaultFreeformSearchActuallyReachesTheNewsFetcher() async throws {
        let search = AIWebSearch(fetchEvidence: { queries in
            XCTAssertEqual(queries.first?.name, "英伟达")
            return AIWebEvidence(text: "News", sources: "https://example.com", fetchedAt: Date())
        })
        let result = try await search.evidence(for: "最近英伟达有什么新闻？")
        XCTAssertFalse(result.sources.isEmpty)
    }

    func testLiveFreeformNewsSearchWithoutModelOrOpenRouter() async throws {
        guard ProcessInfo.processInfo.environment["CATFOLIO_LIVE_AI_NEWS"] == "1" else {
            throw XCTSkip("Opt-in public news requests, no AI credentials required")
        }
        let search = AIWebSearch()
        for question in ["最近英伟达有什么新闻？", "今天美股有什么新闻？"] {
            let evidence = try await ContentLanguage.$requested.withValue("zh-Hans") {
                try await search.evidence(for: question)
            }
            XCTAssertFalse(evidence.text.isEmpty)
            XCTAssertFalse(evidence.sources.isEmpty)
            print("Live news verified: \(question) — \(evidence.sources.components(separatedBy: "\n").count) sources")
        }
    }

    func testErrorsPreserveActualFailureAndDoNotMentionOpenRouter() {
        let source = DataSource.named("google-news")!
        let messages = [DataSourceOutcome.offline, .timedOut, .rateLimited, .httpStatus(403), .unusable("bad RSS")].map { outcome in
            let trace = NewsSearchFailures()
            trace.record(outcome, source: source)
            return AINewsSearchError.fallbackMessage(for: AINewsSearchError.sourcesFailed(trace.messages))
        }
        XCTAssertEqual(Set(messages).count, 5)
        XCTAssertTrue(messages.allSatisfy { !$0.contains("OpenRouter") })
        XCTAssertTrue(messages[2].contains("429"))
        XCTAssertTrue(messages[3].contains("403"))
    }

    func testRequestDiagnosticsCaptureRealWrapperOutcomesAndStayScoped() async {
        let trace = NewsSearchFailures()
        let url = URL(string: "https://news.google.com/rss/search")!
        await NewsSearchTrace.$current.withValue(trace) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { DataSourceHealth.enqueue(url, error: URLError(.timedOut)) }
                group.addTask { DataSourceHealth.reportUnusable(DataSource.of(url), issue: .invalidFormat) }
            }
        }
        DataSourceHealth.enqueue(url, error: URLError(.notConnectedToInternet))
        XCTAssertEqual(trace.messages.count, 2)
        XCTAssertNil(NewsSearchTrace.current)
    }

    func testKnownSecurityBypassesQueryPlannerAndReusesCache() async throws {
        actor Counter {
            var value = 0
            func increment() { value += 1 }
        }
        let counter = Counter()
        let search = AIWebSearch(planQueries: { _, _ in XCTFail("Known security needs no model planning"); return [] },
            fetchEvidence: { queries in
                await counter.increment()
                XCTAssertEqual(queries.first?.ticker, "AAPL")
                return AIWebEvidence(text: "News", sources: "https://example.com", fetchedAt: Date())
            })
        _ = try await search.evidence(for: "Apple news", queries: [query])
        _ = try await search.evidence(for: "Apple news", queries: [query])
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testBlockedSitesRemainExcludedFromChatEvidence() async throws {
        let saved = UserDefaults.standard.object(forKey: NewsSettings.blockedSitesKey)
        defer { UserDefaults.standard.set(saved, forKey: NewsSettings.blockedSitesKey) }
        UserDefaults.standard.set("example.com", forKey: NewsSettings.blockedSitesKey)
        let search = AINewsSearch(hub: NewsSourceHub(providers: [Feed(rows: [source()])]), readsArticles: false)
        do { _ = try await search.evidence(for: [query]); XCTFail("Blocked article must not reach chat") }
        catch AINewsSearchError.noResults { }
    }

    func testFreeformQuestionUsesNewsPlanAndSearchFailureCanBeRetried() async throws {
        actor Attempts {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let attempts = Attempts()
        let search = AIWebSearch(planQueries: { question, language in
            XCTAssertEqual(question, "What happened to Apple?")
            return [NewsQuery(ticker: "AAPL", name: "Apple", language: language)]
        }, fetchEvidence: { queries in
            XCTAssertEqual(queries.first?.ticker, "AAPL")
            if await attempts.next() == 1 { throw URLError(.timedOut) }
            return AIWebEvidence(text: "News", sources: "https://example.com", fetchedAt: Date())
        })
        do { _ = try await search.evidence(for: "What happened to Apple?"); XCTFail("First fetch should fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let result = try await search.evidence(for: "What happened to Apple?")
        XCTAssertFalse(result.sources.isEmpty)
    }

    func testChangingNewsSettingsInvalidatesEvidenceCache() async throws {
        let saved = UserDefaults.standard.object(forKey: NewsSettings.readsArticlesKey)
        defer { UserDefaults.standard.set(saved, forKey: NewsSettings.readsArticlesKey) }
        actor Attempts {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let attempts = Attempts()
        let search = AIWebSearch(fetchEvidence: { _ in
            let count = await attempts.next()
            return AIWebEvidence(text: "Fetch \(count)", sources: "https://example.com", fetchedAt: Date())
        })
        UserDefaults.standard.set(false, forKey: NewsSettings.readsArticlesKey)
        let first = try await search.evidence(for: "Apple", queries: [query])
        UserDefaults.standard.set(true, forKey: NewsSettings.readsArticlesKey)
        let second = try await search.evidence(for: "Apple", queries: [query])
        XCTAssertNotEqual(first.text, second.text)
    }

    func testCancellationDoesNotBecomeAnEmptyResultOrSearchWarning() async {
        let search = AINewsSearch(hub: NewsSourceHub(providers: [Feed()]), readsArticles: false)
        let query = query
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await search.evidence(for: [query])
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
