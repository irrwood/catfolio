import SwiftUI
import XCTest
@testable import CatfolioIOS

final class VolumeProfileLayoutRegressionTests: XCTestCase {
    func testEnglishVolumeSummarySeparatesSentencesAndFragments() {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        let summary = VolumeProfileInterpretation.result(sessions: 60, quote: 100,
            valueAreaLow: 92, valueAreaHigh: 108, pointOfControl: 100, cost: 100).text
        XCTAssertTrue(summary.contains("the past 60 trading days and close to peak volume."))
        XCTAssertTrue(summary.contains("volume. Your holding cost"))
        XCTAssertFalse(summary.contains("daysand"))
    }

    private func markers(width: CGFloat, peakY: CGFloat, costY: CGFloat, currentY: CGFloat)
        -> [VolumeProfileMarkerLayout.Marker] {
        let pillWidth = min(width * 0.42, 111)
        let rightX = width - pillWidth / 2
        return [
            .init(id: "peak", centerX: 58, width: 104, anchorY: peakY),
            .init(id: "cost", centerX: rightX, width: pillWidth, anchorY: costY),
            .init(id: "current", centerX: abs(currentY - costY) < 28 ? rightX - pillWidth - 6 : rightX,
                  width: pillWidth, anchorY: currentY),
        ]
    }

    func testThreeCoincidentOrNearbyPricesKeepEveryLabelReadable() throws {
        for width in [CGFloat(248), 321] {
            for anchors in [(150.0, 150.0, 150.0), (150, 155, 145), (2, 3, 4), (300, 301, 302)] {
                let markers = markers(width: width, peakY: anchors.0, costY: anchors.1, currentY: anchors.2)
                let frames = VolumeProfileMarkerLayout.frames(for: markers, height: 303)
                XCTAssertEqual(frames.count, 3)
                for marker in markers {
                    let frame = try XCTUnwrap(frames[marker.id])
                    XCTAssertGreaterThanOrEqual(frame.minY, 0)
                    XCTAssertLessThanOrEqual(frame.maxY, 303)
                    XCTAssertEqual(frame.midX, marker.centerX, "Price labels keep their original side of the chart")
                    for (otherID, other) in frames where otherID != marker.id {
                        XCTAssertFalse(frame.insetBy(dx: -2, dy: -2).intersects(other),
                                       "\(marker.id) overlaps \(otherID) at width \(width)")
                    }
                    if abs(frame.midY - marker.anchorY) > 0.5 {
                        let others = frames.filter { $0.key != marker.id }.map(\.value)
                        let x = VolumeProfileMarkerLayout.leaderX(for: frame, anchorY: marker.anchorY,
                                                                 width: width, excluding: others)
                        let anchor = CGPoint(x: x, y: marker.anchorY)
                        XCTAssertTrue((0...width).contains(x))
                        XCTAssertFalse(others.contains { $0.contains(anchor) },
                                       "The actual price point must not be hidden under another label")
                    }
                }
            }
        }
    }

    func testSeparatedMarkersStayExactlyOnTheirOriginalPrices() throws {
        let markers = markers(width: 321, peakY: 150, costY: 250, currentY: 50)
        let frames = VolumeProfileMarkerLayout.frames(for: markers, height: 303)
        for marker in markers {
            let frame = try XCTUnwrap(frames[marker.id])
            XCTAssertEqual(frame.midY, marker.anchorY)
            XCTAssertEqual(frame.midX, marker.centerX)
        }
    }

    @MainActor
    func testRangeLabelsMakeRoomForCompleteLargeAmounts() throws {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        func height(low: Double, high: Double, type: DynamicTypeSize) -> CGFloat {
            let host = UIHostingController(rootView: FiftyTwoWeekRangeLabels(low: low, high: high, currency: "USD")
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.dynamicTypeSize, type))
            host.safeAreaRegions = []
            return host.sizeThatFits(in: CGSize(width: 248, height: 2_000)).height
        }
        let ordinary = height(low: 100, high: 200, type: .large)
        let long = height(low: 12_345.67, high: 98_765.43, type: .large)
        let accessible = height(low: 12_345.67, high: 98_765.43, type: .accessibility2)
        XCTAssertLessThan(ordinary, 30, "Short amounts retain the ordinary single-row design")
        XCTAssertGreaterThan(long, ordinary + 8, "Long amounts need a second row instead of ellipses")
        XCTAssertGreaterThan(accessible, long, "Dynamic Type must grow the labels' layout height")
    }

    @MainActor
    func testVolumeAndRangeRenderAtPhoneWidthsAndLargeType() async throws {
        let old = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(old, forKey: AppLanguage.preferenceKey) }
        let profile = VolumeProfile(ticker: "TEST", currency: "USD", available: true,
            valueAreaHigh: 108, pointOfControl: 100, valueAreaLow: 92, sessions: 60, valueAreaPercent: 70,
            asOf: "2026-09-21", fiftyTwoWeekHigh: 110, fiftyTwoWeekLow: 90, fiftyTwoWeekStartPrice: 95,
            todayChangePercent: 1, bins: (0..<20).map { index in
                VolumeProfileBin(priceLow: 90 + Double(index), priceHigh: 91 + Double(index),
                                 volume: Double(12 - abs(index - 10)) * 1_000)
            })
        let holding = HoldingDetailLayoutAuditTests.holding(price: 100)
        for (language, width, large) in [("en", 320.0, false), ("en", 320.0, true), ("zh-Hans", 393.0, true)] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previousWindow = scene.windows.first(where: \.isKeyWindow)
            let host = UIHostingController(rootView: VStack(spacing: 16) {
                VolumePriceChart(profile: profile, holding: holding, showsHoldingCost: true)
                FiftyTwoWeekRange(low: 12_345.67, high: 98_765.43, current: 50_000, periodStart: 30_000, currency: "USD")
            }
            .padding(.horizontal, 16).padding(.vertical, 2)
            .frame(width: width)
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, large ? .accessibility2 : .large)
            .environment(\.colorScheme, large ? .dark : .light))
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = large ? .dark : .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(200))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 8_000))
            XCTAssertEqual(size.width, width, accuracy: 0.5)
            host.view.bounds = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "volume-range-fixed-\(language)-\(Int(width))-\(large ? "large" : "regular")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
