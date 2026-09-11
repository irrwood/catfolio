"""Execute the production chart-difference calculation without UI dependencies."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


class HomeMeasurementTests(unittest.TestCase):
    def test_cost_adjusted_selection(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        calculation = source.split("private func costMarketChange(", 1)[1].split(
            "private struct CostMarketPlotPoint", 1)[0]
        fixture = """
struct CostMarketPlotPoint { let marketValue: Double; let cost: Double }
""" + "private func costMarketChange(" + calculation + """
func check(_ a: Double, _ b: Double, _ c: Double, _ d: Double,
           _ amount: Double, _ percent: Double) {
    let result = costMarketChange(from: .init(marketValue: a, cost: b),
                                  to: .init(marketValue: c, cost: d))
    precondition(abs(result.amount - amount) < 0.000001)
    precondition(abs(result.percentage - percent) < 0.000001)
}
check(100, 80, 150, 130, 0, 0) // Capital increase is not profit.
check(100, 80, 160, 130, 10, 10)
check(100, 80, 60, 50, -10, -10) // Preserve the negative sign.
check(100, 80, 100, 80, 0, 0)
check(0, 0, 50, 50, 0, 0)
check(125, 100, 200, 162.5, 12.5, 10) // Common currency scaling preserves percent.
"""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "check.swift"
            path.write_text(fixture)
            subprocess.run(["swift", str(path)], check=True, capture_output=True)

    def test_header_and_toggle_contract(self):
        source = (ROOT / "PortfolioView.swift").read_text()
        card = source.split("private struct CostMarketCard: View", 1)[1].split(
            "private struct FastCostMarketPlot", 1)[0]
        self.assertIn("private var displayedPrimaryAmount: Double {\n        displayedMarketValue", card)
        self.assertNotIn("ENDING VALUE", card)
        self.assertNotIn("abs(rangePerformance.percentage)", card)
        self.assertIn("showsNetDeposit.toggle()", card)
        self.assertIn("series: showsNetDeposit ? [costSeries, marketSeries] : [marketSeries]", source)


if __name__ == "__main__":
    unittest.main()
