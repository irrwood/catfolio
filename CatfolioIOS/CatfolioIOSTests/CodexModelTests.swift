import XCTest
@testable import CatfolioIOS

final class CodexModelTests: XCTestCase {
    func testModelListSkipsHiddenAndFollowsPriority() {
        let json = """
        {"models":[
          {"slug":"gpt-old","display_name":"Old","visibility":"hide","priority":0},
          {"slug":"gpt-b","display_name":"B","visibility":"list","priority":2},
          {"slug":"gpt-a","display_name":"A","visibility":"list","priority":1}
        ]}
        """
        XCTAssertEqual(CodexOAuthClient.decodeModels(Data(json.utf8)).map(\.id), ["gpt-a", "gpt-b"])
    }

    func testDataShapedListAlsoReads() {
        let json = #"{"data":[{"id":"gpt-x"},{"id":"gpt-y","name":"Y"}]}"#
        XCTAssertEqual(CodexOAuthClient.decodeModels(Data(json.utf8)).map(\.name), ["gpt-x", "Y"])
    }

    func testRetiredModelIsRecognised() {
        let rejected = #"{"detail":"The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account."}"#
        XCTAssertTrue(CodexOAuthClient.isModelUnavailable(status: 400, data: Data(rejected.utf8)))
        let other = #"{"detail":"Rate limit reached"}"#
        XCTAssertFalse(CodexOAuthClient.isModelUnavailable(status: 400, data: Data(other.utf8)))
        XCTAssertFalse(CodexOAuthClient.isModelUnavailable(status: 500, data: Data(rejected.utf8)))
    }
}
