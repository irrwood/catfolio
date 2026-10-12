import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class IncomeChartPanelTests: XCTestCase {
    func testDragBoundsProjectionAndCancellation() {
        let disclosure = ReturnsChartDisclosure()
        disclosure.beginDrag()
        disclosure.drag(translation: -120, height: 400)
        XCTAssertEqual(disclosure.progress, 0.3, accuracy: 0.001)
        disclosure.endDrag(translation: -120, velocity: -800, height: 400)
        XCTAssertEqual(disclosure.progress, 1, "A short upward flick finishes closing")
        disclosure.beginDrag()
        disclosure.drag(translation: 900, height: 400)
        XCTAssertEqual(disclosure.progress, 0)
        disclosure.endDrag(translation: 900, velocity: 0, height: 400, cancelled: true)
        XCTAssertEqual(disclosure.progress, 1, "Cancellation returns to the starting detent")
        disclosure.beginDrag()
        disclosure.drag(translation: 280, height: 400)
        disclosure.endDrag(translation: 280, velocity: 0, height: 400)
        XCTAssertEqual(disclosure.progress, 0)
        disclosure.beginDrag()
        disclosure.drag(translation: -900, height: 400)
        XCTAssertEqual(disclosure.progress, 1)
        disclosure.drag(translation: -1, height: 0)
        XCTAssertEqual(disclosure.progress, 1, "An unmeasured chart cannot divide by zero")
    }

    func testListScrollLeavesChartAndHandleInPlaceAndFadesRows() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.layout()
        let scroll = try fixture.scroll()
        let handle = try fixture.handle()
        let heroFrame = fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view)
        let handleFrame = handle.convert(handle.bounds, to: fixture.host.view)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        try await fixture.layout()
        XCTAssertEqual(fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view), heroFrame)
        XCTAssertEqual(handle.convert(handle.bounds, to: fixture.host.view), handleFrame)
        XCTAssertEqual(fixture.disclosure.progress, 0)
        XCTAssertEqual(handle.gestureRecognizers?.filter { $0 is UIPanGestureRecognizer }.count, 1)
        XCTAssertFalse(fixture.hero.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer } ?? false)

        // White rows dim into the background in the first 24pt of the list,
        // then become fully opaque. Sample away from the handle and gutters.
        let image = fixture.capture("income-list-scrolled")
        let top = scroll.convert(scroll.bounds, to: fixture.host.view).minY
        let faded = try pixel(image, x: 40, y: top + 3)
        let middle = try pixel(image, x: 40, y: top + 12)
        let visible = try pixel(image, x: 40, y: top + 30)
        XCTAssertLessThan(faded, middle)
        XCTAssertLessThan(middle, visible)
        XCTAssertGreaterThan(visible, 0.9)
    }

    func testOnlyHandleDragsChartUpWithoutScalingAndTapRestores() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.layout()
        let handle = try fixture.handle()
        let scroll = try fixture.scroll()
        let start = fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view)
        let listStart = scroll.convert(scroll.bounds, to: fixture.host.view).minY
        let touch = CGPoint(x: handle.bounds.midX, y: handle.bounds.midY)
        XCTAssertTrue(handle.hitTest(touch, with: nil) === handle)
        fixture.hero.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.disclosure.progress, 0)

        handle.onPan?(.began, 0, 0)
        handle.onPan?(.changed, -150, 0)
        try await fixture.layout()
        let dragged = fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view)
        XCTAssertEqual(dragged.height, start.height, accuracy: 0.5)
        XCTAssertEqual(dragged.minY, start.minY - 150, accuracy: 1)
        XCTAssertEqual(scroll.convert(scroll.bounds, to: fixture.host.view).minY, listStart - 150, accuracy: 1)
        _ = fixture.capture("income-chart-dragged-up")

        handle.onPan?(.ended, -250, -600)
        try await fixture.layout()
        XCTAssertEqual(fixture.disclosure.progress, 1)
        XCTAssertEqual(fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view).maxY, start.minY, accuracy: 1)
        // At the safe-area edge UIKit extends the scroll view under the bar
        // and adds an inset. The visible content edge must remain stationary.
        XCTAssertEqual(scroll.convert(scroll.bounds, to: fixture.host.view).minY + scroll.adjustedContentInset.top,
                       start.minY, accuracy: 1)
        XCTAssertGreaterThan(handle.convert(handle.bounds, to: fixture.host.view).maxY, start.minY)
        _ = fixture.capture("income-chart-collapsed")

        handle.sendActions(for: .touchUpInside)
        try await fixture.layout()
        XCTAssertEqual(fixture.disclosure.progress, 0)
        XCTAssertEqual(fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view), start)
        XCTAssertTrue(handle.accessibilityActivate())
        try await fixture.layout()
        XCTAssertEqual(fixture.disclosure.progress, 1)
    }

    func testAnimatedTapTravelsUpAndRapidReversalReturnsToStart() async throws {
        let fixture = try Fixture(disableAnimations: false)
        defer { fixture.close() }
        try await fixture.layout()
        let handle = try fixture.handle()
        let start = fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view)
        handle.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(120))
        fixture.host.view.layoutIfNeeded()
        let moving = fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view)
        XCTAssertLessThan(moving.minY, start.minY)
        XCTAssertGreaterThan(moving.maxY, start.minY, "The tap must animate through intermediate positions")
        XCTAssertEqual(moving.height, start.height, accuracy: 0.5)
        _ = fixture.capture("income-chart-tap-animation")
        handle.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(500))
        fixture.host.view.layoutIfNeeded()
        XCTAssertEqual(fixture.disclosure.progress, 0)
        XCTAssertEqual(fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view).minY, start.minY, accuracy: 1)
    }

    func testHidingRowScrollsWholeListUnderChartWithoutReordering() async throws {
        let fixture = try Fixture(disableAnimations: false)
        defer { fixture.close() }
        try await fixture.layout()
        let scroll = try fixture.scroll()
        let hero = fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view)
        let before = fixture.rowControls.map { $0.convert($0.bounds, to: fixture.host.view).minY }
        fixture.rowControls[2].sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(100))
        let intermediate = scroll.contentOffset.y
        XCTAssertGreaterThan(intermediate, 0, "The whole list must move after the tap")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThan(intermediate, scroll.contentOffset.y, "The scroll must animate through intermediate positions")
        let after = fixture.rowControls.map { $0.convert($0.bounds, to: fixture.host.view).minY }
        for index in before.indices {
            XCTAssertEqual(before[index] - after[index], scroll.contentOffset.y, accuracy: 1,
                           "Every row moves by the same amount; no row swaps places")
        }
        XCTAssertEqual(after, after.sorted())
        let hidden = fixture.rowControls[2]
        XCTAssertLessThanOrEqual(hidden.convert(hidden.bounds, to: fixture.host.view).maxY, hero.maxY + 1)
        XCTAssertEqual(hidden.alpha, 0.4, accuracy: 0.01)
        XCTAssertEqual(fixture.hero.convert(fixture.hero.bounds, to: fixture.host.view), hero)
        XCTAssertEqual(fixture.disclosure.progress, 0)
        _ = fixture.capture("income-row-hidden-under-chart")
    }

    func testLastRowCanHideAndScrollBackToRestoreInOriginalPlace() async throws {
        let fixture = try Fixture(rowCount: 3)
        defer { fixture.close() }
        try await fixture.layout()
        let scroll = try fixture.scroll()
        let original = fixture.rowControls.map { $0.convert($0.bounds, to: fixture.host.view).minY }
        let last = try XCTUnwrap(fixture.rowControls.last)
        last.sendActions(for: .touchUpInside)
        try await fixture.layout()
        let top = scroll.convert(scroll.bounds, to: fixture.host.view).minY + scroll.adjustedContentInset.top
        XCTAssertLessThanOrEqual(last.convert(last.bounds, to: fixture.host.view).maxY, top + 1,
                                 "Even a short list's final row must clear the chart edge")
        XCTAssertEqual(last.alpha, 0.4, accuracy: 0.01)
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        try await fixture.layout()
        for (index, control) in fixture.rowControls.enumerated() {
            XCTAssertEqual(control.convert(control.bounds, to: fixture.host.view).minY, original[index], accuracy: 1)
        }
        last.sendActions(for: .touchUpInside)
        try await fixture.layout()
        XCTAssertEqual(last.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1,
                       "Restoring a source must leave the list where the user put it")
        last.sendActions(for: .touchUpInside)
        try await fixture.layout()
        XCTAssertLessThanOrEqual(last.convert(last.bounds, to: fixture.host.view).maxY, top + 1,
                                 "Hiding the same source again issues a new scroll")
    }

    func testRapidHidesAndCollapsedChartUseLatestRowWithoutAnimation() async throws {
        let fixture = try Fixture(rowCount: 4)
        defer { fixture.close() }
        try await fixture.layout()
        fixture.disclosure.toggle()
        try await fixture.layout()
        fixture.rowControls[0].sendActions(for: .touchUpInside)
        fixture.rowControls[3].sendActions(for: .touchUpInside)
        try await fixture.layout()
        let scroll = try fixture.scroll()
        let top = scroll.convert(scroll.bounds, to: fixture.host.view).minY + scroll.adjustedContentInset.top
        let last = fixture.rowControls[3]
        XCTAssertLessThanOrEqual(last.convert(last.bounds, to: fixture.host.view).maxY, top + 1)
        XCTAssertEqual(last.alpha, 0.4, accuracy: 0.01)
        XCTAssertEqual(fixture.disclosure.progress, 1)
    }

    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> CGFloat {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let crop = try XCTUnwrap(cg.cropping(to: CGRect(x: x * image.scale, y: y * image.scale, width: 1, height: 1)))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGFloat(bytes[0]) / 255
    }

    @MainActor private final class Fixture {
        let disclosure = ReturnsChartDisclosure()
        let hero = UIControl()
        let rowControls: [RowControl]
        let window: UIWindow
        let previous: UIWindow?
        let host: UIHostingController<AnyView>

        init(disableAnimations: Bool = true, rowCount: Int = 30) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            hero.backgroundColor = .red
            rowControls = (0..<rowCount).map { _ in RowControl() }
            host = UIHostingController(rootView: AnyView(PanelFixtureView(disclosure: disclosure,
                hero: hero, rowControls: rowControls, disableAnimations: disableAnimations)))
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func close() { window.isHidden = true; previous?.makeKeyAndVisible() }

        func layout() async throws {
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
        }

        func handle() throws -> ReturnsChartHandle.Control { try XCTUnwrap(find(host.view)) }
        func scroll() throws -> UIScrollView { try XCTUnwrap(find(host.view)) }

        private func find<T: UIView>(_ view: UIView) -> T? {
            if let result = view as? T { return result }
            return view.subviews.lazy.compactMap { self.find($0) as T? }.first
        }

        func capture(_ name: String) -> UIImage {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
            return image
        }
    }

    @MainActor @Observable final class RowState {
        var request: ReturnsSourceScrollRequest?
        var hidden: Set<Int> = []
        func toggle(_ index: Int) {
            if hidden.remove(index) == nil {
                hidden.insert(index)
                request = ReturnsSourceScrollRequest(id: "row-\(index)")
            }
        }
    }

    private struct PanelFixtureView: View {
        let disclosure: ReturnsChartDisclosure
        let hero: UIControl
        let rowControls: [RowControl]
        let disableAnimations: Bool
        @State private var state = RowState()
        var body: some View {
            ReturnsChartPanel(disclosure: disclosure, scrollRequest: state.request) {
                HeroMarker(control: hero).frame(height: 360)
            } rows: {
                VStack(spacing: 0) {
                    ForEach(rowControls.indices, id: \.self) { index in
                        RowMarker(control: rowControls[index], isOn: !state.hidden.contains(index),
                                  onTap: { state.toggle(index) })
                            .frame(height: 65)
                            .returnsSourceScrollRow(id: "row-\(index)")
                    }
                }
            }.transaction {
                if disableAnimations {
                    $0.disablesAnimations = true
                    $0.animation = nil
                }
            }
        }
    }

    private final class RowControl: UIControl {
        var onTap: (() -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .white
            addTarget(self, action: #selector(tap), for: .touchUpInside)
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc private func tap() { onTap?() }
    }

    private struct RowMarker: UIViewRepresentable {
        let control: RowControl
        let isOn: Bool
        let onTap: () -> Void
        func makeUIView(context: Context) -> RowControl { control }
        func updateUIView(_ view: RowControl, context: Context) {
            view.onTap = onTap
            view.alpha = isOn ? 1 : 0.4
        }
    }

    private struct HeroMarker: UIViewRepresentable {
        let control: UIControl
        func makeUIView(context: Context) -> UIControl { control }
        func updateUIView(_ view: UIControl, context: Context) {}
    }
}
