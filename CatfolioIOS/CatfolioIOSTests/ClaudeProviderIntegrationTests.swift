import Foundation
import XCTest
@testable import CatfolioIOS

@MainActor
final class ClaudeProviderIntegrationTests: XCTestCase {
    func testClaudeSetupResumesWithItsOwnDraft() throws {
        let suite = "claude-setup-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = ServiceAPISetupState(defaults: defaults)
        setup.started = true
        setup.path = [.key(.claude)]
        setup.settingsProvider = .claude

        let store = DraftStore()
        let drafts = ServiceAPIKeyDrafts(read: { store.values[$0] }, write: { store.values[$0] = $1 })
        try drafts.update("unfinished-claude-key", for: .claude, savedKey: "")

        let resumed = ServiceAPISetupState(defaults: defaults)
        XCTAssertTrue(resumed.started)
        XCTAssertEqual(resumed.path, [.key(.claude)])
        XCTAssertEqual(resumed.settingsProvider, .claude)
        XCTAssertEqual(drafts.text(for: .claude, savedKey: ""), "unfinished-claude-key")
        XCTAssertEqual(drafts.text(for: .openRouter, savedKey: ""), "")
        XCTAssertEqual(drafts.text(for: .claude, savedKey: "rotated-key"), "rotated-key")
        XCTAssertNil(defaults.string(forKey: LocalServiceKeys.claude))
    }

    func testClaudeCredentialCaptureKeepsModelWithKeyAndRejectsOtherConfiguration() throws {
        let suite = "claude-credential-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("custom-claude-model", forKey: LocalServiceKeys.claudeModel)
        defaults.set("other-provider-model", forKey: LocalServiceKeys.openRouterModel)
        let captured = CloudCredentialPolicy.capture(
            secrets: [LocalServiceKeys.claude: "test-claude-key"], defaults: defaults)
        let connection = try XCTUnwrap(captured["service.claude"])
        XCTAssertEqual(connection.secrets, [LocalServiceKeys.claude: "test-claude-key"])
        XCTAssertEqual(connection.configuration, [LocalServiceKeys.claudeModel: "custom-claude-model"])
        XCTAssertTrue(CloudCredentialPolicy.accepts(.init(connection: connection), id: "service.claude"))

        var unrelated = connection
        unrelated.configuration[LocalServiceKeys.openRouterModel] = "unexpected-model"
        XCTAssertFalse(CloudCredentialPolicy.accepts(.init(connection: unrelated), id: "service.claude"))
        XCTAssertTrue(CloudCredentialPolicy.accepts(.init(connection: nil), id: "service.claude"))
        XCTAssertNil(CloudCredentialPolicy.capture(secrets: [:], defaults: defaults)["service.claude"])
    }

    func testAnthropicRequestsAppearAsClaudeInDataSourceHealth() throws {
        let source = try XCTUnwrap(DataSource.of(URL(string: "https://api.anthropic.com/v1/messages")))
        XCTAssertEqual(source.id, "claude")
        XCTAssertEqual(source.title, "Claude")
        XCTAssertEqual(source.kind, .ai)
        XCTAssertEqual(source, DataSource.named("claude"))
    }

    func testClaudeModelCatalogUsesDisplayNamesAndDeduplicatesIDs() throws {
        let data = Data("""
        {"data":[
            {"id":"claude-b","display_name":"Claude B"},
            {"id":"claude-a","display_name":"Claude A"},
            {"id":"claude-b","display_name":"Duplicate B"}
        ]}
        """.utf8)
        let models = try AIModelCatalog.decode(data)
        XCTAssertEqual(models.map(\.id), ["claude-a", "claude-b"])
        XCTAssertEqual(models.map(\.name), ["Claude A", "Claude B"])
        XCTAssertTrue(AIModelCatalog.supports(.claude))
    }

    func testExplicitClaudePreferenceRemainsTheResearchProvider() {
        XCTAssertEqual(LocalAIClient.researchProvider(preference: .claude), .claude)
        XCTAssertEqual(LocalAIClient.researchProvider(preference: .claude, allowsCodex: true), .claude)
    }

    private final class DraftStore {
        var values: [String: String] = [:]
    }
}
