"""Regression checks for range-picker scroll residency."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


class TimePickerScrollPerformanceTests(unittest.TestCase):
    def test_home_pinned_hero_is_not_recycled_at_the_picker_boundary(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        home = source[
            source.index("struct PortfolioView: View"):
            source.index("private struct PortfolioRefreshTimestamp")
        ]
        scroll = home[
            home.index("ScrollView {"):
            home.index(".tracksRootTabBarScroll")
        ]

        self.assertIn("VStack(spacing: 0)", scroll)
        self.assertNotIn("LazyVStack(spacing: 0)", scroll)
        self.assertIn("CostMarketCard(", scroll)
        self.assertIn("isAwaitingEnrichedHistory: model.isPortfolioChartLoading", scroll)
        self.assertIn(".offset(y: homeScrollOffset)", scroll)

    def test_holding_header_chart_stays_resident_while_scrolling(self):
        source = (ROOT / "VolumeProfileView.swift").read_text()
        detail = source[
            source.index("struct HoldingDetailView: View"):
            source.index("private var averageCostInQuoteCurrency")
        ]
        top = detail[:detail.index("LazyVStack(spacing: 64)")]

        self.assertIn("VStack(spacing: 0)", top)
        self.assertNotIn("LazyVStack(spacing: 0)", top)
        self.assertIn("HoldingDetailPriceSection(", top)

    def test_security_chart_drag_does_not_rebuild_the_detail_page_or_all_ranges(self):
        source = (ROOT / "VolumeProfileView.swift").read_text()
        detail = source[
            source.index("struct HoldingDetailView: View"):
            source.index("struct HoldingDetailPriceSection")
        ]
        section = source[
            source.index("struct HoldingDetailPriceSection"):
            source.index("private struct HoldingDetailAccountSelector")
        ]
        chart = source[
            source.index("private struct SecurityPriceChart: View"):
            source.index("private struct SecurityPriceCostLegend")
        ]

        self.assertNotIn("@State private var priceSelection", detail)
        self.assertIn("@State private var priceSelection", section)
        self.assertIn("SecurityPricePreparedData", chart)
        self.assertIn("Task.detached(priority: .userInitiated)", chart)
        self.assertNotIn("Dictionary(uniqueKeysWithValues: ChartTimeRange.allCases", chart)
        self.assertIn("1.0 / 30.0", chart)

    def test_home_chart_publishes_default_range_before_filling_all_ranges(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        card = source[
            source.index("private struct CostMarketCard: View"):
            source.index("private struct FastCostMarketPlot: View")
        ]
        prepared = source[
            source.index("private final class CostMarketPreparedData"):
            source.index("private struct CostMarketRangeData")
        ]

        source_build = card.index("CostMarketPreparedSource(response: response)")
        initial = card.index("CostMarketPreparedData(source: source, requestedRanges: initialRanges)")
        visible = card.index("isPreparing = false", initial)
        complete = card.index("CostMarketPreparedData(source: source)", visible)
        self.assertLess(source_build, initial)
        self.assertLess(initial, visible)
        self.assertLess(visible, complete)
        self.assertIn("Task.detached(priority: .utility)", card)
        self.assertIn("isDisabled: isChartLoading || !hasPreparedAllRanges", card)
        self.assertIn("else if isChartLoading", card)
        self.assertIn("Color.clear", card)
        self.assertIn("private final class CostMarketPreparedSource", source)
        self.assertIn("requestedRanges: [ChartTimeRange] = ChartTimeRange.allCases", prepared)


if __name__ == "__main__":
    unittest.main()
