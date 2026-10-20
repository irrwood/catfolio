import Foundation
import XCTest
@testable import CatfolioIOS

/// Explicit opt-in: uses the device's configured AI service and public Apple data.
final class TodayBriefLiveTests: XCTestCase {
    func testConfiguredProviderProducesSourcedOverviewAndArticle() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CATFOLIO_TODAY_LIVE_TESTS"] == "1")
        try XCTSkipUnless(LocalServiceKeys.hasOpenRouterKey, "No OpenRouter search key is configured on this test device")
        let context = TodayBriefContext(sessionDate: DayDateCodec.string(from: Date()), total: 0,
            benchmarkChange: nil, stocks: [.init(ticker: "AAPL", name: "Apple", logoSymbol: "AAPL", changePercent: 0, amount: 0)],
            sectors: [], language: "zh-Hans")
        let brief = try await TodayBriefResearch.fetch(.init(context: context, target: nil, previous: "")) { _ in }
        XCTAssertFalse(TodayBriefEditorial.clean(brief.text).isEmpty)
        XCTAssertFalse(TodayBriefEditorial.sources(brief.sources).isEmpty)
        let article = try await TodayBriefResearch.fetch(.init(context: context, target: "stock:AAPL", previous: brief.text)) { _ in }
        XCTAssertFalse(TodayBriefEditorial.clean(article.text).isEmpty)
        XCTAssertFalse(TodayBriefEditorial.sources(article.sources).isEmpty)
        let attachment = XCTAttachment(string: "Overview:\n\(TodayBriefEditorial.clean(brief.text))\n\nArticle:\n\(TodayBriefEditorial.clean(article.text))\n\nSources:\n"
            + article.sources.map { "\($0.title) · \($0.url.absoluteString)" }.joined(separator: "\n"))
        attachment.name = "today-brief-live-public-research"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
