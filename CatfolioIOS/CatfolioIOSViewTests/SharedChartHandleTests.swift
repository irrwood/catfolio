import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SharedChartHandleTests: XCTestCase {
    func testCyclePageSharesHandleAndIndependentListInBothAppearances() async throws {
        let suite = "cycle-handle-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("MY", forKey: "research.cycle.subject")
        defaults.set(5, forKey: "research.cycle.years")
        for style in [UIUserInterfaceStyle.light, .dark] {
            let model = AppModel(defaults: defaults)
            model.comparison = cycleComparison()
            let fixture = try Fixture(NavigationStack { CycleComparisonView() }
                .environment(model).defaultAppStorage(defaults), style: style)
            defer { fixture.close() }
            try await fixture.ready()
            try await exercise(fixture, name: "cycle-handle-\(style == .light ? "light" : "dark")")
        }
    }

    func testCycleRetainsCollapsedChartWhenHistoryAndCycleChoicesChange() async throws {
        let suite = "cycle-handle-refresh-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("MY", forKey: "research.cycle.subject")
        let model = AppModel(defaults: defaults)
        model.isReturnsLoading = true
        let fixture = try Fixture(NavigationStack { CycleComparisonView() }
            .environment(model).defaultAppStorage(defaults), style: .light)
        defer { fixture.close() }
        try await fixture.ready()
        try fixture.handle().sendActions(for: .touchUpInside)
        try await fixture.settle()
        let collapsedTop = try fixture.listTop()
        model.comparison = cycleComparison()
        model.isReturnsLoading = false
        model.comparisonRevision &+= 1
        try await fixture.settle()
        XCTAssertEqual(try fixture.listTop(), collapsedTop, accuracy: 1)
        defaults.set(3, forKey: "research.cycle.years")
        defaults.set(4, forKey: "research.cycle.startMonth")
        try await fixture.settle()
        XCTAssertEqual(try fixture.listTop(), collapsedTop, accuracy: 1)
        XCTAssertEqual(try fixture.handle().accessibilityLabel, L10n.text("展开图表"))
        try fixture.handle().sendActions(for: .touchUpInside)
        try await fixture.settle()
        XCTAssertGreaterThan(try fixture.listTop(), collapsedTop + 500)
    }

    func testLossPageSharesHandleAndIndependentListInBothAppearances() async throws {
        let history = LossAnalysisChart.demoHistory()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let fixture = try Fixture(NavigationStack {
                LossAnalysisChart(fetchHistory: { _ in history })
                    .navigationTitle(L10n.text("亏损分析"))
                    .navigationBarTitleDisplayMode(.inline)
            }.environment(AppModel()), style: style)
            defer { fixture.close() }
            try await fixture.ready()
            let handle = try fixture.handle()
            var white: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(handle.tintColor.getWhite(&white, alpha: &alpha))
            XCTAssertEqual(white, 1, accuracy: 0.01, "The purple loss page uses a light handle in both app appearances")
            XCTAssertEqual(alpha, 0.2, accuracy: 0.01)
            try await exercise(fixture, name: "loss-handle-\(style == .light ? "light" : "dark")")
        }
    }

    func testComparisonListScrollsIndependentlyAndHandleMovesChart() async throws {
        let model = AppModel()
        model.comparison = comparison()
        let fixture = try Fixture(ReturnsComparisonPanel().environment(model), style: .dark)
        defer { fixture.close() }
        try await fixture.ready()
        try await Task.sleep(for: .milliseconds(400))
        try await exercise(fixture, name: "comparison-handle")
    }

    func testComparisonRetainsCollapsedChartAcrossLoadingAndRebuilds() async throws {
        let model = AppModel()
        let fixture = try Fixture(ReturnsComparisonPanel().environment(model), style: .dark)
        defer { fixture.close() }
        try await fixture.ready()
        try fixture.handle().sendActions(for: .touchUpInside)
        try await fixture.settle()
        let collapsedTop = try fixture.listTop()
        for _ in 0..<2 {
            model.comparison = comparison()
            model.comparisonRevision &+= 1
            try await fixture.settle()
            XCTAssertEqual(try fixture.listTop(), collapsedTop, accuracy: 1,
                           "A data refresh or benchmark rebuild must not reopen the chart")
            XCTAssertEqual(try fixture.handle().accessibilityLabel, L10n.text("展开图表"))
        }
        try fixture.handle().sendActions(for: .touchUpInside)
        try await fixture.settle()
        XCTAssertGreaterThan(try fixture.listTop(), collapsedTop + 400)
    }

    private func exercise(_ fixture: Fixture, name: String) async throws {
        let handle = try fixture.handle()
        let scroll = try fixture.scroll()
        let start = try fixture.listTop()
        let handleStart = handle.convert(handle.bounds, to: fixture.window)
        XCTAssertEqual(fixture.scrolls.count, 1, "The page must not nest the list in an outer scroll view")
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 80)
        fixture.capture("\(name)-expanded")
        scroll.setContentOffset(CGPoint(x: 0, y: 100 - scroll.adjustedContentInset.top), animated: false)
        try await fixture.settle()
        XCTAssertEqual(try fixture.listTop(), start, accuracy: 1)
        XCTAssertEqual(handle.convert(handle.bounds, to: fixture.window), handleStart)
        fixture.capture("\(name)-scrolled")

        handle.onPan?(.began, 0, 0)
        handle.onPan?(.changed, -120, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try fixture.listTop(), start - 120, accuracy: 1)
        handle.onPan?(.ended, -120, 0)
        try await fixture.settle()
        XCTAssertEqual(try fixture.listTop(), start, accuracy: 1)

        handle.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(100))
        let moving = try fixture.listTop()
        XCTAssertLessThan(moving, start)
        try await fixture.settle()
        let collapsed = try fixture.listTop()
        XCTAssertLessThan(collapsed, moving, "The chart slides upward through intermediate positions")
        XCTAssertGreaterThan(start - collapsed, 350)
        let touch = CGPoint(x: handle.bounds.midX, y: handle.bounds.midY)
        XCTAssertTrue(handle.hitTest(touch, with: nil) === handle, "The collapsed handle stays tappable")
        XCTAssertEqual(handle.accessibilityLabel, L10n.text("展开图表"))
        fixture.capture("\(name)-collapsed")
        XCTAssertTrue(handle.accessibilityActivate())
        try await fixture.settle()
        XCTAssertEqual(try fixture.listTop(), start, accuracy: 1)
    }

    private func comparison() -> ComparisonResponse {
        let dates = ["2026-01-02", "2026-06-01", "2026-10-09"]
        let benchmarks = Dictionary(uniqueKeysWithValues: ComparisonBenchmarkCatalog.symbols.enumerated().map {
            ($0.element, [1, 1 + Double($0.offset + 1) * 0.025, 1 + Double($0.offset + 1) * 0.05].map(Optional.some))
        })
        return ComparisonResponse(available: true, dates: dates, portfolio: [1, 1.12, 1.2], benchmarks: benchmarks,
            cashFlowPortfolioReturns: nil, cashFlowBenchmarkReturns: nil, mwrPortfolio: nil, mwrBenchmarks: nil,
            twrDates: dates, twrPortfolio: [1, 1.12, 1.2], twrBenchmarks: benchmarks, warnings: nil,
            summary: .init(portfolioReturn: 0.2, benchmarkReturn: nil, benchmarkReturns: [:]))
    }

    private func cycleComparison() -> ComparisonResponse {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let dates = (year - 7..<year).map { "\($0)-12-31" } + [DayDateCodec.string(from: Date())]
        let values = dates.indices.map { Optional(pow(1.12, Double($0))) }
        return ComparisonResponse(available: true, dates: dates, portfolio: values, benchmarks: [:],
            cashFlowPortfolioReturns: nil, cashFlowBenchmarkReturns: nil, mwrPortfolio: nil, mwrBenchmarks: nil,
            twrDates: dates, twrPortfolio: values, twrBenchmarks: [:], warnings: nil,
            summary: .init(portfolioReturn: 0.12, benchmarkReturn: nil, benchmarkReturns: [:]))
    }

    @MainActor private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?
        let host: UIHostingController<AnyView>

        init(_ view: some View, style: UIUserInterfaceStyle) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = style
            host = UIHostingController(rootView: AnyView(view))
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func close() { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func ready() async throws {
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                if descendants(host.view).contains(where: { $0 is ReturnsChartHandle.Control }) { break }
            }
            try await settle()
            _ = try handle()
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(350))
            var previousTop: CGFloat?
            var stableFrames = 0
            for _ in 0..<20 {
                host.view.layoutIfNeeded()
                let top = try listTop()
                stableFrames = previousTop.map { abs(top - $0) < 0.1 } == true ? stableFrames + 1 : 0
                if stableFrames >= 3 { return }
                previousTop = top
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("The chart did not settle at its detent")
        }
        var scrolls: [UIScrollView] { descendants(host.view).compactMap { $0 as? UIScrollView } }
        func scroll() throws -> UIScrollView { try XCTUnwrap(scrolls.first) }
        func handle() throws -> ReturnsChartHandle.Control {
            try XCTUnwrap(descendants(host.view).compactMap { $0 as? ReturnsChartHandle.Control }.first)
        }
        func listTop() throws -> CGFloat {
            let scroll = try scroll()
            return scroll.convert(scroll.bounds, to: window).minY + scroll.adjustedContentInset.top
        }
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        }
        private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    }
}
