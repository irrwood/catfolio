from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


class HoldingsHeatmapTests(unittest.TestCase):
    def test_heatmap_period_controls_copy_and_tile_values(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()
        tile = (ROOT / "HoldingsHeatmapTile.swift").read_text()

        self.assertIn("let performancePeriod: HoldingPerformancePeriod", heatmap)
        self.assertIn("case .today:", heatmap)
        self.assertIn("case .holdingPeriod:", heatmap)
        self.assertIn("holding.unrealizedPercent.isFinite", heatmap)
        self.assertIn("performanceTitle: performancePeriod.title", heatmap)
        self.assertIn("model.performanceTitle", tile)
        self.assertNotIn("查看全部持仓", heatmap)


    def test_heatmap_uses_taller_canvas_to_show_more_holdings(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()

        self.assertIn("private let maximumHoldingTiles = 20", heatmap)
        self.assertIn("private let minimumIndividualFraction = 0.008", heatmap)
        self.assertIn("private let heatmapHeight: CGFloat = 700", heatmap)
        self.assertNotIn("usesETFLookThrough ? 700 : 580", heatmap)
        self.assertIn(".frame(height: heatmapHeight)", heatmap)
        self.assertNotIn("面积代表穿透后市值", heatmap)
        self.assertNotIn("面积代表持仓市值", heatmap)


    def test_grouped_look_through_merges_only_the_smallest_tail_at_the_end(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()

        self.assertIn("makeLookThroughSectorGroups(from: lookThroughRows)", heatmap)
        self.assertIn("static let maximumGroupedConstituentTiles = 36", heatmap)
        self.assertIn("static let minimumGroupedConstituentFraction = 0.0025", heatmap)
        self.assertIn("$0.totalUSD / sectorValue >= Self.minimumGroupedConstituentFraction", heatmap)
        self.assertIn("let visibleRows = sortedRows.prefix(visibleCount)", heatmap)
        self.assertIn("let tailRows = sortedRows.dropFirst(visibleRows.count)", heatmap)
        self.assertIn("lookThroughModel(for: $0, portfolioTotal: portfolioTotal)", heatmap)
        self.assertNotIn("__sector_remainder__", heatmap)
        self.assertIn('id: "__sector_micro_tail__\\(title)"', heatmap)
        self.assertIn("HoldingsHeatmapTile.Model.remainder(", heatmap)
        self.assertIn("let effectiveInset = HoldingsHeatmapTile.inset(in: placement.frame.size, maximum: tileInset)", heatmap)
        self.assertIn("groups: sectorGroups", heatmap)
        self.assertIn("Text(\"\\(group.constituentCount)\")", heatmap)
        self.assertIn("HoldingsHeatmapAggregation.modelsForDisplay(models, in: geometry.size)", heatmap)
        self.assertIn("!HoldingsHeatmapTile.canShowIdentifier(in:", heatmap)
        self.assertIn('id: "__compact_tail__"', heatmap)


    def test_missing_change_has_no_visual_dash_placeholder(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()
        tile = (ROOT / "HoldingsHeatmapTile.swift").read_text()

        labels = tile.split("private func performanceLabels", 1)[1].split("private var tileRadius", 1)[0]
        self.assertLess(labels.index("if showsChange"), labels.index("if showsWeight"))
        # The return's row is held even when there is no quote, so the weight
        # never slides up into the slot every other tile uses for a return.
        self.assertIn(".hidden()", labels)
        self.assertNotIn('Text("—")', labels)
        self.assertIn("performanceLabels(change: summary.percent", tile)
        self.assertIn("performanceLabels(change: model.changePercent", tile)
        self.assertIn('?? L10n.text("暂无行情")', tile)
        self.assertNotIn('Text("— 暂无行情")', heatmap)

    def test_tiny_neutral_tiles_have_a_semantic_separator(self) -> None:
        tile = (ROOT / "HoldingsHeatmapTile.swift").read_text()

        self.assertIn("if usesMicroSeparator", tile)
        self.assertIn("min(size.width, size.height) < 24", tile)
        self.assertIn(".strokeBorder(Color(uiColor: .systemBackground), lineWidth: 0.75)", tile)
        self.assertIn("return CatfolioTheme.neutralFill", tile)


    def test_merged_block_reports_a_return_over_what_is_priced(self) -> None:
        """Requiring every constituent blanked the block whenever one of the
        smallest holdings lacked a quote."""
        tile = (ROOT / "HoldingsHeatmapTile.swift").read_text()
        percent = tile.split("var percent: Double?", 1)[1].split("}", 1)[0]
        self.assertNotIn("isComplete", percent)
        self.assertIn("referenceValue > 0", percent)
        # isComplete survives for the coverage line that explains the figure.
        self.assertIn("var isComplete: Bool", tile)
        self.assertIn("缺失数据未计入盈亏", (ROOT / "HoldingsHeatmapView.swift").read_text())

    def test_sector_headers_carry_no_tally(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()
        self.assertNotIn("showsCount", heatmap)
        # Scoped to the visible header: the count also appears in the
        # accessibility value, which is where it should stay.
        header = heatmap.split("if showsHeader {", 1)[1].split("HoldingsHeatmapTileCloud", 1)[0]
        self.assertIn("Text(group.title)", header)
        self.assertNotIn("constituentCount", header)
        self.assertIn('.accessibilityValue(Text("\\(group.constituentCount)"))', heatmap)

    def test_the_weight_appears_wherever_the_return_does(self) -> None:
        tile = (ROOT / "HoldingsHeatmapTile.swift").read_text()
        weight = tile.split("private var showsWeight: Bool {", 1)[1].split("}", 1)[0]
        self.assertIn("showsChange", weight)
        self.assertNotIn("52", weight, "the 8pt taller threshold is what hid the pair")


if __name__ == "__main__":
    unittest.main()
