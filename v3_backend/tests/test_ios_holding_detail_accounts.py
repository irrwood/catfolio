from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
DETAIL = ROOT / "CatfolioIOS" / "CatfolioIOS" / "VolumeProfileView.swift"
RETURNS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "ReturnsView.swift"
PORTFOLIO = ROOT / "CatfolioIOS" / "CatfolioIOS" / "PortfolioView.swift"
DESIGN_SYSTEM = ROOT / "CatfolioIOS" / "CatfolioIOS" / "DesignSystem.swift"
STANDARD_LINE_CHART = ROOT / "CatfolioIOS" / "CatfolioIOS" / "StandardLineChart.swift"


def test_holding_detail_account_pills_are_linked_multi_select_toggles():
    source = DETAIL.read_text(encoding="utf-8")
    toggle = source[
        source.index("private func toggleDetailAccount"):
        source.index("private struct HoldingDetailAccountSelector")
    ]
    selector = source[
        source.index("private struct HoldingDetailAccountSelector"):
        source.index("private struct HoldingDetailModalHandle")
    ]

    assert "selectedAccountKeys = accountContext.allAccountKeys" in source
    assert "selectedAccountKeys.remove(accountKey)" in toggle
    assert "selectedAccountKeys.insert(accountKey)" in toggle
    assert "guard selectedAccountKeys.count > 1 else { return }" not in toggle
    assert "selectedAccountKeys = [accountKey]" not in toggle

    assert "isSelected: selectedAccountKeys == allAccountKeys" in selector
    assert "isSelected: selectedAccountKeys.contains(option.id)" in selector
    assert "selectedAccountKeys != allAccountKeys" not in selector


def test_holding_detail_allows_an_empty_account_selection_without_showing_all_account_data():
    source = DETAIL.read_text(encoding="utf-8")

    assert "accountContext == nil || !selectedAccountKeys.isEmpty" in source
    assert "guard hasSelectedDetailAccounts else { return nil }" in source
    assert "if hasSelectedDetailAccounts {" in source
    assert "showsHoldingCost: hasSelectedDetailAccounts" in source
    assert "if showsHoldingCost {" in source


def test_performance_selector_places_voo_and_vti_in_the_last_column():
    source = RETURNS.read_text(encoding="utf-8")
    selector = source[
        source.index("static let selectorOrder"):
        source.index("static let colors")
    ]

    assert '"GLD", "VOO", "VTI"' in selector


def test_home_refresh_timestamp_disappears_when_refresh_finishes():
    source = PORTFOLIO.read_text(encoding="utf-8")
    timestamp = source[
        source.index("private struct PortfolioRefreshTimestamp"):
        source.index("private struct TodayContributionCard")
    ]

    assert "isRefreshing: model.isPortfolioLoading" in source
    assert "let isRefreshing: Bool" in timestamp
    assert ".opacity(isRefreshing ? 1 : 0)" in timestamp
    assert ".accessibilityHidden(!isRefreshing)" in timestamp


def test_today_direction_switch_cannot_reuse_the_previous_company_logo():
    portfolio = PORTFOLIO.read_text(encoding="utf-8")
    design_system = DESIGN_SYSTEM.read_text(encoding="utf-8")
    bars = portfolio[
        portfolio.index("private var contributionBars"):
        portfolio.index("private var directionPicker")
    ]
    asset_logo = design_system[
        design_system.index("struct AssetLogo"):
        design_system.index("enum AssetBrandColor")
    ]

    assert ".id(contribution.id)" in bars
    assert ".task(id: logoURL)" in asset_logo
    assert "loadedImage = nil" in asset_logo


def test_holding_detail_time_range_drives_the_header_return():
    source = DETAIL.read_text(encoding="utf-8")
    chart = source[
        source.index("private struct SecurityPriceChart: View"):
        source.index("private struct SecurityPriceCostLegend: View")
    ]
    range_data = source[
        source.index("private struct SecurityPriceRangeData"):
        source.index("private struct SecurityPricePlotPoint")
    ]

    assert 'task(id: "\\(range.rawValue)|\\(selectionSignature)")' in chart
    assert "onSelectionChange(rangeSelection)" in chart
    assert "makeSelection(start: first, end: latest, price: nil" in chart
    assert "returnPercent: (end.price / start.price - 1) * 100" in chart
    assert "history.points" in range_data
    assert "$0.dateText < sessionDay" in range_data


def test_home_time_range_drives_both_header_return_values():
    source = PORTFOLIO.read_text(encoding="utf-8")
    card = source[
        source.index("private struct CostMarketCard: View"):
        source.index("private struct FastCostMarketPlot: View")
    ]

    assert "private var rangePerformance: (amount: Double, percentage: Double)" in card
    assert "let marketMovement = end.marketValue - start.marketValue" in card
    assert "let contributionMovement = end.cost - start.cost" in card
    assert "Text(DisplayFormat.money(rangePerformance.amount, signed: true))" in card
    assert "Text(DisplayFormat.percent(abs(rangePerformance.percentage), signed: false))" in card


def test_home_time_range_picker_keeps_full_height_hit_targets_clear_of_chart_gestures():
    portfolio = PORTFOLIO.read_text(encoding="utf-8")
    design_system = DESIGN_SYSTEM.read_text(encoding="utf-8")
    standard_chart = STANDARD_LINE_CHART.read_text(encoding="utf-8")
    picker = design_system[
        design_system.index("struct ChartTimeRangePicker: View"):
        design_system.index("struct ChartTimeRangePickerSkeleton")
    ]

    assert ".frame(maxWidth: .infinity, maxHeight: .infinity)" in picker
    assert ".contentShape(Rectangle())" in picker
    assert "let interactionBottomInset: CGFloat" in standard_chart
    assert "plot.height - interactionBottomInset" in standard_chart

    fast_plot = portfolio[
        portfolio.index("private struct FastCostMarketPlot: View"):
        portfolio.index("private final class CostMarketPreparedData")
    ]
    assert "interactionBottomInset: PortfolioHeroChartLayout.chartInteractionBottomInset" in fast_plot

    layout = portfolio[
        portfolio.index("private enum PortfolioHeroChartLayout"):
        portfolio.index("private struct CostMarketCard")
    ]
    values = {
        name: float(value)
        for name, value in re.findall(
            r"static let (plotTop|plotHeight|pickerTop): CGFloat = ([0-9.]+)",
            layout,
        )
    }
    assert values["plotTop"] + values["plotHeight"] <= values["pickerTop"]


def test_holding_detail_modal_uses_one_soft_appearance_haptic():
    source = DETAIL.read_text(encoding="utf-8")
    detail = source[
        source.index("struct HoldingDetailView: View"):
        source.index("private var averageCostInQuoteCurrency")
    ]

    assert "@AppStorage(ChartInteractionStyle.hapticsPreferenceKey)" in detail
    assert ".impact(flexibility: .soft, intensity: 0.68)" in detail
    assert "trigger: presentationReady" in detail
    assert "hapticsEnabled && !wasReady && isReady" in detail


def test_holding_detail_renders_available_content_while_async_sections_load():
    source = DETAIL.read_text(encoding="utf-8")
    detail = source[
        source.index("struct HoldingDetailView: View"):
        source.index("private var averageCostInQuoteCurrency")
    ]

    initial_loading = detail[
        detail.index("private var showsInitialLoadingPlaceholder"):
        detail.index("private var showsDataDesignPreview")
    ]
    assert '--show-security-detail-loading' in initial_loading
    assert "priceHistory == nil" not in initial_loading
    assert "profile == nil" not in initial_loading
    assert ".task(id: presentationReady)" not in detail
    assert "guard presentationReady, profile == nil" not in detail
    assert "await Task.yield()" not in detail
