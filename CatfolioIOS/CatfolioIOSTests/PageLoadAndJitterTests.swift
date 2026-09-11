import Foundation
import SwiftUI
import XCTest
@testable import CatfolioIOS

private struct PageLoadMetrics {
    let loadDuration: TimeInterval
    let maxJitter: CGFloat
}

private enum PageLoadAndJitterError: LocalizedError {
    case noActiveWindowScene
    case readinessTimeout(String)

    var errorDescription: String? {
        switch self {
        case .noActiveWindowScene:
            return "Unable to locate an active UIWindowScene for hosting views"
        case .readinessTimeout(let identifier):
            return "Ready state for page \(identifier) was not reached in time"
        }
    }
}

final class PageLoadAndJitterTests: XCTestCase {
    @MainActor
    func testPortfolioPageLoadSpeedAndJitter() async throws {
        let start = CACurrentMediaTime()
        do {
            let scene = try connectedWindowScene()
            let model = await seededModel()
            let result = try await capturePageLoad(
                in: scene,
                pageView: PortfolioView().environment(model),
                pageIdentifier: "page.portfolio",
                jitterTargetIdentifier: "portfolio-scroll",
                ready: { [self] root in
                    let hasScrollableContent = !descendants(root, of: UIScrollView.self)
                        .filter { $0.contentSize.height > 80 && $0.bounds.height > 0 }
                        .isEmpty
                    return hasScrollableContent || !root.subviews.isEmpty
                }
            )
            let measuredLoad = CACurrentMediaTime() - start
            logMetrics(page: "Portfolio", loadDuration: measuredLoad, maxJitter: result.maxJitter)
            XCTAssertLessThan(measuredLoad, 2.5)
            XCTAssertLessThan(result.maxJitter, 2.5)
        } catch {
            XCTFail(error.localizedDescription)
        }
    }

    @MainActor
    func testReturnsPageLoadSpeedAndJitter() async throws {
        let start = CACurrentMediaTime()
        do {
            let scene = try connectedWindowScene()
            let model = await seededModel()
            let result = try await capturePageLoad(
                in: scene,
                pageView: ReturnsView().environment(model),
                pageIdentifier: "returns-root",
                jitterTargetIdentifier: "returns-root",
                ready: { [self] root in
                    return self.view(withIdentifier: "performance.heatmap", in: root) != nil
                        || !root.subviews.isEmpty
                }
            )
            let measuredLoad = CACurrentMediaTime() - start
            logMetrics(page: "Returns", loadDuration: measuredLoad, maxJitter: result.maxJitter)
            XCTAssertLessThan(measuredLoad, 2.5)
            XCTAssertLessThan(result.maxJitter, 2.5)
        } catch {
            XCTFail(error.localizedDescription)
        }
    }

    @MainActor
    func testSettingsPageLoadSpeedAndJitter() async throws {
        let start = CACurrentMediaTime()
        do {
            let scene = try connectedWindowScene()
            let model = await seededModel()
            let result = try await capturePageLoad(
                in: scene,
                pageView: SettingsView().environment(model),
                pageIdentifier: "settings-root",
                jitterTargetIdentifier: "settings-root",
                ready: { [self] root in
                    return self.view(withIdentifier: "settings.language", in: root) != nil
                        || !root.subviews.isEmpty
                }
            )
            let measuredLoad = CACurrentMediaTime() - start
            logMetrics(page: "Settings", loadDuration: measuredLoad, maxJitter: result.maxJitter)
            XCTAssertLessThan(measuredLoad, 2.5)
            XCTAssertLessThan(result.maxJitter, 2.5)
        } catch {
            XCTFail(error.localizedDescription)
        }
    }

    @MainActor
    func testHistoryPageLoadSpeedAndJitter() async throws {
#if DEBUG
        let start = CACurrentMediaTime()
        do {
            let scene = try connectedWindowScene()
            let model = await seededModel()
            let (ledger, prepared) = try makeHistoryFixture()
            let result = try await capturePageLoad(
                in: scene,
                pageView: HistoryView(previewLedger: ledger, prepared: prepared)
                    .environment(model),
                pageIdentifier: "page.history",
                jitterTargetIdentifier: "history-list",
                ready: { [self] root in
                    return self.view(withIdentifier: "history-list", in: root) != nil
                        || !root.subviews.isEmpty
                }
            )
            let measuredLoad = CACurrentMediaTime() - start
            logMetrics(page: "History", loadDuration: measuredLoad, maxJitter: result.maxJitter)
            XCTAssertLessThan(measuredLoad, 2.5)
            XCTAssertLessThan(result.maxJitter, 2.5)
        } catch {
            XCTFail(error.localizedDescription)
        }
#else
        XCTSkip("History fixture initializer uses debug-only HistoryView APIs")
#endif
    }

    @MainActor
    private func connectedWindowScene() throws -> UIWindowScene {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw PageLoadAndJitterError.noActiveWindowScene
        }
        return scene
    }

    @MainActor
    private func seededModel() async -> AppModel {
        let suiteName = "catfolio-page-load-performance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.set(true, forKey: "catfolio.fakeDataMode")
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        defaults.set("",
                      forKey: PublicInvestorPreferences.selectionKey)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { FakePortfolioGenerator.make() })
        await model.refreshPortfolio(refreshMarketData: false)
        while model.isPortfolioLoading || model.isPortfolioChartLoading || model.isHoldingDailyChangesLoading {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    @MainActor
    private func capturePageLoad<V: View>(
        in scene: UIWindowScene,
        pageView: V,
        pageIdentifier: String,
        jitterTargetIdentifier: String,
        ready: @escaping (UIView) -> Bool,
        timeout: TimeInterval = 5.0,
        jitterSamples: Int = 24
    ) async throws -> PageLoadMetrics {
        let host = UIHostingController(rootView: AnyView(NavigationStack { pageView }))
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
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

        let start = CACurrentMediaTime()
        let pageRoot = try await waitForReadyPage(
            identifier: pageIdentifier,
            in: host.view,
            timeout: timeout,
            ready: ready
        )
        let loadDuration = CACurrentMediaTime() - start

        let jitterRoot = view(withIdentifier: jitterTargetIdentifier, in: pageRoot)
            ?? pageRoot
        let maxJitter = await measureJitter(in: jitterRoot, samples: jitterSamples)
        return PageLoadMetrics(loadDuration: loadDuration, maxJitter: maxJitter)
    }

    @MainActor
    private func waitForReadyPage(
        identifier: String,
        in rootView: UIView,
        timeout: TimeInterval,
        ready: @escaping (UIView) -> Bool
    ) async throws -> UIView {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if let candidate = view(withIdentifier: identifier, in: rootView), ready(candidate) {
                return candidate
            }
            if let fallback = fallbackReadyRoot(from: rootView) {
                return fallback
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        throw PageLoadAndJitterError.readinessTimeout(identifier)
    }

    @MainActor
    private func fallbackReadyRoot(from rootView: UIView) -> UIView? {
        let visibleScrollView = descendants(rootView, of: UIScrollView.self)
            .first { !$0.isHidden && $0.bounds.width > 0 && $0.bounds.height > 0 }
        if let visibleScrollView { return visibleScrollView }

        return rootView.subviews
            .first { !$0.isHidden && $0.bounds.width > 0 && $0.bounds.height > 0 }
    }

    @MainActor
    private func measureJitter(in rootView: UIView, samples: Int) async -> CGFloat {
        var base = rootView.convert(rootView.bounds, to: nil)
        var maxDelta: CGFloat = 0
        for _ in 0..<samples {
            try? await Task.sleep(for: .milliseconds(16))
            let current = rootView.convert(rootView.bounds, to: nil)
            let delta = max(
                abs(current.minX - base.minX),
                abs(current.minY - base.minY),
                abs(current.width - base.width),
                abs(current.height - base.height)
            )
            maxDelta = max(maxDelta, delta)
            base = current
        }
        return maxDelta
    }

    private func view(withIdentifier identifier: String, in rootView: UIView) -> UIView? {
        if rootView.accessibilityIdentifier == identifier { return rootView }
        return rootView.subviews.lazy.compactMap { [self] in
            self.view(withIdentifier: identifier, in: $0)
        }.first
    }

    private func logMetrics(page: String, loadDuration: TimeInterval, maxJitter: CGFloat) {
        let loadMs = loadDuration * 1000
        let jitterPt = maxJitter
        let message = String(format: "[PageLoadAndJitter] %@ load=%.2fms jitter=%.2fpt", page, loadMs, jitterPt)
        print(message)
    }

    @MainActor
    private func descendants<T: UIView>(_ rootView: UIView, of type: T.Type) -> [T] {
        let selfMatch = (rootView as? T).map { [$0] } ?? []
        return selfMatch + rootView.subviews.flatMap { descendants($0, of: type) }
    }

    private func makeHistoryFixture() throws -> (PortfolioActivityLedger, HistoryPreparedLedger) {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let actions = ["BUY", "SELL", "DIVIDEND", "INTEREST", "DEPOSIT", "WITHDRAWAL", "TRANSFER"]
        let tickers = ["AAPL", "MSFT", "NVDA", "AMZN", "VOO", "EQQQ.L"]
        let accountID = "acct-demo"
        var rows: [LocalTransactionRecord] = []
        for index in 0..<220 {
            let date = DayDateCodec.string(from: calendar.date(byAdding: .day, value: -index, to: now) ?? now)
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

        let accountIDKey = "CSV|\(accountID)"
        let account = PortfolioAccount(
            id: accountIDKey,
            accountID: accountID,
            source: "CSV",
            name: "Demo Account",
            baseCurrency: "USD",
            positionCount: 0,
            transactionCount: rows.count,
            manualTransactionCount: 0,
            hasCSVImport: true,
            marketValueUSD: 0
        )
        var securityNames: [String: String] = [:]
        for row in rows {
            securityNames[row.ticker] = row.ticker
        }
        let ledger = PortfolioActivityLedger(accounts: [account], transactions: rows, securityNames: securityNames)
        let prepared = try HistoryPreparedLedger.build(
            ledger: ledger,
            accountIDs: Set([account.id]),
            locale: Locale(identifier: "en_GB")
        )
        return (ledger, prepared)
    }
}
