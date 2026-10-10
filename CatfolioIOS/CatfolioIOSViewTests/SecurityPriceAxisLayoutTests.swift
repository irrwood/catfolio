import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class SecurityPriceAxisLayoutTests: XCTestCase {
    private final class FrameCapture {
        var frames: [String: CGRect] = [:]
    }

    func testShortPricesKeepTheOriginalFontAndColumn() {
        let layout = fit(["114", "105"])
        XCTAssertEqual(layout.fontSize, TypeScale.footnote.size)
        XCTAssertEqual(layout.width, 49)
    }

    func testLongerPricesShrinkBeforeTakingSpaceFromThePlot() throws {
        let label = "12,345"
        let layout = fit([label, "12,400"])
        XCTAssertLessThan(layout.fontSize, TypeScale.footnote.size)
        XCTAssertGreaterThan(layout.fontSize, TypeScale.nano.size)
        XCTAssertEqual(layout.width, 49)
        try assertTextFits(label, layout: layout)
    }

    func testVeryLongPricesWidenOnlyAfterReachingTheMinimumFont() throws {
        let label = "1,234,567.89"
        let layout = fit(["114", label])
        XCTAssertEqual(layout.fontSize, TypeScale.nano.size)
        XCTAssertGreaterThan(layout.width, 49)
        try assertTextFits(label, layout: layout)
    }

    func testAxisLayoutRefreshesWhenLabelsOrTextSizeChange() {
        let cache = SecurityPricePlotSeriesCache()
        func key(_ label: String, size: CGFloat = 14) -> SecurityPriceAxisLayout.Key {
            .init(labels: [label], preferredFontSize: size, minimumFontSize: size * 10 / 14)
        }
        let short = cache.axisLayout(for: key("114"))
        let long = cache.axisLayout(for: key("1,234,567.89"))
        XCTAssertGreaterThan(long.width, short.width)
        let accessible = cache.axisLayout(for: key("1,234,567.89", size: 28))
        XCTAssertGreaterThan(accessible.fontSize, long.fontSize)
        XCTAssertGreaterThan(accessible.width, long.width)
        XCTAssertEqual(cache.axisLayout(for: key("114")).width, short.width)
    }

    func testPriceAndCostLabelsStayInsideTheAxisAtPhoneWidthsAndLargeType() async throws {
        let cases: [(String, Double, Double)] = [
            ("short", 114.02, 105),
            ("shrink", 12_345.67, 12_400),
            ("widen", 1_234_567.89, 1_230_000),
            ("offscale-above", 114.02, 1_234_567.89),
            ("offscale-below", 1_234_567.89, 123_456.78),
            ("fractional", 0.01234, 0.01)
        ]
        for (name, price, cost) in cases {
            let history = SecurityPriceHistory(ticker: "TEST", currency: "USD", points: [
                .init(dateText: "2026-09-21", close: price * 0.96),
                .init(dateText: "2026-09-22", close: price * 1.02),
                .init(dateText: "2026-09-23", close: price)
            ], intradayPoints: [], trades: [])
            let data = SecurityPriceRangeData(history: history, range: .maximum,
                                             averageCost: cost, selectedAccountKeys: [])
            for width: CGFloat in [320, 402] {
                for large in [false, true] {
                    let plot = SecurityPricePlot(data: data, currency: "USD", appearanceID: UUID().uuidString,
                        transitionKey: "test", selectedPoint: nil, measuredRange: nil,
                        selectionIndicatorLabel: nil, onSelect: { _ in }, onMeasure: { _ in },
                        onInteractionEnded: { _ in })
                        .frame(height: SecurityPriceChartState.plotHeight)
                    let frames = try await measure(plot, width: width, large: large,
                        snapshot: width == 320 && ["shrink", "widen", "offscale-above"].contains(name)
                            ? "price-axis-\(name)-\(large ? "large" : "regular")" : nil)
                    let chart = try XCTUnwrap(frames["standard-chart.plot"])
                    let labels = frames.filter {
                        $0.key.hasPrefix("standard-chart.axis.") || $0.key == "security-price.axis.offscale"
                    }
                    XCTAssertFalse(labels.isEmpty)
                    XCTAssertGreaterThan(chart.width, width * 0.5, "The price plot must remain usable")
                    for (key, label) in labels {
                        XCTAssertGreaterThanOrEqual(label.minX, chart.maxX + 2,
                            "\(name) \(large) \(key) must not intrude into the plot")
                        XCTAssertLessThanOrEqual(label.maxX, width - 2,
                            "\(name) \(large) \(key) must not run off the screen")
                    }
                }
            }
        }
    }

    private func fit(_ labels: [String]) -> SecurityPriceAxisLayout {
        .init(.init(labels: labels, preferredFontSize: TypeScale.footnote.size,
                    minimumFontSize: TypeScale.nano.size))
    }

    private func assertTextFits(_ label: String, layout: SecurityPriceAxisLayout) throws {
        let renderer = ImageRenderer(content: Text(label)
            .font(Typography.number(size: layout.fontSize, weight: .semibold)).fixedSize())
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertLessThanOrEqual(image.size.width, layout.width - 6,
                                "Measure the actual rendered font, not a character-count estimate")
    }

    private func measure<V: View>(_ view: V, width: CGFloat, large: Bool,
                                  snapshot: String?) async throws -> [String: CGRect] {
        let captured = FrameCapture()
        let host = UIHostingController(rootView: view
            .frame(width: width)
            .overlayPreferenceValue(ResearchCardLayoutFrames.self) { anchors in
                GeometryReader { geometry in
                    let frames = anchors.mapValues { geometry[$0] }
                    Color.clear.onAppear { captured.frames = frames }
                        .onChange(of: frames) { _, new in captured.frames = new }
                }.allowsHitTesting(false)
            }
            .environment(\.dynamicTypeSize, large ? .accessibility2 : .large)
            .environment(\.colorScheme, large ? .dark : .light)
            .background(large ? Color.black : Color.white))
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = large ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.frame = CGRect(origin: .zero, size: host.sizeThatFits(in: CGSize(width: width, height: 900)))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(70))
        if let snapshot {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = snapshot
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return captured.frames
    }
}
