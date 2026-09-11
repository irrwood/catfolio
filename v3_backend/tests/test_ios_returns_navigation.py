from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_performance_uses_system_navigation_title_in_every_loading_state():
    source = (ROOT / "CatfolioIOS/CatfolioIOS/ReturnsView.swift").read_text()
    root, panel = source.split("struct ReturnsComparisonPanel: View", 1)
    assert '.navigationTitle(L10n.text("Performance"))' in root
    assert '.navigationBarTitleDisplayMode(.large)' in root
    assert '.toolbarVisibility(.visible, for: .navigationBar)' in root
    assert '.toolbar(.hidden, for: .navigationBar)' not in root
    assert 'Text("Performance")' not in panel
    assert '.font(ReturnsTypography.medium(28, relativeTo: .title))' not in panel


def test_performance_routes_each_chart_to_a_separate_page():
    source = (ROOT / "CatfolioIOS/CatfolioIOS/ReturnsView.swift").read_text()
    landing, detail = source.split("private struct ReturnsChartPage: View", 1)
    assert "SettingsPage {" in landing
    assert "ForEach(ReturnsChartDestination.allCases)" in landing
    assert "ReturnsChartPage(chart: chart)" in landing
    assert "case heatmap, comparison, drawdown, valuation" in landing
    assert "ReturnsComparisonPanel()" not in landing
    assert "PortfolioDetailsCard(" not in landing
    for destination in ("heatmap", "comparison", "drawdown", "valuation"):
        assert f"case .{destination}:" in detail
    assert ".refreshable { await model.refreshReturnsPage() }" in detail
    assert ".sheet(item: $selectedHolding)" in detail


def test_market_tools_move_to_performance_and_provider_stays_in_settings():
    returns = (ROOT / "CatfolioIOS/CatfolioIOS/ReturnsView.swift").read_text()
    settings = (ROOT / "CatfolioIOS/CatfolioIOS/SettingsView.swift").read_text()
    for title in ("板块轮动", "行业情绪", "研究", "选股器", "今天值得关注", "策略编曲家", "税务计算"):
        entry = f'title: L10n.text("{title}")'
        assert entry in returns
        assert entry not in settings
    assert 'connector(L10n.text("服务商")' in settings
    assert 'L10n.text("服务商")' not in returns
    assert '.fullScreenCover(isPresented: $showsPolicyComposer)' in returns


def test_analytics_loading_and_content_only_render_the_selected_chart():
    source = (ROOT / "CatfolioIOS/CatfolioIOS/ReturnsAnalyticsView.swift").read_text()
    content, loading = source.split("struct ReturnsAnalyticsLoadingView: View", 1)
    loading = loading.split("private struct AnalyticsLoadingCard: View", 1)[0]
    for section in (content, loading):
        assert "switch chart" in section
        assert "case .drawdown:" in section
        assert "case .valuation:" in section
    assert "pendingParts.contains(.drawdown)" in content
    assert "pendingParts.contains(.valuation)" in content


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_") and callable(test):
            test()
            print(f"PASS: {name}")
