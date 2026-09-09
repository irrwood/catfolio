"""Every time selector confirms the tap.

Choosing a range was the one interaction in the app that changed what the
chart showed and gave nothing back — the scrubbing haptic, the sheet-ready
haptic and the gains/losses toggle all had one. Feedback fires on the change,
so tapping the range already selected stays silent; there is nothing for it to
confirm.

All of it goes through the shared preference, so the Settings toggle governs
every one of them rather than most of them.
"""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"
PREFERENCE = "@AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true"

# The control, the file that owns it, and the state its feedback watches.
SELECTORS = [
    ("range picker, shared by four screens", "DesignSystem.swift", "ChartTimeRangePicker", "selection"),
    ("financials reporting period", "CompanyFinancialsView.swift", "CompanyFinancialsView", "periodKind"),
    ("financials year row", "CompanyFinancialsView.swift", "CompanyFinancialsView", "selectedPeriodEnd"),
    ("holdings return period", "PortfolioView.swift", "HoldingSortMenu", "performancePeriod"),
    ("options expiry window", "OptionsOIView.swift", "OptionsOIView", "days"),
]


class TimePickerHapticsTests(unittest.TestCase):
    def test_every_time_selector_gives_feedback_on_the_change(self):
        for label, filename, owner, trigger in SELECTORS:
            with self.subTest(label):
                source = (ROOT / filename).read_text()
                expected = (
                    f".sensoryFeedback(.selection, trigger: {trigger}) "
                    "{ _, _ in hapticsEnabled }"
                )
                # assertTrue rather than assertIn: a failing assertIn prints the
                # whole Swift file, which buries the one line that matters.
                self.assertTrue(expected in source,
                                f"{label}: {filename} is missing {expected}")

    def test_the_owning_view_reads_the_shared_preference(self):
        """A local `true` would ignore the Settings toggle."""
        for label, filename, owner, _ in SELECTORS:
            with self.subTest(label):
                source = (ROOT / filename).read_text()
                declaration = source.split(f"struct {owner}: View {{", 1)[1]
                # Stop at the next top-level type so the property is this one's.
                declaration = re.split(r"\n(?:private )?struct \w+", declaration)[0]
                self.assertTrue(PREFERENCE in declaration,
                                f"{owner} does not read the shared haptics preference")

    def test_the_shared_picker_carries_it_rather_than_each_caller(self):
        """Four screens present this control; the feedback belongs to it once."""
        design = (ROOT / "DesignSystem.swift").read_text()
        picker = design.split("struct ChartTimeRangePicker: View {", 1)[1]
        picker = picker.split("struct ChartTimeRangePickerSkeleton", 1)[0]
        self.assertIn("trigger: selection", picker)

        callers = ["PortfolioView.swift", "ReturnsView.swift",
                   "ReturnsAnalyticsView.swift", "VolumeProfileView.swift"]
        for filename in callers:
            with self.subTest(filename):
                source = (ROOT / filename).read_text()
                self.assertIn("ChartTimeRangePicker(", source)
                self.assertNotIn("trigger: range)", source,
                                 "a caller is duplicating the picker's own feedback")

    def test_the_preference_key_is_the_one_settings_writes(self):
        design = (ROOT / "DesignSystem.swift").read_text()
        self.assertIn('static let hapticsPreferenceKey = "catfolio.haptics"', design)
        settings = (ROOT / "SettingsView.swift").read_text()
        self.assertIn('@AppStorage("catfolio.haptics")', settings)


if __name__ == "__main__":
    unittest.main()
