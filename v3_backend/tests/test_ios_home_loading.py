"""Static loading contract; runtime refresh coverage lives in native Swift tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


class HomeLoadingTests(unittest.TestCase):
    def test_static_skeletons_do_not_install_shimmer_clocks_or_compositing(self):
        for filename in ("DesignSystem.swift", "PortfolioView.swift", "VolumeProfileView.swift"):
            source = (ROOT / filename).read_text()
            self.assertNotIn("catfolioLoadingShimmer", source)
            self.assertNotIn("CatfolioLoadingShimmer", source)


if __name__ == "__main__":
    unittest.main()
