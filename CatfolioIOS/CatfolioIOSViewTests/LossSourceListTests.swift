import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class LossSourceListTests: XCTestCase {
    func testHiddenRowsRetainTheirPlaceIdentityAndPortfolioTotals() throws {
        let history = history(count: 9)
        let original = HoldingLossStack(history: history, range: .oneYear)
        let originalIDs = original.legendItems.map(\.id)
        let hidden = HoldingLossStack(history: history, range: .oneYear, hiding: ["B", "D"])
        XCTAssertEqual(hidden.legendItems.map(\.id).filter { originalIDs.contains($0) }, originalIDs,
                       "Newly promoted holdings must not move the existing rows")
        XCTAssertEqual(hidden.legendItems.map(\.id), ["A", "B", "C", "D", "E", "F", "G", "H", "I", "loss-others"])
        for ticker in ["B", "D"] {
            let before = try XCTUnwrap(original.legendItems.first { $0.id == ticker })
            let after = try XCTUnwrap(hidden.legendItems.first { $0.id == ticker })
            XCTAssertNil(after.index)
            XCTAssertEqual(before.band.id, after.band.id)
            XCTAssertEqual(original.rank(for: before.band), hidden.rank(for: after.band))
        }
        XCTAssertEqual(hidden.rows.map(\.totalLoss), original.rows.map(\.totalLoss))
        XCTAssertEqual(hidden.rows.map(\.netGain), original.rows.map(\.netGain))
        let restored = HoldingLossStack(history: history, range: .oneYear)
        XCTAssertEqual(restored.legendItems.map(\.id), originalIDs)
    }

    func testVisibilityChangesImmediatelyAndRapidRestoreCancelsScrollRequest() throws {
        let stack = HoldingLossStack(history: history(), range: .oneYear)
        let band = try XCTUnwrap(stack.legendItems.first { $0.id == "B" }).band
        let state = LossSourceListState()
        state.highlight(band)
        state.toggle(band)
        XCTAssertFalse(state.isShown(band), "The row dims before the prepared chart has finished rebuilding")
        XCTAssertEqual(state.scrollRequest?.id, band.id)
        XCTAssertNil(state.highlightedBand)
        let first = state.scrollRequest
        state.toggle(band)
        XCTAssertTrue(state.isShown(band))
        XCTAssertNil(state.scrollRequest)
        state.toggle(band)
        XCTAssertNotEqual(first, state.scrollRequest, "Hiding the same source again must scroll again")
        state.highlight(band)
        XCTAssertTrue(state.isShown(band))
        XCTAssertEqual(state.highlightedBand, band.id)
        XCTAssertNil(state.scrollRequest, "Restoring by highlighting must not push the row away")

        let others = try XCTUnwrap(stack.legendItems.last).band
        state.toggle(others)
        XCTAssertFalse(state.showsOthers)
        XCTAssertEqual(state.scrollRequest?.id, others.id)
        state.toggle(others)
        XCTAssertTrue(state.showsOthers)
        XCTAssertNil(state.scrollRequest)
    }

    func testLossPageScrollsHiddenRowUnderChartAndCanRestoreAfterScrollingBack() async throws {
        let history = history()
        let stack = HoldingLossStack(history: history, range: .oneYear)
        let band = try XCTUnwrap(stack.legendItems.first { $0.id == "C" }).band
        let state = LossSourceListState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack {
            LossAnalysisChart(fetchHistory: { _ in history }, listState: state)
                .navigationTitle(L10n.text("亏损分析"))
                .navigationBarTitleDisplayMode(.inline)
        }.environment(AppModel()).preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if descendants(host.view).contains(where: { $0 is ReturnsChartHandle.Control }) { break }
        }
        try await Task.sleep(for: .milliseconds(300))
        let scrolls = descendants(host.view).compactMap { $0 as? UIScrollView }
        XCTAssertEqual(scrolls.count, 1)
        let scroll = try XCTUnwrap(scrolls.first)
        let handle = try XCTUnwrap(descendants(host.view).compactMap { $0 as? ReturnsChartHandle.Control }.first)
        let handleFrame = handle.convert(handle.bounds, to: window)
        let originalOffset = scroll.contentOffset.y
        let originalHeight = scroll.contentSize.height
        withAnimation(.smooth(duration: 0.3)) { state.toggle(band) }
        try await Task.sleep(for: .milliseconds(120))
        let moving = scroll.contentOffset.y
        XCTAssertGreaterThan(moving, originalOffset)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertGreaterThan(scroll.contentOffset.y, moving, "The list travels through intermediate positions")
        XCTAssertGreaterThan(scroll.contentOffset.y - originalOffset, 150,
                             "The third row must travel all the way behind the chart")
        XCTAssertEqual(handle.convert(handle.bounds, to: window), handleFrame)
        XCTAssertEqual(handle.accessibilityLabel, L10n.text("收起图表"))
        capture(window, name: "loss-source-hidden-under-chart")

        scroll.setContentOffset(CGPoint(x: 0, y: originalOffset), animated: false)
        try await Task.sleep(for: .milliseconds(250))
        capture(window, name: "loss-source-hidden-original-position")
        withAnimation(.smooth(duration: 0.3)) { state.toggle(band) }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(state.isShown(band))
        XCTAssertEqual(scroll.contentOffset.y, originalOffset, accuracy: 1,
                       "Restoring a row must leave the list where the reader put it")
        XCTAssertGreaterThanOrEqual(scroll.contentSize.height, originalHeight,
                                    "Keep any extra scrolling space stable when restoring a row")
    }

    private func history(count: Int = 3) -> HoldingValueHistory {
        let symbols = Array(["A", "B", "C", "D", "E", "F", "G", "H", "I"].prefix(count))
        let costs = Dictionary(uniqueKeysWithValues: symbols.map { ($0, 1000.0) })
        let values = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { ($0.element, 100.0 + Double($0.offset) * 100) })
        return HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: Double(count) * 1000, values: costs, costs: costs),
            .init(dateText: "2026-10-09", cost: Double(count) * 1000, values: values, costs: costs)
        ], costs: costs, names: [:])
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
}
