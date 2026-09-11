from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


class LineChartMotionContracts(unittest.TestCase):
    def test_shared_consumers_use_template_entrance(self):
        for name in ("PortfolioView", "VolumeProfileView", "ReturnsView", "ReturnsAnalyticsView"):
            text = (ROOT / f"{name}.swift").read_text()
            self.assertIn("animatesInitialAppearance: true", text)
            self.assertNotIn("revealsInitialAppearance: true", text)

    def test_swift_charts_share_entrance_without_replacing_special_marks(self):
        for name in ("ResearchView", "SectorPerformance", "StockChartsRotationView", "AnalystHistoryView"):
            self.assertIn("StandardLineChartEntrance { phase in", (ROOT / f"{name}.swift").read_text())
        history = (ROOT / "AnalystHistoryView.swift").read_text()
        for contract in ("AreaMark", "BarMark", "priceSegment(for: p)", "segment(for: p)", ".chartXSelection(value: $selection)"):
            self.assertIn(contract, history)

    def test_rebased_series_are_interpolated_not_spliced(self):
        text = (ROOT / "StandardLineChart.swift").read_text()
        self.assertNotIn("samplesByDate", text)
        self.assertIn("oldValues[index] + (newValues[index] - oldValues[index]) * t", text)
        self.assertIn("currentPresentation(progress: presentationProgress.value)", text)
        self.assertIn("morphPairs = Dictionary", text)
        self.assertIn("guard generation == transitionGeneration", text)
        self.assertIn(".onChange(of: reduceMotion)", text)

    def test_markers_and_cost_use_the_animated_projection(self):
        text = (ROOT / "StandardLineChart.swift").read_text()
        self.assertIn("let paths = viewportPaths.mapValues { $0.samples(progress: progress) }", text)
        self.assertIn("StandardLineChartViewportPath.value(at: date, in: samples)", text)
        self.assertNotIn("progress / 0.45", text)
        self.assertEqual(text.count("referenceY(reference.value, plot: plot, progress: progress)"), 2)
        detail = (ROOT / "VolumeProfileView.swift").read_text()
        self.assertIn('seriesID: "price"', detail)
        self.assertIn("sampled + visibleTrades.map(\\.point)", detail)
        self.assertIn("referenceLines: [costReference].compactMap", detail)


if __name__ == "__main__":
    unittest.main()
