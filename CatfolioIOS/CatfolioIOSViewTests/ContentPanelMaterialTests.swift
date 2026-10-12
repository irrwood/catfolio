import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ContentPanelMaterialTests: XCTestCase {
    func testSectionHeadersResolveToTranslucentBlackAndWhite() {
        for dark in [false, true] {
            for increased in [false, true] {
                let traits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
                    UITraitCollection(accessibilityContrast: increased ? .high : .normal)
                ])
                let color = SettingsTemplate.uiSectionHeader.resolvedColor(with: traits)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
                XCTAssertEqual(r, dark ? 1 : 0)
                XCTAssertEqual(g, r)
                XCTAssertEqual(b, r)
                XCTAssertEqual(a, increased ? 0.8 : 0.6, accuracy: 0.001)
            }
        }
    }

    func testOverviewTileUsesTheSharedPanel() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 190)
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let host = UIHostingController(rootView: HStack(spacing: 12) {
                SettingsHistoryOverviewTile(title: "Dividends", icon: .dividend, caption: "",
                                            value: "$1.00", valueColor: .primary)
                    .frame(height: 130)
                Color.clear.frame(height: 130).modifier(ContentPanelSurface())
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(SettingsTemplate.pageBackground).ignoresSafeArea().preferredColorScheme(scheme))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(300))
            let image = try save(window, name: "overview-tile-panel-\(scheme)")
            // Clear space in each: right of the tile's icon, above its figures.
            XCTAssertLessThan(try distance(pixel(image, x: 140, y: 65), pixel(image, x: 321, y: 65)), 0.02,
                              "\(scheme): the overview tile must be the page's panel, not glass")
        }
    }

    func testPanelPicksUpBackdropColourAndBlursItsDetail() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let blue = try await render(scheme: scheme, green: false)
            let green = try await render(scheme: scheme, green: true)
            let bluePixel = try pixel(blue, x: 160, y: 160)
            let greenPixel = try pixel(green, x: 160, y: 160)
            XCTAssertGreaterThan(bluePixel.b, bluePixel.r + 0.02, "Blue must come through the material")
            XCTAssertGreaterThan(greenPixel.g, greenPixel.r + 0.02, "Green must come through the same material")
            XCTAssertGreaterThan(distance(bluePixel, greenPixel), 0.03,
                                 "Panels must blend their backdrop rather than use a fixed fill")
            let exteriorDetail = try distance(pixel(blue, x: 17, y: 160), pixel(blue, x: 21, y: 160))
            let interiorDetail = try distance(pixel(blue, x: 153, y: 160), pixel(blue, x: 157, y: 160))
            XCTAssertGreaterThan(exteriorDetail, 0.1)
            XCTAssertLessThan(interiorDetail, exteriorDetail * 0.4, "Blur must remove fine detail behind the cells")
            let luminance = relativeLuminance(bluePixel)
            let contrast = scheme == .dark ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05
            XCTAssertGreaterThan(contrast, 4.5, "Primary cell text needs a readable backing")
        }
    }

    func testSubtitleInkStaysReadableOnTintedPanels() {
        let night = UITraitCollection(userInterfaceStyle: .dark)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        SettingsTemplate.uiSecondaryText.resolvedColor(with: night).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1); XCTAssertEqual(g, 1); XCTAssertEqual(b, 1)
        XCTAssertEqual(a, 0.6, accuracy: 0.001, "Night subtitles are translucent white")
        // The bluest night panel on Research: 12% white over the night glow.
        for panel in [(r: 31.0, g: 31.0, b: 31.0), (r: 64.0, g: 75.0, b: 93.0)] {
            let ink = (r: (255 * a + panel.r * (1 - a)) / 255, g: (255 * a + panel.g * (1 - a)) / 255,
                       b: (255 * a + panel.b * (1 - a)) / 255)
            let ground = (r: panel.r / 255, g: panel.g / 255, b: panel.b / 255)
            let contrast = (relativeLuminance(ink) + 0.05) / (relativeLuminance(ground) + 0.05)
            XCTAssertGreaterThan(contrast, 4.3, "Subtitle on \(panel)")
        }
        SettingsTemplate.uiSecondaryText.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 0); XCTAssertEqual(g, 0); XCTAssertEqual(b, 0)
        XCTAssertEqual(a, 0.5, accuracy: 0.001, "Day subtitles are translucent black")
        // A day panel over the home page's sky blue reads about (240, 250, 255).
        let ink = (r: 240 * 0.5 / 255, g: 250 * 0.5 / 255, b: 255 * 0.5 / 255)
        let contrast = (relativeLuminance((r: 240 / 255, g: 250 / 255, b: 1)) + 0.05) / (relativeLuminance(ink) + 0.05)
        XCTAssertGreaterThan(contrast, 3.5, "Day subtitle on a sky-tinted panel")
    }

    func testDisclosureInkIsTranslucent() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        SettingsTemplate.uiDisclosure.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual([r, g, b], [0, 0, 0])
        // On a white card: the drawing's #E0E0E0.
        XCTAssertEqual(255 * (1 - a), 0xE0, accuracy: 1)
        SettingsTemplate.uiDisclosure.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual([r, g, b], [1, 1, 1])
        XCTAssertEqual(a, 0.18, accuracy: 0.001)
    }

    func testPressedPanelLetsMoreOfThePageThrough() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let resting = try pixel(try await render(scheme: scheme, green: false), x: 160, y: 160)
            let pressed = try pixel(try await render(scheme: scheme, green: false, pressed: true), x: 160, y: 160)
            XCTAssertGreaterThan(distance(resting, pressed), 0.03, "\(scheme): the press must show")
            XCTAssertLessThan(relativeLuminance(pressed), relativeLuminance(resting),
                              "\(scheme): a pressed panel carries less white")
            XCTAssertGreaterThan(pressed.b, pressed.r, "\(scheme): the page's blue comes through")
        }
    }

    func testPressedRowIsTranslucentInk() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        SettingsTemplate.uiRowPressed.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual([r, g, b], [0, 0, 0])
        // On a white card: the drawing's #F7F7F7.
        XCTAssertEqual(255 * (1 - a), 0xF7, accuracy: 1)
        SettingsTemplate.uiRowPressed.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual([r, g, b], [1, 1, 1])
        // On a night panel (12% white over black, 31): about #2C2C2E.
        XCTAssertEqual(31 + (255 - 31) * a, 44, accuracy: 2)
    }

    func testNightPanelIsTranslucentWhiteOverTheNightGround() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 320)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: ZStack {
            Color.black
            ContentPanelMaterial(colorScheme: .dark, isOpaque: false, increasedContrast: false).padding(32)
        }.ignoresSafeArea().preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(220))
        let panel = try pixel(try save(window, name: "content-panel-night-ground"), x: 160, y: 160)
        // 12% white over black: the material's grey lift is taken back out.
        XCTAssertEqual(panel.r, 0.12, accuracy: 0.015)
        XCTAssertEqual(panel.g, panel.r, accuracy: 0.005)
        XCTAssertEqual(panel.b, panel.r, accuracy: 0.005)
        XCTAssertGreaterThan(1.05 / (relativeLuminance(panel) + 0.05), 4.5, "White text must stay readable")
    }

    func testOpaqueAndIncreasedContrastPanelsDoNotDependOnBackdrop() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for increased in [false, true] {
                let blue = try await render(scheme: scheme, green: false,
                                            opaque: !increased, increasedContrast: increased)
                let green = try await render(scheme: scheme, green: true,
                                             opaque: !increased, increasedContrast: increased)
                XCTAssertLessThan(try distance(pixel(blue, x: 160, y: 160), pixel(green, x: 160, y: 160)), 0.01)
            }
        }
    }

    func testGroupedPanelScrollRemainsResponsive() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(0..<24) { group in
                    SettingsCard {
                        ForEach(0..<3) { row in
                            HStack {
                                Text("Account \(group + 1) · \(row + 1)")
                                Spacer()
                                Text("$12,345.67").monospacedDigit()
                            }
                            .padding(20)
                        }
                    }
                }
            }.padding(16)
        }.background(PanelTestBackdrop(green: false)).preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(350))
        let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }
            .max(by: { $0.contentSize.height < $1.contentSize.height }))
        let clock = PanelFrameClock()
        clock.start()
        defer { clock.stop() }
        for frame in 0..<120 {
            scroll.setContentOffset(CGPoint(x: 0, y: 1400 * sin(.pi * Double(frame) / 119)
                                          - scroll.adjustedContentInset.top), animated: false)
            await clock.nextFrame()
        }
        clock.stop()
        let gaps = clock.gaps.sorted()
        XCTAssertGreaterThan(gaps.count, 100)
        let p95 = gaps[Int(Double(gaps.count) * 0.95)]
        print(String(format: "[ContentPanel] scroll p95=%.2fms", p95 * 1000))
        XCTAssertLessThan(p95, 0.05, "Grouped blur must not cause sustained scroll stalls")
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1)
        XCTAssertTrue(scroll.delaysContentTouches)
        try save(window, name: "content-panel-groups-dark")
    }

    private func render(scheme: ColorScheme, green: Bool, opaque: Bool = false,
                        increasedContrast: Bool = false, pressed: Bool = false) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 320)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        let host = UIHostingController(rootView: ZStack {
            PanelTestBackdrop(green: green)
            ContentPanelMaterial(colorScheme: scheme, isOpaque: opaque, increasedContrast: increasedContrast,
                                 isPressed: pressed)
                .padding(32)
        }.ignoresSafeArea().preferredColorScheme(scheme))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(220))
        return try save(window, name: "content-panel-\(scheme)-\(green ? "green" : "blue")-\(opaque ? "opaque" : "material")-\(increasedContrast)\(pressed ? "-pressed" : "")")
    }

    @discardableResult
    private func save(_ window: UIWindow, name: String) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        return image
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> (r: Double, g: Double, b: Double) {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let offset = (y * cg.width + x) * 4
        return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset + 2]) / 255)
    }
    private func distance(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
    }
    private func relativeLuminance(_ colour: (r: Double, g: Double, b: Double)) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(colour.r) + 0.7152 * linear(colour.g) + 0.0722 * linear(colour.b)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

private struct PanelTestBackdrop: View {
    let green: Bool
    var body: some View {
        Canvas { context, size in
            let base = green ? Color(red: 0.03, green: 0.45, blue: 0.22) : Color(red: 0.03, green: 0.3, blue: 0.62)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            for x in stride(from: 0.0, to: size.width, by: 8) {
                context.fill(Path(CGRect(x: x, y: 0, width: 4, height: size.height)), with: .color(.white.opacity(0.3)))
            }
        }.ignoresSafeArea()
    }
}

@MainActor
private final class PanelFrameClock {
    private var link: CADisplayLink?
    private var waiter: CheckedContinuation<Void, Never>?
    private var last: CFTimeInterval?
    var gaps: [Double] = []
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil; waiter?.resume(); waiter = nil }
    func nextFrame() async { await withCheckedContinuation { waiter = $0 } }
    @objc private func tick() {
        let now = CACurrentMediaTime()
        if let last { gaps.append(now - last) }
        last = now
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
}
