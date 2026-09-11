"""Detail research applicability uses offline identity and actual content."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


class FundResearchVisibilityTests(unittest.TestCase):
    def test_all_research_modules_share_one_visibility_policy(self):
        source = (ROOT / "VolumeProfileView.swift").read_text()
        section = source.split("struct HoldingResearchSection: View", 1)[1].split("private struct HoldingFinancialCard", 1)[0]
        for module in ("developments", "consensus", "analystHistory", "earnings", "financials", "predictionMarkets"):
            self.assertIn(f"visibility.shows(.{module})", section)
        self.assertIn("if visibility.hasVisibleModules", section)
        self.assertIn(".padding(.top, 40)", section)
        self.assertIn("HoldingResearchSection(holding: holding", source)

    def test_visibility_restore_only_reads_existing_data(self):
        source = (ROOT / "VolumeProfileView.swift").read_text()
        restore = source.split("private func restoreAvailableContent()", 1)[1].split("private struct HoldingFinancialCard", 1)[0]
        for getter in ("AnalystConsensusClient.shared.cached", "EarningsHistoryClient.shared.cached",
                       "CompanyFinancialsClient.shared.cached", "PolymarketClient.shared.cachedRelatedMarkets"):
            self.assertIn(getter, restore)
        for forbidden in ("researchAnswer", ".start(", ".load(", "forceRefresh: true", "removeItem", ".clear("):
            self.assertNotIn(forbidden, restore)

    def test_identity_uses_reference_type_and_exact_etf_directory(self):
        source = (ROOT / "CompanyReferenceCatalog.swift").read_text()
        identity = source.split("enum HoldingSecurityKind", 1)[1].split("enum HoldingResearchModule", 1)[0]
        self.assertIn("entry(brokerSymbol: holding.ticker)", identity)
        self.assertIn("entry?.instrumentType", identity)
        self.assertIn("LocalETFLookThrough.isKnownFund", identity)
        self.assertNotIn("holding.shares", identity)
        self.assertNotIn("holding.sector", identity)
        self.assertNotIn("holding.source", identity)

    def test_history_entry_is_not_just_a_nonempty_ticker(self):
        source = (ROOT / "AnalystConsensusView.swift").read_text()
        self.assertIn("showsHistoryEntry ?? Self.hasHistory(symbol: symbol)", source)
        self.assertIn("AnalystHistorySnapshot.load(symbol: symbol)?.points.contains", source)
        self.assertIn("guard data?.hasContent == true else { return }", source)

    def test_empty_financial_entry_is_removed_after_native_dismissal(self):
        source = (ROOT / "VolumeProfileView.swift").read_text()
        card = source.split("private struct HoldingFinancialCard: View", 1)[1].split("private struct HoldingPredictionMarketsCard", 1)[0]
        self.assertIn("onDismiss: { onAvailability(availability) }", card)
        self.assertIn("onAvailability: { availability = $0 }", card)
        self.assertIn(".navigationTransition(.zoom", card)

    def test_known_fund_caches_do_not_trigger_an_extra_request(self):
        source = (ROOT / "VolumeProfileView.swift").read_text()
        card = source.split("private struct HoldingPredictionMarketsCard: View", 1)[1].split("enum HoldingDetailCardStyle", 1)[0]
        self.assertIn("if usesCachedContentOnlyInitially", card)
        self.assertIn("onAvailability(markets.isEmpty ? .empty : .available)", card)
        self.assertNotIn("markets = []", card.split("private func load(forceRefresh:", 1)[1])


if __name__ == "__main__":
    unittest.main()
