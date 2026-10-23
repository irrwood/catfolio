import XCTest
@testable import CatfolioIOS

final class AIStreamingTests: XCTestCase {
    @MainActor func testStoppingKeepsReceivedTextAndRejectsLateDeltas() async {
        let live = StreamingAnswer()
        live.receive(.reasoning("Checking weights."))
        live.receive(.text("Partial answer"))
        let saved = live.stoppedMessage()
        live.receive(.text(" late text"))
        live.receive(.reasoning(" late reasoning"))
        await live.finish()
        XCTAssertEqual(saved?.text, "Partial answer")
        XCTAssertEqual(saved?.reasoning, "Checking weights.")
        XCTAssertEqual(live.visibleText, "Partial answer")
        XCTAssertFalse(live.isRevealing)
        XCTAssertTrue(live.isCancelled)
    }

    @MainActor func testStoppingBeforeAnyContentDoesNotInventAnAnswer() {
        XCTAssertNil(StreamingAnswer().stoppedMessage())
    }

    func testCodexRequestPreservesStructuredInstructionsAndUserSchema() throws {
        let instructions = "Output a single JSON object without Markdown."
        let body = CodexOAuthClient.completionRequestBody(prompt: "schema: {answer: string}", instructions: instructions)
        XCTAssertEqual(body["instructions"] as? String, instructions)
        let encoded = try JSONSerialization.data(withJSONObject: body)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("schema: {answer: string}"))
        XCTAssertFalse((CodexOAuthClient.completionRequestBody(prompt: "hi")["instructions"] as? String ?? "").isEmpty)
    }

    func testStructuredCodexAnswerRejectsProseMarkdownAndJSONScalars() throws {
        let valid = #"{"answer":"yes","items":[]}"#
        XCTAssertEqual(try LocalAIClient.validatedStructuredAnswer(valid), valid)
        for invalid in ["Here is my analysis.", "```json\n{}\n```", "null", "42", "[]", "{broken}"] {
            XCTAssertThrowsError(try LocalAIClient.validatedStructuredAnswer(invalid))
        }
    }

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

    func testOpenRouterSendsItsThinkingAsReasoningAndItsErrorsInTheStream() {
        XCTAssertEqual(AIStreamParsing.chatCompletionEvents(
            #"data: {"choices":[{"delta":{"reasoning":"weighing","content":""}}]}"#), [.reasoning("weighing")])
        XCTAssertEqual(AIStreamParsing.chatCompletionEvents(": OPENROUTER PROCESSING"), [])
        XCTAssertEqual(AIStreamParsing.chatCompletionError(
            #"data: {"error":{"code":502,"message":"Provider returned error"}}"#), "Provider returned error")
        XCTAssertNil(AIStreamParsing.chatCompletionError(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#))
    }

    func testClaudeStreamsThinkingAndAnswerAsNativeContentBlockDeltas() throws {
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"content":[]}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Checking weights."}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signature"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Your top "}}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"holding."}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":""}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":""}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"future_delta","text":"not an answer"}}"#,
            #"data: {"type":"future_event"}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        XCTAssertEqual(try lines.flatMap { try AIStreamParsing.claudeEvents($0) }, [
            .reasoning("Checking weights."), .text("Your top "), .text("holding."),
        ])
    }

    func testClaudeFinishesOnlyAtItsNativeMessageStop() {
        XCTAssertTrue(AIStreamParsing.isClaudeDone(#"data: {"type":"message_stop"}"#))
        for line in ["event: message_stop", "data: [DONE]", #"data: {"type":"content_block_stop"}"#,
                     #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#] {
            XCTAssertFalse(AIStreamParsing.isClaudeDone(line))
        }
    }

    func testClaudeReportsInlineErrorsAndTruncation() {
        XCTAssertThrowsError(try AIStreamParsing.claudeEvents(
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        )) { error in
            XCTAssertEqual(error.localizedDescription, LocalServiceError.remote("Overloaded").localizedDescription)
        }
        XCTAssertThrowsError(try AIStreamParsing.claudeEvents(#"data: {"type":"error","error":{}}"#))
        XCTAssertThrowsError(try AIStreamParsing.claudeEvents(
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#
        )) { error in
            guard case LocalServiceError.remote = error else { return XCTFail("Expected truncation to be reported") }
        }
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
