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
        for mode in ("`.whole`", "`.tenth`", "`.statement`", "`.latin`", "`.localised`"):
            self.assertIn(mode, doc, f"{mode} is not documented")

    def test_the_documented_modes_are_the_modes_the_app_compiles(self):
        """A table that drifts from the code is read as authoritative and wrong."""
        code = DESIGN_SYSTEM.read_text()
        for mode in ("case whole", "case tenth", "case statement",
                     "case latin", "case localised"):
            self.assertIn(mode, code, f"DESIGN.md documents {mode!r} but the code has no such case")

    def test_the_ladder_lives_in_one_place(self):
        """DisplayFormat is the only home for compact notation."""
        code = DESIGN_SYSTEM.read_text()
        self.assertIn("static func compact(", code)
        self.assertIn("static func compactMoney(", code)
        self.assertIn("notation(.compactName)", code)
