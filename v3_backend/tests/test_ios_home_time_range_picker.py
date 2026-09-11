"""Contracts for the global grouped, repeat-tap chart time picker."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PORTFOLIO = ROOT / "CatfolioIOS" / "CatfolioIOS" / "PortfolioView.swift"
DESIGN_SYSTEM = ROOT / "CatfolioIOS" / "CatfolioIOS" / "DesignSystem.swift"
RETURNS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "ReturnsView.swift"
ANALYTICS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "ReturnsAnalyticsView.swift"
DETAIL = ROOT / "CatfolioIOS" / "CatfolioIOS" / "VolumeProfileView.swift"


class HomeTimeRangePickerTests(unittest.TestCase):
    def test_global_range_type_owns_the_five_groups(self) -> None:
        source = DESIGN_SYSTEM.read_text()
        ranges = source.split("enum ChartTimeRange", 1)[1].split(
            "struct ChartTimeRangePicker", 1
        )[0]

        for group in (
            "[.oneWeek, .oneDay]",
            "[.oneMonth, .twoMonths]",
            "[.yearToDate, .sixMonths]",
            "[.oneYear, .twoYears]",
            "[.maximum]",
        ):
            self.assertIn(group, ranges)
        self.assertNotIn("[.oneDay, .oneWeek]", ranges)

    def test_every_chart_calls_the_same_global_picker(self) -> None:
        for path in (PORTFOLIO, RETURNS, ANALYTICS, DETAIL):
            source = path.read_text()
            self.assertIn("ChartTimeRangePicker(", source)
        self.assertNotIn("private struct SecurityPriceRangePicker", DETAIL.read_text())

    def test_home_defaults_to_year_to_date(self) -> None:
        source = PORTFOLIO.read_text()
        card = source.split("private struct CostMarketCard: View", 1)[1].split(
            "private struct FastCostMarketPlot", 1
        )[0]

        self.assertIn("@State private var range = ChartTimeRange.yearToDate", card)

    def test_home_lines_zoom_the_viewport_when_the_range_changes(self) -> None:
        source = PORTFOLIO.read_text()
        plot = source.split("private struct FastCostMarketPlot", 1)[1].split(
            "private final class CostMarketPreparedData", 1
        )[0]
        shared = (ROOT / "CatfolioIOS" / "CatfolioIOS" / "StandardLineChart.swift").read_text()

        self.assertIn("dataTransition: .viewportZoom", plot)
        self.assertIn("animatesInitialAppearance: true", plot)
        self.assertNotIn("revealsInitialAppearance: true", plot)
        self.assertIn("case viewportZoom", shared)
        self.assertIn("drawViewportZoomedSeries(", shared)
        self.assertIn("interpolatedDate(from: oldStart, to: newStart", shared)
        self.assertIn("interpolatedDomain(", shared)

    def test_other_shared_line_charts_morph_the_entrance_and_zoom_ranges(self) -> None:
        returns = RETURNS.read_text()
        analytics = ANALYTICS.read_text()
        detail = DETAIL.read_text()

        for source in (returns, analytics, detail):
            self.assertIn("dataTransition: .viewportZoom", source)
            self.assertIn("animatesInitialAppearance: true", source)

        # Their semantic overlays remain owned by each feature.
        self.assertIn("rangePrimarySeriesID: ReturnsSeriesStyle.portfolio", returns)
        self.assertIn("areaFill: CatfolioStyle.blue.opacity(0.065)", analytics)
        self.assertIn("markers: data.trades.map", detail)
        self.assertIn("referenceLines: [costReference].compactMap", detail)

        # Loading may retain layout/axis placeholders, but never invent a line.
        self.assertGreaterEqual(returns.count("showsSeries: false"), 2)
        self.assertGreaterEqual(detail.count("showsSeries: false"), 2)

    def test_repeat_tap_cycles_within_the_selected_group(self) -> None:
        source = DESIGN_SYSTEM.read_text()
        picker = source.split("struct ChartTimeRangePicker: View", 1)[1].split(
            "struct ChartTimeRangePickerSkeleton", 1
        )[0]

        self.assertIn("group.firstIndex(of: selection)", picker)
        self.assertIn("group[(selectedIndex + 1) % group.count]", picker)
        self.assertIn("group.contains(selection)", picker)
        self.assertIn("再次轻点切换到", picker)
        self.assertIn("@Binding var selection: ChartTimeRange", picker)
        self.assertNotIn("choices:", picker)

    def test_range_labels_morph_per_character_without_animating_chart_state(self) -> None:
        source = DESIGN_SYSTEM.read_text()
        morph = source.split(
            "private struct ChartTimeRangeMorphingLabel: View", 1
        )[1].split("struct ChartTimeRangePicker: View", 1)[0]
        picker = source.split("struct ChartTimeRangePicker: View", 1)[1].split(
            "struct ChartTimeRangePickerSkeleton", 1
        )[0]

        self.assertIn("Array(text.enumerated())", morph)
        self.assertIn('.id("\\(item.offset)-\\(item.element)")', morph)
        self.assertIn("insertion: .offset(y: 5).combined(with: .opacity)", morph)
        self.assertIn("removal: .offset(y: -5).combined(with: .opacity)", morph)
        self.assertIn("accessibilityReduceMotion", morph)
        self.assertIn(".animation(textAnimation, value: text)", morph)
        self.assertIn("ChartTimeRangeMorphingLabel(text: choice.title)", picker)
        self.assertNotIn("withAnimation", picker)

    def test_two_month_and_two_year_ranges_use_real_date_filters(self) -> None:
        source = DESIGN_SYSTEM.read_text()
        ranges = source.split("enum ChartTimeRange", 1)[1].split(
            "struct ChartTimeRangePicker", 1
        )[0]

        self.assertIn("case .twoMonths:", ranges)
        self.assertIn("value: -2, to: lastDate", ranges)
        self.assertIn("case .twoYears:", ranges)
        self.assertIn("value: -2, to: lastDate", ranges)
        self.assertIn("case .sixMonths:", ranges)
        self.assertIn("value: -6, to: lastDate", ranges)

    def test_one_day_hides_only_the_latest_endpoint_dots(self) -> None:
        source = PORTFOLIO.read_text()
        card = source.split("private struct CostMarketCard: View", 1)[1].split(
            "private struct FastCostMarketPlot", 1
        )[0]
        plot = source.split("private struct FastCostMarketPlot", 1)[1].split(
            "private final class CostMarketPreparedData", 1
        )[0]

        self.assertIn("showsLatestPoint: range != .oneDay", card)
        self.assertEqual(plot.count("latestPointRadius: showsLatestPoint ? 5 : 0"), 2)


if __name__ == "__main__":
    unittest.main()
