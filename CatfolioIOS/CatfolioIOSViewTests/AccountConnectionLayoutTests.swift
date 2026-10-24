import SwiftUI
import WebKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountConnectionLayoutTests: XCTestCase {
    func testPreparingSharedSnapshotsKeepsTheLiveHeaderVisibleUntilMounted() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let root = UIViewController()
        fixture.window.rootViewController = root
        fixture.window.makeKeyAndVisible()
        let pages = [UIViewController(), UIViewController()]
        var headers: [AccountFlowSharedElementController] = []
        for (index, page) in pages.enumerated() {
            root.addChild(page)
            root.view.addSubview(page.view)
            page.view.frame = root.view.bounds
            page.didMove(toParent: root)
            let header = AccountFlowSharedElementController(rootView: AnyView(Text("连接账户")))
            header.safeAreaRegions = []
            header.elementID = "broker.title"
            page.addChild(header)
            page.view.addSubview(header.view)
            header.view.frame = CGRect(x: 40, y: 120, width: 200, height: 40)
            header.view.alpha = index == 0 ? 1 : 0.8
            header.didMove(toParent: page)
            headers.append(header)
        }
        try await Task.sleep(for: .milliseconds(100))
        let shared = AccountFlowSharedOverlay(from: pages[0], to: pages[1], container: root.view)
        XCTAssertEqual(shared.subviews.count, 1)
        XCTAssertEqual(headers[0].view.alpha, 1, "Preparing a snapshot must not expose an empty header frame")
        XCTAssertEqual(headers[1].view.alpha, 0.8, accuracy: 0.0001)
        shared.hideOriginals()
        XCTAssertEqual(headers[0].view.alpha, 1, "An unattached replacement cannot hide the live view")
        root.view.addSubview(shared)
        shared.hideOriginals()
        XCTAssertTrue(headers.allSatisfy { $0.view.alpha == 0 })
        shared.restore()
        shared.restore()
        XCTAssertEqual(headers[0].view.alpha, 1)
        XCTAssertEqual(headers[1].view.alpha, 0.8, accuracy: 0.0001,
                       "Completion and cancellation preserve the original opacity")
    }

    func testRepeatedPageChangesKeepBackgroundAndForegroundVisibleAtHandoff() async throws {
        for firstLaunch in [false, true] {
            let fixture = try WindowFixture()
            defer { fixture.close() }
            let state = StepBackState()
            state.step = 1
            fixture.show(SharedCanvasHarness(state: state, firstLaunch: firstLaunch))
            try await Task.sleep(for: .milliseconds(350))
            let reference = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            // Sample outside the moving foreground, including the gradient and
            // bottom safe area. Header artwork can legitimately cross an edge.
            let backgroundRows = [60, 600, 860]
            let colors = try backgroundRows.map { try backgroundPixel(reference, y: CGFloat($0)) }
            for step in [2, 1, 2, 1] {
                state.step = step
                // Include both ends of the transition, rather than checking
                // only a single frame halfway through the slide.
                for frame in 0..<40 {
                    try await Task.sleep(for: .milliseconds(16))
                    let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                        fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: false)
                    }
                    for (index, y) in backgroundRows.enumerated() {
                        for (before, current) in zip(colors[index], try backgroundPixel(image, y: CGFloat(y))) {
                            XCTAssertEqual(before, current, accuracy: 0.025,
                                "The canvas must not flash at frame \(frame), step \(step), first launch \(firstLaunch)")
                        }
                    }
                    XCTAssertGreaterThan(try foregroundInk(image), 20,
                        "The foreground must not disappear at frame \(frame), step \(step), first launch \(firstLaunch)")
                }
                XCTAssertTrue(descendants(fixture.window, of: AccountFlowContentTransitionOverlay.self).isEmpty)
                let stack = try XCTUnwrap(navigationController(in: XCTUnwrap(fixture.window.rootViewController)))
                XCTAssertEqual(stack.topViewController?.view.alpha, 1)
            }
        }
    }

    func testForegroundRemainsVisibleOverAStationaryBackground() async throws {
        for firstLaunch in [false, true] {
            let fixture = try WindowFixture()
            defer { fixture.close() }
            let state = StepBackState()
            state.step = 1
            fixture.show(SharedCanvasHarness(state: state, firstLaunch: firstLaunch))
            try await Task.sleep(for: .milliseconds(350))
            state.step = 2
            try await Task.sleep(for: .milliseconds(120))
            let canvas = try XCTUnwrap(descendants(fixture.window, of: AccountFlowContentTransitionOverlay.self).first)
            for foreground in [canvas.outgoing, canvas.incoming] {
                XCTAssertTrue(foreground.superview === canvas, "Foreground content must stay above the hidden native pages")
                XCTAssertEqual(foreground.alpha, 1)
                XCTAssertEqual(foreground.backgroundColor?.cgColor.alpha ?? 0, 0)
            }
            let origin = presentationOrigin(canvas.incoming, in: fixture.window)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(canvas.subviews.filter { $0 is UIImageView }.count, 1,
                           "The initial cover must release so the content slide remains visible")
            XCTAssertLessThan(presentationOrigin(canvas.incoming, in: fixture.window).x, origin.x - 5)
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: false)
            }
            XCTAssertGreaterThan(try foregroundInk(image), 20,
                                 "Changed foreground content must remain visible, not flash blank")
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-fixed-background-\(firstLaunch).png"))
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(descendants(fixture.window, of: AccountFlowContentTransitionOverlay.self).isEmpty)
        }
    }

    private func foregroundInk(_ image: UIImage) throws -> Int {
        let width = 100, height = 100
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 0, y: 350 * image.scale,
            width: image.size.width * image.scale, height: 300 * image.scale)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] < 50 && pixels[$0 + 1] < 50 && pixels[$0 + 2] < 50 && pixels[$0 + 3] > 200
        }.count
    }

    private struct SharedCanvasHarness: View {
        @Bindable var state: StepBackState
        let firstLaunch: Bool
        var body: some View {
            NavigationStack {
                AccountFlowPage(showsNext: Binding(get: { state.step == 2 }, set: { if !$0 { state.step = 1 } })) {
                    page(1)
                } next: { page(2) }
            }
            .background { FirstLaunchBackground(stage: .broker(.longbridge)).ignoresSafeArea() }
            .environment(\.hasSharedOnboardingBackground, firstLaunch)
            .accountFlowBrand(.longbridge)
        }
        private func page(_ step: Int) -> some View {
            OnboardingPage(isAccountPreparation: true) {
                AccountConnectionHeader(provider: .longbridge, title: "连接 Longbridge", subtitle: "只开启读取权限")
                Text(step == 1 ? "准备连接账户" : "填写账户凭证").appText(.title)
                Rectangle().fill(CatfolioTheme.primaryText).frame(width: 100, height: 32).padding(.top, 70)
            } actions: {
                OnboardingPrimaryButton(title: step == 1 ? "下一步" : "读取") { state.step = 2 }
            }
        }
    }

    func testHeaderPreservesLogoSlotsAndWrapsAtLargeTextSizes() async throws {
        for provider in AddAccountProvider.allCases {
            let header = AccountConnectionHeader(provider: provider, title: provider.title,
                                                  subtitle: L10n.text("只开启读取权限"))
            let normal = try await measure(header, width: 370)
            let large = try await measure(header.environment(\.dynamicTypeSize, .accessibility2), width: 288)
            XCTAssertEqual(normal.width, 370, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(normal.height, 154)
            XCTAssertEqual(large.width, 288, accuracy: 0.5)
            XCTAssertGreaterThan(large.height, normal.height)
        }
        for (name, size) in [("AccountConnectionLink", CGSize(width: 24, height: 24)),
                             ("AccountCredentialVisibility", CGSize(width: 24, height: 24)),
                             ("AccountConnectionTrading212", CGSize(width: 64, height: 64))] {
            XCTAssertEqual(try XCTUnwrap(UIImage(named: name)).size, size)
        }
        let logo = try XCTUnwrap(UIImage(named: "CatfolioConnectionMark"))
        XCTAssertEqual(logo.size.width / logo.size.height, 41.7034 / 51.7916, accuracy: 0.01)
        let tile = try await measure(CatfolioConnectionLogo(), width: 64)
        XCTAssertEqual(tile.width, 64, accuracy: 0.5)
        XCTAssertEqual(tile.height, 64, accuracy: 0.5)
    }

    func testCredentialPasteMatchesFigmaSizeAndTypographyWithoutHorizontalOverflow() async throws {
        for dark in [false, true] {
            let fixture = try WindowFixture()
            defer { fixture.close() }
            fixture.show(VStack(alignment: .leading, spacing: 16) {
                AccountCredentialRow(title: "API Key", text: .constant("demo-key"),
                                     accessibilityIdentifier: "test.key", isSecret: false)
                AccountCredentialRow(title: "API Secret", text: .constant(""),
                                     accessibilityIdentifier: "test.secret")
            }.frame(width: 370).accountFlowBrand(.trading212), dark: dark)
            try await Task.sleep(for: .milliseconds(250))
            let key = try XCTUnwrap(fixture.fields.first { $0.accessibilityIdentifier == "test.key" })
            let secret = try XCTUnwrap(fixture.fields.first { $0.accessibilityIdentifier == "test.secret" })
            XCTAssertFalse(key.isSecureTextEntry)
            XCTAssertTrue(secret.isSecureTextEntry)
            let keyFrame = key.convert(key.bounds, to: fixture.window)
            let secretFrame = secret.convert(secret.bounds, to: fixture.window)
            XCTAssertEqual(secretFrame.midY - keyFrame.midY, 107, accuracy: 2)
            let paste = try XCTUnwrap(descendants(fixture.window, of: UIButton.self).first { $0.accessibilityIdentifier == "test.secret.paste" })
            XCTAssertEqual(paste.titleLabel?.font.pointSize, 14)
            XCTAssertEqual(paste.titleLabel?.text, L10n.text("粘贴").uppercased())
            XCTAssertEqual(key.font?.pointSize, 17)
            let pasteFrame = paste.convert(paste.bounds, to: fixture.window)
            XCTAssertEqual(pasteFrame.height, 32, accuracy: 0.5)
            XCTAssertEqual(pasteFrame.width, 66, accuracy: 1)
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-paste-sizing-\(dark ? "dark" : "light").png"))
            XCTAssertLessThanOrEqual(pasteFrame.maxX, fixture.window.bounds.maxX - 16)
        }
    }

    func testCredentialSurfaceCompositesWithBackgroundWhileScrolling() async throws {
        for dark in [false, true] {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            for color in [CatfolioPalette.accountCredentialLabel, CatfolioPalette.accountCredentialBackground, CatfolioPalette.accountCredentialBorder] {
                let alpha = UIColor(color).resolvedColor(with: traits).cgColor.alpha
                XCTAssertGreaterThan(alpha, 0)
                XCTAssertLessThan(alpha, 1, "Credential styling must composite over the current backdrop")
            }
            let fixture = try WindowFixture()
            defer { fixture.close() }
            fixture.show(ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 280)
                    AccountCredentialRow(title: "API Key", text: .constant(""), accessibilityIdentifier: "scroll.key")
                        .padding(.horizontal, 16)
                    Color.clear.frame(height: 1000)
                }
            }.background {
                AccountConnectionBackground(theme: AddAccountProvider.trading212.flowTheme, isPreparation: true)
                    .ignoresSafeArea()
            }.accountFlowBrand(.trading212), dark: dark)
            try await Task.sleep(for: .milliseconds(250))
            let scroll = try XCTUnwrap(descendants(fixture.window, of: UIScrollView.self).first)
            let field = try XCTUnwrap(fixture.fields.first)
            var samples: [[CGFloat]] = []
            for offset in [CGFloat(0), 200] {
                scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                try await Task.sleep(for: .milliseconds(150))
                let frame = field.convert(field.bounds, to: fixture.window)
                let snapshot = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
                }
                try snapshot.pngData()?.write(to: URL(fileURLWithPath:
                    "/tmp/catfolio-credential-scroll-\(dark ? "dark" : "light")-\(Int(offset)).png"))
                // Sample the empty left inset of the field, away from text and border.
                let crop = try XCTUnwrap(snapshot.cgImage?.cropping(to: CGRect(
                    x: (frame.minX - 10) * snapshot.scale, y: frame.midY * snapshot.scale, width: 1, height: 1)))
                var pixel = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                samples.append(pixel.prefix(3).map { CGFloat($0) / 255 })
            }
            XCTAssertGreaterThan(zip(samples[0], samples[1]).map { abs($0 - $1) }.max() ?? 0,
                                 dark ? 0.01 : 0.1, "Moving over the gradient must change the field fill")
            XCTAssertTrue(fixture.fields.first === field, "Scrolling preserves the editable input")
        }
    }

    func testBrokerPasteRequiresExplicitTapAndKeepsTheInputEditable() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let draft = Draft()
        fixture.show(AccountCredentialRow(title: "API Secret", text: Binding(
            get: { draft.text }, set: { draft.text = $0 }), accessibilityIdentifier: "test.secret")
            .accountFlowBrand(.ibkr))
        try await Task.sleep(for: .milliseconds(250))
        let paste = try XCTUnwrap(descendants(fixture.window, of: UIButton.self).first { $0.accessibilityIdentifier == "test.secret.paste" })
        let previousClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboard }
        UIPasteboard.general.string = "  demo-secret  "
        XCTAssertEqual(draft.text, "", "Showing the form must not paste automatically")
        paste.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(draft.text, "demo-secret")
        let field = try XCTUnwrap(fixture.fields.first)
        XCTAssertEqual(field.text, "demo-secret")
        XCTAssertTrue(field.isSecureTextEntry)
        field.text = "edited-secret"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(draft.text, "edited-secret")
    }

    func testPasteButtonRespectsDisabledStateAndScalesWithLargerText() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let draft = Draft()
        let previousClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboard }
        UIPasteboard.general.string = "test-key"
        let binding = Binding(get: { draft.text }, set: { draft.text = $0 })
        fixture.show(AccountCredentialPasteButton(text: binding, accessibilityIdentifier: "paste.disabled")
            .disabled(true).accountFlowBrand(.trading212))
        try await Task.sleep(for: .milliseconds(250))
        let disabled = try XCTUnwrap(descendants(fixture.window, of: UIButton.self).first { $0.accessibilityIdentifier == "paste.disabled" })
        XCTAssertFalse(disabled.isEnabled)
        disabled.sendActions(for: .touchUpInside)
        XCTAssertEqual(draft.text, "")
        fixture.show(AccountCredentialPasteButton(text: binding, accessibilityIdentifier: "paste.large")
            .environment(\.dynamicTypeSize, .accessibility2).accountFlowBrand(.trading212))
        try await Task.sleep(for: .milliseconds(250))
        let large = try XCTUnwrap(descendants(fixture.window, of: UIButton.self).first { $0.accessibilityIdentifier == "paste.large" })
        XCTAssertGreaterThan(try XCTUnwrap(large.titleLabel?.font.pointSize), 14)
        XCTAssertGreaterThan(large.bounds.height, 32)
        UIPasteboard.general.string = "  \n  "
        large.sendActions(for: .touchUpInside)
        XCTAssertEqual(draft.text, "")
        UIPasteboard.general.string = "test-key"
        large.sendActions(for: .touchUpInside)
        XCTAssertEqual(draft.text, "test-key")
    }

    func testCredentialBrokersSharePreparationHelpAndPreserveDraftsWhenReturning() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer {
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
            UIPasteboard.general.items = []
        }
        UserDefaults.standard.set("zh-Hans", forKey: AppLanguage.preferenceKey)
        UIPasteboard.general.string = "demo-secret-for-layout"
        for provider in [AddAccountProvider.trading212, .ibkr, .longbridge, .alpaca, .snaptrade] {
            for dark in [false, true] {
                let fixture = try WindowFixture()
                defer { fixture.close() }
                let navigation = AddAccountNavigation()
                navigation.select(provider)
                var draft: String?
                let store = Trading212SetupStore(defaults: fixture.defaults,
                    read: { _ in draft }, write: { _, value in draft = value })
                let presentation = CatalogPresentation()
                fixture.show(CatalogRoot(presentation: presentation, navigation: navigation,
                                         store: store).environment(fixture.model), dark: dark)
                try await Task.sleep(for: .milliseconds(200))
                presentation.isPresented = true
                for _ in 0..<100 {
                    if let controller = fixture.window.rootViewController,
                       let stack = navigationController(in: controller),
                       stack.viewControllers.count == 3, stack.transitionCoordinator == nil { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try await Task.sleep(for: .milliseconds(650))
                let stack = try XCTUnwrap(navigationController(in: XCTUnwrap(fixture.window.rootViewController)))
                XCTAssertNil(fixture.window.rootViewController?.presentedViewController)
                XCTAssertEqual(stack.viewControllers.count, 3, "Caller, catalog and connector share one stack")
                let page = try XCTUnwrap(stack.topViewController)
                XCTAssertNil(navigationController(in: page), "The connector must not nest a second navigation stack")
                XCTAssertTrue(fixture.fields.isEmpty, "A new connection starts with preparation instructions")
                XCTAssertEqual(navigation.setup.step, .prepare)
                XCTAssertNil(page.navigationItem.titleView, "Preparation matches the updated design without progress")
                let preparationImage = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
                }
                try preparationImage.pngData()?.write(to: URL(fileURLWithPath:
                    "/tmp/catfolio-prepare-\(provider.rawValue)-\(dark ? "dark" : "light").png"))
                let preparationAttachment = XCTAttachment(image: preparationImage)
                preparationAttachment.name = "Connection-preparation-\(provider.rawValue)-\(dark)"
                preparationAttachment.lifetime = .keepAlways
                add(preparationAttachment)
                // The first page's Next action advances this shared navigation state.
                navigation.setup.showCredentials()
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(stack.transitionCoordinator?.isAnimated == true)
                let shared = try XCTUnwrap(descendants(fixture.window, of: AccountFlowSharedOverlay.self).first,
                    "Matching broker header elements stay above the native slide")
                let canvas = try XCTUnwrap(descendants(fixture.window, of: AccountFlowContentTransitionOverlay.self).first,
                    "A fixed canvas must cover the native moving page surfaces")
                let incomingStart = presentationOrigin(canvas.incoming, in: fixture.window)
                let logo = try XCTUnwrap(shared.subviews.first {
                    $0.accessibilityIdentifier == "account-shared.\(provider.rawValue).logos"
                })
                let logoOrigin = logo.convert(CGPoint.zero, to: fixture.window)
                XCTAssertEqual(shared.subviews.count, provider == .ibkr ? 2 : (provider == .trading212 ? 3 : 4),
                    "The primary button and unchanged header pieces stay still")
                let action = try XCTUnwrap(shared.subviews.first {
                    $0.accessibilityIdentifier == "account-shared.primary-action"
                }, "Preparation and credentials share one stationary primary action")
                let actionOrigin = presentationOrigin(action, in: fixture.window)
                XCTAssertTrue(shared.elements.allSatisfy { $0.0.alpha == 0 }, "Moving copies must be hidden")
                try await Task.sleep(for: .milliseconds(60))
                XCTAssertEqual(canvas.subviews.filter { $0 is UIImageView }.count, 1,
                               "The initial cover must not obscure the broker's content slide")
                XCTAssertLessThan(presentationOrigin(canvas.incoming, in: fixture.window).x, incomingStart.x - 5,
                                  "The foreground still slides left while the background stays still")
                XCTAssertEqual(logo.convert(CGPoint.zero, to: fixture.window).x, logoOrigin.x, accuracy: 0.5)
                XCTAssertEqual(logo.convert(CGPoint.zero, to: fixture.window).y, logoOrigin.y, accuracy: 0.5)
                XCTAssertEqual(presentationOrigin(action, in: fixture.window).x, actionOrigin.x, accuracy: 0.5)
                XCTAssertEqual(presentationOrigin(action, in: fixture.window).y, actionOrigin.y, accuracy: 0.5)
                let movingImage = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: false)
                }
                for y: CGFloat in [120, 300, 600] {
                    for (before, during) in zip(try backgroundPixel(preparationImage, y: y),
                                                try backgroundPixel(movingImage, y: y)) {
                        XCTAssertEqual(before, during, accuracy: 0.025,
                            "No moving page tint, edge or shadow may change the background during the slide")
                    }
                }
                try movingImage.pngData()?.write(to: URL(fileURLWithPath:
                    "/tmp/catfolio-account-slide-\(provider.rawValue)-\(dark).png"))
                try await Task.sleep(for: .milliseconds(550))
                XCTAssertTrue(descendants(fixture.window, of: AccountFlowSharedOverlay.self).isEmpty)
                XCTAssertTrue(descendants(fixture.window, of: AccountFlowContentTransitionOverlay.self).isEmpty)
                XCTAssertEqual(fixture.fields.count, provider == .longbridge ? 3 : 2, "Credential entry follows the preparation step")
                XCTAssertNil(page.navigationItem.titleView, "Key entry must not display a progress bar")
                let edited = try XCTUnwrap(fixture.fields.first)
                let placeholder = edited.placeholder
                edited.text = "unfinished-credential"
                edited.sendActions(for: .editingChanged)
                fixture.window.endEditing(true)
                XCTAssertEqual(stack.viewControllers.count, 4, "Preparation and credentials are separate native pages")
                XCTAssertFalse(try XCTUnwrap(stack.topViewController).navigationItem.hidesBackButton)
                XCTAssertTrue(try XCTUnwrap(stack.interactivePopGestureRecognizer).isEnabled)
                if !dark {
                    let credentialPage = try XCTUnwrap(stack.topViewController)
                    let driver = InteractivePop()
                    let delegate = stack.delegate
                    stack.delegate = driver
                    stack.popViewController(animated: true)
                    for _ in 0..<100 where stack.transitionCoordinator?.isInteractive != true {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertTrue(stack.transitionCoordinator?.isInteractive == true)
                    driver.interaction.update(0.4)
                    try await Task.sleep(for: .milliseconds(100))
                    let cancelledOverlay = try XCTUnwrap(descendants(fixture.window, of: AccountFlowSharedOverlay.self).first)
                    let hiddenElements = cancelledOverlay.elements
                    driver.interaction.cancel()
                    for _ in 0..<100 where stack.transitionCoordinator != nil {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    stack.delegate = delegate
                    XCTAssertTrue(descendants(fixture.window, of: AccountFlowSharedOverlay.self).isEmpty)
                    XCTAssertTrue(descendants(fixture.window, of: AccountFlowContentTransitionOverlay.self).isEmpty)
                    XCTAssertEqual(credentialPage.view.alpha, 1, "A cancelled swipe restores the live page")
                    XCTAssertTrue(hiddenElements.allSatisfy { $0.0.alpha == $0.1 },
                                  "Cancelling a right swipe restores both pages' real header elements")
                    XCTAssertTrue(stack.topViewController === credentialPage)
                    XCTAssertEqual(navigation.setup.step, .credentials)
                    XCTAssertEqual(edited.text, "unfinished-credential")
                    XCTAssertEqual(stack.viewControllers.count, 4)
                }
                stack.popViewController(animated: true)
                try await Task.sleep(for: .milliseconds(650))
                XCTAssertEqual(navigation.setup.step, .prepare)
                XCTAssertNil(page.navigationItem.titleView)
                XCTAssertTrue(fixture.fields.isEmpty, "Back pops only the credential page")
                XCTAssertEqual(stack.viewControllers.count, 3)
                navigation.setup.showCredentials()
                try await Task.sleep(for: .milliseconds(650))
                XCTAssertEqual(fixture.fields.first { $0.placeholder == placeholder }?.text, "unfinished-credential")
                for field in fixture.fields {
                    let frame = field.convert(field.bounds, to: fixture.window)
                    XCTAssertGreaterThanOrEqual(frame.minX, 16)
                    XCTAssertLessThanOrEqual(frame.maxX, fixture.window.bounds.maxX - 16)
                    XCTAssertLessThan(frame.maxY, fixture.window.bounds.maxY)
                }
                let snapshot = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
                }
                for (before, after) in zip(try backgroundPixel(preparationImage), try backgroundPixel(snapshot)) {
                    XCTAssertEqual(before, after, accuracy: 0.02, "Pushing credentials preserves the broker gradient")
                }
                try snapshot.pngData()?.write(to: URL(fileURLWithPath:
                    "/tmp/catfolio-connection-push-\(provider.rawValue)-\(dark ? "dark" : "light").png"))
                let attachment = XCTAttachment(image: snapshot)
                attachment.name = "Connection-subpage-\(provider.rawValue)-\(dark)"
                attachment.lifetime = .keepAlways
                add(attachment)
                if !dark {
                    let field = try XCTUnwrap(fixture.fields.first)
                    let draftBeforeHelp = field.text
                    let help = try await NativeToolbarTestSupport.button(in: stack, leading: false,
                        identifier: "\(provider.rawValue)-open-setup-guide")
                    if let control = help.view as? UIControl { control.sendActions(for: .touchUpInside) }
                    else { try help.tap() }
                    for _ in 0..<100 where stack.viewControllers.count != 5 || stack.transitionCoordinator != nil {
                        try await Task.sleep(for: .milliseconds(30))
                    }
                    XCTAssertEqual(stack.viewControllers.count, 5)
                    XCTAssertNil(fixture.window.rootViewController?.presentedViewController)
                    XCTAssertNil(navigationController(in: try XCTUnwrap(stack.topViewController)))
                    if provider != .ibkr {
                        let webView = try XCTUnwrap(descendants(try XCTUnwrap(stack.topViewController).view,
                                                               of: WKWebView.self).first)
                        XCTAssertEqual(webView.accessibilityIdentifier, "official-broker-tutorial",
                                       "Help opens the official guide instead of repeating preparation")
                    }
                    stack.popViewController(animated: true)
                    for _ in 0..<100 where stack.viewControllers.count != 4 || stack.transitionCoordinator != nil {
                        try await Task.sleep(for: .milliseconds(30))
                    }
                    XCTAssertTrue(fixture.fields.contains { $0 === field })
                    XCTAssertEqual(field.text, draftBeforeHelp, "Help must preserve the credential form")
                    XCTAssertNil(page.navigationItem.titleView, "Returning from help must not restore progress")
                }
                stack.popViewController(animated: true)
                for _ in 0..<100 where stack.viewControllers.count != 3 || stack.transitionCoordinator != nil {
                    try await Task.sleep(for: .milliseconds(30))
                }
                XCTAssertEqual(navigation.setup.step, .prepare)
                XCTAssertFalse(navigation.path.isEmpty)
                stack.popViewController(animated: true)
                for _ in 0..<100 where !navigation.path.isEmpty || stack.transitionCoordinator != nil {
                    try await Task.sleep(for: .milliseconds(30))
                }
                XCTAssertTrue(navigation.path.isEmpty)
                XCTAssertEqual(stack.viewControllers.count, 2)
                stack.popViewController(animated: true)
                for _ in 0..<100 where presentation.isPresented || stack.transitionCoordinator != nil {
                    try await Task.sleep(for: .milliseconds(30))
                }
                XCTAssertFalse(presentation.isPresented)
                XCTAssertEqual(stack.viewControllers.count, 1)
            }
        }
    }

    func testOAuthPreparationOmitsProgressAndKeepsPushedHelp() async throws {
        for provider in [AddAccountProvider.moomoo, .robinhood] {
            let fixture = try WindowFixture()
            defer { fixture.close() }
            let navigation = AddAccountNavigation()
            navigation.select(provider)
            let presentation = CatalogPresentation()
            let store = Trading212SetupStore(defaults: fixture.defaults, read: { _ in nil }, write: { _, _ in })
            fixture.show(CatalogRoot(presentation: presentation, navigation: navigation, store: store)
                .environment(fixture.model))
            try await Task.sleep(for: .milliseconds(200))
            presentation.isPresented = true
            for _ in 0..<100 {
                if let controller = fixture.window.rootViewController,
                   let stack = navigationController(in: controller),
                   stack.viewControllers.count == 3, stack.transitionCoordinator == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(350))
            let stack = try XCTUnwrap(navigationController(in: XCTUnwrap(fixture.window.rootViewController)))
            XCTAssertNil(stack.topViewController?.navigationItem.titleView)
            let help = try await NativeToolbarTestSupport.button(in: stack, leading: false,
                identifier: "\(provider.rawValue)-open-setup-guide")
            if let control = help.view as? UIControl { control.sendActions(for: .touchUpInside) }
            else { try help.tap() }
            for _ in 0..<100 where stack.viewControllers.count != 4 || stack.transitionCoordinator != nil {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(stack.viewControllers.count, 4)
            XCTAssertNil(fixture.window.rootViewController?.presentedViewController)
            stack.popViewController(animated: true)
            for _ in 0..<100 where stack.viewControllers.count != 3 || stack.transitionCoordinator != nil {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(navigation.path, [provider])
        }
    }

    func testImportAndDetailedHelpPagesOmitProgress() async throws {
        for firstLaunch in [false, true] {
            for provider in [AddAccountProvider.csv, .screenshot] {
                let fixture = try WindowFixture()
                defer { fixture.close() }
                fixture.show(AddAccountDestination(provider: provider, isFirstLaunchSetup: firstLaunch)
                    .environment(fixture.model).environment(\.isServiceAPISetupGuide, firstLaunch))
                try await Task.sleep(for: .milliseconds(350))
                let stack = try XCTUnwrap(navigationController(in: XCTUnwrap(fixture.window.rootViewController)))
                XCTAssertNil(stack.topViewController?.navigationItem.titleView, "\(provider) import has no progress bar")
            }
        }
        let fixture = try WindowFixture()
        defer { fixture.close() }
        fixture.show(NavigationStack { IBKRGuideHelpView().accountFlowBrand(.ibkr) })
        try await Task.sleep(for: .milliseconds(350))
        let stack = try XCTUnwrap(navigationController(in: XCTUnwrap(fixture.window.rootViewController)))
        XCTAssertNil(stack.topViewController?.navigationItem.titleView, "Detailed account help has no progress bar")
    }

    func testFirstLaunchKeepsPreparationAndCredentialsAsSeparatePages() async throws {
        for provider in [AddAccountProvider.trading212, .ibkr, .longbridge, .alpaca, .snaptrade] {
            let fixture = try WindowFixture()
            defer { fixture.close() }
            let store = Trading212SetupStore(defaults: fixture.defaults, read: { _ in nil }, write: { _, _ in })
            let setup = AccountSetupNavigation()
            fixture.show(AddAccountDestination(provider: provider, setupStore: store,
                isFirstLaunchSetup: true, setupNavigation: setup)
                .environment(fixture.model).environment(\.isServiceAPISetupGuide, true))
            try await Task.sleep(for: .milliseconds(500))
            let stack = try XCTUnwrap(navigationController(in: XCTUnwrap(fixture.window.rootViewController)))
            XCTAssertTrue(fixture.fields.isEmpty, "First launch starts with instructions")
            XCTAssertEqual(stack.viewControllers.count, 1)
            setup.showCredentials()
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(stack.viewControllers.count, 2)
            XCTAssertEqual(fixture.fields.count, provider == .longbridge ? 3 : 2, "\(provider) shows its credential fields")
            XCTAssertNil(stack.topViewController?.navigationItem.titleView, "\(provider) key entry has no progress bar on first launch")
            XCTAssertFalse(try XCTUnwrap(stack.topViewController).navigationItem.hidesBackButton,
                           "The input page keeps native Back")
            stack.popViewController(animated: true)
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(setup.step, .prepare)
            XCTAssertEqual(stack.viewControllers.count, 1)
            XCTAssertTrue(fixture.fields.isEmpty)
        }
    }

    func testStageChangesAnimateThroughTheNativeNavigationStack() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let state = StepBackState()
        state.step = 1
        fixture.show(StepBackHarness(state: state))
        try await Task.sleep(for: .milliseconds(250))
        state.isPresented = true
        try await Task.sleep(for: .milliseconds(650))
        let stack = try XCTUnwrap(navigationController(in: XCTUnwrap(fixture.window.rootViewController)))
        XCTAssertEqual(stack.viewControllers.count, 2)
        state.step = 2
        for _ in 0..<20 where stack.transitionCoordinator == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let push = try XCTUnwrap(stack.transitionCoordinator, "Advancing a stage must animate its native push")
        XCTAssertTrue(push.isAnimated)
        try await assertHorizontalSlide(push, in: fixture.window, forward: true)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(stack.viewControllers.count, 3)
        XCTAssertTrue(try XCTUnwrap(stack.interactivePopGestureRecognizer).isEnabled)
        state.step = 1
        for _ in 0..<20 where stack.transitionCoordinator == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pop = try XCTUnwrap(stack.transitionCoordinator, "Changing credentials must animate back")
        XCTAssertTrue(pop.isAnimated)
        try await assertHorizontalSlide(pop, in: fixture.window, forward: false)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(stack.viewControllers.count, 2)
    }

    private func assertHorizontalSlide(_ transition: UIViewControllerTransitionCoordinator,
                                       in window: UIWindow, forward: Bool) async throws {
        let movingView = try XCTUnwrap(transition.viewController(forKey: forward ? .to : .from)?.view)
        func origin() -> CGPoint {
            let layer = movingView.layer.presentation() ?? movingView.layer
            return layer.convert(.zero, to: window.layer.presentation() ?? window.layer)
        }
        try await Task.sleep(for: .milliseconds(80))
        let first = origin()
        try await Task.sleep(for: .milliseconds(80))
        let second = origin()
        XCTAssertGreaterThan(forward ? first.x - second.x : second.x - first.x, 10,
                             "Forward slides left; back slides right: \(first) → \(second)")
        XCTAssertEqual(first.y, second.y, accuracy: 2, "Navigation stays on the horizontal axis")
    }

    func testStepBackConsumesOneNativePageBeforeReturningToTheCatalog() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let state = StepBackState()
        fixture.show(StepBackHarness(state: state))
        try await Task.sleep(for: .milliseconds(250))
        state.isPresented = true
        let stack = try XCTUnwrap(navigationController(in: XCTUnwrap(fixture.window.rootViewController)))
        for _ in 0..<100 where stack.viewControllers.count != 4 || stack.transitionCoordinator != nil {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(stack.viewControllers.count, 4)
        for expected in [2, 1] {
            XCTAssertFalse(try XCTUnwrap(stack.topViewController).navigationItem.hidesBackButton)
            XCTAssertTrue(try XCTUnwrap(stack.interactivePopGestureRecognizer).isEnabled)
            stack.popViewController(animated: true)
            for _ in 0..<100 where state.step != expected || stack.transitionCoordinator != nil {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(state.step, expected)
            XCTAssertEqual(stack.viewControllers.count, expected + 1)
            XCTAssertTrue(state.isPresented)
        }
        stack.popViewController(animated: true)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(stack.viewControllers.count, 1)
    }

    private final class InteractivePop: NSObject, UINavigationControllerDelegate, UIViewControllerAnimatedTransitioning {
        let interaction = UIPercentDrivenInteractiveTransition()

        func navigationController(_ navigationController: UINavigationController,
                                  animationControllerFor operation: UINavigationController.Operation,
                                  from fromVC: UIViewController,
                                  to toVC: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? { self }

        func navigationController(_ navigationController: UINavigationController,
                                  interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning)
            -> (any UIViewControllerInteractiveTransitioning)? { interaction }

        func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0.4 }

        func animateTransition(using context: any UIViewControllerContextTransitioning) {
            guard let from = context.viewController(forKey: .from),
                  let to = context.viewController(forKey: .to) else { return }
            context.containerView.insertSubview(to.view, belowSubview: from.view)
            to.view.frame = context.finalFrame(for: to)
            UIView.animate(withDuration: transitionDuration(using: context), animations: {
                from.view.frame.origin.x = context.containerView.bounds.width
            }, completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            })
        }
    }

    @MainActor @Observable final class StepBackState {
        var isPresented = false
        var step = 3
    }

    private struct StepBackHarness: View {
        @Bindable var state: StepBackState
        var body: some View {
            NavigationStack {
                Text("Catalog")
                    .navigationDestination(isPresented: $state.isPresented) { page(1) }
            }
        }
        private func page(_ step: Int) -> some View {
            AccountFlowPage(showsNext: Binding(
                get: { state.step > step },
                set: { if !$0 { state.step = step } })) {
                    Text("Step \(step)")
                } next: { AnyView(page(step + 1)) }
        }
    }

    @MainActor @Observable final class CatalogPresentation { var isPresented = false }

    private struct CatalogRoot: View {
        @Bindable var presentation: CatalogPresentation
        let navigation: AddAccountNavigation
        let store: Trading212SetupStore
        var body: some View {
            NavigationStack {
                Color.clear.navigationTitle("Accounts")
                    .navigationDestination(isPresented: $presentation.isPresented) {
                        AddAccountView(setupStore: store, navigation: navigation)
                    }
            }
        }
    }

    private func presentationOrigin(_ view: UIView, in window: UIWindow) -> CGPoint {
        let layer = view.layer.presentation() ?? view.layer
        return layer.convert(.zero, to: window.layer.presentation() ?? window.layer)
    }

    private func backgroundPixel(_ image: UIImage, y: CGFloat = 120) throws -> [CGFloat] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: image.scale * 2, y: image.scale * y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel.prefix(3).map { CGFloat($0) / 255 }
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigationController(in: $0) }.first
    }

    private func measure<V: View>(_ view: V, width: CGFloat) async throws -> CGSize {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let host = UIHostingController(rootView: view.frame(width: width))
        host.safeAreaRegions = []
        fixture.window.rootViewController = host
        fixture.window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(40))
        return host.sizeThatFits(in: CGSize(width: width, height: 2000))
    }

    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    @MainActor @Observable final class Draft { var text = "" }

    @MainActor private final class WindowFixture {
        let suite = "connection-layout-\(UUID())"
        let defaults: UserDefaults
        let model: AppModel
        let window: UIWindow
        let previous: UIWindow?
        var fields: [UITextField] {
            func find(_ view: UIView) -> [UITextField] {
                ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(find)
            }
            return find(window)
        }
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        }
        func show<V: View>(_ view: V, dark: Bool = false) {
            window.rootViewController = UIHostingController(rootView: view.preferredColorScheme(dark ? .dark : .light))
            window.makeKeyAndVisible()
        }
        func close() {
            window.endEditing(true)
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
