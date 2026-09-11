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
    def test_refresh_publishes_cache_before_network_and_retains_it_on_failure(self):
        source = (ROOT / "APIClient.swift").read_text()
        method = source[source.index("    func refreshPortfolio() async {"):
                        source.index("    private func mergeCachedTrading212History(")]
        harness = r'''
import Foundation
struct Document { var positions = ["NVDA"] }
enum Failure: Error { case unavailable }
@MainActor enum Probe {
    static var mode = 0
    static var published = false
    static var visitedNetwork = false
}
@MainActor struct LocalMarketDataClient {
    func latestQuotes(for positions: [String]) async -> [String: Double] {
        precondition(Probe.published, "Network ran before local presentation")
        Probe.visitedNetwork = true
        try? await Task.sleep(for: .milliseconds(40))
        return Probe.mode == 0 ? [:] : ["NVDA": 123]
    }
}
@MainActor final class LocalCurrentFXRefresh {
    static let shared = LocalCurrentFXRefresh()
    func refresh() async {}
}
@MainActor final class LocalPortfolioStore {
    static let shared = LocalPortfolioStore()
    func updateMarketQuotes(_ quotes: [String: Double]) async throws -> Document {
        if Probe.mode == 1 { throw Failure.unavailable }
        return Document()
    }
}
@MainActor final class Model {
    var portfolioRequestGeneration = 0
    var isPortfolioLoading = false
    var isPortfolioChartLoading = false
    var portfolioError: String?
    var isFakeDataMode = false
    var isPublicInvestorMode = false
    var isHoldingDailyChangesLoading = false
    var holdings: [String] = []
    var document = Document()
    func loadActiveDocument() async throws -> Document {
        if Probe.mode == 2 { throw Failure.unavailable }
        return Document()
    }
    func mergeCachedTrading212History(into value: Document) async throws -> Document { value }
    func apply(_ value: Document, invalidatesDailyChanges: Bool = true) throws {
        document = value
        holdings = value.positions
        Probe.published = true
        if invalidatesDailyChanges { isHoldingDailyChangesLoading = true }
    }
    func refreshHoldingDailyChanges() async { isHoldingDailyChangesLoading = false }
    func enrichPortfolioChart(from value: Document, generation: Int) async {}
''' + method + r'''
}
@main struct Tests {
    @MainActor static func main() async {
        for mode in 0...2 {
            Probe.mode = mode
            Probe.published = false
            Probe.visitedNetwork = false
            let model = Model()
            model.holdings = ["NVDA"]
            await model.refreshPortfolio()
            precondition(model.holdings == ["NVDA"], "Refresh erased cached holdings")
            precondition(!model.isPortfolioLoading, "Loading did not settle")
            precondition(!model.isHoldingDailyChangesLoading, "Daily loading did not settle")
            precondition((model.portfolioError != nil) == (mode != 0))
            precondition(Probe.visitedNetwork == (mode != 2))
        }
        print("Offline quotes, quote-save failure, and disk-load failure passed")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="catfolio-home-test-") as folder:
            fixture = Path(folder) / "HomeLoading.swift"
            fixture.write_text(harness)
            executable = Path(folder) / "checks"
            compiled = subprocess.run(
                ["swiftc", "-parse-as-library", str(fixture), "-o", str(executable)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            subprocess.run([str(executable)], check=True, capture_output=True, text=True)

    def test_skeleton_is_neutral_and_has_five_equal_bars(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        bars = source.split("private struct TodayContributionLoadingBars: View", 1)[1].split(
            "private struct TodayLoadingHeader", 1)[0]
        self.assertIn("0..<5", bars)
        self.assertIn(".frame(height: 140)", bars)
        self.assertIn(".frame(width: 30, height: 30)", bars)
        self.assertNotIn("contributionGreen", bars)
        self.assertIn("HomeSkeletonStyle.color", bars)
        self.assertIn("PortfolioLoadingView(isAnimating: model.isPortfolioLoading)", source)

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

    def test_chart_uses_complete_disk_history_before_network_enrichment(self):
        model = (ROOT / "APIClient.swift").read_text()
        services = (ROOT / "LocalServices.swift").read_text()
        refresh = model.split("func refreshPortfolio() async", 1)[1].split(
            "private func mergeCachedTrading212History", 1
        )[0]

        self.assertIn("cachedOnly: true", model)
        self.assertLess(
            refresh.index("await enrichPortfolioChart(from: document"),
            refresh.index("let quotes = await LocalMarketDataClient().latestQuotes"),
        )
        self.assertIn("if cachedOnly, histories.count != symbols.count", services)
        self.assertIn("if cachedOnly {", services)


if __name__ == "__main__":
    unittest.main()
