from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


class HoldingsHeatmapTests(unittest.TestCase):
    def test_heatmap_moves_with_filters_to_performance_first(self) -> None:
        returns = (ROOT / "ReturnsView.swift").read_text()
        portfolio = (ROOT / "PortfolioView.swift").read_text()
        self.assertLess(returns.index("showsHeatmap: true"), returns.index("ReturnsComparisonPanel()"))
        self.assertLess(returns.index("ReturnsComparisonPanel()"), returns.index("ReturnsAnalyticsView("))
        self.assertIn("holdings: model.holdings", returns)
        self.assertIn("onSelect: { selectedHolding = $0 }", returns)
        self.assertIn("HoldingDetailView(holding: holding)", returns)
        self.assertNotIn('tableMode = "热力图"', portfolio)
        self.assertIn('showsHeatmap ? "热力图"', portfolio)
        self.assertIn("HeatmapPerformancePeriodMenu(", portfolio)
        for value in ("heatmapPerformancePeriod", "heatmapGroupsBySector", "heatmapLooksThroughETF"):
            self.assertIn(value, portfolio)

    def test_heatmap_header_uses_native_period_filter(self) -> None:
        portfolio = (ROOT / "PortfolioView.swift").read_text()

        self.assertIn("@State private var heatmapPerformancePeriod: HoldingPerformancePeriod = .today", portfolio)
        self.assertIn("HeatmapPerformancePeriodMenu(", portfolio)
        self.assertIn('Section(L10n.text("收益时间"))', portfolio)
        self.assertIn("performancePeriod: heatmapPerformancePeriod", portfolio)

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

    def test_exposure_preparation_does_not_wait_for_daily_quotes(self) -> None:
        portfolio = (ROOT / "PortfolioView.swift").read_text()
        api = (ROOT / "APIClient.swift").read_text()
        preparation = portfolio.split("// Local exposure preparation must not wait for network quotes.", 1)[1].split('.task(id: "heatmap-daily-', 1)[0]
        self.assertIn("await loadETF()", preparation)
        self.assertNotIn("refreshHoldingDailyChanges", preparation)
        self.assertNotIn("loadETFConstituentDailyChanges", preparation)
        self.assertIn('heatmapPerformancePeriod == .today else { return }', portfolio)
        self.assertIn("requestedKey == etfHoldingsKey", portfolio)
        load = api.split("func loadETFLookThrough", 1)[1].split("func selectAllAccounts", 1)[0]
        self.assertIn("Task.detached(priority: .userInitiated)", load)
        self.assertIn("withTaskCancellationHandler", load)
        self.assertIn("preparation.cancel()", load)

    def test_heatmap_uses_taller_canvas_to_show_more_holdings(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()

        self.assertIn("private let maximumHoldingTiles = 20", heatmap)
        self.assertIn("private let minimumIndividualFraction = 0.008", heatmap)
        self.assertIn("private let heatmapHeight: CGFloat = 700", heatmap)
        self.assertNotIn("usesETFLookThrough ? 700 : 580", heatmap)
        self.assertIn(".frame(height: heatmapHeight)", heatmap)
        self.assertNotIn("面积代表穿透后市值", heatmap)
        self.assertNotIn("面积代表持仓市值", heatmap)

    def test_heatmap_can_group_holdings_by_sector(self) -> None:
        portfolio = (ROOT / "PortfolioView.swift").read_text()
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()

        self.assertIn('.contains("--group-heatmap-by-sector")', portfolio)
        self.assertIn('Toggle(L10n.text("按板块分组"), isOn: $groupsBySector)', portfolio)
        self.assertIn("groupsBySector: heatmapGroupsBySector", portfolio)
        self.assertIn("GroupedHoldingsHeatmap(", heatmap)
        self.assertIn("Dictionary(grouping: models, by: sectorTitle(for:))", heatmap)
        self.assertIn("SectorAttribution.split", heatmap)
        self.assertIn('if attribution.isLookThrough { return "ETF" }', heatmap)
        self.assertIn("portfolioFraction: holding.marketValue / total", heatmap)
        self.assertIn("fraction: model.portfolioFraction", heatmap)

    def test_heatmap_can_expand_etfs_into_constituent_tiles(self) -> None:
        portfolio = (ROOT / "PortfolioView.swift").read_text()
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()
        tile = (ROOT / "HoldingsHeatmapTile.swift").read_text()
        services = (ROOT / "LocalServices.swift").read_text()

        self.assertIn('Toggle(L10n.text("穿透 ETF"), isOn: $looksThroughETF)', portfolio)
        self.assertIn("lookThroughRows: loadedETFHoldingsKey == etfHoldingsKey", portfolio)
        self.assertIn("await loadETFConstituentDailyChanges()", portfolio)
        self.assertIn("func dailyChanges(tickers: [String])", services)
        self.assertIn("if usesETFLookThrough, let lookThroughRows", heatmap)
        self.assertIn("makeLookThroughModels(from: lookThroughRows)", heatmap)
        self.assertIn("content: .exposure(row, directHolding: directHolding)", heatmap)
        self.assertIn("case exposure(ETFLookThroughRow, directHolding: Holding?)", tile)
        self.assertIn("row.totalUSD / portfolioTotal", heatmap)
        self.assertIn("static let maximumLookThroughTiles = 28", heatmap)
        self.assertIn("Array(valid.prefix(Self.maximumLookThroughTiles))", heatmap)
        self.assertIn("let batchSize = HoldingsHeatmapView.maximumLookThroughTiles", portfolio)
        self.assertIn("etfConstituentDailyChanges.merge(changes)", portfolio)

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

    def test_sector_header_opens_a_native_complete_holdings_list(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()

        self.assertIn("@State private var expandedGroup: HoldingsHeatmapSectorGroup?", heatmap)
        self.assertIn("onExpand: { expandedGroup = $0 }", heatmap)
        self.assertIn(".sheet(item: $expandedGroup)", heatmap)
        self.assertIn("HoldingsHeatmapSectorDetail(", heatmap)
        self.assertNotIn('Image(systemName: "arrow.up.left.and.arrow.down.right")', heatmap)
        sector = heatmap.split("private struct HoldingsHeatmapSectorView: View {", 1)[1].split("private struct HoldingsHeatmapSectorDetail", 1)[0]
        self.assertIn("onExpand(group)", sector)
        self.assertIn("isInteractive: false", sector)
        self.assertIn(".contentShape(Rectangle())", sector)
        self.assertIn(".allowsHitTesting(false)", sector)
        self.assertIn(".presentationDetents([.large])", heatmap)
        self.assertIn('contains("--expand-first-heatmap-sector")', heatmap)

    def test_remainder_opens_a_complete_holdings_list(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()
        tile = (ROOT / "HoldingsHeatmapTile.swift").read_text()
        self.assertIn("var detailItems: [Model] = []", tile)
        self.assertIn("items.flatMap(\\.leafItems)", tile)
        self.assertIn("case let .remainder(count):", tile)
        self.assertIn('Text(L10n.text("其他"))', tile)
        self.assertIn("if model.isRemainder { expandedRemainder = model }", heatmap)
        self.assertIn(".sheet(item: $expandedRemainder", heatmap)
        self.assertIn("HoldingsHeatmapRemainderDetail(model: remainder)", heatmap)
        self.assertIn("ForEach(items)", heatmap)

    def test_stock_detail_is_presented_by_the_list_sheet_without_dismissing_it(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()
        detail = heatmap.split("private struct HoldingsHeatmapRemainderDetail: View {", 1)[1]
        self.assertIn("@State private var selectedHolding: Holding?", detail)
        self.assertIn("Button { selectedHolding = holding }", detail)
        self.assertIn(".sheet(item: $selectedHolding)", detail)
        self.assertIn("HoldingDetailView(holding: holding)", detail)
        self.assertNotIn("pendingSelection", heatmap)
        self.assertNotIn("expandedGroup = nil", heatmap)
        self.assertNotIn("expandedRemainder = nil", heatmap)
        self.assertNotIn("Task.sleep", heatmap)

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

    def test_grouped_sectors_have_no_gray_container(self) -> None:
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()

        self.assertNotIn(".stroke(.primary.opacity(0.08), lineWidth: 1)", heatmap)
        self.assertNotIn(".background(.secondary.opacity(0.07)", heatmap)
        self.assertIn("private let groupedScreenInset: CGFloat = 16", heatmap)
        self.assertIn("? groupedScreenInset - CatfolioStyle.pageHorizontalInset", heatmap)
        self.assertIn("placement.frame.insetBy(dx: 1.5, dy: 1.5)", heatmap)
        self.assertIn("tileInset: 2", heatmap)

    def test_every_sector_sheet_row_is_a_tap_target(self) -> None:
        """A row was a Button only when it had a direct position, so
        look-through constituents held only inside an ETF rendered identically
        and did nothing."""
        heatmap = (ROOT / "HoldingsHeatmapView.swift").read_text()
        tile = (ROOT / "HoldingsHeatmapTile.swift").read_text()
        detail = (ROOT / "VolumeProfileView.swift").read_text()

        self.assertIn("if let holding = item.detailHolding {", heatmap)
        self.assertNotIn("if let holding = item.holding {", heatmap)

        # The stub carries identity and exposure but never a position.
        stub = tile.split("var detailHolding: Holding?", 1)[1].split("var holding: Holding?", 1)[0]
        self.assertIn("shares: 0", stub)
        self.assertIn("averageCost: 0", stub)
        self.assertIn("costCurrency: nil", stub)
        self.assertIn("unrealized: 0", stub)

        # And the detail sheet leaves the position blocks out rather than
        # showing those zeros as though they were a position.
        self.assertIn("displayedHolding.shares > 0", detail)
        self.assertIn("hasSelectedDetailAccounts && hasPosition", detail)
        self.assertIn("if showsPosition {", detail)
        self.assertIn("showsHoldingCost: showsPosition", detail)

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
