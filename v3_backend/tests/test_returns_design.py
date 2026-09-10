from pathlib import Path

from starlette.requests import Request


ROOT = Path(__file__).parents[1]


def _request():
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/returns",
            "headers": [],
            "query_string": b"ui=v5",
        }
    )


def _zh_request():
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/returns",
            "headers": [(b"accept-language", b"zh-CN")],
            "query_string": b"",
        }
    )


def test_returns_page_matches_single_cash_flow_comparison_design():
    from app.routes import returns as returns_route

    html = returns_route.returns_page(_request()).body.decode("utf-8")

    assert "Comparison" in html
    assert "Cash-Flow-Matched Comparison" in html
    assert "Portfolio NAV" in html
    assert "Benchmark NAV" in html
    assert "AI Explanation" in html
    assert 'class="ai-action-icon comparison-ai-icon"' in html
    design_system = (ROOT / "app" / "static" / "design-system.css").read_text(encoding="utf-8")
    assert 'mask: url("/static/icons/ai-action.svg")' in design_system
    assert "background-color: currentColor;" in design_system
    assert 'class="active" data-range="3m" aria-pressed="true"' in html
    assert 'data-range="1d" aria-pressed="false"' in html
    assert 'id="returnsChart"' in html
    assert 'id="comparisonCrosshairDate"' in html
    assert 'id="comparisonCrosshairValue"' in html
    assert 'id="comparisonEndLabels"' in html
    assert 'id="comparisonPortfolioReturn"' in html
    assert 'id="comparisonBenchmarkReturn"' in html
    assert "__RETURNS_CASH_FLOW__" not in html
    assert "twrMode" not in html
    assert "costValueMode" not in html
    assert "收益口径" not in html
    assert "各基准表现汇总" not in html


def test_comparison_page_has_complete_chinese_copy():
    from app.routes import returns as returns_route

    html = returns_route.returns_page(_zh_request()).body.decode("utf-8")

    assert "<h1>收益对比</h1>" in html
    assert "<span>AI 解读</span>" in html
    assert "组合净值" in html
    assert "基准净值" in html
    assert "现金流匹配对比" in html
    assert "按实际交易重放现金流" in html
    assert 'data-range="ytd" aria-pressed="false">年初至今</button>' in html
    assert 'href="/returns" title="收益对比"' in html


def test_comparison_is_second_sidebar_tab():
    from app.components import _V5_NAV_GROUPS

    analysis_items = _V5_NAV_GROUPS[0][1]

    assert analysis_items[0][:2] == ("/lab", "Portfolio")
    assert analysis_items[1][:2] == ("/returns", "收益对比")
    assert [href for href, _, _ in analysis_items].count("/returns") == 1


def test_returns_chart_keeps_all_cash_flow_benchmarks_and_smooth_dragging():
    route = (ROOT / "app" / "routes" / "returns.py").read_text(encoding="utf-8")
    script = (ROOT / "app" / "static" / "returns.js").read_text(encoding="utf-8")
    css = (ROOT / "app" / "static" / "returns.css").read_text(encoding="utf-8")

    api = (ROOT / "app" / "routes" / "api.py").read_text(encoding="utf-8")

    assert '@router.get("/comparison")' in api
    assert "ThreadPoolExecutor" in api
    assert 'fetch("/api/comparison"' in script
    assert "__RETURNS_CASH_FLOW__" not in route
    assert "Object.entries(benchmarkRows)" in script
    assert 'pressedMouseMove: true' in script
    assert 'mouseWheel: true' in script
    assert 'kineticScroll: { mouse: true, touch: true }' in script
    assert 'LineType?.Curved' in script
    assert "chart.subscribeCrosshairMove(positionCrosshairLabels)" in script
    assert script.count("visible: false,") >= 4
    assert "labelVisible: true" not in script
    assert "autoscaleInfoProvider: adaptiveAutoscale" in script
    assert "const scale = baseImplementation()" in script
    assert "const padding = span * 0.08" in script
    assert "figmaPriceRange" not in script
    assert "attributionLogo: false" in script
    assert "lastValueVisible: false" in script
    assert "function updateEndLabels()" in script
    assert "seriesMeta.forEach((meta) =>" in script
    assert 'setRange("3m")' in script
    assert "height: 555px;" in css
    assert "height: 406px;" in css


def test_returns_hover_bubble_tracks_the_nearest_series_point():
    script = (ROOT / "app" / "static" / "returns.js").read_text(encoding="utf-8")
    css = (ROOT / "app" / "static" / "returns.css").read_text(encoding="utf-8")

    assert "param.seriesData?.get(meta.series)" in script
    assert "Math.abs(coordinate - param.point.y)" in script
    assert "closest.distance > 18" in script
    assert "crosshairValue.style.background = closest.meta.color" in script
    assert "crosshairValue.dataset.series = closest.meta.title" in script
    assert 'transform: translate(-50%, -100%);' in css


def test_returns_dynamic_messages_follow_current_language():
    script = (ROOT / "app" / "static" / "returns.js").read_text(encoding="utf-8")

    assert 'portfolio: "组合"' in script
    assert "对比数据加载失败" in script
    assert "AI 解读失败" in script
    assert 'portfolio: "Portfolio"' in script
    assert "Comparison data could not be loaded" in script


def test_returns_page_and_chart_follow_shared_theme_tokens():
    script = (ROOT / "app" / "static" / "returns.js").read_text(encoding="utf-8")
    css = (ROOT / "app" / "static" / "returns.css").read_text(encoding="utf-8")

    assert "background: var(--panel);" in css
    assert "border: 1px solid var(--line);" in css
    assert "color: var(--ink);" in css
    assert "color: var(--muted);" in css
    assert ".comparison-chart-empty[hidden]" in css
    assert 'background: "rgba(0, 0, 0, 0)"' in script
    assert 'window.addEventListener("catfolio:themechange", applyChartTheme)' in script
    assert "chart.applyOptions({" in script


def test_returns_workspace_matches_lab_content_width():
    css = (ROOT / "app" / "static" / "returns.css").read_text(encoding="utf-8")

    assert "body.page-returns .v5-main .v5-content" in css
    assert "max-width: 1520px;" in css
