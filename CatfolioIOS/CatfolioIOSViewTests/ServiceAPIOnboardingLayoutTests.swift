import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class ServiceAPIOnboardingLayoutTests: XCTestCase {
    func testWelcomeSelectionAndKeyRenderWithoutCredentials() async throws {
        let defaults = UserDefaults.standard
        let setupSuite = "api-onboarding-layout-\(UUID())"
        let setupDefaults = try XCTUnwrap(UserDefaults(suiteName: setupSuite))
        defer { setupDefaults.removePersistentDomain(forName: setupSuite) }
        let setup = ServiceAPISetupState(defaults: setupDefaults)
        let selectionDefaults = try XCTUnwrap(UserDefaults(suiteName: setupSuite + "-selection"))
        defer { selectionDefaults.removePersistentDomain(forName: setupSuite + "-selection") }
        let selectionSetup = ServiceAPISetupState(defaults: selectionDefaults)
        selectionSetup.started = true
        let previousLanguage = defaults.object(forKey: AppLanguage.preferenceKey)
        defer { defaults.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let directory = URL(fileURLWithPath: "/tmp/catfolio-service-api-guide", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in ["zh-Hans", "en"] {
            defaults.set(language, forKey: AppLanguage.preferenceKey)
            for dark in [false, true] {
                let screens: [(String, AnyView)] = [
                    ("welcome", AnyView(ServiceAPIOnboardingView(setup: setup))),
                    ("provider", AnyView(ServiceAPIOnboardingView(setup: selectionSetup))),
                    ("services", AnyView(NavigationStack {
                        ScrollView { FirstLaunchServiceOptions(isExpanded: .constant(true)).padding(20) }
                            .background { FirstLaunchBackground(stage: .selection).ignoresSafeArea() }
                    })),
                    ("key", AnyView(serviceScreen(.openRouter))),
                    ("claude-key", AnyView(serviceScreen(.claude)))
                ]
                for (name, screen) in screens {
                    let host = UIHostingController(rootView: screen.preferredColorScheme(dark ? .dark : .light))
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    try await Task.sleep(for: .milliseconds(150))
                    host.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                    }
                    let filename = "\(name)-\(language)-\(dark)"
                    try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(filename + ".png"))
                    let attachment = XCTAttachment(image: image)
                    attachment.name = filename
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    if name == "claude-key" {
                        let keyField = try XCTUnwrap(findKeyField(in: host.view))
                        XCTAssertTrue(keyField.isSecureTextEntry)
                        XCTAssertTrue(keyField.placeholder?.contains("Claude") == true)
                    }
                    if name == "provider" || name == "claude-key" {
                        let scroll = try XCTUnwrap(findScroll(in: host.view))
                        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                        if name == "provider" {
                            let viewport = scroll.convert(scroll.bounds, to: window)
                            XCTAssertEqual(viewport.maxY, window.bounds.maxY, accuracy: 1,
                                "The account catalog has no action footer and must scroll to the screen edge")
                        }
                        let bottom = max(-scroll.adjustedContentInset.top,
                            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                        try await Task.sleep(for: .milliseconds(150))
                        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
                        let bottomImage = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                        }
                        try XCTUnwrap(bottomImage.pngData()).write(to: directory.appendingPathComponent(filename + "-bottom.png"))
                    }
                    window.isHidden = true
                    window.rootViewController = nil
                    previousWindow?.makeKeyAndVisible()
                }
            }
        }
    }

    func testIntroOmitsHelpAndBackPreservesTheSelectedStep() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let suite = "intro-toolbar-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let setup = ServiceAPISetupState(defaults: defaults)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: ServiceAPIOnboardingView(setup: setup))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(350))
        let navigation = try XCTUnwrap(findNavigation(in: host))
        for started in [false, true] {
            setup.started = started
            if started {
                try await Task.sleep(for: .milliseconds(120))
                try captureTransition(window, name: "welcome-forward")
            }
            try await Task.sleep(for: .milliseconds(450))
            if started {
                XCTAssertNil(navigation.topViewController?.navigationItem.titleView, "Adding an account has no progress bar")
                continue
            }
            let title = try XCTUnwrap(navigation.topViewController?.navigationItem.titleView)
            XCTAssertLessThanOrEqual(title.bounds.width, 145, "Welcome progress stays compact in the native toolbar")
            XCTAssertGreaterThan(title.bounds.width, 70)
            let item = try XCTUnwrap(navigation.topViewController?.navigationItem)
            XCTAssertTrue((item.leftBarButtonItems ?? []).isEmpty)
            XCTAssertTrue(item.leadingItemGroups.flatMap(\.barButtonItems).isEmpty,
                          "Welcome has no help button")
            XCTAssertEqual(navigation.viewControllers.count, 1)
            XCTAssertTrue(setup.isPresented)
        }
        let back = try await NativeToolbarTestSupport.button(in: navigation, leading: true,
                                                             identifier: "service-onboarding-back")
        if let control = back.view as? UIControl { control.sendActions(for: .touchUpInside) }
        else { try back.tap() }
        try await Task.sleep(for: .milliseconds(120))
        try captureTransition(window, name: "welcome-back")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(setup.started)
        XCTAssertTrue(setup.isPresented)
    }

    private func serviceScreen(_ provider: LocalServiceProvider) -> some View {
        let suite = "intro-service-preview-\(provider.rawValue)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let setup = ServiceAPISetupState(defaults: defaults)
        setup.started = true
        setup.path = [.key(provider)]
        return ServiceAPIOnboardingView(setup: setup,
            drafts: ServiceAPIKeyDrafts(read: { _ in nil }, write: { _, _ in }))
    }

    func testPagesAnimateAndSettleOnGradientWithSkipInToolbar() async throws {
        let suite = "intro-background-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let setup = ServiceAPISetupState(defaults: defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        let host = UIHostingController(rootView: ServiceAPIOnboardingView(setup: setup,
            drafts: ServiceAPIKeyDrafts(read: { _ in nil }, write: { _, _ in })).environment(model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(350))
        let navigation = try XCTUnwrap(findNavigation(in: host))
        let skip = try await NativeToolbarTestSupport.button(in: navigation, leading: false,
                                                             identifier: "service-onboarding-skip")
        let skipFrame = skip.view.convert(skip.view.bounds, to: window)
        XCTAssertGreaterThan(skipFrame.midX, window.bounds.midX)
        XCTAssertLessThan(skipFrame.midY, 150)
        setup.started = true
        try await Task.sleep(for: .milliseconds(400))
        for route in [ServiceAPISetupState.Step.key(.massive), .key(.claude), .account(.longbridge)] {
            withAnimation { setup.path = [route] }
            for delay in [80, 120, 450] {
                try await Task.sleep(for: .milliseconds(delay))
                let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                if delay == 80 {
                    XCTAssertTrue(navigation.transitionCoordinator?.isAnimated == true,
                                  "Forward navigation must animate instead of replacing the page instantly")
                }
                if delay == 450 {
                    // During the slide these points can belong to different pages.
                    // Once settled, the gradient must span the entire destination.
                    let left = try pixel(snapshot, x: 2, y: 300)
                    let right = try pixel(snapshot, x: 399, y: 300)
                    XCTAssertLessThan(zip(left, right).map { abs($0 - $1) }.max() ?? 1, 0.04)
                }
                if delay == 120 {
                    try snapshot.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-intro-transition-\(String(describing: route)).png"))
                }
            }
            XCTAssertEqual(navigation.view.backgroundColor?.cgColor.alpha, 0)
            XCTAssertEqual(navigation.topViewController?.view.backgroundColor?.cgColor.alpha, 0)
            navigation.popViewController(animated: true)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(setup.path.isEmpty)
        }
        let finishSkip = try await NativeToolbarTestSupport.button(in: navigation, leading: false,
                                                                   identifier: "service-onboarding-skip")
        if let control = finishSkip.view as? UIControl { control.sendActions(for: .touchUpInside) }
        else { try finishSkip.tap() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(setup.isPresented)
    }

    private func captureTransition(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/catfolio-intro-\(name).png"))
    }

    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> [CGFloat] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: x * image.scale, y: y * image.scale, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map { CGFloat($0) / 255 }
    }

    private func findNavigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.findNavigation(in: $0) }.first
    }

    private func findScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
    }

    private func findKeyField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.accessibilityIdentifier == "local-service.api-key" { return field }
        return view.subviews.lazy.compactMap { self.findKeyField(in: $0) }.first
    }
}
