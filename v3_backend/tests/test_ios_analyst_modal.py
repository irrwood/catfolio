"""Structural checks for native analyst modal stacking on iOS."""
from pathlib import Path
import unittest


SOURCE = (
    Path(__file__).resolve().parents[2]
    / "CatfolioIOS"
    / "CatfolioIOS"
    / "AnalystConsensusView.swift"
)


class AnalystModalPresentationTests(unittest.TestCase):
    def test_analyst_details_are_a_nested_native_sheet(self):
        source = SOURCE.read_text()
        view = source[
            source.index("struct AnalystConsensusView: View"):
            source.index("private struct AnalystConsensusContent: View")
        ]

        self.assertIn(".sheet(isPresented: $showsDetails)", view)
        self.assertIn("NavigationStack {", view)
        self.assertIn(".presentationDetents([.large])", view)
        self.assertIn(".presentationDragIndicator(.visible)", view)
        self.assertIn(".navigationTransition(.zoom(sourceID: symbol, in: zoom))", view)
        self.assertIn(".matchedTransitionSource(id: symbol, in: zoom)", view)
        self.assertNotIn("NavigationLink {", view)

    def test_first_tap_loads_then_presents_and_sheet_has_native_close_action(self):
        source = SOURCE.read_text()

        self.assertIn("await load()", source)
        self.assertIn("showsDetails = true", source)
        self.assertIn("ToolbarItem(placement: .cancellationAction)", source)
        self.assertIn("Label(L10n.text(\"关闭\"), systemImage: \"xmark\")", source)

    def test_analyst_data_persists_until_an_explicit_refresh(self):
        source = SOURCE.read_text()
        client = source[
            source.index("actor AnalystConsensusClient"):
            source.index("struct AnalystConsensusView: View")
        ]

        self.assertIn("applicationSupportDirectory", client)
        self.assertIn("analyst-consensus-v1.json", client)
        self.assertIn("if !forceRefresh, let cached", client)
        self.assertNotIn("timeIntervalSince(cached.fetchedAt)", client)
        self.assertIn("if data.ratings != nil || valid { store(data, symbol: symbol) }", client)
        self.assertIn("await load(forceRefresh: true)", source)
        self.assertIn(".refreshable {", source)

    def test_data_methodology_is_a_small_bottom_footnote(self):
        source = SOURCE.read_text()
        details = source[source.index("private struct AnalystConsensusDetails: View"):]

        self.assertNotIn('Section("数据口径")', details)
        self.assertIn('Text(L10n.text("数据口径"))', details)
        self.assertIn(".font(.caption2)", details)
        self.assertIn(".listRowBackground(Color.clear)", details)


if __name__ == "__main__":
    unittest.main()
