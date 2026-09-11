"""Regression coverage for the iOS Icon Composer app icon wiring."""
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "CatfolioIOS" / "CatfolioIOS.xcodeproj" / "project.pbxproj"
ICON = ROOT / "CatfolioIOS" / "CatfolioIOS" / "AppIcon.icon"


class IOSAppIconTests(unittest.TestCase):
    def test_icon_composer_file_is_complete_and_wired_to_target(self):
        project = PROJECT.read_text()
        metadata = json.loads((ICON / "icon.json").read_text())

        self.assertIn("lastKnownFileType = folder.iconcomposer.icon", project)
        self.assertIn("AppIcon.icon in Resources", project)
        self.assertIn("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;", project)
        self.assertEqual(metadata["groups"][0]["layers"][0]["image-name"], "Catffff-1.png")
        self.assertTrue((ICON / "Assets" / "Catffff-1.png").is_file())


if __name__ == "__main__":
    unittest.main()
