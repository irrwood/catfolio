"""Run the iOS design checker as part of the suite.

DESIGN.md says a rule with no check is how the last one was missed. The
checker existed but nothing invoked it, so a violation only surfaced if
somebody remembered to run the script by hand. This makes it fail the way a
test fails.
"""
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts" / "check_ios_design.py"
DESIGN_DOC = ROOT / "CatfolioIOS" / "DESIGN.md"
DESIGN_SYSTEM = ROOT / "CatfolioIOS" / "CatfolioIOS" / "DesignSystem.swift"


class IOSDesignRuleTests(unittest.TestCase):
    def test_design_checker_passes(self):
        result = subprocess.run(
            [sys.executable, str(CHECKER)], capture_output=True, text=True
        )
        self.assertEqual(
            result.returncode, 0,
            f"scripts/check_ios_design.py failed:\n{result.stdout}\n{result.stderr}"
        )

    def test_the_abbreviation_rule_is_documented_where_the_checker_says_it_is(self):
        """The checker points readers at DESIGN.md; the section must exist."""
        doc = DESIGN_DOC.read_text()
        self.assertIn("Where a figure may be abbreviated", doc)
        for mode in ("`.whole`", "`.tenth`", "`.statement`"):
            self.assertIn(mode, doc, f"{mode} is not documented")
        # The convention is settled: the suffix follows the language, so there
        # is no style to choose and the two cases that offered one are gone.
        self.assertIn("The suffix follows the language", doc)
        for gone in ("`.latin`", "`.localised`"):
            self.assertNotIn(gone, doc, f"{gone} was deleted from the code")

    def test_the_documented_modes_are_the_modes_the_app_compiles(self):
        """A table that drifts from the code is read as authoritative and wrong."""
        code = DESIGN_SYSTEM.read_text()
        for mode in ("case whole", "case tenth", "case statement"):
            self.assertIn(mode, code, f"DESIGN.md documents {mode!r} but the code has no such case")
        for gone in ("case latin", "case localised"):
            self.assertNotIn(gone, code, f"{gone!r} is documented as deleted but still exists")

    def test_the_ladder_lives_in_one_place(self):
        """DisplayFormat is the only home for compact notation."""
        code = DESIGN_SYSTEM.read_text()
        self.assertIn("static func compact(", code)
        self.assertIn("static func compactMoney(", code)
        self.assertIn("notation(.compactName)", code)

    def test_the_ladder_formats_in_the_app_language_not_the_device_one(self):
        """The load-bearing half of the convention.

        `formatted()` follows `Locale.current`, which tracks the device, while
        the language preference lives in `AppLanguage` and never reaches
        `AppleLanguages`. Without an explicit locale a reader in Chinese on an
        English phone is shown K and M, which is the bug the rule exists to
        prevent — and it would not show up on a Chinese device.
        """
        code = DESIGN_SYSTEM.read_text()
        ladder = code.split("static func compact(", 1)[1].split("static func compactMoney(", 1)[0]
        self.assertIn("AppLanguage.currentIdentifier", ladder)
        # Every render, not just the compact ones: the fallback that re-adds a
        # thousands separator below the first step formats too, and it would be
        # just as wrong in the device's language.
        self.assertEqual(
            ladder.count(".locale(locale)"), ladder.count(".formatted("),
            "every render in the ladder must carry the app's locale",
        )
        self.assertIn("The locale is passed explicitly", DESIGN_DOC.read_text())
