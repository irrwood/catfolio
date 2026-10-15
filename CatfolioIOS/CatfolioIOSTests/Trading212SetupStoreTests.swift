import XCTest
@testable import CatfolioIOS

@MainActor
final class Trading212SetupStoreTests: XCTestCase {
    func testBothCredentialsAndStepSurviveRecreatingTheSetupStore() throws {
        let fixture = try StoreFixture()
        defer { fixture.clean() }
        let first = fixture.store()
        let draft = Trading212SetupDraft(step: .credentials, environment: .demo,
            apiKey: "test-key", apiSecret: "test-secret", accountSlot: 3,
            nickname: "New account", nicknameEdited: true)
        first.setCreationPresented(true)
        try first.save(draft, for: .create)
        let reopened = fixture.store()
        XCTAssertTrue(reopened.shouldResumeCreation)
        XCTAssertEqual(reopened.load(for: .create), draft)
        XCTAssertEqual(reopened.load(for: .create)?.restoredStep, .credentials)
        XCTAssertNil(fixture.values["trading212.account-3.api-key"])
        XCTAssertNil(fixture.values["trading212.account-3.api-secret"])
        XCTAssertEqual(fixture.defaults.persistentDomain(forName: fixture.suite)?.count, 1)
    }

    func testClosingKeepsTheDraftButCompletingClearsIt() throws {
        let fixture = try StoreFixture()
        defer { fixture.clean() }
        let store = fixture.store()
        let draft = Trading212SetupDraft(step: .permissions, environment: .live,
            apiKey: "partial", apiSecret: "", accountSlot: 1, nickname: "Draft", nicknameEdited: false)
        try store.save(draft, for: .create)
        store.setCreationPresented(true)
        store.setCreationPresented(false)
        XCTAssertFalse(fixture.store().shouldResumeCreation)
        XCTAssertEqual(fixture.store().load(for: .create), draft)
        try store.clear(for: .create)
        XCTAssertNil(fixture.store().load(for: .create))
        XCTAssertFalse(fixture.store().shouldResumeCreation)
    }

    func testRecreatingPreviewNeverRestoresAnUnconfirmedImport() {
        for step in Trading212GuideStep.allCases {
            let draft = Trading212SetupDraft(step: step, environment: .live, apiKey: "", apiSecret: "",
                accountSlot: 1, nickname: "", nicknameEdited: false)
            XCTAssertEqual(draft.restoredStep, step.isTutorial ? .prepare : .credentials)
        }
    }

    func testCompletedCreationDoesNotReopenIfRemovingTheDraftFails() throws {
        let fixture = try StoreFixture()
        defer { fixture.clean() }
        let store = Trading212SetupStore(defaults: fixture.defaults, read: { _ in nil },
            write: { _, _ in throw NSError(domain: "test-keychain-unavailable", code: 1) })
        store.setCreationPresented(true)
        XCTAssertThrowsError(try store.clear(for: .create))
        XCTAssertFalse(fixture.store().shouldResumeCreation)
    }

    @MainActor private final class StoreFixture {
        let suite = "trading212-setup-\(UUID())"
        let defaults: UserDefaults
        var values: [String: String] = [:]
        init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) }
        func store() -> Trading212SetupStore {
            Trading212SetupStore(defaults: defaults, read: { self.values[$0] }, write: { key, value in
                self.values[key] = value.isEmpty ? nil : value
            })
        }
        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
}
