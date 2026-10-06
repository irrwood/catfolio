import Foundation
import XCTest
@testable import CatfolioIOS

final class AIWebSearchTests: XCTestCase {
    func testResearchDoesNotDependOnCodexEvenWhenPreviouslySelected() {
        XCTAssertFalse(LocalAIClient().allowsCodex)
        XCTAssertEqual(LocalAIClient.researchProvider(preference: .codex), .automatic)
        XCTAssertEqual(LocalAIClient.researchProvider(preference: .deepSeek), .deepSeek)
        XCTAssertEqual(LocalAIClient.researchProvider(preference: .openRouter), .openRouter)
    }

    func testCitationsUseServerAnnotationsDeduplicateAndRejectUnsafeLinks() throws {
        let annotations: [[String: Any]] = [
            ["type": "url_citation", "title": "Report [2026]", "url": "https://example.com/report"],
            ["type": "url_citation", "title": "Duplicate", "url": "https://example.com/report"],
            ["type": "url_citation", "title": "Unsafe", "url": "javascript:alert(1)"],
            ["type": "url_citation", "title": "Credential URL", "url": "https://user:password@example.com/private"],
            ["type": "text", "url": "https://invented.example.com"]
        ]
        let event: [String: Any] = ["type": "response.completed", "response": ["output": [["content": [["annotations": annotations]]]]]]
        let json = try JSONSerialization.data(withJSONObject: event)
        let stream = Data(("data: " + String(decoding: json, as: UTF8.self) + "\n\ndata: [DONE]\n").utf8)
        let links = AIWebSearch.sourceLinks(in: stream)
        XCTAssertEqual(links, "- [Report \\[2026\\]](<https://example.com/report>)")
    }

    func testNewsRequestRequiresSearchRatherThanAnOptionalModelChoice() {
        let body = CodexOAuthClient.completionRequestBody(prompt: "今天有什么动静？", webSearch: true)
        XCTAssertEqual(body["tool_choice"] as? String, "required")
        XCTAssertEqual((body["tools"] as? [[String: String]])?.first?["type"], "web_search")
    }

    func testTextAndMalformedEventsCannotBecomeCitations() {
        let stream = Data("data: {bad json}\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"https://example.com\"}\n".utf8)
        XCTAssertEqual(AIWebSearch.sourceLinks(in: stream), "")
    }
}
