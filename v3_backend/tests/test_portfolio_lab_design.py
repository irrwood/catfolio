from pathlib import Path

from starlette.requests import Request


def _request(path="/lab", query_string=b""):
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": path,
            "headers": [],
            "query_string": query_string,
        }
    )


def test_lab_page_uses_figma_portfolio_structure():
    from app.routes import lab as lab_route

    response = lab_route.lab_page(_request())
    html = response.body.decode("utf-8")

    assert response.status_code == 200
    assert 'class="portfolio-metrics"' in html
    assert "Unrealized P/L" in html
    assert 'class="portfolio-insights-row"' in html
    assert 'id="costValueChart"' in html
    assert "Current stock-position cost and historical market value (USD, excluding account cash)" in html
    assert "Stock-position cost and historical market-value chart, excluding account cash" in html
    assert 'class="portfolio-chart-legend"' not in html
    assert 'id="profitCalendarGrid"' in html
    assert 'id="profitCalendarDay"' in html
    assert 'id="profitCalendarMonth"' in html
    assert 'id="profitCalendarYear"' in html
    assert '>D</button>' in html
    assert '>M</button>' in html
    assert '>Y</button>' in html
    assert 'class="portfolio-ranges"' in html
    assert 'data-range="1d"' in html
    assert 'class="active" data-range="3m"' in html
    assert 'data-range="max"' in html
    assert "/static/portfolio.css" in html
    assert "/static/portfolio.js" in html
    assert "/static/portfolio-calendar.js" in html
    assert "/static/portfolio-holdings.js" in html
    assert 'class="portfolio-holdings-card"' in html
    assert 'id="portfolioHoldingsRows"' in html
    assert 'data-portfolio-holdings-mode="direct"' in html
    assert 'data-portfolio-holdings-mode="lookthrough"' in html
    assert "/static/icons/sidebar/research.svg" in html
    assert "/static/icons/sidebar/document.svg" in html
    assert "/static/icons/sidebar/theme-light.svg" in html
    assert 'system: ["theme-system.svg", "System"]' in html
    assert 'light: ["theme-light.svg", "Light Mode"]' in html
    assert 'dark: ["theme.svg", "Dark Mode"]' in html
    assert "themeIcon(meta[0])" in html
    assert "THEME_ICON_FILE" not in html
    assert 'class="v5-lang" role="group"' in html
    assert 'class="v5-lang-toggle"' in html
    assert html.count('class="v5-lang-toggle"') == 1
    assert '>Chinese</a>' not in html
    assert 'class="v5-nav-group-label"' not in html


def test_v5_language_control_shows_current_language_and_links_to_the_other_language():
    from app import components

    chinese_html = components.wrap_v5_layout("测试", "<p>body</p>", "/ai", "zh")
    english_html = components.wrap_v5_layout("Test", "<p>body</p>", "/ai", "en")

    assert chinese_html.count('class="v5-lang-toggle"') == 1
    assert 'href="/set-lang/en"' in chinese_html
    assert 'href="/set-lang/zh"' not in chinese_html
    assert '>CN</a>' in chinese_html
    assert '>EN</a>' not in chinese_html
    assert 'aria-label="切换到英文"' in chinese_html

    assert english_html.count('class="v5-lang-toggle"') == 1
    assert 'class="v5-lang-toggle"' in english_html
    assert 'href="/set-lang/zh"' in english_html
    assert 'href="/set-lang/en"' not in english_html
    assert '>EN</a>' in english_html
    assert '>CN</a>' not in english_html
    assert 'aria-label="Switch to Chinese"' in english_html


def test_lab_places_profit_calendar_beside_cost_market_value():
    from app.routes import lab as lab_route

    root = Path(__file__).resolve().parents[1]
    html = lab_route.lab_page(_request()).body.decode("utf-8")
    css = (root / "app" / "static" / "portfolio.css").read_text(encoding="utf-8")
    script = (root / "app" / "static" / "portfolio-calendar.js").read_text(encoding="utf-8")

    assert html.index('id="costValueChart"') < html.index('id="profitCalendarGrid"')
    assert "grid-template-columns: repeat(2, minmax(0, 1fr));" in css
    assert "@media (max-width: 960px)" in css
    assert ".portfolio-insights-row { grid-template-columns: minmax(0, 1fr); }" in css
    assert 'fetch("/api/profit-calendar"' in script
    assert "income.monthly_rows || []" in script


def test_profit_calendar_period_arrows_are_centered_in_their_buttons():
    root = Path(__file__).resolve().parents[1]
    css = (root / "app" / "static" / "portfolio.css").read_text(encoding="utf-8")

    button_rule = css[css.index(".profit-calendar-period-nav button {", css.index(".profit-calendar-period-nav button {") + 1) :]
    button_rule = button_rule[: button_rule.index("}")]
    assert "display: grid;" in button_rule
    assert "padding: 0;" in button_rule
    assert "place-items: center;" in button_rule


def test_lab_page_keeps_portfolio_nav_active():
    from app.routes import lab as lab_route

    response = lab_route.lab_page(_request())
    html = response.body.decode("utf-8")

    assert 'class="v5-nav-link active" href="/lab"' in html
    assert 'body class="page-lab"' in html


def test_standalone_holdings_page_is_removed_but_api_remains():
    from app.main import app

    paths = {route.path for route in app.routes}
    assert "/holdings" not in paths
    assert "/api/holdings" in paths
    assert "/api/holdings/detail" in paths

    from app.routes import lab as lab_route

    html = lab_route.lab_page(_request()).body.decode("utf-8")
    assert 'href="/holdings' not in html
    assert 'id="portfolioHoldingsRows"' in html


def test_portfolio_card_radii_match_figma():
    css_path = Path(__file__).parents[1] / "app" / "static" / "portfolio.css"
    css = css_path.read_text(encoding="utf-8")

    assert "--portfolio-card-radius: 20px;" in css
    assert "corner-shape: squircle" not in css
    assert css.count("grid-template-columns: 24px minmax(160px, 1fr) 100px 100px 118px 100px 118px 100px;") == 2
    assert css.count("column-gap: 20px;") == 2
    assert ".portfolio-holdings-table tbody {\n  padding-top: 10px;\n  display: flex;\n  flex-direction: column;\n  gap: 8px;" in css
    assert "transition: background-color 180ms ease;" in css
    assert ".portfolio-holdings-table tbody tr:not(.portfolio-holdings-message) {\n  width: calc(100% - 40px);" in css
    assert "height: 44px;" in css
    assert "margin-inline: 20px;" in css
    assert "padding: 4px 16px 4px 8px;" in css
    assert "border-radius: 8px;" in css
    assert "background: var(--panel-hover);" in css
    assert ".portfolio-holdings-table tbody tr:not(.portfolio-holdings-message):hover > td {\n    background: transparent;" in css
    assert ".portfolio-holding-identity {\n  width: 100%;" in css
    assert ".portfolio-holding-badge.has-logo {\n  overflow: visible;\n  border-radius: 0;\n  background: transparent;" in css


def test_holdings_list_uses_figma_asset_and_value_rules():
    script_path = Path(__file__).parents[1] / "app" / "static" / "portfolio-holdings.js"
    script = script_path.read_text(encoding="utf-8")

    assert "row.company_name || row.name" in script
    assert "formatNumber(shares, 3, 3)" in script
    assert "[copy.marketValueColumn, \"position\"]" in script
    assert "preciseMoney(row.market_value_usd)" in script
    assert 'profit: "Unreal. P&L",' in script
    assert 'fxProfit: "汇率盈亏",' in script
    assert '[copy.fxProfit, "fx"]' in script
    assert "row.broker_fx_ppl_usd" in script
    assert '<span class="portfolio-holding-profit ${tone(profit)}"><b>${signedMoney(profit)}</b><span>${signedPercent(profitPercent)}</span></span>' in script
    assert 'profit: "Unreal. P&L %",' not in script
    assert "const sortIcon = active ?" in script
    assert "${escapeHtml(label)}${sortIcon}" in script
    assert 'profitSortMetric: "amount"' in script
    assert 'state.profitSortMetric = "percent"' in script
    assert 'state.profitSortMetric === "amount" ? numeric(row.unrealized_usd) : numeric(row.unrealized_percent)' in script
    assert '[copy.marketValueColumn, "position"], [copy.weeks, "range"]' in script
    assert 'range: rangePosition(row) ?? Number.NEGATIVE_INFINITY' in script
    assert 'class="portfolio-holding-range-marker"' in script
    assert 'rangeCurrent: "当前价格"' in script


def test_portfolio_chart_uses_figma_colors_and_dynamic_axis_rules():
    script_path = Path(__file__).parents[1] / "app" / "static" / "portfolio.js"
    script = script_path.read_text(encoding="utf-8")

    assert 'market: "#2F8A3E"' in script
    assert 'cost: "#708CFF"' in script
    assert 'grid: "#EAEBED"' in script
    assert "function visibleYAxisValues(bounds)" in script
    assert "index === 0 || index === lastIndex || index % 2 === 0" in script
    assert "const axisInterval = intervalCount % 2 === 0 ? interval : interval / 2" in script
    assert "splitLine: { show: false }" in script
    assert "grid: { left: 0, right: 8, top: 14, bottom: 8, containLabel: true }" in script


def test_portfolio_metrics_use_count_up_animation():
    route_path = Path(__file__).parents[1] / "app" / "routes" / "lab.py"
    script_path = Path(__file__).parents[1] / "app" / "static" / "portfolio.js"

    route = route_path.read_text(encoding="utf-8")
    script = script_path.read_text(encoding="utf-8")

    assert '<script src="/static/portfolio.js"></script>' in route
    assert "function animateMetric(element, targetValue, formatter, delay = 0)" in script
    assert "const duration = 720" in script
    assert "const eased = 1 - Math.pow(1 - progress, 4)" in script
    assert "prefers-reduced-motion: reduce" in script
