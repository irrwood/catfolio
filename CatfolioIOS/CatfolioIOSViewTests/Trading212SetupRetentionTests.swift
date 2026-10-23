import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class Trading212SetupRetentionTests: XCTestCase {
    func testOneSelectionOpensTrading212AndCanReopenAfterBack() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        await fixture.model.refreshPortfolio(refreshMarketData: false)
        let route = AddAccountNavigation()
        let store = fixture.store()
        let host = UIHostingController(rootView: NavigationStack { AddAccountView(setupStore: store, navigation: route) }
            .environment(fixture.model).environment(\.scenePhase, .active))
        fixture.window.rootViewController = host
        fixture.window.makeKeyAndVisible()
        try await settle()
        let navigation = try XCTUnwrap(formNavigation(in: host))
        XCTAssertEqual(navigation.viewControllers.count, 1)
        for _ in 0..<3 {
            // The provider row calls this same action once per activation.
            route.select(.trading212)
            try await waitUntil { navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil }
            let page = try XCTUnwrap(navigation.topViewController)
            let reads = fixture.reads
            let writes = fixture.writes
            try await settle()
            XCTAssertEqual(fixture.reads, reads, "Idle navigation must not recreate and reload the form")
            XCTAssertEqual(fixture.writes, writes, "Idle navigation must not repeatedly save a draft")
            XCTAssertTrue(navigation.topViewController === page)
            XCTAssertTrue(store.shouldResumeCreation)
            XCTAssertEqual(route.path, [.trading212])
            navigation.popViewController(animated: true)
            try await waitUntil { route.path.isEmpty && navigation.transitionCoordinator == nil }
            XCTAssertEqual(navigation.viewControllers.count, 1)
            XCTAssertFalse(store.shouldResumeCreation)
        }
    }

    func testAddingAccountFromPublicAndDemoModesLoadsPersonalSlotsBeforeOpeningConnector() async throws {
        let account = PortfolioAccount(id: "Trading 212|account-1", accountID: "account-1",
            source: "Trading 212", name: "Existing personal account", baseCurrency: "USD",
            positionCount: 0, transactionCount: 0, manualTransactionCount: 0,
            hasCSVImport: false, marketValueUSD: 0)
        var personal = LocalPortfolioDocument.empty
        personal.knownAccounts = [account]
        for selection in ["pelosi", "demo"] {
            let fixture = try Fixture(selection: selection, personal: personal)
            defer { fixture.close() }
            XCTAssertTrue(fixture.model.isPublicInvestorMode || fixture.model.isFakeDataMode)
            let route = AddAccountNavigation(resumesTrading212: true)
            let store = fixture.store()
            let host = UIHostingController(rootView: NavigationStack {
                AddAccountView(setupStore: store, navigation: route)
            }.environment(fixture.model).environment(\.scenePhase, .active))
            fixture.window.rootViewController = host
            fixture.window.makeKeyAndVisible()
            try await waitUntil { store.load(for: .create)?.accountSlot == 2 }
            XCTAssertNil(self.field("trading212.api-secret", in: fixture.window))
            XCTAssertEqual(route.setup.step, .prepare)
            route.setup.showCredentials()
            try await waitUntil { self.field("trading212.api-secret", in: fixture.window) != nil }
            XCTAssertFalse(fixture.model.isPublicInvestorMode)
            XCTAssertFalse(fixture.model.isFakeDataMode)
            XCTAssertEqual(fixture.model.publicInvestorSelection, selection)
            XCTAssertEqual(fixture.model.accounts.map(\.id), [account.id])
            try await waitUntil { store.load(for: .create)?.accountSlot == 2 }
            let navigation = try XCTUnwrap(formNavigation(in: host))
            try await waitUntil { navigation.transitionCoordinator == nil }
            navigation.popViewController(animated: true)
            try await waitUntil { route.setup.step == .prepare && navigation.transitionCoordinator == nil }
            XCTAssertEqual(route.path, [.trading212])
            navigation.popViewController(animated: true)
            try await waitUntil { route.path.isEmpty && navigation.transitionCoordinator == nil }
            route.select(.trading212)
            try await waitUntil { navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil }
            route.setup.showCredentials()
            try await waitUntil { self.field("trading212.api-secret", in: fixture.window) != nil }
            XCTAssertEqual(store.load(for: .create)?.accountSlot, 2)
        }
    }

    private func formNavigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.formNavigation(in: $0) }.first
    }

    func testRestoredTutorialDoesNotRecreateOrSaveWhileIdle() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.seed(step: .settings)
        await fixture.model.refreshPortfolio(refreshMarketData: false)
        let host = fixture.show(phase: Phase())
        try await waitUntil { fixture.store().load(for: .create)?.step == .prepare }
        try await settle()
        XCTAssertNil(self.field("trading212.api-secret", in: fixture.window))
        let reads = fixture.reads
        let writes = fixture.writes
        fixture.defaults.set(DisplayCurrency.eur.rawValue, forKey: DisplayCurrency.preferenceKey)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(fixture.reads, reads, "Preference updates must keep the current tutorial's form state")
        XCTAssertEqual(fixture.writes, writes, "An idle tutorial must not keep saving its restored draft")
    }

    func testSwitchingAppsKeepsThePushedAccountPageAndBothInputs() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.seed()
        await fixture.model.refreshPortfolio(refreshMarketData: false)
        let phase = Phase()
        let host = fixture.show(phase: phase)
        try await waitUntil { self.field("trading212.api-secret", in: fixture.window) != nil }
        let key = try XCTUnwrap(field("trading212.api-key", in: fixture.window))
        let secret = try XCTUnwrap(field("trading212.api-secret", in: fixture.window))
        let navigation = try XCTUnwrap(accountNavigation(in: host))
        let page = try XCTUnwrap(navigation.topViewController)
        key.text = "edited-key"
        key.sendActions(for: .editingChanged)
        secret.text = "edited-secret"
        secret.sendActions(for: .editingChanged)
        try await settle()
        for value in [ScenePhase.inactive, .background, .inactive, .active] {
            phase.value = value
            try await settle()
            XCTAssertTrue(navigation.topViewController === page, "Switching apps must keep the account page")
            XCTAssertNil(presentedController(in: host))
            XCTAssertTrue(field("trading212.api-key", in: fixture.window) === key)
            XCTAssertTrue(field("trading212.api-secret", in: fixture.window) === secret)
            XCTAssertEqual(key.text, "edited-key")
            XCTAssertEqual(secret.text, "edited-secret")
        }
        // Exercise another appearance of the presenting page. Its launch
        // task used to reset showsAddAccount to false on every appearance.
        host.beginAppearanceTransition(false, animated: false)
        host.endAppearanceTransition()
        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        try await settle()
        XCTAssertTrue(navigation.topViewController === page)
        XCTAssertEqual(key.text, "edited-key")
        XCTAssertEqual(secret.text, "edited-secret")
        XCTAssertEqual(fixture.store().load(for: .create)?.apiKey, "edited-key")
        XCTAssertEqual(fixture.store().load(for: .create)?.apiSecret, "edited-secret")
        XCTAssertEqual(fixture.store().load(for: .create)?.environment, .live,
                       "Restoring a legacy demo draft must keep its inputs but use a live account")
    }

    func testRecreatingTheAppReopensTrading212AtCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.seed()
        await fixture.model.refreshPortfolio(refreshMarketData: false)
        let phase = Phase()
        var host: UIHostingController<Root>? = fixture.show(phase: phase)
        try await waitUntil { self.field("trading212.api-secret", in: fixture.window) != nil }
        let key = try XCTUnwrap(field("trading212.api-key", in: fixture.window))
        let secret = try XCTUnwrap(field("trading212.api-secret", in: fixture.window))
        key.text = "key-before-background"
        key.sendActions(for: .editingChanged)
        secret.text = "secret-before-background"
        secret.sendActions(for: .editingChanged)
        phase.value = .background
        try await settle()
        fixture.window.rootViewController = nil
        host = nil
        try await settle()
        XCTAssertTrue(fixture.store().shouldResumeCreation)

        host = fixture.show(phase: Phase())
        try await waitUntil { self.field("trading212.api-secret", in: fixture.window) != nil }
        let restoredKey = try XCTUnwrap(field("trading212.api-key", in: fixture.window))
        let restoredSecret = try XCTUnwrap(field("trading212.api-secret", in: fixture.window))
        XCTAssertFalse(restoredKey === key)
        XCTAssertEqual(restoredKey.text, "key-before-background")
        XCTAssertEqual(restoredSecret.text, "secret-before-background")
        XCTAssertFalse(restoredKey.isSecureTextEntry, "The API Key is visible, as designed; the Secret stays hidden")
        XCTAssertTrue(restoredSecret.isSecureTextEntry)
        XCTAssertEqual(fixture.store().load(for: .create)?.step, .credentials)
        let restoredHost = try XCTUnwrap(host)
        let navigation = try XCTUnwrap(accountNavigation(in: restoredHost))
        try await waitUntil { navigation.transitionCoordinator == nil && navigation.viewControllers.count == 4 }
        XCTAssertNil(presentedController(in: restoredHost))
        navigation.popViewController(animated: true)
        try await waitUntil { navigation.transitionCoordinator == nil && navigation.viewControllers.count == 3 }
        XCTAssertEqual(fixture.store().load(for: .create)?.step, .prepare)
        navigation.popViewController(animated: true)
        try await waitUntil { navigation.transitionCoordinator == nil && navigation.viewControllers.count == 2 }
        XCTAssertFalse(fixture.store().shouldResumeCreation, "Going back to the catalog must stop reopening the connector")
        navigation.popViewController(animated: true)
        try await waitUntil { navigation.transitionCoordinator == nil && navigation.viewControllers.count == 1 }
        XCTAssertFalse(fixture.store().shouldResumeCreation)

    }

    struct Root: View {
        let model: AppModel
        let store: Trading212SetupStore
        let defaults: UserDefaults
        let phase: Phase
        var body: some View {
            RootTabView(trading212SetupStore: store)
            .environment(model)
            .environment(\.scenePhase, phase.value)
            .defaultAppStorage(defaults)
        }
    }

    @MainActor @Observable final class Phase { var value: ScenePhase = .active }

    @MainActor private final class Fixture {
        let suite = "trading212-retention-\(UUID())"
        let defaults: UserDefaults
        let model: AppModel
        let window: UIWindow
        let previous: UIWindow?
        var values: [String: String] = [:]
        var reads = 0
        var writes = 0
        init(selection: String? = nil, personal: LocalPortfolioDocument = .empty) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(selection != nil && selection != "demo", forKey: PublicInvestorPreferences.enabledKey)
            defaults.set(selection == "demo", forKey: "catfolio.fakeDataMode")
            if let selection { defaults.set(selection, forKey: PublicInvestorPreferences.selectionKey) }
            model = AppModel(defaults: defaults, personalDocumentLoader: {
                try await Task.sleep(for: .milliseconds(150))
                return personal
            })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
        }
        func seed(step: Trading212GuideStep = .credentials) throws {
            let store = store()
            try store.save(.init(step: step, environment: .demo, apiKey: "initial", apiSecret: "initial-secret",
                accountSlot: 1, nickname: "Unfinished account", nicknameEdited: true), for: .create)
            store.setCreationPresented(true)
        }
        func store() -> Trading212SetupStore {
            Trading212SetupStore(defaults: defaults, read: { self.reads += 1; return self.values[$0] }, write: { key, value in
                self.writes += 1
                self.values[key] = value.isEmpty ? nil : value
            })
        }
        func show(phase: Phase) -> UIHostingController<Root> {
            let host = UIHostingController(rootView: Root(model: model, store: store(), defaults: defaults, phase: phase))
            window.rootViewController = host
            window.makeKeyAndVisible()
            return host
        }
        func close() {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func field(_ id: String, in view: UIView) -> UITextField? {
        // Visit each view once. Lazy compactMap.first can evaluate the same
        // recursive lookup repeatedly across the full TabView hierarchy.
        var pending = [view]
        while let next = pending.popLast() {
            if let field = next as? UITextField, field.accessibilityIdentifier == id { return field }
            pending.append(contentsOf: next.subviews.reversed())
        }
        return nil
    }

    private func accountNavigation(in controller: UIViewController) -> UINavigationController? {
        // SecurityDetailNavigationContainer also owns an outer navigation
        // controller. Return the innermost stack that owns the credential page.
        for child in controller.children {
            if let navigation = accountNavigation(in: child) { return navigation }
        }
        if let navigation = controller as? UINavigationController,
           navigation.viewIfLoaded?.window != nil,
           let page = navigation.topViewController?.viewIfLoaded,
           field("trading212.api-secret", in: page) != nil { return navigation }
        return nil
    }

    private func presentedController(in controller: UIViewController) -> UIViewController? {
        if let presented = controller.presentedViewController { return presented }
        for child in controller.children {
            if let presented = presentedController(in: child) { return presented }
        }
        return nil
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Trading 212 navigation did not reach its expected state")
    }
}
