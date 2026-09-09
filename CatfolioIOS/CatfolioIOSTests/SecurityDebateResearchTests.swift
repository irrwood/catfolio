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
        XCTAssertEqual(deduped.map(\.id), ["a", "c"])
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

    // MARK: Model

    func testASideResolvesItsCitationsBackToSources() {
        let debate = SecurityDebate(
            ticker: "NVDA", name: "NVIDIA", generatedAt: .distantPast,
            questions: [SecurityDebateQuestion(
                question: "Durability of the AI spending cycle",
                bull: SecurityDebateSide(claim: "up", sourceIDs: ["s1", "s2"]),
                bear: SecurityDebateSide(claim: "down", sourceIDs: ["s2", "missing"])
            )],
            sources: [source("s1", "one", "https://x.com/1"), source("s2", "two", "https://x.com/2")]
        )
        let question = debate.questions[0]
        XCTAssertEqual(debate.sources(for: question.bull).map(\.id), ["s1", "s2"])
        XCTAssertEqual(debate.sources(for: question.bear).map(\.id), ["s2"],
                       "a citation the model invented must not become a phantom row")
    }
}
