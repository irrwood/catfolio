import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
private final class ResearchLayoutCapture {
    var frames: [String: CGRect] = [:]
}

final class ResearchCardLayoutTests: XCTestCase {
    @MainActor
    func testInsiderAndAnalystCardsFitBothWidthsAndLanguagesAtLargeType() async throws {
        for language in ["zh-Hans", "en"] {
            for width in [320.0, 393.0] {
                for type in [DynamicTypeSize.large, .accessibility2] {
                    let result = try await capture(width: width, language: language, type: type,
                        name: "research-summary-\(language)-\(Int(width))-\(type)") {
                        VStack(spacing: 24) {
                            InsiderTradesSummaryCard(snapshot: insiderFixture)
                                .padding(.horizontal, 20)
                            HoldingDetailDisclosureCard(title: L10n.text("分析师一致预期"),
                                subtitle: L10n.text("评级、目标价与分析师覆盖 · 按需读取"), isExpanded: .constant(true)) {
                                AnalystConsensusContent(data: self.analystFixture)
                                    .researchLayoutFrame("analyst.bounds")
                            }
                            .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                        }
                    }
                    let netLabel = try XCTUnwrap(result.frames["insider.net.label"])
                    XCTAssertGreaterThan(netLabel.width, 24, "The transaction label must have usable space")
                    XCTAssertLessThanOrEqual(netLabel.height, singleLineHeight(type: type) + 4,
                        "The fixed amount columns must not squeeze the label into a vertical word")

                    let analystBounds = try XCTUnwrap(result.frames["analyst.bounds"])
                    let amounts = result.frames.filter { $0.key.hasPrefix("analyst.value.") }.map(\.value)
                    XCTAssertEqual(amounts.count, 4, "All four target/quote values must be present")
                    for amount in amounts {
                        XCTAssertGreaterThanOrEqual(amount.minX, analystBounds.minX - 1)
                        XCTAssertLessThanOrEqual(amount.maxX, analystBounds.maxX + 1)
                        XCTAssertLessThanOrEqual(amount.height, singleLineHeight(type: type) + 4,
                            "A complete price must remain on one line")
                    }
                    let rating = try XCTUnwrap(result.frames["analyst.rating.bearish"])
                    XCTAssertLessThanOrEqual(rating.height, singleLineHeight(type: type) + 4,
                        "Rating counts and their labels should not fragment on narrow screens")
                    let source = try XCTUnwrap(result.frames["analyst.source"])
                    XCTAssertLessThanOrEqual(source.maxX, analystBounds.maxX + 1)
                    if language == "en", width == 320, type == .accessibility2 {
                        XCTAssertGreaterThan(source.height, singleLineHeight(type: type),
                            "The large retrieval date must wrap rather than end in an ellipsis")
                    }
                }
            }
        }
    }

    @MainActor
    func testEarningsLegendAndQuarterCellsGrowTogetherWithoutOverlapping() async throws {
        for language in ["zh-Hans", "en"] {
            for width in [320.0, 393.0] {
                let revenue = width == 393
                let snapshot = earningsFixture(count: revenue ? 16 : 4)
                var normalFrames: [String: CGRect] = [:]
                for type in [DynamicTypeSize.large, .accessibility2] {
                    let result = try await capture(width: width, language: language, type: type,
                        name: "research-earnings-\(language)-\(Int(width))-\(type)-\(revenue ? "revenue16" : "eps4")") {
                        HoldingDetailDisclosureCard(title: L10n.text("盈利历史"),
                            subtitle: L10n.text("每股收益与收入 · 实际对比预期"), isExpanded: .constant(true)) {
                            EarningsHistoryContent(symbol: "LAYOUT", snapshot: snapshot,
                                revenue: .constant(revenue), loading: false, errorMessage: nil)
                        }
                        .padding(.horizontal, HoldingDetailCardStyle.pageInset)
                    }
                    let chart = try XCTUnwrap(result.frames["earnings.chart"])
                    for point in snapshot.observations {
                        let label = try XCTUnwrap(result.frames["earnings.quarter.label.\(point.id)"])
                        let cell = try XCTUnwrap(result.frames["earnings.quarter.cell.\(point.id)"])
                        XCTAssertGreaterThanOrEqual(label.minX, cell.minX - 1)
                        XCTAssertLessThanOrEqual(label.maxX, cell.maxX + 1,
                            "Scaling the quarter font must also widen its chart column")
                        XCTAssertLessThanOrEqual(label.maxY, chart.maxY + 2,
                            "The horizontal scroll viewport must reserve the scaled axis height")
                    }
                    if type == .large {
                        normalFrames = result.frames
                    } else {
                        let regularLegend = try XCTUnwrap(normalFrames["earnings.legend.估计"])
                        let largeLegend = try XCTUnwrap(result.frames["earnings.legend.估计"])
                        XCTAssertGreaterThan(largeLegend.height, regularLegend.height * 1.2)
                        let first = try XCTUnwrap(snapshot.observations.first)
                        let regularQuarter = try XCTUnwrap(normalFrames["earnings.quarter.label.\(first.id)"])
                        let largeQuarter = try XCTUnwrap(result.frames["earnings.quarter.label.\(first.id)"])
                        XCTAssertGreaterThan(largeQuarter.height, regularQuarter.height * 1.2)
                        XCTAssertGreaterThan(chart.height, try XCTUnwrap(normalFrames["earnings.chart"]).height)
                    }
                }
            }
        }
    }

    private var analystFixture: AnalystConsensusData {
        AnalystConsensusData(ratings: RatingSpread(bearish: 12, neutral: 34, bullish: 56),
            consensus: "Strong Buy", low: 1_234.56, mean: 2_000, high: 3_456.78, current: 1_900,
            source: "FMP", fetchedAt: Date(timeIntervalSince1970: 1_790_035_200), warnings: [])
    }

    private var insiderFixture: InsiderTradesSnapshot {
        let now = Date()
        let trades = [
            InsiderTrade(id: "buy", insider: "ALEXANDER SAMPLE", relation: "Officer",
                date: now.addingTimeInterval(-20 * 86_400), nasdaqType: "Buy", kind: .buy,
                ownType: "Direct", shares: 123_456, price: 123.45, sharesHeld: nil),
            InsiderTrade(id: "sell", insider: "ELIZABETH SAMPLE", relation: "Director",
                date: now.addingTimeInterval(-70 * 86_400), nasdaqType: "Sell", kind: .sell,
                ownType: "Direct", shares: 7_654, price: 123.45, sharesHeld: nil),
            InsiderTrade(id: "older", insider: "ALEXANDER SAMPLE", relation: "Officer",
                date: now.addingTimeInterval(-200 * 86_400), nasdaqType: "Sell", kind: .sell,
                ownType: "Direct", shares: 53_456, price: 134.56, sharesHeld: nil)
        ]
        return InsiderTradesSnapshot(trades: trades, totalRecords: trades.count, fetchedAt: now)
    }

    private func earningsFixture(count: Int) -> EarningsSnapshot {
        let observations = (0..<count).map { index in
            EarningsObservation(date: String(format: "%04d-%02d-25", 2022 + index / 4, 1 + (index % 4) * 3),
                period: nil, epsActual: 1.2 + Double(index % 3) * 0.2, epsEstimated: 1.3,
                revenueActual: 4e9 + Double(index % 3) * 2e8, revenueEstimated: 4.1e9)
        }
        return EarningsSnapshot(observations: observations, source: "Layout fixture", fetchedAt: .now, note: nil)
    }

    @MainActor
    private func singleLineHeight(type: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: type == .large ? .large : .accessibilityLarge)
        let size = UIFontMetrics(forTextStyle: .callout).scaledValue(for: 15, compatibleWith: traits)
        return UIFont.systemFont(ofSize: size).lineHeight
    }

    @MainActor
    private func capture<Content: View>(width: CGFloat, language: String, type: DynamicTypeSize,
                                      name: String, @ViewBuilder content: () -> Content) async throws -> ResearchLayoutCapture {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
        defer {
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let captured = ResearchLayoutCapture()
        let host = UIHostingController(rootView: content()
            .frame(width: width)
            .padding(.vertical, 16)
            .overlayPreferenceValue(ResearchCardLayoutFrames.self) { anchors in
                GeometryReader { geometry in
                    let resolved = anchors.mapValues { geometry[$0] }
                    Color.clear
                        .onAppear { captured.frames = resolved }
                        .onChange(of: resolved) { _, frames in captured.frames = frames }
                }
                .allowsHitTesting(false)
            }
            .background(Color(uiColor: .systemBackground))
            .fontDesign(.rounded)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, type)
            .environment(\.colorScheme, .light))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: width, height: 5_000))
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        host.view.layoutIfNeeded()
        XCTAssertEqual(size.width, width, accuracy: 0.5)
        XCTAssertFalse(captured.frames.isEmpty)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return captured
    }
}
