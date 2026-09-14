"""Structural checks for the Figma-matched scrolling home content sheet."""
from pathlib import Path
import unittest

PORTFOLIO = (
    Path(__file__).resolve().parents[2]
    / "CatfolioIOS"
    / "CatfolioIOS"
    / "PortfolioView.swift"
)


class HomeContentSheetTests(unittest.TestCase):
    def test_page_backdrop_is_one_full_viewport_blue_to_white_gradient(self) -> None:
        source = PORTFOLIO.read_text()
        gradient = source.split("private struct PortfolioHomeTopBackground", 1)[1].split(
            "private struct PortfolioHomePageBackdrop", 1
        )[0]
        backdrop = source.split("private struct PortfolioHomePageBackdrop", 1)[1].split(
            "private enum PortfolioContentSheetLayout", 1
        )[0]

        self.assertIn("Color(red: 154 / 255, green: 220 / 255, blue: 1)", gradient)
        self.assertIn(".init(color: .white, location: 1)", gradient)
        self.assertIn(".frame(maxWidth: .infinity, maxHeight: .infinity)", backdrop)
        self.assertIn("private var gradientDismissalProgress: CGFloat", backdrop)
        self.assertIn("guard let start = fadeStartOffset else { return 0 }", backdrop)
        self.assertIn("start + PortfolioContentSheetLayout.backdropFadeDistance", backdrop)
        self.assertIn("(scrollOffset - start) / max(end - start, 1)", backdrop)
        self.assertIn("linear * linear * (3 - 2 * linear)", backdrop)
        self.assertIn("static let backdropFadeDistance: CGFloat = transitionHeight - 47", source)
        self.assertIn(".opacity(1 - gradientDismissalProgress)", backdrop)
        self.assertNotIn(".frame(height: 520)", backdrop)
        self.assertNotIn(".frame(height: 180)", backdrop)

    def test_today_and_holdings_share_one_scrolling_content_sheet(self) -> None:
        source = PORTFOLIO.read_text()
        home = source.split("struct PortfolioView: View", 1)[1].split(
            "private struct PortfolioRefreshTimestamp", 1
        )[0]

        sheet = home.index("PortfolioContentSheet(scrollOffset: homeScrollOffset)")
        today = home.index("TodayContributionCard(", sheet)
        holdings = home.index("PortfolioDetailsCard(", today)
        self.assertLess(sheet, today)
        self.assertLess(today, holdings)
        self.assertIn("VStack(spacing: 0)", home[sheet:holdings])

    def test_backdrop_starts_fading_only_after_today_title_leaves_screen(self) -> None:
        source = PORTFOLIO.read_text()
        home = source.split("struct PortfolioView: View", 1)[1].split(
            "private struct PortfolioRefreshTimestamp", 1
        )[0]
        card = source.split("private struct TodayContributionCard", 1)[1].split(
            "private enum TodayContributionAnimation", 1
        )[0]

        self.assertIn("@State private var todayTitleExitScrollOffset: CGFloat?", home)
        self.assertIn("fadeStartOffset: todayTitleExitScrollOffset", home)
        self.assertIn("let exitOffset = homeScrollOffset + titleBottomY", home)
        self.assertIn("geometry.frame(in: .global).maxY", card)
        self.assertIn("onTitleBottomPositionChange?(newValue)", card)

    def test_foreground_sheet_scrolls_over_the_fixed_hero_chart(self) -> None:
        source = PORTFOLIO.read_text()
        home = source.split("struct PortfolioView: View", 1)[1].split(
            "private struct PortfolioRefreshTimestamp", 1
        )[0]
        hero = home.index("CostMarketCard(")
        sheet = home.index("PortfolioContentSheet(scrollOffset: homeScrollOffset)", hero)

        hero_source = home[hero:sheet]
        self.assertIn(".offset(y: homeScrollOffset)", hero_source)
        self.assertIn(".zIndex(0)", hero_source)
        self.assertIn(".zIndex(1)", home[sheet:])

    def test_today_direction_picker_matches_figma_toggle_pill(self) -> None:
        source = PORTFOLIO.read_text()
        card = source.split("private struct TodayContributionCard", 1)[1].split(
            "private enum TodayContributionAnimation", 1
        )[0]

        self.assertIn(".background(Color.white.opacity(0.40), in: Capsule())", card)
        self.assertIn("HStack(spacing: 2)", card)
        self.assertIn(".padding(3)", card)
        self.assertIn(".frame(width: 97, height: 47)", card)
        self.assertIn(".frame(width: 44, height: 41)", card)
        self.assertIn(".fill(Color.white)", card)
        self.assertIn(".shadow(color: Color.black.opacity(0.10), radius: 2, y: 2)", card)
        self.assertNotIn("GlassEffectContainer(spacing: 2)", card)

    def test_dark_today_glow_cannot_intercept_chart_or_picker_taps(self) -> None:
        source = PORTFOLIO.read_text()
        sheet = source.split("private struct PortfolioContentSheet<", 1)[1].split(
            "private struct PortfolioContentSheetBackground", 1
        )[0]
        card = source.split("private struct TodayContributionCard", 1)[1].split(
            "private enum TodayContributionAnimation", 1
        )[0]

        self.assertIn("PortfolioContentSheetBackground(", sheet)
        self.assertIn(".allowsHitTesting(false)", sheet)
        self.assertIn("todayBackground\n                .allowsHitTesting(false)", card)

    def test_sheet_expands_and_keeps_liquid_glass_while_scrolling(self) -> None:
        source = PORTFOLIO.read_text()
        layout = source.split("private enum PortfolioContentSheetLayout", 1)[1].split(
            "private struct PortfolioContentSheet<", 1
        )[0]
        sheet = source.split("private struct PortfolioContentSheet<", 1)[1].split(
            "private struct PortfolioContentSheetBackground", 1
        )[0]
        background = source.split("private struct PortfolioContentSheetBackground", 1)[1].split(
            "struct PortfolioView", 1
        )[0]

        self.assertIn("initialHorizontalInset: CGFloat = 12", layout)
        self.assertIn("widthExpansionDistance: CGFloat = 263", layout)
        self.assertIn("initialHorizontalInset * (1 - widthProgress)", sheet)
        self.assertIn("private var settlingProgress: CGFloat", sheet)
        self.assertIn("settlingProgress: settlingProgress", sheet)
        self.assertIn("if #available(iOS 26.0, *)", background)
        self.assertIn(".glassEffect(", background)
        self.assertIn(".clear,", background)
        self.assertNotIn(".clear.interactive()", background)
        self.assertNotIn(".regular,", background)
        self.assertIn("in: sheetShape", background)
        self.assertIn(".fill(.ultraThinMaterial)", background)
        self.assertNotIn(".mask", background)
        self.assertNotIn("solidProgress", sheet)
        self.assertNotIn("solidProgress", background)
        self.assertIn("terminalColor.opacity(settlingProgress)", background)
        self.assertIn("terminalColor.opacity(0.10)", background)
        self.assertIn("terminalColor.opacity(0.54)", background)
        self.assertIn("terminalColor", background)

    def test_home_keeps_native_scroll_tracking_with_touch_scoped_controller(self) -> None:
        source = PORTFOLIO.read_text()
        home = source.split("struct PortfolioView: View", 1)[1].split(
            "private struct PortfolioRefreshTimestamp", 1
        )[0]
        interaction = PORTFOLIO.with_name("PortfolioHomeScrollInteraction.swift").read_text()
        self.assertIn(".tracksRootTabBarScroll()", home)
        self.assertIn("PortfolioHomeScrollBridge(", home)
        self.assertIn("homeScrollOffset = offset", home)
        self.assertIn("homePullDistance = pull", home)
        self.assertIn("PortfolioHeroChartLayout.sectionHeight - PortfolioHeroChartLayout.plotTop", source)
        self.assertIn("static let response: Double = 0.42", interaction)
        self.assertIn("static let dampingRatio: Double = 0.82", interaction)
        self.assertIn("PortfolioHomeSnapMotion.Spring(start: offset, end: target, velocity: velocity", interaction)
        self.assertNotIn("DragGesture", home)
        self.assertNotIn(".spring(", interaction)

    def test_refresh_is_native_and_gated_before_the_pull(self) -> None:
        source = PORTFOLIO.read_text()
        home = source.split("struct PortfolioView: View", 1)[1].split(
            "private struct PortfolioRefreshTimestamp", 1
        )[0]
        interaction = PORTFOLIO.with_name("PortfolioHomeScrollInteraction.swift").read_text()
        self.assertIn("refresh: { await model.refreshPortfolio() }", home)
        self.assertIn("let refreshControl = UIRefreshControl()", interaction)
        self.assertIn("gate.beginTouch(offset: offset, isSettling: isSettling", interaction)
        self.assertIn("scroll.refreshControl = gate.permitsRefresh ? refreshControl : nil", interaction)
        self.assertIn("guard gate.beginRefresh() else", interaction)
        self.assertIn("self.refreshControl.endRefreshing()", interaction)
        self.assertNotIn(".refreshable", home)  # No second, independently armed control.
        self.assertNotIn("PortfolioHomePullResistance", source)  # One native rubber-band.
        self.assertIn("guard homePullDistance < 0.5 else { return }", home)

    def test_home_scroll_tail_clears_the_floating_tab_bar(self) -> None:
        source = PORTFOLIO.read_text()
        home = source.split("struct PortfolioView: View", 1)[1].split(
            "private struct PortfolioRefreshTimestamp", 1
        )[0]

        self.assertIn(".padding(.bottom, 96)", home)
        self.assertNotIn(".padding(.bottom, 16)", home)


if __name__ == "__main__":
    unittest.main()
