import XCTest
@testable import CatfolioIOS

final class ClaudeAPITests: XCTestCase {
    func testMessagesUseNativeAuthenticationAndSeparateSystemInstructions() throws {
        let request = try ClaudeAPI.messagesRequest(
            apiKey: " \nsecret-key\t", model: " claude-test-model \n",
            system: "Return one JSON object.", user: "schema: {answer: string}", stream: false
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), ClaudeAPI.apiVersion)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-test-model")
        XCTAssertEqual(body["system"] as? String, "Return one JSON object.")
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["temperature"], "Claude models decide which sampling controls they accept")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "schema: {answer: string}"]])
    }

    func testStreamingMessagesUseEventStreamAndDefaultModelForBlankPreference() throws {
        let request = try ClaudeAPI.messagesRequest(apiKey: "key", model: " \n", system: "System", user: "Hello", stream: true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, LocalServiceKeys.defaultClaudeModel)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testModelsRequestUsesTheSameCredentialsAndVersion() throws {
        let request = try ClaudeAPI.modelsRequest(apiKey: " key \n")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), ClaudeAPI.apiVersion)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.httpBody)
    }

    func testRequestsRejectEmptyCredentialsBeforeContactingTheProvider() {
        for key in ["", " \n\t"] {
            XCTAssertThrowsError(try ClaudeAPI.messagesRequest(apiKey: key, model: "model", system: "", user: "Hi", stream: false)) { error in
                guard case LocalServiceError.missingClaudeKey = error else { return XCTFail("Expected missingClaudeKey") }
            }
            XCTAssertThrowsError(try ClaudeAPI.modelsRequest(apiKey: key)) { error in
                guard case LocalServiceError.missingClaudeKey = error else { return XCTFail("Expected missingClaudeKey") }
            }
        }
    }

    func testMessageCombinesOnlyTextBlocksInTheirOriginalOrder() throws {
        let data = Data(#"{"type":"message","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Hello "},{"type":"tool_use","name":"example","input":{}},{"type":"text","text":"world!"}],"stop_reason":"end_turn"}"#.utf8)
        XCTAssertEqual(try ClaudeAPI.decodeMessage(data), "Hello world!")
    }

    func testMessageRejectsEmptyAndMalformedAnswers() {
        for raw in [
            "not JSON", "[]", "{}",
            #"{"type":"message","content":"Hello"}"#,
            #"{"type":"message","content":[]}"#,
            #"{"type":"message","content":[{"type":"thinking","thinking":"thinking"}]}"#,
            #"{"type":"message","content":[{"type":"text","text":" \n"}]}"#,
            #"{"type":"message","content":[{"type":"text"}]}"#,
            #"{"type":"message","content":[{"type":"text","text":12}]}"#,
        ] {
            XCTAssertThrowsError(try ClaudeAPI.decodeMessage(Data(raw.utf8)), "Should reject: \(raw)") { error in
                guard case LocalServiceError.invalidResponse = error else { return XCTFail("Expected invalidResponse") }
            }
        }
    }

    func testMessageReportsProviderErrorAndRejectsTruncatedOutput() {
        let errorData = Data(#"{"type":"error","error":{"type":"authentication_error","message":"Invalid API key"}}"#.utf8)
        XCTAssertThrowsError(try ClaudeAPI.decodeMessage(errorData)) { error in
            XCTAssertEqual(error.localizedDescription, LocalServiceError.remote("Invalid API key").localizedDescription)
        }
        let truncated = Data(#"{"type":"message","content":[{"type":"text","text":"{\"answer\":"}],"stop_reason":"max_tokens"}"#.utf8)
        XCTAssertThrowsError(try ClaudeAPI.decodeMessage(truncated)) { error in
            guard case LocalServiceError.remote = error else { return XCTFail("Expected truncation to be reported") }
        }
    }

    func testHTTPErrorUsesProviderMessageOrStatusFallback() {
        XCTAssertEqual(ClaudeAPI.errorMessage(Data(#"{"error":{"message":"Rate limit exceeded"}}"#.utf8), status: 429), "Rate limit exceeded")
        XCTAssertTrue(ClaudeAPI.errorMessage(Data("<html>Unavailable</html>".utf8), status: 503).contains("503"))
        XCTAssertTrue(ClaudeAPI.errorMessage(Data(#"{"error":{"message":" \n"}}"#.utf8), status: 401).contains("401"))
    }
}
