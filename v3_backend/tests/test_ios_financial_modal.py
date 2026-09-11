"""Structural checks for the native nested Financial presentation."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"
HOLDING_DETAIL = ROOT / "VolumeProfileView.swift"
FINANCIALS = ROOT / "CompanyFinancialsView.swift"


class FinancialModalPresentationTests(unittest.TestCase):
    def test_financial_card_presents_a_second_native_sheet(self):
        source = HOLDING_DETAIL.read_text()
        card = source[
            source.index("private struct HoldingFinancialCard: View"):
            source.index("private struct HoldingPredictionMarketsCard: View")
        ]

        self.assertIn(".sheet(isPresented: $showsFinancials, onDismiss:", card)
        self.assertIn("NavigationStack {", card)
        self.assertIn(".presentationDetents([.large])", card)
        self.assertIn(".presentationDragIndicator(.visible)", card)
        self.assertNotIn("NavigationLink {", card)

    def test_financial_sheet_uses_the_official_interactive_zoom_transition(self):
        source = HOLDING_DETAIL.read_text()
        card = source[
            source.index("private struct HoldingFinancialCard: View"):
            source.index("private struct HoldingPredictionMarketsCard: View")
        ]

        self.assertIn("@Namespace private var zoom", card)
        self.assertIn(".matchedTransitionSource(id: holding.ticker, in: zoom)", card)
        self.assertIn(
            ".navigationTransition(.zoom(sourceID: holding.ticker, in: zoom))",
            card,
        )

    def test_financial_sheet_has_a_native_close_action(self):
        source = FINANCIALS.read_text()

        self.assertIn("@Environment(\\.dismiss) private var dismiss", source)
        self.assertIn("ToolbarItem(placement: .cancellationAction)", source)
        self.assertIn('Label(L10n.text("关闭"), systemImage: "xmark")', source)


if __name__ == "__main__":
    unittest.main()
