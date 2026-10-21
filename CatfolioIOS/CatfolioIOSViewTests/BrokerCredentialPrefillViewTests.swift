import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class BrokerCredentialPrefillViewTests: XCTestCase {
    func testTrading212NewConnectionUsesSyncedSlotWithoutCreatingAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.model.refreshPortfolio(refreshMarketData: false)
        fixture.show(Trading212View(setupStore: fixture.store(), isFirstLaunchSetup: true,
            credentialValues: { ["trading212.account-1.api-key": "synced-key", "trading212.account-1.api-secret": "synced-secret"] }))
        try await settle()
        XCTAssertEqual(field(id: "trading212.api-key", in: fixture.window)?.text, "synced-key")
        XCTAssertEqual(field(id: "trading212.api-secret", in: fixture.window)?.text, "synced-secret")
        XCTAssertTrue(fixture.model.accounts.isEmpty, "Prefill must wait for the user's account import")
    }

    func testTrading212DraftWinsOverSyncedCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store()
        try store.save(.init(step: .credentials, environment: .live, apiKey: "draft-key", apiSecret: "draft-secret",
                            accountSlot: 1, nickname: "Draft", nicknameEdited: true), for: .create)
        fixture.show(Trading212View(setupStore: store, isFirstLaunchSetup: true,
            credentialValues: { ["trading212.account-1.api-key": "synced-key", "trading212.account-1.api-secret": "synced-secret"] }))
        try await settle()
        XCTAssertEqual(field(id: "trading212.api-key", in: fixture.window)?.text, "draft-key")
        XCTAssertEqual(field(id: "trading212.api-secret", in: fixture.window)?.text, "draft-secret")
    }

    func testIBKRNewConnectionUsesOneSyncedPairButKeepsPartialDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let synced = [IBKRFlexKeys.token(accountID: "U123"): "123456789",
                      IBKRFlexKeys.queryID(accountID: "U123"): "123"]
        fixture.show(IBKRFlexView(isFirstLaunchSetup: true, credentialValues: { synced }))
        try await settle()
        XCTAssertEqual(field(placeholder: "Flex Token", in: fixture.window)?.text, "123456789")
        XCTAssertEqual(field(placeholder: "Query ID", in: fixture.window)?.text, "123")
        XCTAssertTrue(fixture.model.accounts.isEmpty)

        fixture.window.rootViewController = nil
        var pending = synced
        pending[IBKRFlexKeys.pendingToken] = "987654321"
        fixture.show(IBKRFlexView(isFirstLaunchSetup: true, credentialValues: { pending }))
        try await settle()
        XCTAssertEqual(field(placeholder: "Flex Token", in: fixture.window)?.text, "987654321")
        XCTAssertEqual(field(placeholder: "Query ID", in: fixture.window)?.text, "")
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }

    private func field(id: String? = nil, placeholder: String? = nil, in view: UIView) -> UITextField? {
        if let field = view as? UITextField,
           (id != nil && field.accessibilityIdentifier == id) || (placeholder != nil && field.placeholder == placeholder) {
            return field
        }
        return view.subviews.lazy.compactMap { self.field(id: id, placeholder: placeholder, in: $0) }.first
    }

    @MainActor private final class Fixture {
        let suite = "broker-prefill-ui-\(UUID())"
        let defaults: UserDefaults
        let model: AppModel
        let window: UIWindow
        let previous: UIWindow?
        var drafts: [String: String] = [:]

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
            model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
        }

        func store() -> Trading212SetupStore {
            Trading212SetupStore(defaults: defaults, read: { self.drafts[$0] },
                write: { self.drafts[$0] = $1.isEmpty ? nil : $1 })
        }

        func show<Content: View>(_ content: Content) {
            let host = UIHostingController(rootView: content.environment(model))
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func close() {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
