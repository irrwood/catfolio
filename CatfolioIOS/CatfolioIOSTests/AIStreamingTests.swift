import XCTest
@testable import CatfolioIOS

final class AIStreamingTests: XCTestCase {
    func testCodexStreamSplitsThinkingFromTheAnswer() throws {
        var index: Int?
        let lines = [
            #"data: {"type":"response.reasoning_summary_text.delta","summary_index":0,"delta":"Look at "}"#,
            #"data: {"type":"response.reasoning_summary_text.delta","summary_index":0,"delta":"weights."}"#,
            #"data: {"type":"response.reasoning_summary_text.delta","summary_index":1,"delta":"Then risk."}"#,
            #"data: {"type":"response.output_text.delta","delta":"Your top"}"#,
            "event: response.completed",
            #"data: {"type":"response.completed","response":{}}"#,
        ]
        let events = try lines.flatMap { try AIStreamParsing.codexEvents($0, summaryIndex: &index) }
        XCTAssertEqual(events, [
            .reasoning("Look at "), .reasoning("weights."),
            .reasoning("\n\n"), .reasoning("Then risk."),
            .text("Your top"),
        ], "a new summary part starts a new paragraph of the thinking")
    }

    func testACodexFailureInTheStreamIsReported() {
        var index: Int?
        let line = #"data: {"type":"response.failed","response":{"error":{"message":"quota"}}}"#
        XCTAssertThrowsError(try AIStreamParsing.codexEvents(line, summaryIndex: &index)) { error in
            XCTAssertEqual(error.localizedDescription, LocalServiceError.remote("quota").localizedDescription)
        }
    }

    func testChatCompletionsCarryReasoningBeforeContent() {
        XCTAssertEqual(AIStreamParsing.chatCompletionEvents(
            #"data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}"#), [.reasoning("thinking")])
        XCTAssertEqual(AIStreamParsing.chatCompletionEvents(
            #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#), [.text("Hi")])
        XCTAssertEqual(AIStreamParsing.chatCompletionEvents(": keep-alive"), [])
        XCTAssertTrue(AIStreamParsing.isDone("data: [DONE]"))
    }

    func testTheTypewriterSpeedsUpWhenItFallsBehind() {
        XCTAssertEqual(SmoothReveal.step(backlog: 0), 0)
        XCTAssertEqual(SmoothReveal.step(backlog: 1), 1, "never past what has arrived")
        XCTAssertEqual(SmoothReveal.step(backlog: 10), 2, "a steady couple of characters a frame")
        XCTAssertEqual(SmoothReveal.step(backlog: 800), 100, "a burst is caught up within a few frames")
    }

    func testUnfinishedMarkdownIsClosedForDisplay() {
        XCTAssertEqual(StreamingMarkdown.displayable("Concentration is **high"), "Concentration is **high**")
        XCTAssertEqual(StreamingMarkdown.displayable("Concentration is *"), "Concentration is ")
        XCTAssertEqual(StreamingMarkdown.displayable("Run `swift"), "Run `swift`")
        XCTAssertEqual(StreamingMarkdown.displayable("```\nlet a = 1"), "```\nlet a = 1\n```")
        XCTAssertEqual(StreamingMarkdown.displayable("**Done** here."), "**Done** here.", "finished markdown is left alone")
    }
}
