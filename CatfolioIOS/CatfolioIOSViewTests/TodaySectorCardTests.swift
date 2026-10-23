import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class TodaySectorCardTests: XCTestCase {
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

    func testRenderedGroupCentersItsOccupiedRangeAndKeepsOneProportionalScale() throws {
        let scenarios: [[Double]] = [[-100, -50], [100, 50], [-100, 10], [-10, 100],
                                     [-100, 100, 0], [0, 0], []]
        for amounts in scenarios {
            let maximum = amounts.map { abs($0) }.max() ?? 0
            let zero = TodaySectorBar.centeredZeroFraction(for: amounts)
            var occupied: [Int] = []
            for amount in amounts {
                let columns = try renderedColumns(amount: amount, maximum: maximum, zeroFraction: zero)
                occupied.append(contentsOf: columns)
                XCTAssertEqual(Double(columns.count), maximum > 0 ? abs(amount) / maximum * 100 : 0, accuracy: 2,
                               "Centering translates bars without changing their relative lengths")
                if amount != 0 {
                    let edge: Int
                    if amount < 0 {
                        edge = try XCTUnwrap(columns.last) + 1
                    } else {
                        edge = try XCTUnwrap(columns.first)
                    }
                    XCTAssertEqual(Double(edge), Double(zero * 200), accuracy: 1,
                                   "Every bar must still meet the same zero axis")
                }
            }
            if maximum > 0 {
                let left = try XCTUnwrap(occupied.min())
                let right = try XCTUnwrap(occupied.max()) + 1
                XCTAssertEqual(Double(left + right) / 2, 100, accuracy: 1,
                               "The whole occupied range must center in its column: \(amounts)")
                XCTAssertGreaterThanOrEqual(left, 0)
                XCTAssertLessThanOrEqual(right, 200)
            } else {
                XCTAssertTrue(occupied.isEmpty)
                XCTAssertEqual(zero, 0.5)
            }
        }
    }

    private func renderedColumns(amount: Double, maximum: Double, zeroFraction: CGFloat = 0.5) throws -> [Int] {
        let renderer = ImageRenderer(content:
            TodaySectorBar(amount: amount, largestMagnitude: maximum, tint: .green, zeroFraction: zeroFraction)
                .frame(width: 200, height: TodaySectorBar.height).background(.white))
        renderer.scale = 1
        let bitmap = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: 200 * Int(TodaySectorBar.height) * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 200, height: Int(TodaySectorBar.height),
            bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: 200, height: TodaySectorBar.height))
        return (0..<200).filter { x in
            let index = (Int(TodaySectorBar.height / 2) * 200 + x) * 4
            return Int(pixels[index + 1]) - Int(pixels[index]) > 30
        }
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
