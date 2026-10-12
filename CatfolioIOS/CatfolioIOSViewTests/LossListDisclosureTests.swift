import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class LossListDisclosureTests: XCTestCase {
    func testPullMeetsResistingStopAndClicksOnlyOnceBeforeOpeningOnRelease() {
        let drawer = ReturnsListDisclosure()
        XCTAssertFalse(drawer.isExpanded)
        drawer.begin(at: 0)
        drawer.update(offset: -30)
        XCTAssertFalse(drawer.isArmed)
        XCTAssertEqual(drawer.feedbackRevision, 0)
        drawer.update(offset: -64)
        XCTAssertTrue(drawer.isArmed)
        XCTAssertFalse(drawer.isExpanded, "The controls stay tucked away until release")
        XCTAssertEqual(drawer.feedbackRevision, 1)
        drawer.update(offset: -40)
        drawer.update(offset: -80)
        XCTAssertEqual(drawer.feedbackRevision, 1, "Crossing the detent twice in one pull must not chatter")
        drawer.update(offset: -1000)
        XCTAssertLessThan(1000 + drawer.pullCorrection, ReturnsListDisclosure.maximumTravel)
        XCTAssertGreaterThan(1000 + drawer.pullCorrection, 30)
        XCTAssertTrue(drawer.release())
        XCTAssertTrue(drawer.isExpanded)
        XCTAssertEqual(drawer.pullCorrection, 0)
    }

    func testShortReversedAndCancelledPullsStayClosed() {
        for offsets in [[-30.0], [-80, -20]] {
            let drawer = ReturnsListDisclosure()
            drawer.begin(at: 0)
            for offset in offsets { drawer.update(offset: offset) }
            XCTAssertFalse(drawer.release())
            XCTAssertFalse(drawer.isExpanded)
            drawer.update(offset: 0)
            XCTAssertEqual(drawer.pullCorrection, 0)
        }
        let drawer = ReturnsListDisclosure()
        drawer.begin(at: 0)
        drawer.update(offset: -80)
        XCTAssertFalse(drawer.release(cancelled: true))
        XCTAssertFalse(drawer.isExpanded)
    }

    func testScrollingBackToTopAndProgrammaticOffsetsCannotOpenDrawer() {
        let drawer = ReturnsListDisclosure()
        drawer.update(offset: -80)
        XCTAssertEqual(drawer.feedbackRevision, 0)
        XCTAssertFalse(drawer.release())
        drawer.begin(at: 200)
        drawer.update(offset: -80)
        XCTAssertFalse(drawer.release())
        XCTAssertEqual(drawer.feedbackRevision, 0)
    }

    func testDrawerTucksOnlyAfterUserScrollCoversItAndPreservesRowPosition() {
        let drawer = ReturnsListDisclosure()
        drawer.contentHeight = 160
        drawer.setExpanded(true)
        XCTAssertNil(drawer.tuckIfCovered(offset: 200), "A programmatic hidden-row scroll must not close controls")
        drawer.begin(at: 0)
        drawer.update(offset: 100)
        drawer.release()
        XCTAssertNil(drawer.tuckIfCovered(offset: 100))
        XCTAssertTrue(drawer.isExpanded)
        drawer.begin(at: 100)
        drawer.update(offset: 220)
        drawer.release()
        XCTAssertEqual(drawer.tuckIfCovered(offset: 220), 60)
        XCTAssertFalse(drawer.isExpanded)
        drawer.begin(at: 0)
        drawer.update(offset: -80)
        XCTAssertTrue(drawer.release(), "A fresh pull can reveal it again")
    }

    func testNativeListPullRevealsControlsWithoutMovingChartOrFetchingAgain() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let drawer = ReturnsListDisclosure()
        let suite = "loss-drawer-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: ChartInteractionStyle.hapticsPreferenceKey)
        var fetches = 0
        let history = LossAnalysisChart.demoHistory()
        let host = UIHostingController(rootView: NavigationStack {
            LossAnalysisChart(fetchHistory: { _ in fetches += 1; return history }, listDisclosure: drawer)
                .navigationTitle(L10n.text("亏损分析"))
                .navigationBarTitleDisplayMode(.inline)
        }.environment(AppModel(defaults: defaults)).defaultAppStorage(defaults))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        for _ in 0..<50 {
            if drawer.contentHeight > 0, fetches >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(500))
        let scrolls = descendants(host.view).compactMap { $0 as? UIScrollView }
        XCTAssertEqual(scrolls.count, 1)
        let scroll = try XCTUnwrap(scrolls.first)
        let handle = try XCTUnwrap(descendants(host.view).compactMap { $0 as? ReturnsChartHandle.Control }.first)
        let picker = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UISegmentedControl }.first)
        let handleFrame = handle.convert(handle.bounds, to: window)
        let heightBefore = scroll.contentSize.height
        let fetchesBefore = fetches
        XCTAssertFalse(drawer.isExpanded)
        XCTAssertLessThan(picker.convert(picker.bounds, to: window).maxY,
                          scroll.convert(scroll.bounds, to: window).minY)
        capture(window, name: "loss-controls-tucked")

        // Drive the native delegate callbacks used by SwiftUI's scroll phases,
        // not a second gesture implementation in the fixture.
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: -80 - scroll.adjustedContentInset.top), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(drawer.feedbackRevision, 1)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(drawer.isExpanded)
        XCTAssertEqual(handle.convert(handle.bounds, to: window), handleFrame)
        XCTAssertEqual(fetches, fetchesBefore)
        XCTAssertNil(scroll.refreshControl)
        XCTAssertGreaterThan(scroll.contentSize.height, heightBefore + 100)
        XCTAssertGreaterThan(picker.convert(picker.bounds, to: window).minY,
                             scroll.convert(scroll.bounds, to: window).minY)
        capture(window, name: "loss-controls-revealed")

        let drawerHeight = drawer.contentHeight
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: drawerHeight + 40 - scroll.adjustedContentInset.top), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(drawer.isExpanded)
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 40, accuracy: 1,
                       "Removing the covered controls must preserve the holding rows' screen positions")
        XCTAssertEqual(handle.convert(handle.bounds, to: window), handleFrame)
        XCTAssertEqual(fetches, fetchesBefore)
        capture(window, name: "loss-controls-retucked")
    }

    func testShortListCanTuckDrawerWithAndWithoutAnimations() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for disableAnimations in [false, true] {
            let drawer = ReturnsListDisclosure()
            let host = UIHostingController(rootView: ReturnsChartPanel(listDisclosure: drawer, surface: .losses) {
                Color.clear.frame(height: 200)
            } rows: {
                VStack(spacing: 0) {
                    ReturnsListDrawer(disclosure: drawer) { Text("Controls").frame(height: 120) }
                    Text("One holding").frame(height: 60)
                }
            }.transaction { $0.disablesAnimations = disableAnimations })
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
            scroll.delegate?.scrollViewWillBeginDragging?(scroll)
            scroll.setContentOffset(CGPoint(x: 0, y: -80 - scroll.adjustedContentInset.top), animated: false)
            try await Task.sleep(for: .milliseconds(80))
            scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertTrue(drawer.isExpanded)
            let maximumOffset = scroll.contentSize.height - scroll.bounds.height
                + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom
            XCTAssertGreaterThanOrEqual(maximumOffset, drawer.contentHeight - 1)
            scroll.delegate?.scrollViewWillBeginDragging?(scroll)
            scroll.setContentOffset(CGPoint(x: 0, y: drawer.contentHeight - scroll.adjustedContentInset.top), animated: false)
            try await Task.sleep(for: .milliseconds(80))
            scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(drawer.isExpanded)
            XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1)
        }
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
    }
}
