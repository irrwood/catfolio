import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class ReturnsSourceLoadingTests: XCTestCase {
    private func history() -> HoldingValueHistory {
        .init(rows: [
            .init(dateText: "2026-01-01", cost: 100, values: ["A": 100], costs: ["A": 100]),
            .init(dateText: DayDateCodec.string(from: Date()), cost: 100, values: ["A": 70], costs: ["A": 100])
        ], costs: ["A": 100], names: ["A": "Alpha"])
    }

    func testScopeAndAccountingModeKeepSeparateResultsAndReusePreparedData() async {
        let cache = ReturnsSourceCache()
        let entry = cache.entry(scope: "real|account-a", kind: .current)
        let saved = history()
        await entry.load(revision: 1) { _ in saved }
        let gains = entry.gains.entry(configuration: "default")
        await gains.prepare(key: "1") { HoldingContributionStack(history: saved) }
        let returned = cache.entry(scope: "real|account-a", kind: .current)
        XCTAssertTrue(returned === entry)
        XCTAssertNotNil(returned.gains.entry(configuration: "default").value,
                        "Prepared results must be available synchronously on a return visit")
        XCTAssertNil(cache.entry(scope: "real|account-b", kind: .current).loading.history)
        XCTAssertNil(cache.entry(scope: "demo|account-a", kind: .current).loading.history)
        XCTAssertNil(cache.entry(scope: "real|account-a", kind: .includingSold).loading.history)
        XCTAssertNil(entry.gains.entry(configuration: "hide-a").value)
        var requests = 0
        await returned.load(revision: 1) { _ in requests += 1; return saved }
        XCTAssertEqual(requests, 0, "Reopening a current result must not reread or refetch history")
        await returned.load(revision: 2) { _ in requests += 1; return saved }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(entry.loading.revision, 1, "An unchanged curve keeps prepared results valid")
    }

    func testSimultaneousReadersShareRequestAndLeavingOneDoesNotCancelTheOther() async {
        let entry = ReturnsSourceCacheEntry()
        let saved = history()
        let began = expectation(description: "First fetch")
        var resume: CheckedContinuation<HoldingValueHistory, Never>?
        var requests = 0
        let fetch: @MainActor (Bool) async throws -> HoldingValueHistory = { _ in
            requests += 1
            return await withCheckedContinuation { resume = $0; began.fulfill() }
        }
        let first = Task { await entry.load(revision: 1, fetch: fetch) }
        await fulfillment(of: [began], timeout: 2)
        let second = Task { await entry.load(revision: 1, fetch: fetch) }
        await Task.yield()
        first.cancel()
        resume?.resume(returning: saved)
        await first.value
        await second.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(entry.loading.history, saved)
    }

    func testPreparedResultIsReusedAndRebuiltOffMainThread() async {
        let prepared = ReturnsSourcePreparation<Bool>()
        await prepared.prepare(key: "one") { !Thread.isMainThread }
        XCTAssertEqual(prepared.value, true)
        let revision = prepared.revision
        await prepared.prepare(key: "one") { false }
        XCTAssertEqual(prepared.revision, revision)
        XCTAssertEqual(prepared.value, true)
        await prepared.prepare(key: "two") { throw LocalServiceError.noHistoricalPrices }
        XCTAssertEqual(prepared.value, true, "A failed preparation keeps the previous result")
    }

    func testFailedRefreshDoesNotValidateANewPortfolioRevision() async {
        let entry = ReturnsSourceCacheEntry()
        let saved = history()
        await entry.load(revision: 1) { _ in saved }
        var reads = 0
        let fail: @MainActor (Bool) async throws -> HoldingValueHistory = { _ in
            reads += 1
            throw LocalServiceError.noHistoricalPrices
        }
        await entry.load(revision: 2, fetch: fail)
        await entry.load(revision: 2, fetch: fail)
        XCTAssertEqual(reads, 4, "A failed refresh must remain eligible for another attempt")
        XCTAssertEqual(entry.loading.history, saved)
    }

    func testOlderPreparationCannotReplaceLatestResult() async {
        let prepared = ReturnsSourcePreparation<Int>()
        let began = expectation(description: "Old computation began")
        let gate = DispatchSemaphore(value: 0)
        let first = Task {
            await prepared.prepare(key: "old") {
                began.fulfill()
                gate.wait()
                return 1
            }
        }
        await fulfillment(of: [began], timeout: 2)
        await prepared.prepare(key: "new") { 2 }
        gate.signal()
        await first.value
        XCTAssertEqual(prepared.value, 2)
        XCTAssertEqual(prepared.key, "new")
    }

    func testDrawdownSlotHasSameHeightBeforeAndAfterLoading() throws {
        let series = UnderwaterSeries.portfolio(history(), range: .maximum)
        for size: DynamicTypeSize in [.large, .accessibility2] {
            let empty = UIHostingController(rootView: DrawdownStatistics(series: nil).dynamicTypeSize(size))
            let loaded = UIHostingController(rootView: DrawdownStatistics(series: series).dynamicTypeSize(size))
            let proposal = CGSize(width: 350, height: 1000)
            XCTAssertEqual(empty.sizeThatFits(in: proposal).height,
                           loaded.sizeThatFits(in: proposal).height, accuracy: 0.5)
        }
    }

    func testLoadingAndLoadedPanelsKeepHandleAndListPositionWithoutRefreshControl() async throws {
        for isLoss in [false, true] {
            let began = expectation(description: "History requested")
            var resumes: [CheckedContinuation<HoldingValueHistory, Never>] = []
            let saved = history()
            let fetch: @MainActor (Bool) async throws -> HoldingValueHistory = { cachedOnly in
                if cachedOnly { throw LocalServiceError.noHistoricalPrices }
                return await withCheckedContinuation {
                    resumes.append($0)
                    if resumes.count == 1 { began.fulfill() }
                }
            }
            let host = UIHostingController(rootView: Group {
                if isLoss { LossAnalysisChart(fetchHistory: fetch) }
                else { HoldingContributionChart(fetchHistory: fetch) }
            }.environment(AppModel()))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                resumes.forEach { $0.resume(returning: saved) }
                window.isHidden = true
                previous?.makeKeyAndVisible()
            }
            await fulfillment(of: [began], timeout: 3)
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let handle = try XCTUnwrap(descendant(host.view, of: ReturnsChartHandle.Control.self))
            let scroll = try XCTUnwrap(descendant(host.view, of: UIScrollView.self))
            let handleY = handle.convert(handle.bounds, to: host.view).midY
            let scrollY = scroll.convert(scroll.bounds, to: host.view).minY
            XCTAssertNil(scroll.refreshControl)
            resumes.forEach { $0.resume(returning: saved) }
            resumes.removeAll()
            try await Task.sleep(for: .milliseconds(650))
            host.view.layoutIfNeeded()
            XCTAssertTrue(descendant(host.view, of: ReturnsChartHandle.Control.self) === handle)
            XCTAssertTrue(descendant(host.view, of: UIScrollView.self) === scroll)
            XCTAssertEqual(handle.convert(handle.bounds, to: host.view).midY, handleY, accuracy: 1)
            XCTAssertEqual(scroll.convert(scroll.bounds, to: host.view).minY, scrollY, accuracy: 1)
            XCTAssertNil(scroll.refreshControl)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = isLoss ? "Loss-stable-loading" : "Income-stable-loading"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSourcePageDoesNotInstallPullToRefresh() async throws {
        let model = AppModel()
        let saved = history()
        for kind: ReturnsSourceCache.Kind in [.current, .includingSold, .drawdown] {
            await model.returnsSourceEntry(kind: kind).load(revision: model.portfolioChartRevision) { _ in saved }
        }
        for chart: ReturnsChartDestination in [.contributors, .losses] {
            let host = UIHostingController(rootView: ReturnsChartPage(chart: chart).environment(model))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(descendant(host.view, of: UIScrollView.self))
            XCTAssertNil(scroll.refreshControl, "The page wrapper must not install a refresh control")
        }
    }

    private func descendant<T: UIView>(_ view: UIView, of type: T.Type) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant($0, of: type) }.first
    }
}
