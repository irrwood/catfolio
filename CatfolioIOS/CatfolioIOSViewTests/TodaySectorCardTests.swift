import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class TodaySectorCardTests: XCTestCase {
    func testAmountsOnlyKeepCentsBelowOneDisplayedCurrencyUnit() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DisplayCurrency.preferenceKey)
        defer { defaults.set(previous, forKey: DisplayCurrency.preferenceKey) }
        defaults.set("USD", forKey: DisplayCurrency.preferenceKey)
        for (amount, expected) in [(12.34, "+$12"), (12.75, "+$13"), (-12.34, "-$12"),
                                   (1, "+$1"), (-1, "-$1"), (0, "+$0"),
                                   (0.01, "+$0.01"), (-0.01, "-$0.01"), (0.5, "+$0.50"),
                                   (0.99, "+$0.99")] {
            XCTAssertEqual(TodaySectorRow.amountText(amount), expected)
        }
        defaults.set("JPY", forKey: DisplayCurrency.preferenceKey)
        let rate = try XCTUnwrap(LocalPortfolioEngine.usdRate(for: "JPY"))
        XCTAssertTrue(TodaySectorRow.amountText(12.34 * rate).hasSuffix("12"),
                      "Choose precision after display-currency conversion, even when the USD amount is below one")
        XCTAssertTrue(TodaySectorRow.amountText(0.01 * rate).hasSuffix("0.01"))
    }

    func testSectorIconTonesStayOpaqueAndReadableInBothAppearances() {
        let sectors: [PortfolioSector?] = PortfolioSector.allCases.map { $0 } + [nil]
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            for sector in sectors {
                let colors = CatfolioTheme.sectorIconColors(for: sector, scheme: scheme)
                let foreground = colors.foreground.resolve(in: environment)
                let background = colors.background.resolve(in: environment)
                XCTAssertEqual(foreground.opacity, 1)
                XCTAssertEqual(background.opacity, 1, "The circle must be a solid colour")
                let a = luminance(foreground), b = luminance(background)
                XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 3,
                    "The small icon must remain readable: \(String(describing: sector)), \(scheme)")
            }
        }
    }

    private func luminance(_ color: Color.Resolved) -> Double {
        func linear(_ channel: Float) -> Double {
            let c = Double(channel)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    func testRenderedBarsDivergeFromZeroOnTheSameMagnitudeScale() throws {
        for (amount, maximum, expectedStart, expectedWidth) in [
            (100.0, 100.0, 100, 100), (50, 100, 100, 50),
            (-25, 100, 75, 25), (-100, 100, 0, 100),
            (0, 100, 100, 0), (0, 0, 100, 0)
        ] {
            let coloredColumns = try renderedColumns(amount: amount, maximum: maximum)
            XCTAssertEqual(Double(coloredColumns.count), Double(expectedWidth), accuracy: 2,
                           "The rendered bar must encode absolute amount on the shared scale")
            if expectedWidth > 0 {
                XCTAssertEqual(Double(try XCTUnwrap(coloredColumns.first)), Double(expectedStart), accuracy: 2,
                               "Losses extend left and gains extend right from the common zero axis")
                XCTAssertEqual(Double(try XCTUnwrap(coloredColumns.last)),
                               Double(expectedStart + expectedWidth - 1), accuracy: 2)
            } else {
                XCTAssertTrue(coloredColumns.isEmpty, "Zero must not draw a coloured bar")
            }
        }
    }

    func testEveryTrackKeepsACenteredZeroMarkerAndSubtleBackground() throws {
        for scheme in [ColorScheme.light, .dark] {
            for amount in [-100.0, -25, 0, 25, 100] {
                let pixels = try renderedPixels(amount: amount, maximum: 100, scheme: scheme)
                func brightness(_ x: Int, _ y: Int) -> Double {
                    let index = (y * 200 + x) * 4
                    return pixels[index..<index + 3].map(Double.init).reduce(0, +) / 3
                }
                // The zero tick stays inside the track's height in every row.
                let background = brightness(20, 7)
                let marker = brightness(100, 12)
                XCTAssertGreaterThan(abs(marker - background), 100)
                for y in [0, 7, 16, 23] {
                    XCTAssertEqual(brightness(100, y), background, accuracy: 1,
                                   "The marker must not extend above or below the eight-point track")
                }
                let emptySide = amount <= 0 ? 180 : 20
                let track = brightness(emptySide, 12)
                XCTAssertGreaterThan(abs(track - background), 2, "Even zero values retain a visible track")
                XCTAssertLessThan(abs(track - background), 35, "The neutral track must stay very subtle")
                if scheme == .light {
                    XCTAssertLessThan(marker, background, "The light appearance uses a black zero tick")
                } else {
                    XCTAssertGreaterThan(marker, background, "The dark appearance keeps the zero tick readable")
                }
            }
        }
    }

    func testGradientIntensifiesAwayFromZeroOnTheSharedScale() throws {
        for scheme in [ColorScheme.light, .dark] {
            for sign in [-1.0, 1.0] {
                let full = try renderedPixels(amount: sign * 100, maximum: 100, scheme: scheme)
                let short = try renderedPixels(amount: sign * 25, maximum: 100, scheme: scheme)
                func channel(_ pixels: [UInt8], x: Int, _ component: Int) -> Int {
                    Int(pixels[(12 * 200 + x) * 4 + component])
                }
                let near = sign > 0 ? 110 : 89
                let far = sign > 0 ? 190 : 9
                XCTAssertGreaterThan(channel(full, x: far, 2) - channel(full, x: near, 2), 60,
                                     "Blue increases towards teal for gains and violet for losses")
                for component in 0..<3 {
                    XCTAssertEqual(channel(full, x: near, component), channel(short, x: near, component),
                                   accuracy: 2, "Equal magnitudes must have equal colours on short and long bars")
                }
                if sign > 0 {
                    XCTAssertGreaterThan(channel(full, x: far, 1), channel(full, x: far, 0) + 60)
                    XCTAssertEqual(channel(full, x: far, 1), channel(full, x: far, 2), accuracy: 30)
                } else {
                    XCTAssertGreaterThan(channel(full, x: far, 0), channel(full, x: far, 1) + 60)
                    XCTAssertGreaterThan(channel(full, x: far, 2), channel(full, x: far, 1) + 60)
                }
            }
        }
    }

    private func renderedColumns(amount: Double, maximum: Double) throws -> [Int] {
        let pixels = try renderedPixels(amount: amount, maximum: maximum)
        return (0..<200).filter { x in
            let index = (Int(TodaySectorBar.height / 2) * 200 + x) * 4
            let channels = pixels[index..<index + 3].map(Int.init)
            return channels.max()! - channels.min()! > 40
        }
    }

    private func renderedPixels(amount: Double, maximum: Double, scheme: ColorScheme = .light) throws -> [UInt8] {
        let renderer = ImageRenderer(content:
            TodaySectorBar(amount: amount, largestMagnitude: maximum,
                           tint: amount < 0 ? CatfolioTheme.danger : CatfolioTheme.positive)
                .frame(width: 200, height: TodaySectorBar.height)
                .background(SettingsTemplate.card)
                .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let bitmap = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: 200 * Int(TodaySectorBar.height) * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 200, height: Int(TodaySectorBar.height),
            bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: 200, height: TodaySectorBar.height))
        return pixels
    }

    func testSectorCardFitsLanguagesSchemesAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
        }
        let rows = PortfolioSector.allCases.enumerated().map { index, sector in
            TodayDetailView.SectorBreakdown(sector: sector,
                amount: index.isMultiple(of: 2) ? 100 - Double(index * 7) : -Double(index * 7),
                components: [])
        } + [.init(sector: nil, amount: 0, components: [])]
        for (language, width, scheme, size, lossesFirst) in [
            ("zh-Hans", CGFloat(393), ColorScheme.light, DynamicTypeSize.large, false),
            ("zh-Hans", 393, .light, .large, true),
            ("en", 320, .dark, .large, false),
            ("en", 320, .light, .accessibility3, true)
        ] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            let scenarioRows = rows.map { row in
                TodayDetailView.SectorBreakdown(sector: row.sector,
                    amount: lossesFirst ? -row.amount : row.amount, components: row.components)
            }
            let host = UIHostingController(rootView: ScrollView {
                TodaySectorCard(rows: scenarioRows, onSelect: { _ in })
                    .settingsCardSurface()
                    .padding(CatfolioStyle.pageHorizontalInset)
            }.background(SettingsTemplate.pageBackground)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, size)
                .preferredColorScheme(scheme))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(200))
            host.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(scrollView(in: host.view))
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = "today-sectors-\(language)-\(scheme)-\(size)" + (lossesFirst ? "-losses" : "")
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))

        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}
