import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

/// Diagnostic harness for "全部历史 上下左右滑动很掉帧".
///
/// Drives the real `HistoryView` (pager, category bar, SwiftUI lists) with one
/// viewport step per displayed frame and reports the wall-clock cost of each
/// frame, so a dropped frame shows up as an interval of two or more vsyncs.
@MainActor
final class HistoryScrollPerformanceTests: XCTestCase {

    // MARK: - Fixture

    private func makeLedger(rowCount: Int, tickers: [String]) throws
        -> (PortfolioActivityLedger, HistoryPreparedLedger) {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let actions = ["BUY", "SELL", "DIVIDEND", "INTEREST", "DEPOSIT", "WITHDRAWAL", "TRANSFER"]
        let accountID = "acct-demo"
        var rows: [LocalTransactionRecord] = []
        rows.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let date = DayDateCodec.string(
                from: calendar.date(byAdding: .day, value: -(index / 2), to: now) ?? now)
            rows.append(LocalTransactionRecord(
                date: date,
                action: actions[index % actions.count],
                ticker: tickers[index % tickers.count],
                quantity: 1,
                price: 100 + Double(index % 25),
                currency: "USD",
                source: "CSV",
                accountID: accountID,
                accountName: "Demo Account",
                tradeID: "history-\(index)"
            ))
        }
        let account = PortfolioAccount(
            id: "CSV|\(accountID)", accountID: accountID, source: "CSV", name: "Demo Account",
            baseCurrency: "USD", positionCount: 0, transactionCount: rows.count,
            manualTransactionCount: 0, hasCSVImport: true, marketValueUSD: 0)
        var securityNames: [String: String] = [:]
        for row in rows { securityNames[row.ticker] = row.ticker }
        let ledger = PortfolioActivityLedger(accounts: [account], transactions: rows,
                                             securityNames: securityNames)
        let prepared = try HistoryPreparedLedger.build(
            ledger: ledger, accountIDs: [account.id], locale: Locale(identifier: "zh_CN"))
        return (ledger, prepared)
    }

    private func seededModel() async -> AppModel {
        let defaults = UserDefaults(suiteName: "catfolio-history-scroll-perf.\(UUID().uuidString)")
            ?? .standard
        defaults.set(true, forKey: "catfolio.fakeDataMode")
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        defaults.set("", forKey: PublicInvestorPreferences.selectionKey)
        let model = AppModel(defaults: defaults,
                             personalDocumentLoader: { FakePortfolioGenerator.make() })
        await model.refreshPortfolio(refreshMarketData: false)
        while model.isPortfolioLoading || model.isPortfolioChartLoading
            || model.isHoldingDailyChangesLoading {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func connectedWindowScene() throws -> UIWindowScene {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw XCTSkip("No active window scene")
        }
        return scene
    }

    // MARK: - Frame sampling

    /// Resumes one continuation per displayed frame, and records the wall-clock
    /// gap between frame callbacks.
    private final class FrameClock {
        private var link: CADisplayLink?
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var wallGaps: [Double] = []
        var vsyncGaps: [Double] = []
        private var lastWall: CFTimeInterval = 0
        private var lastVsync: CFTimeInterval = 0

        func start() {
            lastWall = 0
            lastVsync = 0
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        @objc private func tick(_ link: CADisplayLink) {
            let wall = CACurrentMediaTime()
            if lastWall > 0 { wallGaps.append(wall - lastWall) }
            if lastVsync > 0 { vsyncGaps.append(link.timestamp - lastVsync) }
            lastWall = wall
            lastVsync = link.timestamp
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        func nextFrame() async {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private struct FrameReport {
        let label: String
        let frames: Int
        let medianVsyncMs: Double
        let p50Ms: Double
        let p95Ms: Double
        let worstMs: Double
        let hitches: Int
        let totalMs: Double

        var description: String {
            String(format: "%@ frames=%d vsync=%.2fms p50=%.2f p95=%.2f worst=%.2f hitches=%d/%@ total=%.0fms",
                   label, frames, medianVsyncMs, p50Ms, p95Ms, worstMs, hitches, "\(frames)", totalMs)
        }
    }

    private func summarize(_ label: String, _ wallGaps: [Double], _ vsyncGaps: [Double]) -> FrameReport {
        let wall = wallGaps.sorted()
        let vsync = vsyncGaps.sorted()
        guard !wall.isEmpty else {
            return FrameReport(label: label, frames: 0, medianVsyncMs: 0, p50Ms: 0,
                               p95Ms: 0, worstMs: 0, hitches: 0, totalMs: 0)
        }
        let medianVsync = vsync.isEmpty ? 16.67 : vsync[vsync.count / 2] * 1000
        let threshold = medianVsync / 1000 * 1.5
        return FrameReport(
            label: label,
            frames: wall.count,
            medianVsyncMs: medianVsync,
            p50Ms: wall[wall.count / 2] * 1000,
            p95Ms: wall[min(wall.count - 1, Int(Double(wall.count) * 0.95))] * 1000,
            worstMs: (wall.last ?? 0) * 1000,
            hitches: wallGaps.filter { $0 > threshold }.count,
            totalMs: wallGaps.reduce(0, +) * 1000)
    }

    // MARK: - Views

    private func descendants<T: UIView>(_ root: UIView, of type: T.Type) -> [T] {
        let match = (root as? T).map { [$0] } ?? []
        return match + root.subviews.flatMap { descendants($0, of: type) }
    }

    private func verticalList(in root: UIView, excluding: UIScrollView?) -> UIScrollView? {
        descendants(root, of: UIScrollView.self).first {
            $0 !== excluding && $0.contentSize.height > $0.bounds.height + 50
                && $0.contentSize.width <= $0.bounds.width + 1
        }
    }

    private func waitForScrollViews(in root: UIView, timeout: TimeInterval = 10) async -> [UIScrollView] {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            let found = descendants(root, of: UIScrollView.self)
            if found.contains(where: { $0.accessibilityIdentifier == "history-pager" }) { return found }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return []
    }

    // MARK: - The measurement

    func testHistoryScrollFramePacing() async throws {
        let tickers = ["AAPL", "MSFT", "NVDA", "AMZN", "META", "JPM", "VOO", "EQQQ.L"]
        let (ledger, prepared) = try makeLedger(rowCount: 1_500, tickers: tickers)
        let model = await seededModel()
        let scene = try connectedWindowScene()
        let previousWindow = scene.windows.first(where: \.isKeyWindow)

        let host = UIHostingController(rootView: AnyView(
            NavigationStack {
                HistoryView(previewLedger: ledger, prepared: prepared)
                    .environment(model)
            }))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.frame = UIScreen.main.bounds
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }

        let scrollViews = await waitForScrollViews(in: host.view)
        let pager = try XCTUnwrap(scrollViews.first { $0.accessibilityIdentifier == "history-pager" },
                                  "history pager never appeared")
        let list = try XCTUnwrap(verticalList(in: pager, excluding: pager),
                                 "history list never appeared")
        // Let the push settle and the neighbour pages warm up.
        try await Task.sleep(for: .milliseconds(700))
        host.view.layoutIfNeeded()

        var reports: [FrameReport] = []
        let clock = FrameClock()

        // Phase 0 — idle baseline.
        clock.start()
        for _ in 0..<60 { await clock.nextFrame() }
        clock.stop()
        reports.append(summarize("idle            ", clock.wallGaps, clock.vsyncGaps))
        clock.wallGaps.removeAll()
        clock.vsyncGaps.removeAll()

        // Phase 1 — vertical drag down, one viewport per 24 pt frame.
        let verticalTravel = min(list.contentSize.height - list.bounds.height, 24 * 320)
        clock.start()
        for frame in 0..<320 {
            let y = -list.adjustedContentInset.top + verticalTravel / 320 * Double(frame)
            list.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            await clock.nextFrame()
        }
        clock.stop()
        reports.append(summarize("vertical 24pt/f ", clock.wallGaps, clock.vsyncGaps))
        clock.wallGaps.removeAll()
        clock.vsyncGaps.removeAll()

        // Phase 2 — vertical drag down again through fresh rows.
        let startY = list.contentOffset.y
        clock.start()
        for frame in 0..<320 {
            let y = startY + verticalTravel / 320 * Double(frame)
            list.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            await clock.nextFrame()
        }
        clock.stop()
        reports.append(summarize("vertical 24pt/f2", clock.wallGaps, clock.vsyncGaps))
        clock.wallGaps.removeAll()
        clock.vsyncGaps.removeAll()

        // Phase 3 — horizontal paging across every category, driven through the
        // real delegate sequence (willBeginDragging is where neighbour pages wake).
        let pageWidth = pager.bounds.width
        var horizontalLabels: [FrameReport] = []
        for page in 0..<(HistoryCategory.allCases.count - 1) {
            let from = CGFloat(page) * pageWidth
            let step = pageWidth / 24
            clock.start()
            pager.delegate?.scrollViewWillBeginDragging?(pager)
            for frame in 0..<24 {
                pager.setContentOffset(CGPoint(x: from + step * Double(frame), y: 0), animated: false)
                await clock.nextFrame()
            }
            pager.setContentOffset(CGPoint(x: from + pageWidth, y: 0), animated: false)
            pager.delegate?.scrollViewDidEndDragging?(pager, willDecelerate: false)
            pager.delegate?.scrollViewDidEndDecelerating?(pager)
            await clock.nextFrame()
            clock.stop()
            horizontalLabels.append(summarize("page \(page)->\(page + 1)     ",
                                              clock.wallGaps, clock.vsyncGaps))
            clock.wallGaps.removeAll()
            clock.vsyncGaps.removeAll()
            host.view.layoutIfNeeded()
        }
        reports.append(contentsOf: horizontalLabels)

        for report in reports { print("[HistoryScrollPerf] \(report.description)") }
        XCTAssertFalse(reports.isEmpty)
    }

    /// Microbenchmarks for the per-row work a scroll frame repeats.
    func testHistoryRowUnitCosts() throws {
        let tickers = ["AAPL", "MSFT", "NVDA", "AMZN", "META", "JPM", "VOO", "EQQQ.L"]
        let (ledger, prepared) = try makeLedger(rowCount: 600, tickers: tickers)
        let activities = prepared.page(category: .all, basis: .calendar, year: nil).activities
        XCTAssertFalse(activities.isEmpty)

        func measure(_ label: String, iterations: Int, _ body: () -> Void) {
            let start = CACurrentMediaTime()
            for _ in 0..<iterations { body() }
            let elapsed = (CACurrentMediaTime() - start) / Double(iterations) * 1_000_000
            print(String(format: "[HistoryRowCost] %@ %.2f µs/call", label, elapsed))
        }

        let symbols = tickers + ["BRK.B", "0700.HK", "SAP.DE", "TEST"]
        measure("Bundle export logo URL", iterations: 400) {
            for symbol in symbols {
                _ = AssetLogoExportCatalog.imageURL(for: symbol, dark: false)
            }
        }
        measure("Bundle legacy logo URL", iterations: 400) {
            for symbol in symbols {
                _ = Bundle.main.url(forResource: symbol.uppercased(), withExtension: "png",
                                    subdirectory: "AssetLogos")
            }
        }
        measure("L10n.text(kind title)", iterations: 400) {
            for activity in activities.prefix(symbols.count) {
                _ = activity.kind.title
            }
        }
        measure("HistoryRowPresentation", iterations: 400) {
            for activity in activities.prefix(symbols.count) {
                _ = HistoryRowPresentation(activity)
            }
        }
        measure("DisplayFormat.money", iterations: 400) {
            for activity in activities.prefix(symbols.count) {
                _ = DisplayFormat.money(activity.nativeAmount,
                                        currency: activity.transaction.currency, signed: true)
            }
        }
        measure("preparedLedger.page(.all)", iterations: 200) {
            _ = prepared.page(category: .all, basis: .calendar, year: nil)
        }
        _ = ledger
    }
}
