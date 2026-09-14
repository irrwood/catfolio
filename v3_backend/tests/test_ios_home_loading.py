"""Home loading regression checks; execute the production refresh method in Swift."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


class HomeLoadingTests(unittest.TestCase):
    def test_loading_matches_current_home_shell(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        loading = source.split("private struct PortfolioLoadingView: View", 1)[1]
        self.assertIn("PortfolioContentSheet(scrollOffset: scrollOffset)", loading)
        self.assertIn(".offset(y: scrollOffset)", loading)
        self.assertIn("ChartTimeRangePickerSkeleton()", loading)
        self.assertNotIn('Image("HomeSkeletonLineOne")', loading)
        self.assertNotIn('Image("HomeSkeletonLineTwo")', loading)
        self.assertIn("if model.isPublicInvestorMode && !model.isPortfolioLoading", source)
        self.assertNotIn("TimelineView", loading)

    def test_chart_refresh_preserves_identity_and_last_prepared_curve(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        card = source.split("private struct CostMarketCard: View", 1)[1].split(
            "private struct FastCostMarketPlot", 1
        )[0]
        self.assertNotIn(".id(model.portfolioChartRevision)", source)
        self.assertIn(".id(model.selectedAccountKeys.sorted())", source)
        self.assertIn('.task(id: "\\(model.portfolioChartRevision)-\\(isAwaitingEnrichedHistory)")', card)
        self.assertIn("prepared == nil && (isPreparing || isAwaitingEnrichedHistory)", card)
        self.assertIn("guard !isAwaitingEnrichedHistory else { return }", card)
        self.assertNotIn("prepared = nil", card)
        preparation = card.split('.task(id:', 1)[1].split('.onChange(of: range)', 1)[0]
        self.assertNotIn("hasPreparedAllRanges = false", preparation)
        self.assertIn("if !hasPreparedAllRanges {", preparation)
        self.assertGreaterEqual(card.count("guard !Task.isCancelled else { return }"), 3)

    def test_static_skeletons_do_not_install_shimmer_clocks_or_compositing(self):
        for filename in ("DesignSystem.swift", "PortfolioView.swift", "VolumeProfileView.swift"):
            source = (ROOT / filename).read_text()
            self.assertNotIn("catfolioLoadingShimmer", source)
            self.assertNotIn("CatfolioLoadingShimmer", source)

    @unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
    def test_refresh_publishes_quotes_before_history_and_retains_cache_on_failure(self):
        source = (ROOT / "APIClient.swift").read_text()
        method = source[source.index("    func refreshPortfolio("):
                        source.index("    private func mergeCachedTrading212History(")]
        helper = source[source.index("    private func refreshHistoricalChart("):
                        source.index("    private func enrichPortfolioChart(")]
        harness = r'''
import Foundation
struct LocalPortfolioDocument { var positions = ["NVDA"]; var fresh = false }
enum Failure: Error { case unavailable }
enum PublicInvestorCatalog { static let loaded: Result<Int, Failure> = .success(0) }
struct PublicStore {
    func refreshIfNeeded(catalog: Int, selection: String) async throws -> LocalPortfolioDocument? { nil }
}
@MainActor enum Probe {
    static var mode = 0
    static var published = false
    static var visitedNetwork = false
    static var quotePublished = false
    static var historyCalls = 0
    static var historyFinished = false
    static var releaseHistory = false
}
@MainActor struct LocalMarketDataClient {
    func latestQuotes(for positions: [String]) async -> [String: Double] {
        precondition(Probe.published, "Network ran before local presentation")
        Probe.visitedNetwork = true
        try? await Task.sleep(for: .milliseconds(20))
        return Probe.mode == 0 ? [:] : ["NVDA": 123]
    }
}
@MainActor final class LocalCurrentFXRefresh {
    static let shared = LocalCurrentFXRefresh()
    func refresh() async {}
}
@MainActor final class LocalPortfolioStore {
    static let shared = LocalPortfolioStore()
    func updateMarketQuotes(_ quotes: [String: Double]) async throws -> LocalPortfolioDocument {
        if Probe.mode == 1 { throw Failure.unavailable }
        return LocalPortfolioDocument(fresh: true)
    }
}
@MainActor final class Model {
    var portfolioRequestGeneration = 0
    var isPortfolioLoading = false
    var isPortfolioChartLoading = false
    var portfolioError: String?
    var isFakeDataMode = false
    var isPublicInvestorMode = false
    var publicInvestorStore = PublicStore()
    var publicInvestorSelection = ""
    var isHoldingDailyChangesLoading = false
    var holdings: [String] = []
    var document = LocalPortfolioDocument()
    func loadActiveDocument() async throws -> LocalPortfolioDocument {
        if Probe.mode == 2 { throw Failure.unavailable }
        return LocalPortfolioDocument()
    }
    func mergeCachedTrading212History(into value: LocalPortfolioDocument) async throws -> LocalPortfolioDocument { value }
    func apply(_ value: LocalPortfolioDocument, invalidatesDailyChanges: Bool = true,
               loadsCachedChart: Bool = true, preservesChart: Bool = false) async throws {
        precondition(!loadsCachedChart, "Refresh rebuilt the complete cached curve")
        document = value
        holdings = value.positions
        Probe.published = true
        if value.fresh {
            precondition(preservesChart, "Quote publication erased the prepared history")
            Probe.quotePublished = true
        }
        if invalidatesDailyChanges { isHoldingDailyChangesLoading = true }
    }
    func refreshHoldingDailyChanges() async { isHoldingDailyChangesLoading = false }
    func enrichPortfolioChart(from value: LocalPortfolioDocument, generation: Int) async {
        Probe.historyCalls += 1
        while Probe.mode == 3 && !Probe.releaseHistory && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        Probe.historyFinished = true
        isPortfolioChartLoading = false
    }
''' + method + helper + r'''
}
@main struct Tests {
    @MainActor static func main() async {
        for mode in 0...4 {
            Probe.mode = mode
            Probe.published = false
            Probe.visitedNetwork = false
            Probe.quotePublished = false
            Probe.historyCalls = 0
            Probe.historyFinished = false
            Probe.releaseHistory = false
            let model = Model()
            model.holdings = ["NVDA"]
            let refresh = Task { await model.refreshPortfolio(refreshMarketData: mode != 4) }
            if mode == 3 {
                let deadline = Date().addingTimeInterval(2)
                while !Probe.quotePublished && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                precondition(Probe.quotePublished, "Quotes were blocked behind history")
                precondition(!Probe.historyFinished, "The gate did not hold history")
                Probe.releaseHistory = true
            }
            await refresh.value
            precondition(model.holdings == ["NVDA"], "Refresh erased cached holdings")
            precondition(!model.isPortfolioLoading, "Loading did not settle")
            precondition(!model.isHoldingDailyChangesLoading, "Daily loading did not settle")
            precondition((model.portfolioError != nil) == (mode == 1 || mode == 2))
            precondition(Probe.visitedNetwork == (mode != 2 && mode != 4))
            precondition(Probe.historyCalls == (mode == 2 || mode == 4 ? 0 : 1), "History was rebuilt more than once")
        }
        print("Slow history, offline quotes, quote-save failure, disk-load failure, and cache-only load passed")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="catfolio-home-test-") as folder:
            fixture = Path(folder) / "HomeLoading.swift"
            fixture.write_text(harness)
            executable = Path(folder) / "checks"
            compiled = subprocess.run(
                ["swiftc", "-parse-as-library", str(fixture), "-o", str(executable)],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_skeleton_is_neutral_and_has_five_equal_bars(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        bars = source.split("private struct TodayContributionLoadingBars: View", 1)[1].split(
            "private struct TodayLoadingHeader", 1)[0]
        self.assertIn("0..<5", bars)
        self.assertIn(".frame(height: 140)", bars)
        self.assertIn(".frame(width: 30, height: 30)", bars)
        self.assertNotIn("contributionGreen", bars)
        self.assertIn("HomeSkeletonStyle.color", bars)
        self.assertIn("PortfolioLoadingView(isAnimating: model.isPortfolioLoading, scrollOffset: homeScrollOffset)", source)

    def test_all_contribution_bars_share_one_non_bouncy_reveal(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        animation = source.split("private enum TodayContributionAnimation", 1)[1].split(
            "private struct TodayContributionBar", 1
        )[0]
        card = source.split("private struct TodayContributionCard", 1)[1].split(
            "private enum TodayContributionAnimation", 1
        )[0]
        bar = source.split("private struct TodayContributionBar", 1)[1].split(
            "private struct ContributionBarButtonStyle", 1
        )[0]
        self.assertIn(".timingCurve(0.16, 1, 0.30, 1, duration: 0.34)", animation)
        self.assertNotIn("spring", animation)
        self.assertIn("barRevealProgress", card)
        self.assertIn("withAnimation(TodayContributionAnimation.reveal)", card)
        self.assertIn("growth: barRevealProgress", card)
        self.assertIn("transaction.disablesAnimations = true", card)
        self.assertIn("barRevealProgress = reduceMotion ? 1 : 0", card)
        self.assertNotIn("withAnimation(TodayContributionAnimation.reveal)", bar)
        self.assertNotIn("delay(", card)

    def test_home_backdrop_is_fixed_outside_the_scroll_view(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        backdrop = source.split("private struct PortfolioHomePageBackdrop", 1)[1].split(
            "struct PortfolioView", 1
        )[0]
        body = source.split("ScrollViewReader { scrollProxy in", 1)[1].split(
            ".sheet(item: $selectedHolding)", 1
        )[0]
        self.assertIn("colorScheme == .light ? Color.white : Color.black", backdrop)
        self.assertIn(".frame(maxWidth: .infinity, maxHeight: .infinity)", backdrop)
        self.assertLess(body.index("PortfolioHomePageBackdrop"), body.index("ScrollView {"))

    def test_ledger_history_downloads_have_bounded_concurrency(self):
        services = (ROOT / "LocalServices.swift").read_text()
        ledger = services.split("withThrowingTaskGroup(of: (String, LedgerPriceHistory?).self)", 1)[1]
        self.assertIn("min(4, symbols.count)", ledger)
        self.assertIn("group.addTask", ledger)
        self.assertIn("while let result = try await group.next()", ledger)


if __name__ == "__main__":
    unittest.main()
