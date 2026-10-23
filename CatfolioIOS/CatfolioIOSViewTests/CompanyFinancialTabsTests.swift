import SwiftUI
import Vision
import XCTest
@testable import CatfolioIOS

@MainActor
final class CompanyFinancialTabsTests: XCTestCase {
    func testStatementTabsStayOnOneLineAtPhoneAndAccessibilitySizes() async throws {
        let savedLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(savedLanguage, forKey: AppLanguage.preferenceKey) }
        let directory = URL(fileURLWithPath: "/tmp/catfolio-financial-tabs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            for width: CGFloat in [280, 362] {
                for large in [false, true] {
                    let host = UIHostingController(rootView:
                        CompanyFinancialStatementTabs(selection: .constant(.cashFlow))
                            .frame(width: width)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .background(Color.white)
                            .environment(\.colorScheme, .light)
                            .environment(\.locale, Locale(identifier: language))
                            .environment(\.dynamicTypeSize, large ? .accessibility2 : .large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color.white)
                            .ignoresSafeArea())
                    window.frame = CGRect(x: 0, y: 0, width: width + 20, height: 180)
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    try await Task.sleep(for: .milliseconds(150))
                    host.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = language == "en" ? ["en-US"] : ["zh-Hans", "en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                    let boxes = try XCTUnwrap(request.results).map(\.boundingBox)
                    XCTAssertFalse(boxes.isEmpty, "Tabs must remain visible")
                    // All recognized labels must share a vertical band; a
                    // wrapped word would produce a second line below it.
                    let centers = boxes.map(\.midY)
                    let spread = (centers.max() ?? 0) - (centers.min() ?? 0)
                    XCTAssertLessThan(spread * image.size.height, 6,
                                      "\(language), width=\(width), accessibility=\(large)")
                    if language == "en", width == 362, !large {
                        let text = request.results!.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        for title in ["Income", "Revenue", "Balance", "Cash flow"] {
                            XCTAssertTrue(text.contains(title), "Every tab should fit at standard size: \(text)")
                        }
                    }
                    try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(
                        "\(language)-\(Int(width))-\(large ? "large" : "regular").png"))
                }
            }
        }
    }

    func testRevenueSegmentsHaveDistinctColorsThatFollowNamesAcrossPeriods() throws {
        func period(_ fy: Int, _ items: [(String, Double)]) -> RevenueSegmentCatalog.Period {
            .init(fy: fy, date: "\(fy)-12-31", currency: "USD", revenue: 100,
                  items: items.map { .init(name: $0.0, value: $0.1) }, unallocated: nil,
                  eliminations: nil, overlap: nil)
        }
        let first = period(2025, [("iPhone", 45), ("Services", 25), ("Mac", 15), ("iPad", 10), ("Wearables", 5)])
        let second = period(2024, [("Services", 35), ("iPhone", 30), ("Wearables", 15), ("Mac", 12), ("iPad", 8)])
        let palette = RevenueSegmentColors(periods: [first, second])
        let reversed = RevenueSegmentColors(periods: [second, first])
        let rows = SegmentFlowDiagram.rows(for: first)
        for (index, row) in rows.enumerated() {
            let color = UIColor(palette.color(for: row))
            XCTAssertEqual(color, UIColor(reversed.color(for: row)))
            for other in rows.dropFirst(index + 1) {
                XCTAssertNotEqual(color, UIColor(palette.color(for: other)))
            }
        }
        let directory = URL(fileURLWithPath: "/tmp/catfolio-financial-tabs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let renderer = ImageRenderer(content: VStack(spacing: 20) {
                SegmentFlowDiagram(period: first, colors: palette)
                SegmentRows(period: first, colors: palette)
            }.frame(width: 362).padding(20)
                .foregroundStyle(dark ? Color.white : Color.black)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("segments-\(dark ? "dark" : "light").png"))
        }
    }
}
