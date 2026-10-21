import SwiftUI
import UIKit
import Vision
import XCTest
@testable import CatfolioIOS

@MainActor
final class ServiceAPIInputTests: XCTestCase {
    func testRevealingKeyKeepsResponderSelectionAndAllowsOrdinaryKeyboard() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let input = Input()
        let host = UIHostingController(rootView: ServiceAPIKeyField(placeholder: "API Key",
            text: Binding(get: { input.text }, set: { input.text = $0 }), revealsKey: input.revealed).disabled(false))
        fixture.show(host)
        try await settle()
        let field = try XCTUnwrap(findField(host.view))
        XCTAssertTrue(field.isSecureTextEntry)
        XCTAssertTrue(field.becomeFirstResponder())
        try await settle()
        let position = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 4))
        field.selectedTextRange = field.textRange(from: position, to: position)
        for revealed in [true, false, true] {
            input.revealed = revealed
            host.rootView = ServiceAPIKeyField(placeholder: "API Key",
                text: Binding(get: { input.text }, set: { input.text = $0 }), revealsKey: revealed).disabled(false)
            try await settle()
            XCTAssertTrue(findField(host.view) === field)
            XCTAssertTrue(field.isFirstResponder)
            XCTAssertEqual(field.isSecureTextEntry, !revealed)
            XCTAssertEqual(field.keyboardType, .default)
            XCTAssertNotEqual(field.textContentType, .password)
            XCTAssertEqual(field.autocorrectionType, .no)
            XCTAssertEqual(field.text, "test-key-123")
            let selection = try XCTUnwrap(field.selectedTextRange)
            XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selection.start), 4)
        }
        field.insertText("X")
        field.sendActions(for: .editingChanged)
        try await settle()
        XCTAssertEqual(input.text, "testX-key-123")
        host.rootView = ServiceAPIKeyField(placeholder: "API Key",
            text: Binding(get: { input.text }, set: { input.text = $0 }), revealsKey: true).disabled(true)
        try await settle()
        XCTAssertFalse(field.isEnabled, "Validation must prevent further edits to the candidate key")
    }

    func testSwitchingAppsKeepsTheSameInputAndNavigationPage() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let store = TestStore()
        let setup = ServiceAPISetupState(defaults: fixture.defaults)
        setup.started = true
        setup.path = [.key(.deepSeek)]
        let phase = Phase()
        let host = UIHostingController(rootView: Flow(setup: setup, drafts: store.drafts(), phase: phase))
        fixture.show(host)
        try await settle()
        let field = try XCTUnwrap(findField(host.view))
        field.text = "unfinished-key"
        field.sendActions(for: .editingChanged)
        try await settle()
        let navigation = try XCTUnwrap(findFormNavigation(host))
        let page = try XCTUnwrap(navigation.topViewController)
        let scroll = try XCTUnwrap(page.contentScrollView(for: .top))
        let offset = scroll.contentOffset
        for value in [ScenePhase.inactive, .background, .inactive, .active] {
            phase.value = value
            try await settle()
            XCTAssertTrue(navigation.topViewController === page)
            XCTAssertTrue(findField(host.view) === field)
            XCTAssertEqual(field.text, "unfinished-key")
            XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1)
            XCTAssertEqual(setup.path, [.key(.deepSeek)])
        }
    }

    func testProcessRecreationAndBackNavigationRetainTheUnfinishedForm() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let store = TestStore()
        let setup = ServiceAPISetupState(defaults: fixture.defaults)
        setup.started = true
        setup.path = [.key(.massive)]
        let phase = Phase()
        let first = UIHostingController(rootView: Flow(setup: setup, drafts: store.drafts(), phase: phase))
        fixture.show(first)
        try await settle()
        let field = try XCTUnwrap(findField(first.view))
        field.text = "draft-for-relaunch"
        field.sendActions(for: .editingChanged)
        try await settle()
        phase.value = .background
        try await settle()
        fixture.window.rootViewController = nil
        try await settle()

        let resumed = ServiceAPISetupState(defaults: fixture.defaults)
        XCTAssertTrue(resumed.isPresented)
        let second = UIHostingController(rootView: Flow(setup: resumed, drafts: store.drafts(), phase: Phase()))
        fixture.show(second)
        try await settle()
        XCTAssertEqual(try XCTUnwrap(findField(second.view)).text, "draft-for-relaunch")
        XCTAssertEqual(findFormNavigation(second)?.viewControllers.count, 2)

        let navigation = try XCTUnwrap(findFormNavigation(second))
        navigation.popViewController(animated: true)
        try await waitUntil {
            guard let navigation = self.findFormNavigation(second),
                  let page = navigation.topViewController else { return false }
            return navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil
                && self.findField(page.view) == nil && resumed.path.isEmpty
        }
        let back = try await NativeToolbarTestSupport.button(in: navigation, leading: true,
                                                             identifier: "service-onboarding-back")
        try back.tap()
        try await waitUntil { !resumed.started }
        XCTAssertTrue(resumed.isPresented, "Back to Welcome must keep first-launch onboarding open")
        XCTAssertFalse(ServiceAPISetupState(defaults: fixture.defaults).started,
                       "Reopening the app must keep the step chosen by Back")

        resumed.started = true
        resumed.path.append(.key(.massive))
        try await waitUntil {
            guard let navigation = self.findFormNavigation(second),
                  let page = navigation.topViewController else { return false }
            return navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil
                && self.findField(page.view)?.text == "draft-for-relaunch"
        }
    }

    func testFirstLaunchAccountsOpenCredentialsAndReturnWithinTheSameNavigation() async throws {
        for route in [ServiceAPISetupState.Step.account(.trading212), .account(.ibkr)] {
            let fixture = try WindowFixture()
            defer { fixture.close() }
            let model = AppModel(defaults: fixture.defaults, personalDocumentLoader: { .empty })
            let setup = ServiceAPISetupState(defaults: fixture.defaults)
            let keys = TestStore()
            let accountStore = Trading212SetupStore(defaults: fixture.defaults,
                read: { keys.values[$0] }, write: { keys.values[$0] = $1 })
            try accountStore.save(.init(step: .prepare, environment: .demo,
                apiKey: "unfinished-account-key", apiSecret: "unfinished-account-secret",
                accountSlot: 1, nickname: "Test", nicknameEdited: true), for: .create)

            setup.started = true
            setup.path = [route]
            let phase = Phase()
            let host = UIHostingController(rootView: Flow(setup: setup, drafts: keys.drafts(), phase: phase,
                accountStore: accountStore).environment(model))
            fixture.show(host)
            try await waitUntil {
                self.findAccountInput(route, in: host.view) != nil
                    && self.findFormNavigation(host)?.viewControllers.count == 2
            }
            let field = try XCTUnwrap(findAccountInput(route, in: host.view))
            let navigation = try XCTUnwrap(findFormNavigation(host))
            let page = try XCTUnwrap(navigation.topViewController)
            XCTAssertNil(findFormNavigation(page), "Account setup must reuse the first-launch navigation stack")
            field.text = "edited-onboarding-account-key"
            field.sendActions(for: .editingChanged)
            try await settle()
            for value in [ScenePhase.background, .active] {
                phase.value = value
                try await settle()
                XCTAssertEqual(setup.path, [route])
                XCTAssertTrue(findAccountInput(route, in: host.view) === field)
                XCTAssertEqual(field.text, "edited-onboarding-account-key")
            }
            if route.accountProvider == .trading212 {
                XCTAssertEqual(accountStore.load(for: .create)?.apiKey, "edited-onboarding-account-key")
                XCTAssertEqual(accountStore.load(for: .create)?.environment, .live)
                XCTAssertFalse(accountStore.shouldResumeCreation,
                               "First-launch resume must not also open an Add Account sheet in Settings")
            }
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/catfolio-first-launch-\(route).png"))
            navigation.popViewController(animated: true)
            try await waitUntil { setup.path.isEmpty && navigation.transitionCoordinator == nil }
            let back = try await NativeToolbarTestSupport.button(in: navigation, leading: true,
                                                                 identifier: "service-onboarding-back")
            try back.tap()
            try await waitUntil { !setup.started }
            XCTAssertTrue(setup.isPresented, "Returning from \(route) must keep onboarding open")
            fixture.window.rootViewController = nil
        }
    }

    private func findAccountInput(_ route: ServiceAPISetupState.Step, in view: UIView) -> UITextField? {
        if let field = view as? UITextField,
           route.accountProvider == .trading212 ? field.accessibilityIdentifier == "trading212.api-key" : field.placeholder == "Flex Token" {
            return field
        }
        return view.subviews.lazy.compactMap { self.findAccountInput(route, in: $0) }.first
    }

    func testOtherAccountChoicesUseExistingConnectorsAndCanReturnToWelcome() async throws {
        let destinations: [(AddAccountProvider, String)] = [
            (.moomoo, L10n.text("连接 Moomoo")),
            (.robinhood, L10n.text("连接 Robinhood")),
            (.snaptrade, L10n.text("连接其他券商")),
            (.csv, L10n.text("导入 CSV"))
        ]
        for (provider, title) in destinations {
            let fixture = try WindowFixture()
            defer { fixture.close() }
            let model = AppModel(defaults: fixture.defaults, personalDocumentLoader: { .empty })
            let setup = ServiceAPISetupState(defaults: fixture.defaults)
            setup.started = true
            setup.path = [.account(provider)]
            let phase = Phase()
            let host = UIHostingController(rootView: Flow(setup: setup, drafts: TestStore().drafts(), phase: phase)
                .environment(model))
            fixture.show(host)
            try await waitUntil {
                guard let navigation = self.findFormNavigation(host) else { return false }
                return navigation.viewControllers.count == 2 && navigation.topViewController?.contentScrollView(for: .top) != nil
                    && navigation.transitionCoordinator == nil
            }
            let navigation = try XCTUnwrap(findFormNavigation(host))
            let page = try XCTUnwrap(navigation.topViewController)
            XCTAssertNil(findFormNavigation(page), "\(provider) must reuse the first-launch navigation stack")
            let clientField = provider == .snaptrade ? findCredential("Client ID", in: page.view) : nil
            if provider == .snaptrade {
                let field = try XCTUnwrap(clientField)
                field.text = "unfinished-snaptrade-client"
                field.sendActions(for: .editingChanged)
                try await settle()
            }
            for value in [ScenePhase.background, .active] {
                phase.value = value
                try await settle()
                XCTAssertEqual(setup.path, [.account(provider)])
                XCTAssertTrue(navigation.topViewController === page)
                if let clientField {
                    XCTAssertTrue(findCredential("Client ID", in: page.view) === clientField)
                    XCTAssertEqual(clientField.text, "unfinished-snaptrade-client")
                }
            }
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/catfolio-first-launch-\(provider.rawValue).png"))
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
            let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
            let normalized = text.filter { !$0.isWhitespace }.lowercased()
            XCTAssertTrue(normalized.contains(title.filter { !$0.isWhitespace }.lowercased()),
                          "The connector heading must be visible: \(text)")

            navigation.popViewController(animated: true)
            try await waitUntil { setup.path.isEmpty && navigation.transitionCoordinator == nil }
            let back = try await NativeToolbarTestSupport.button(in: navigation, leading: true,
                                                                 identifier: "service-onboarding-back")
            try back.tap()
            try await waitUntil { !setup.started }
            XCTAssertTrue(setup.isPresented, "Returning from \(provider) must keep onboarding open")
        }
    }

    private struct Flow: View {
        let setup: ServiceAPISetupState
        let drafts: ServiceAPIKeyDrafts
        let phase: Phase
        /// Never the app's own store: a flag left in its defaults reopens the
        /// Trading 212 setup over later tests.
        var accountStore = Trading212SetupStore(defaults: Self.isolatedDefaults, read: { _ in nil }, write: { _, _ in })

        static let isolatedDefaults: UserDefaults = {
            let suite = "api-input-trading212"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }()
        var body: some View {
            // First-launch onboarding owns its navigation in a full-screen cover;
            // it is outside the home page's security-detail navigation controller.
            ServiceAPIOnboardingView(setup: setup, drafts: drafts, trading212SetupStore: accountStore)
                .environment(\.scenePhase, phase.value)
        }
    }

    @MainActor @Observable final class Input {
        var text = "test-key-123"
        var revealed = false
    }
    @MainActor @Observable final class Phase { var value: ScenePhase = .active }

    @MainActor private final class TestStore {
        var values: [String: String] = [:]
        func drafts() -> ServiceAPIKeyDrafts {
            ServiceAPIKeyDrafts(read: { self.values[$0] }, write: { key, value in
                self.values[key] = value.isEmpty ? nil : value
            })
        }
    }

    @MainActor private final class WindowFixture {
        let window: UIWindow
        let previous: UIWindow?
        let suite = "api-input-\(UUID())"
        let defaults: UserDefaults
        init() throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        }
        func show(_ controller: UIViewController) {
            window.rootViewController = controller
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

    private func findField(_ view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.accessibilityIdentifier == "local-service.api-key" { return field }
        return view.subviews.lazy.compactMap { self.findField($0) }.first
    }

    private func findCredential(_ placeholder: String, in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.placeholder == placeholder { return field }
        return view.subviews.lazy.compactMap { self.findCredential(placeholder, in: $0) }.first
    }

    private func findFormNavigation(_ controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController,
           !(navigation is SecurityDetailNavigationController) { return navigation }
        return controller.children.lazy.compactMap { self.findFormNavigation($0) }.first
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("API setup did not finish navigating")
    }
}
