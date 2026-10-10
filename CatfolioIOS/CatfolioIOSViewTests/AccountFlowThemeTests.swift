import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountFlowThemeTests: XCTestCase {
    func testEveryCreationPageRendersItsOwnBrandInBothAppearances() async throws {
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
                let image = try await render(page(provider).environment(model), dark: dark)
                let theme = provider.flowTheme
                let targets = [theme.accent, theme.controlTint].map {
                    UIColor($0).resolvedColor(with: traits)
                }
                XCTAssertGreaterThan(try matchingPixels(in: image, colors: targets), 80,
                    "\(provider.rawValue) must render its brand on the actual creation screen")
                let attachment = XCTAttachment(image: image)
                attachment.name = "Account-brand-\(provider.rawValue)-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
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
            ThemeProbe { captured["management"] = $0 != nil }.accountFlowBrand(.moomoo, enabled: false)
        }, dark: false)
        XCTAssertEqual(captured["outside"], false)
        XCTAssertEqual(captured["creation"], true)
        XCTAssertEqual(captured["management"], false)
    }

    @ViewBuilder private func page(_ provider: AddAccountProvider) -> some View {
        switch provider {
        case .trading212: Trading212View(context: .create)
        case .ibkr: IBKRFlexView(context: .create)
        case .moomoo: MoomooOAuthView(context: .create)
        case .robinhood: RobinhoodConnectionView(context: .create)
        case .snaptrade: SnapTradeView(context: .create)
        case .csv: CSVImportView(context: .create)
        }
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
        return stride(from: 0, to: pixels.count, by: 4).filter { offset in
            targets.contains { target in
                (0..<3).allSatisfy { abs(Double(pixels[offset + $0]) / 255 - target[$0]) < 0.10 }
            }
        }.count
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
