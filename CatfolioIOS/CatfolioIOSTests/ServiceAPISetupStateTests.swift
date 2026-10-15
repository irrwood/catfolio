import XCTest
@testable import CatfolioIOS

@MainActor
final class ServiceAPISetupStateTests: XCTestCase {
    func testRelaunchCollapsesTheLegacyGuideRouteUntilExplicitlyFinished() throws {
        let suite = "api-progress-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ServiceAPISetupState(defaults: defaults)
        first.started = true
        first.isPresented = true
        first.path = [.guide(.openRouter), .key(.openRouter)]
        let resumed = ServiceAPISetupState(defaults: defaults)
        XCTAssertTrue(resumed.isPresented)
        XCTAssertTrue(resumed.started)
        XCTAssertEqual(resumed.path, [.key(.openRouter)])
        first.path = [.guide(.massive)]
        XCTAssertEqual(ServiceAPISetupState(defaults: defaults).path, [.key(.massive)])
        resumed.finish()
        let finished = ServiceAPISetupState(defaults: defaults)
        XCTAssertFalse(finished.isPresented)
        XCTAssertFalse(finished.started)
        XCTAssertTrue(finished.path.isEmpty)
    }

    func testSettingsProviderRestoresUntilThePageIsLeft() throws {
        let suite = "api-settings-progress-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ServiceAPISetupState(defaults: defaults)
        first.settingsProvider = .finnhub
        XCTAssertEqual(ServiceAPISetupState(defaults: defaults).settingsProvider, .finnhub)
        first.settingsProvider = nil
        XCTAssertNil(ServiceAPISetupState(defaults: defaults).settingsProvider)
    }

    func testAccountSetupRoutesResumeUntilReturningOrFinishing() throws {
        let suite = "onboarding-account-progress-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let routes = [ServiceAPISetupState.Step.trading212, .ibkr]
            + AddAccountProvider.allCases.map(ServiceAPISetupState.Step.account)
        for route in routes {
            let first = ServiceAPISetupState(defaults: defaults)
            first.started = true
            first.isPresented = true
            first.path = [route]
            let resumed = ServiceAPISetupState(defaults: defaults)
            XCTAssertTrue(resumed.isPresented)
            XCTAssertTrue(resumed.started)
            XCTAssertEqual(resumed.path, [route])
            XCTAssertEqual(resumed.path.first?.accountProvider, route.accountProvider)
            resumed.path = []
            XCTAssertTrue(ServiceAPISetupState(defaults: defaults).path.isEmpty)
            resumed.finish()
            XCTAssertFalse(ServiceAPISetupState(defaults: defaults).isPresented)
        }
    }

    func testDraftSurvivesRecreationWithoutChangingTheActiveCredential() throws {
        let keychain = MemoryKeychain()
        keychain.values[LocalServiceProvider.massive.keychainKey] = "existing-key"
        let first = keychain.drafts()
        try first.update("unfinished-token", for: .massive, savedKey: "existing-key")
        let reopened = keychain.drafts()
        XCTAssertEqual(reopened.text(for: .massive, savedKey: "existing-key"), "unfinished-token")
        XCTAssertEqual(keychain.values[LocalServiceProvider.massive.keychainKey], "existing-key")
        XCTAssertEqual(reopened.text(for: .fmp, savedKey: "another-key"), "another-key")
        XCTAssertEqual(reopened.text(for: .massive, savedKey: "replacement-key"), "replacement-key")
        XCTAssertEqual(reopened.text(for: .massive, savedKey: ""), "")
    }

    func testEmptyDraftIsPreservedAndClearingDoesNotReviveIt() throws {
        let keychain = MemoryKeychain()
        let drafts = keychain.drafts()
        try drafts.update("", for: .deepSeek, savedKey: "saved")
        XCTAssertEqual(keychain.drafts().text(for: .deepSeek, savedKey: "saved"), "")
        try drafts.clear(.deepSeek)
        XCTAssertEqual(keychain.drafts().text(for: .deepSeek, savedKey: "saved"), "saved")
        try drafts.update("new", for: .deepSeek, savedKey: "saved")
        try drafts.update("saved", for: .deepSeek, savedKey: "saved")
        XCTAssertTrue(keychain.values.isEmpty)
    }

    @MainActor private final class MemoryKeychain {
        var values: [String: String] = [:]
        func drafts() -> ServiceAPIKeyDrafts {
            ServiceAPIKeyDrafts(read: { self.values[$0] }, write: { key, value in
                if value.isEmpty { self.values.removeValue(forKey: key) }
                else { self.values[key] = value }
            })
        }
    }
}
