import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class LossRankingInteractionTests: XCTestCase {
    func testSortSwitchUpdatesChartWithoutRefetchingAndKeepsHiddenRowsAndHandleState() async throws {
        let suite = "loss-ranking-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: ChartInteractionStyle.hapticsPreferenceKey)
        let history = history()
        let state = LossSourceListState()
        let drawer = ReturnsListDisclosure()
        let peak = HoldingLossStack(history: history, range: .oneYear)
        state.toggle(try XCTUnwrap(peak.bands.first { $0.title == "B" }))
        state.highlight(try XCTUnwrap(peak.bands.first { $0.title == "A" }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var fetches = 0
        let host = UIHostingController(rootView: NavigationStack {
            LossAnalysisChart(fetchHistory: { _ in fetches += 1; return history }, listState: state,
                              listDisclosure: drawer)
                .navigationTitle(L10n.text("亏损分析"))
                .navigationBarTitleDisplayMode(.inline)
        }.environment(AppModel()).defaultAppStorage(defaults))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        let picker = try await readyPicker(in: host.view)
        drawer.begin(at: 0)
        drawer.update(offset: -ReturnsListDisclosure.threshold)
        withAnimation(.spring(duration: 0.34)) { drawer.release() }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(picker.selectedSegmentIndex, 1, "Existing peak-loss ordering remains the default")
        XCTAssertEqual(picker.titleForSegment(at: 0), HoldingLossSortOrder.currentLoss.title)
        XCTAssertEqual(picker.titleForSegment(at: 1), HoldingLossSortOrder.maximumLoss.title)
        XCTAssertEqual(picker.traitCollection.userInterfaceStyle, .dark)
        let handle = try XCTUnwrap(descendants(host.view).compactMap { $0 as? ReturnsChartHandle.Control }.first)
        let frame = handle.convert(handle.bounds, to: window)
        let plotRegion = CGRect(x: 0, y: frame.midY - ReturnsSourceChartStyle.stripHeight - 190,
                                width: window.bounds.width, height: 180)
        let before = try plotPixels(window, region: plotRegion)
        capture(window, name: "loss-ranking-maximum")
        let fetchesBeforeSwitch = fetches

        picker.selectedSegmentIndex = 0
        picker.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(defaults.string(forKey: HoldingLossSortOrder.preferenceKey), "currentLoss")
        XCTAssertEqual(fetches, fetchesBeforeSwitch, "Sorting reads prepared ranges without a network reload")
        XCTAssertEqual(state.hiddenTickers, ["B"])
        XCTAssertNil(state.highlightedBand, "A recovered holding must not leave all remaining bands dimmed")
        XCTAssertEqual(handle.convert(handle.bounds, to: window), frame)
        let after = try plotPixels(window, region: plotRegion)
        XCTAssertEqual(before.count, after.count)
        let change = zip(before, after).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
        XCTAssertGreaterThan(change / Double(before.count) / 255, 0.02,
                             "The actual plotted bands must change with the native sort control")
        capture(window, name: "loss-ranking-current")

        handle.sendActions(for: .touchUpInside)
        let collapsedFrame = try await settledFrame(of: handle, in: window)
        XCTAssertEqual(handle.accessibilityLabel, L10n.text("展开图表"))
        picker.selectedSegmentIndex = 1
        picker.sendActions(for: .valueChanged)
        let switchedFrame = try await settledFrame(of: handle, in: window)
        XCTAssertEqual(switchedFrame.minY, collapsedFrame.minY, accuracy: 0.1)
        XCTAssertEqual(switchedFrame.size, collapsedFrame.size)
        XCTAssertEqual(handle.accessibilityLabel, L10n.text("展开图表"))
        XCTAssertEqual(state.hiddenTickers, ["B"])
        XCTAssertEqual(fetches, fetchesBeforeSwitch)

        picker.selectedSegmentIndex = 0
        picker.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(300))
        let reopenedDrawer = ReturnsListDisclosure()
        reopenedDrawer.setExpanded(true)
        let reopened = UIHostingController(rootView: NavigationStack {
            LossAnalysisChart(fetchHistory: { _ in history }, listDisclosure: reopenedDrawer)
        }.environment(AppModel()).defaultAppStorage(defaults))
        window.rootViewController = reopened
        let restored = try await readyPicker(in: reopened.view)
        XCTAssertEqual(restored.selectedSegmentIndex, 0, "The chosen sort order survives reopening the page")
    }

    private func readyPicker(in view: UIView) async throws -> UISegmentedControl {
        for _ in 0..<40 {
            if let picker = descendants(view).compactMap({ $0 as? UISegmentedControl }).first { return picker }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try XCTUnwrap(descendants(view).compactMap { $0 as? UISegmentedControl }.first)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func settledFrame(of handle: UIView, in window: UIWindow) async throws -> CGRect {
        try await Task.sleep(for: .milliseconds(350))
        var previous: CGRect?
        var stable = 0
        for _ in 0..<20 {
            let frame = handle.convert(handle.bounds, to: window)
            stable = previous.map { abs($0.minY - frame.minY) < 0.05 } == true ? stable + 1 : 0
            if stable >= 3 { return frame }
            previous = frame
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The chart handle did not finish its animation")
        return handle.convert(handle.bounds, to: window)
    }

    private func plotPixels(_ window: UIWindow, region: CGRect) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 48), format: format).image { context in
            context.cgContext.scaleBy(x: 96 / region.width, y: 48 / region.height)
            context.cgContext.translateBy(x: -region.minX, y: -region.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return Array(try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data)
    }

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

    private func history() -> HoldingValueHistory {
        let costs = ["A": 1000.0, "B": 1000.0, "C": 1000.0, "D": 1000.0]
        return HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: 4000,
                  values: ["A": 100, "B": 200, "C": 500, "D": 900], costs: costs),
            .init(dateText: "2026-10-09", cost: 4000,
                  values: ["A": 1100, "B": 900, "C": 500, "D": 950], costs: costs)
        ], costs: costs, names: [:])
    }
}
