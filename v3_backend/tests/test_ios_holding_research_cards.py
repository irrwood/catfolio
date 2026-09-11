"""Keep the holding research section on the Financial card's shared shell."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


class HoldingResearchCardTests(unittest.TestCase):
    def test_research_spacing_is_separate_from_chart_spacing(self):
        source = (ROOT / "VolumeProfileView.swift").read_text()
        research = source.split("LazyVStack(spacing: HoldingDetailCardStyle.spacing)", 1)[1]
        research = research.split(".padding(.bottom, 72)", 1)[0]
        for name in ("SecurityDebateCard", "AnalystConsensusView", "EarningsHistoryView",
                     "HoldingFinancialCard", "HoldingPredictionMarketsCard"):
            self.assertIn(name, research)
        self.assertIn(".padding(.horizontal, HoldingDetailCardStyle.pageInset)", research)
        self.assertNotIn(".padding(.horizontal, -8)", research)
        self.assertIn("LazyVStack(spacing: 64)", source)

    def test_entry_cards_share_the_financial_label(self):
        for filename in ("VolumeProfileView.swift", "SecurityDebateView.swift", "AnalystConsensusView.swift"):
            self.assertIn("HoldingDetailActionCardLabel(", (ROOT / filename).read_text())
        analyst = (ROOT / "AnalystConsensusView.swift").read_text()
        self.assertIn("VStack(spacing: HoldingDetailCardStyle.spacing)", analyst)
        self.assertEqual(analyst.count("HoldingDetailActionCardLabel("), 2)

    def test_ai_keeps_shared_surface_across_states_without_starting_on_appear(self):
        source = (ROOT / "SecurityDebateView.swift").read_text()
        card = source.split("struct SecurityDebateCardContent: View", 1)[1].split("struct SecurityDebateInbox", 1)[0]
        self.assertIn(".holdingDetailGlassCard()", card)
        self.assertIn("SecurityDebateSection(debate: debate, isHoldingCard: true)", card)
        self.assertIn("Button(action: onStart)", card)
        self.assertNotIn("store.start", card)
        self.assertNotIn(".task", card)
        self.assertNotIn("cornerRadius: 14", card)

    def test_earnings_title_and_chart_share_one_glass_surface(self):
        source = (ROOT / "EarningsHistoryView.swift").read_text()
        self.assertIn(".padding(HoldingDetailCardStyle.contentInset)", source)
        self.assertIn(".holdingDetailGlassCard()", source)
        self.assertNotIn(".padding(24)", source)
        self.assertIn(".pickerStyle(.segmented)", source)
        self.assertIn("await load(force: false)", source)

    def test_shared_shell_keeps_financial_dimensions(self):
        source = (ROOT / "VolumeProfileView.swift").read_text()
        style = source.split("enum HoldingDetailCardStyle", 1)[1].split("struct HoldingDetailGlassCardModifier", 1)[0]
        for value in ("pageInset: CGFloat = 16", "contentInset: CGFloat = 20", "spacing: CGFloat = 16",
                      "cornerRadius: CGFloat = 24", "minimumRowHeight: CGFloat = 105"):
            self.assertIn(value, style)
        self.assertIn(".appText(.subheading, weight: .medium)", style)
        self.assertIn(".appText(.label, weight: .medium)", style)


if __name__ == "__main__":
    unittest.main()
