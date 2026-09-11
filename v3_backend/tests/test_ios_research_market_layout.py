"""Contracts for the compact market and sector grids on iOS Research."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
RESEARCH = ROOT / "CatfolioIOS" / "CatfolioIOS" / "ResearchView.swift"


class ResearchMarketLayoutTests(unittest.TestCase):
    def test_sector_performance_moves_to_rotation_with_existing_market_data(self) -> None:
        research = RESEARCH.read_text()
        rotation = (RESEARCH.parent / "SectorRotationView.swift").read_text()
        performance = (RESEARCH.parent / "SectorPerformance.swift").read_text()
        self.assertNotIn('Text(L10n.text("板块表现"))', research)
        self.assertIn("let definitions = Self.benchmarks", research)
        self.assertNotIn("Self.sectors", research)
        self.assertIn("SectorPerformancePanel(store: sectorPerformance, rotation: snapshot)", rotation)
        self.assertIn("ResearchMarketSnapshot(id:", performance)
        self.assertIn("cachedOnly: true", performance)
        self.assertIn("SectorPerformanceDetailView(definition: definition, store: store", performance)

    def test_key_indicator_tiles_use_a_compact_local_layout(self) -> None:
        source = RESEARCH.read_text()
        cell = source.split("private func marketCell", 1)[1].split(
            "private func marketRow", 1
        )[0]

        self.assertIn("let compactTile = !dynamicTypeSize.isAccessibilitySize", cell)
        self.assertIn("spacing: compactTile ? 6 : 10", cell)
        self.assertIn(".frame(height: compactTile ? 52 : 64)", cell)
        self.assertIn(".padding(.horizontal, compactTile ? 14", cell)
        self.assertIn(".padding(.vertical, compactTile ? 14", cell)
        self.assertIn(".minimumScaleFactor(0.6)", cell)
        self.assertIn("AxisValueLabel", cell)


if __name__ == "__main__":
    unittest.main()
