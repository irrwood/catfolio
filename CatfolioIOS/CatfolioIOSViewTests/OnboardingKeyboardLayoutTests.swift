import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class OnboardingKeyboardLayoutTests: XCTestCase {
    func testKeyboardKeepsCredentialFieldsAboveTheGlassAction() async throws {
        for dark in [false, true] {
            let fixture = try Fixture(dark: dark)
            defer { fixture.close() }
            try await settle()
            let fields = descendants(fixture.window, of: UITextField.self)
            XCTAssertEqual(fields.count, 3)
            let scroll = try XCTUnwrap(descendants(fixture.window, of: UIScrollView.self)
                .first { fields.first?.isDescendant(of: $0) == true })
            for field in fields {
                // A tall input view also covers third-party keyboards, as in the reported screenshot.
                field.inputView = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 340))
                XCTAssertTrue(field.becomeFirstResponder())
                try await settle()
                let viewport = scroll.convert(scroll.bounds, to: fixture.window)
                let action = fixture.state.actionFrame
                XCTAssertGreaterThan(action.height, 40)
                XCTAssertLessThanOrEqual(viewport.maxY, action.minY - 15,
                                         "Input content must be clipped above the footer, not float behind it")
                XCTAssertLessThan(action.maxY, fixture.window.bounds.maxY - 300,
                                  "The action follows the keyboard safe area")
                // Every field remains reachable above the action, including the final access token.
                let fieldRect = field.convert(field.bounds.insetBy(dx: 0, dy: -16), to: scroll)
                scroll.scrollRectToVisible(fieldRect, animated: false)
                try await Task.sleep(for: .milliseconds(100))
                let visibleField = field.convert(field.bounds, to: fixture.window)
                XCTAssertGreaterThanOrEqual(visibleField.minY, viewport.minY)
                XCTAssertLessThanOrEqual(visibleField.maxY, viewport.maxY)
                XCTAssertLessThan(visibleField.maxY, action.minY)
            }
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-keyboard-footer-\(dark).png"))
            fixture.window.endEditing(true)
            try await settle()
            XCTAssertGreaterThan(fixture.state.actionFrame.minY, fixture.window.bounds.maxY - 150)
        }
    }

    func testGlassActionKeepsItsSizeWhenCredentialsBecomeValid() async throws {
        let fixture = try Fixture(dark: false)
        defer { fixture.close() }
        try await settle()
        let disabled = fixture.state.actionFrame
        fixture.state.key = "key"
        fixture.state.secret = "secret"
        fixture.state.token = "token"
        try await settle()
        XCTAssertEqual(fixture.state.actionFrame.height, disabled.height, accuracy: 0.5,
                       "Enabling the glass button must not swap to a different control layout")
        XCTAssertEqual(fixture.state.actionFrame.minY, disabled.minY, accuracy: 0.5)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(600)) }

    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    @Observable final class FormState {
        var key = ""
        var secret = ""
        var token = ""
        var actionFrame = CGRect.zero
    }

    private struct Form: View {
        @Bindable var state: FormState
        var body: some View {
            NavigationStack {
                OnboardingPage(isAccountPreparation: true) {
                    AccountConnectionHeader(provider: .longbridge, title: "连接长桥", subtitle: "只开启读取权限")
                    AccountCredentialRow(title: "App Key", text: $state.key, accessibilityIdentifier: "keyboard.key")
                    AccountCredentialRow(title: "App Secret", text: $state.secret, accessibilityIdentifier: "keyboard.secret")
                    AccountCredentialRow(title: "Access Token", text: $state.token, accessibilityIdentifier: "keyboard.token")
                    SettingsFootnote("凭证保存在本机钥匙串。")
                } actions: {
                    OnboardingPrimaryButton(title: "读取", isDisabled: state.key.isEmpty || state.secret.isEmpty || state.token.isEmpty,
                                            usesGlass: true, action: {})
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.actionFrame = $0 }
                }
                .accountFlowBrand(.longbridge)
            }
        }
    }

    @MainActor private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?
        let state = FormState()
        init(dark: Bool) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = UIHostingController(rootView: Form(state: state).preferredColorScheme(dark ? .dark : .light))
            window.makeKeyAndVisible()
        }
        func close() {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
}
