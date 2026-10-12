import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountFlowThemeTests: XCTestCase {
    func testCreationAndManagementPagesRenderTheirBrandInBothAppearances() async throws {
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
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            for provider in AddAccountProvider.allCases {
                let theme = provider.flowTheme
                let targets = [theme.accent, theme.controlTint].map {
                    UIColor($0).resolvedColor(with: traits)
                }
                for context in [AccountConnectorContext.create, .manage(account(provider))] {
                    let image = try await render(page(provider, context: context).environment(model), dark: dark)
                    XCTAssertGreaterThan(try matchingPixels(in: image, colors: targets), 80,
                        "\(provider.rawValue) must retain its brand when managing an existing account")
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
                XCTAssertGreaterThan(try matchingPixels(in: detail, colors: [logoColor, target]), 80,
                                     "The centered account logo retains its brand color")
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
                    let coloredPixels = try matchingPixels(in: row, colors: [target])
                    if selected {
                        XCTAssertGreaterThan(coloredPixels, 80, "Selected accounts use their connector's color")
                    } else {
                        XCTAssertEqual(coloredPixels, 0, "Unselected circles remain neutral")
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

    @ViewBuilder private func page(_ provider: AddAccountProvider, context: AccountConnectorContext) -> some View {
        switch provider {
        case .trading212: Trading212View(context: context)
        case .ibkr: IBKRFlexView(context: context)
        case .moomoo: MoomooOAuthView(context: context)
        case .robinhood: RobinhoodConnectionView(context: context)
        case .snaptrade: SnapTradeView(context: context)
        case .csv: CSVImportView(context: context)
        }
    }

    private func account(_ provider: AddAccountProvider) -> PortfolioAccount {
        let source: String = switch provider {
        case .trading212: "Trading 212"
        case .ibkr: "IBKR Flex"
        case .moomoo: "Moomoo"
        case .robinhood: "Robinhood"
        case .snaptrade: "SnapTrade"
        case .csv: "CSV"
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
