import SwiftUI
import Vision
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountFlowThemeTests: XCTestCase {
    func testConnectorActionsUseBrokerBrandsInBothAppearances() async throws {
        let suite = "account-brand-pages-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
        }
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        for dark in [false, true] {
            for provider in AddAccountProvider.allCases {
                for context in [AccountConnectorContext.create, .manage(account(provider))] {
                    let image = try await render(page(provider, context: context).environment(model), dark: dark)
                    try image.pngData()?.write(to: URL(fileURLWithPath:
                        "/tmp/catfolio-connector-\(provider.rawValue)-\(context.isCreating ? "create" : "manage")-\(dark ? "dark" : "light").png"))
                    try verifyAction(in: image, provider: provider, context: context, dark: dark)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Account-brand-\(provider.rawValue)-\(context.isCreating ? "create" : "manage")-\(dark ? "dark" : "light")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testExistingAccountDetailsAndSelectionUseTheConnectorBrand() async throws {
        let suite = "account-brand-details-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        for dark in [false, true] {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            for provider in AddAccountProvider.allCases {
                let account = account(provider)
                XCTAssertEqual(account.brandProvider, provider)
                let target = UIColor(provider.flowTheme.controlTint).resolvedColor(with: traits)
                let detail = try await render(NavigationStack {
                    AccountDetailView(accountID: account.id, initialAccount: account)
                }.environment(model), dark: dark)
                let logoColor = UIColor(provider.flowTheme.accent).resolvedColor(with: traits)
                // Longbridge's multicolor artwork uses mint bars; the cyan
                // action tint is intentionally a different part of its palette.
                let artworkColors = provider == .longbridge
                    ? [UIColor(red: 1.0 / 255, green: 218.0 / 255, blue: 181.0 / 255, alpha: 1)]
                    : [logoColor, target]
                XCTAssertGreaterThan(try matchingPixels(in: detail, colors: artworkColors), 80,
                                     "The centered \(provider.rawValue) logo retains its artwork colors")
                let attachment = XCTAttachment(image: detail)
                attachment.name = "Account-detail-\(provider.rawValue)-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
                if provider == .trading212 {
                    try detail.pngData()?.write(to: URL(fileURLWithPath: "/tmp/account-brand-detail-\(dark ? "dark" : "light").png"))
                    let manual = try await render(ManualTransactionView(account: account).environment(model), dark: dark)
                    XCTAssertGreaterThan(try matchingPixels(in: manual, colors: [target]), 80,
                                         "Manual entries retain the account brand in their controls")
                }

                for selected in [true, false] {
                    let row = try await render(SettingsSelectionRow(
                        isSelected: selected, title: account.localizedDisplayName,
                        selectionAccessibilityLabel: "Include account", toggle: {}
                    ).accountFlowBrand(account.brandProvider), dark: dark)
                    // Inspect only the selection column. Monochrome brands share
                    // their tint with the account title, even when unselected.
                    let selection = try XCTUnwrap(row.cgImage?.cropping(to: CGRect(
                        x: SettingsTemplate.rowHorizontalPadding * row.scale, y: 0,
                        width: SettingsTemplate.iconSize * row.scale,
                        height: row.size.height * row.scale)))
                    let coloredPixels = try matchingPixels(in: UIImage(cgImage: selection), colors: [target])
                    if selected {
                        XCTAssertGreaterThan(coloredPixels, 80, "Selected accounts use their connector's color")
                    } else {
                        let neutral = UIColor(CatfolioTheme.primaryText).resolvedColor(with: traits)
                        XCTAssertGreaterThan(try matchingPixels(in: UIImage(cgImage: selection), colors: [neutral]), 80,
                                             "Unselected circles use the neutral text color")
                        // For a monochrome provider, the brand tint is itself neutral.
                        if zip(rgb(neutral), rgb(target)).contains(where: { abs($0 - $1) > 0.2 }) {
                            XCTAssertEqual(coloredPixels, 0, "Unselected circles do not acquire a colored brand tint")
                        }
                    }
                }
            }
        }
    }

    func testButtonLabelsAndInlineControlsStayReadable() {
        for dark in [false, true] {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            let surface = SettingsTemplate.uiCard.resolvedColor(with: traits)
            for provider in AddAccountProvider.allCases {
                let theme = provider.flowTheme
                XCTAssertGreaterThanOrEqual(contrast(UIColor(theme.onAccent), UIColor(theme.accent)), 4.5,
                    "\(provider.rawValue) button label")
                XCTAssertGreaterThanOrEqual(contrast(UIColor(theme.controlTint).resolvedColor(with: traits), surface), 4.5,
                    "\(provider.rawValue) inline controls")
            }
        }
    }

    func testBrandScopeDoesNotLeakToOtherScreens() async throws {
        var captured: [String: Bool] = [:]
        _ = try await render(VStack {
            ThemeProbe { captured["outside"] = $0 != nil }
            ThemeProbe { captured["creation"] = $0 != nil }.accountFlowBrand(.moomoo)
            ThemeProbe { captured["management"] = $0 != nil }.accountFlowBrand(.moomoo)
            ThemeProbe { captured["unknown"] = $0 != nil }.accountFlowBrand(nil)
        }, dark: false)
        XCTAssertEqual(captured["outside"], false)
        XCTAssertEqual(captured["creation"], true)
        XCTAssertEqual(captured["management"], true)
        XCTAssertEqual(captured["unknown"], false)
    }

    /// The Trading 212 page marks setup as unfinished while it is shown. In the
    /// app's own defaults that flag outlived this test and reopened the setup
    /// sheet over every later test that shows the Account tab.
    private static let isolatedDefaults: UserDefaults = {
        let suite = "account-flow-theme-trading212"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()

    @ViewBuilder private func page(_ provider: AddAccountProvider, context: AccountConnectorContext) -> some View {
        switch provider {
        case .trading212: Trading212View(context: context, setupStore: Trading212SetupStore(
            defaults: Self.isolatedDefaults, read: { _ in nil }, write: { _, _ in }))
        case .ibkr: IBKRFlexView(context: context)
        case .moomoo: MoomooOAuthView(context: context)
        case .robinhood: RobinhoodConnectionView(context: context)
        case .snaptrade: SnapTradeView(context: context)
        case .longbridge: DirectBrokerAccountView(broker: .longbridge, context: context)
        case .alpaca: DirectBrokerAccountView(broker: .alpaca, context: context)
        case .csv: CSVImportView(context: context)
        case .screenshot: ScreenshotImportView(context: context)
        }
    }

    private func account(_ provider: AddAccountProvider) -> PortfolioAccount {
        let source: String = switch provider {
        case .trading212: "Trading 212"
        case .ibkr: "IBKR Flex"
        case .moomoo: "Moomoo"
        case .longbridge: "Longbridge"
        case .alpaca: "Alpaca"
        case .robinhood: "Robinhood"
        case .snaptrade: "SnapTrade"
        case .csv: "CSV"
        case .screenshot: "Screenshot"
        }
        return PortfolioAccount(id: "brand-test-\(provider.rawValue)", accountID: nil,
            source: source, name: "\(source) · Orange", baseCurrency: "USD", positionCount: 3,
            transactionCount: 8, manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 12500)
    }

    private func render<V: View>(_ content: V, dark: Bool) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: content.preferredColorScheme(dark ? .dark : .light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    /// Check the actual bottom action, including the native disabled glass state.
    private func verifyAction(in image: UIImage, provider: AddAccountProvider,
                              context: AccountConnectorContext, dark: Bool) throws {
        let title: String = switch provider {
        case .trading212: context.isCreating ? L10n.text("下一步") : L10n.text("读取")
        case .ibkr: context.isCreating ? L10n.text("下一步") : L10n.text("保存凭证")
        case .moomoo: L10n.text("登录 Moomoo")
        case .robinhood: L10n.text("生成桌面登录链接")
        case .snaptrade: context.isCreating ? L10n.text("下一步") : L10n.text("读取账户列表")
        case .longbridge, .alpaca: context.isCreating ? L10n.text("下一步") : L10n.text("预览持仓")
        case .csv: L10n.text("选择 CSV 文件")
        case .screenshot: L10n.text("选择持仓截图")
        }
        let cg = try XCTUnwrap(image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: cg).perform([request])
        func normalized(_ text: String) -> String { text.filter { $0.isLetter || $0.isNumber }.lowercased() }
        let action = try XCTUnwrap(request.results?.first {
            normalized($0.topCandidates(1).first?.string ?? "") == normalized(title)
                && $0.boundingBox.midY < 0.4
        }, "The primary action must remain visible near the bottom: \(provider), \(title). Recognized: \(request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])")
        let x = CGFloat(cg.width) * 48 / image.size.width
        let y = CGFloat(cg.height) * (1 - action.boundingBox.midY)
        let sample = try XCTUnwrap(cg.cropping(to: CGRect(x: x, y: y, width: 3, height: 3)))
        var pixels = [UInt8](repeating: 0, count: 4)
        let bitmap = try XCTUnwrap(CGContext(data: &pixels, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rgb = pixels.prefix(3).map { Double($0) / 255 }
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let brand = self.rgb(UIColor(provider.flowTheme.accent).resolvedColor(with: traits))
        let canvas = self.rgb(UIColor(CatfolioPalette.accountConnectionBackground).resolvedColor(with: traits))
        let preparation = context.isCreating && [.trading212, .ibkr, .longbridge, .alpaca, .snaptrade].contains(provider)
        let disabled = !preparation && [.trading212, .ibkr, .longbridge, .alpaca, .snaptrade].contains(provider)
        if #available(iOS 26.0, *), disabled {
            // Liquid Glass removes the fill tint when disabled. Verify the
            // neutral, visible action rather than the old alpha-blended fill.
            XCTAssertLessThan((rgb.max() ?? 0) - (rgb.min() ?? 0), 0.04,
                              "Empty credential forms must show a neutral disabled action")
            XCTAssertGreaterThan(abs(rgb.reduce(0, +) / 3 - canvas.reduce(0, +) / 3), 0.05,
                                 "The disabled action must remain distinguishable from its canvas")
            return
        }
        let opacity = disabled ? 0.3 : 1.0
        for index in 0..<3 {
            let expected = brand[index] * opacity + canvas[index] * (1 - opacity)
            XCTAssertEqual(rgb[index], expected, accuracy: 0.06,
                           "\(provider.rawValue) must use its own brand on the primary action")
        }
    }

    private func matchingPixels(in image: UIImage, colors: [UIColor]) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let targets = colors.map(rgb)
        var matches = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[offset + 3] > 250 else { continue }
            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            if targets.contains(where: {
                abs(red - $0[0]) < 0.10 && abs(green - $0[1]) < 0.10 && abs(blue - $0[2]) < 0.10
            }) {
                matches += 1
                // Enough color to distinguish a control from antialiasing;
                // do not scan the rest of a full-screen image after success.
                if matches > 80 { return matches }
            }
        }
        return matches
    }

    private func rgb(_ color: UIColor) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b)]
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            let values = rgb(color).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

private struct ThemeProbe: View {
    @Environment(\.accountFlowTheme) private var theme
    let record: (AccountFlowTheme?) -> Void

    var body: some View {
        Color.clear.frame(height: 1).onAppear { record(theme) }
    }
}
