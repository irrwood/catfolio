from pathlib import Path


def test_portfolio_chart_hover_is_coalesced_and_animation_free():
    js = (Path(__file__).parents[1] / "app" / "static" / "portfolio.js").read_text(encoding="utf-8")
    css = (Path(__file__).parents[1] / "app" / "static" / "portfolio.css").read_text(encoding="utf-8")

    assert "pendingHighlightIndex = index" in js
    assert "window.requestAnimationFrame(() =>" in js
    assert "positionChartHover(rows, nextIndex)" in js
    assert "highlightedIndex = rows.length - 1;" in js
    assert 'chartHoverLayer.className = "portfolio-chart-hover-layer"' in js
    assert "chartInstance.convertToPixel" in js
    assert "markPoint" not in js
    assert 'axisPointer: { z: 1, animation: false, animationDurationUpdate: 0 }' in js
    assert "transitionDuration: 0" in js
    assert "animation: none !important;" in css
    assert "transition: none !important;" in css
    assert ".portfolio-chart-legend {\n  display: flex;" in css
    assert "@media (max-width: 960px)" in css
    assert "height: 460px;" in css


def test_portfolio_chart_merges_the_latest_broker_snapshot():
    js = (Path(__file__).parents[1] / "app" / "static" / "portfolio.js").read_text(encoding="utf-8")

    assert "const current = payload?.current_point || {};" in js
    assert 'market: numeric(current, ["market_value_usd"], null)' in js
    assert 'cost: numeric(current, ["cost_usd"], null)' in js
    assert "rows[existingIndex] = currentRow;" in js
    assert "rows.push(currentRow);" in js
    assert 'fetch("/api/portfolio/chart", { cache: "no-store" })' in js
