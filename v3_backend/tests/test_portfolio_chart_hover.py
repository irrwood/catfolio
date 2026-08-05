from pathlib import Path


def test_portfolio_chart_restores_the_cost_and_market_value_curves():
    js = (Path(__file__).parents[1] / "app" / "static" / "portfolio.js").read_text(encoding="utf-8")
    css = (Path(__file__).parents[1] / "app" / "static" / "portfolio.css").read_text(encoding="utf-8")

    assert js.count('type: "line"') >= 2
    assert "smooth: 0.32" in js
    assert "positionChartHover(rows" in js
    assert "if (rows.length === 1)" in js
    assert "const bounds = chartBounds(rows);" in js
    assert "animation: none !important;" in css
    assert ".portfolio-chart-legend" not in css
    assert "@media (max-width: 960px)" in css
    assert "height: 460px;" in css


def test_portfolio_chart_uses_position_history_and_calibrates_latest_broker_point():
    js = (Path(__file__).parents[1] / "app" / "static" / "portfolio.js").read_text(encoding="utf-8")

    assert "const positionHistory = payload?.position_history || {};" in js
    assert "(positionHistory.rows || []).map" in js
    assert 'market: numeric(row, ["market_value_usd"], null)' in js
    assert 'cost: numeric(row, ["cost_usd"], null)' in js
    assert "const current = payload?.current_point || {};" in js
    assert 'market: numeric(current, ["market_value_usd"], null)' in js
    assert 'cost: numeric(current, ["cost_usd"], null)' in js
    assert "rows[existingIndex] = currentRow" in js
    assert "else rows.push(currentRow)" in js
    assert 'fetch("/api/portfolio/chart", { cache: "no-store" })' in js


def test_portfolio_chart_excludes_cash_flow_fields():
    js = (Path(__file__).parents[1] / "app" / "static" / "portfolio.js").read_text(encoding="utf-8")

    normalize_block = js[js.index("function normalizeValueRows"):js.index("function visibleRows")]
    assert "cash_flow_mirror" not in normalize_block
    assert "portfolio_value" not in normalize_block
    assert "open_position_cost_usd" not in normalize_block
    assert "adjusted_portfolio_value" not in normalize_block
    assert "net_cash_flow" not in normalize_block
    assert "account_cash" not in normalize_block
