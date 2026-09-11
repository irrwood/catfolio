from starlette.requests import Request


def _request(path="/analytics", query_string=b""):
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": path,
            "headers": [],
            "query_string": query_string,
        }
    )


def test_analysis_charts_page_contains_requested_charts(monkeypatch):
    from app.routes import analysis_charts

    monkeypatch.setattr(analysis_charts, "get_lang", lambda _request: "zh")
    response = analysis_charts.analysis_charts_page(_request())
    html = response.body.decode("utf-8")

    assert response.status_code == 200
    assert 'class="v5-nav-link active" href="/analytics"' in html
    for chart_id in (
        "monthlyReturnsChart",
        "drawdownChart",
        "correlationChart",
        "valuationMatrixChart",
        "distributionChart",
        "waterfallChart",
    ):
        assert f'id="{chart_id}"' in html
    assert 'id="profitCalendarGrid"' not in html
    for backtest_id in (
        "backtest-optimize",
        "backtestChart",
        "frontierChart",
        "monteCarloChart",
        "factorChart",
        "allocationRows",
        "aiAnalyzeBtn",
    ):
        assert f'id="{backtest_id}"' in html
    assert "/static/backtest.css" in html
    assert "/static/backtest.js" in html
    assert 'id="aiAnalyzeBtn" class="btn primary"' in html
    assert '<span class="ai-action-icon" aria-hidden="true"></span> AI 分析' in html
    assert 'id="valuationWaterlineOverall"' not in html
    assert 'id="valuationTableToggle"' in html
    assert 'id="valuationTablePanel"' in html
    assert 'aria-expanded="false"' in html
    assert 'id="valuationTablePanel" tabindex="0" aria-label="持仓估值明细" hidden' in html
    assert 'id="valuationTableBody"' in html
    assert 'id="valuationRefresh"' in html
    assert 'class="analytics-figma-charts"' in html
    assert 'class="analytics-card analytics-drawdown-card"' in html
    assert 'class="analytics-card analytics-valuation-card"' in html
    assert html.count('class="analytics-ai-link"') == 2
    for period in ("1D", "1W", "1M", "3M", "YTD", "1Y", "MAX"):
        assert f'data-drawdown-range="{period}"' in html


def test_analysis_charts_restores_valuation_matrix_and_table_contracts():
    from pathlib import Path

    root = Path(__file__).resolve().parents[1]
    script = (root / "app" / "static" / "analysis_charts.js").read_text(encoding="utf-8")
    css = (root / "app" / "static" / "analysis_charts.css").read_text(encoding="utf-8")

    assert 'fetchJson("/api/holdings/heatmap"' in script
    assert 'fetchJson("/api/refresh/fundamentals?force=true"' in script
    assert "function renderValuation(payload)" in script
    assert "function renderValuationTable(rows)" in script
    assert "function toggleValuationTable()" in script
    assert 'let drawdownRange = "MAX";' in script
    assert 'dayWindows = { "1D": 1, "1W": 7, "1M": 31, "3M": 93, "1Y": 366 }' in script
    assert 'data-drawdown-range' in script
    assert 'areaStyle: { color: "rgba(228,0,20,.10)" }' in script
    assert 'Math.sqrt(Number(value[2] || 0) / maximumWeight) * 118' in script
    assert 'class="analytics-valuation-tooltip"' in script
    assert ".analytics-valuation-chart-wrap" in css
    assert ".analytics-figma-charts {" in css
    assert "grid-template-columns: minmax(0, 586fr) minmax(0, 889fr);" in css
    assert ".analytics-drawdown-card," in css
    assert "height: 545px;" in css
    assert ".analytics-chart.valuation-matrix-chart { height: 100%; }" in css
    assert ".analytics-drawdown-ranges {" in css
    assert ".analytics-valuation-waterline" not in css
    assert ".valuation-table-wrap[hidden] { display: none; }" in css
    assert ".valuation-table td.numeric" in css
    assert "font-variant-numeric: tabular-nums;" in css

    backtest_script = (root / "app" / "static" / "backtest.js").read_text(encoding="utf-8")
    assert 'btn.innerHTML = \'<span class="ai-action-icon" aria-hidden="true"></span>\'' in backtest_script


def test_legacy_backtest_page_redirects_to_analytics():
    from app.routes import backtest

    response = backtest.backtest_page(_request(path="/backtest"))

    assert response.status_code == 307
    assert response.headers["location"] == "/analytics#backtest-optimize"


def test_sidebar_no_longer_has_separate_backtest_entry():
    from app.components import _V5_NAV_GROUPS

    hrefs = [href for _, items in _V5_NAV_GROUPS for href, _, _ in items]
    assert "/analytics" in hrefs
    assert "/backtest" not in hrefs


def test_profit_calendar_matches_responsive_figma_layout_tokens():
    from pathlib import Path

    root = Path(__file__).resolve().parents[1]
    css = (root / "app" / "static" / "portfolio.css").read_text(encoding="utf-8")
    script = (root / "app" / "static" / "portfolio-calendar.js").read_text(encoding="utf-8")

    assert ".portfolio-profit-calendar-card {" in css
    assert "max-width: 791px;" not in css
    assert "grid-auto-rows: minmax(0, 1fr);" in css
    assert "gap: 6px;" in css
    assert ".profit-calendar-summary" in css and "gap: 8px;" in css
    assert "filter: brightness(1.025);" in css
    assert "color: color-mix(in srgb, var(--ink) 80%, transparent);" in css
    assert 'positive: ["#ffffff", "#edffe0", "#d0f6b7", "#a6e585", "#89d663"]' in script
    assert 'negative: ["#ffffff", "#ffeff1", "#ffd3d9", "#ff97a8", "#ff889e"]' in script
    assert "function paletteColor(amount, colors)" in script
    assert "calendarFill(returnPercent, 2)" in script
    assert "calendarFill(returnPercent, 10)" in script
    assert 'window.addEventListener("catfolio:themechange"' in script
    assert "formatTileMoney(value)" in script


def test_profit_calendar_year_view_matches_figma_matrix_without_date_labels():
    from pathlib import Path

    root = Path(__file__).resolve().parents[1]
    css = (root / "app" / "static" / "portfolio.css").read_text(encoding="utf-8")
    script = (root / "app" / "static" / "portfolio-calendar.js").read_text(encoding="utf-8")

    assert "profit-calendar-year-day" in script
    assert "function renderMonths(data)" in script
    assert 'state.view = "day";' in script
    assert ".sort((left, right) => String(left.date).localeCompare(String(right.date)))" in script
    assert "const cells = rows.slice(0, 272).map(row =>" in script
    assert "while (cells.length < 272)" in script
    assert 'const tone = returnPercent < 0 ? "is-negative" : "is-positive";' in script
    assert 'style="--calendar-fill:${calendarFill(returnPercent, 2)}"' in script
    year_script = script[script.index("function renderYear"):script.index("function render(data)")]
    assert "profit-calendar-day-number" not in year_script
    assert "const daysInYear" not in year_script
    assert "totalCells" not in year_script
    assert "monthStarts" not in year_script
    assert "is-empty" in year_script
    assert "is-outside" not in year_script
    assert "copy.months" not in year_script
    assert "copy.weekdays" not in year_script
    assert ".profit-calendar-year-day.has-value { background: var(--calendar-fill); }" in css
    assert "grid-template-rows: repeat(16, minmax(0, 1fr));" in css
    assert "grid-template-columns: repeat(17, minmax(0, 1fr));" in css
    assert "grid-auto-flow: row;" in css
    assert "align-content: stretch;" in css
    assert "justify-content: stretch;" in css
    assert ".profit-calendar-year-surface" not in css
    assert ".profit-calendar-year-months" not in css
    assert ".profit-calendar-month-tile:not(.has-value) strong { display: none; }" in css


def test_income_summary_groups_dividends_and_interest_by_month_and_year(monkeypatch, tmp_path):
    from app import lab

    source = tmp_path / "transactions.csv"
    source.write_text(
        "Date,Action,Total,Currency (Total)\n"
        "2026-01-10,Dividend (Ordinary),20,USD\n"
        "2026-02-10,Interest on cash,3.5,USD\n"
        "2025-03-10,Dividend (Qualified),10,USD\n"
        "2026-04-10,Market buy,100,USD\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(lab, "SOURCE_FILES", [("A", str(source))])
    lab.income_summary.cache_clear()

    result = lab.income_summary()

    assert result["rows"] == [
        {"year": "2025", "dividends_usd": 10.0, "cash_interest_usd": 0.0},
        {"year": "2026", "dividends_usd": 20.0, "cash_interest_usd": 3.5},
    ]
    assert result["monthly_rows"] == [
        {"month": "2025-03", "dividends_usd": 10.0, "cash_interest_usd": 0.0},
        {"month": "2026-01", "dividends_usd": 20.0, "cash_interest_usd": 0.0},
        {"month": "2026-02", "dividends_usd": 0.0, "cash_interest_usd": 3.5},
    ]


def test_income_summary_does_not_read_private_files_in_demo(monkeypatch):
    from app import lab

    monkeypatch.setattr(lab, "demo_mode", lambda: True)
    monkeypatch.setattr(lab, "_init_source_files", lambda: (_ for _ in ()).throw(AssertionError("demo should not read local files")))
    monkeypatch.setattr(lab, "SOURCE_FILES", [])
    lab.income_summary.cache_clear()

    result = lab.income_summary()

    assert result["currency"] == "USD"
    assert result["rows"]
    assert result["monthly_rows"]
    assert all(row["month"] <= "2026-08" for row in result["monthly_rows"])


def test_profit_calendar_summary_switches_between_month_and_year():
    from pathlib import Path

    root = Path(__file__).resolve().parents[1]
    script = (root / "app" / "static" / "portfolio-calendar.js").read_text(encoding="utf-8")

    assert "income.monthly_rows || []" in script
    assert 'state.view === "day" ? copy.summaryMonth : copy.summaryYear' in script


def test_return_distribution_bins_count_each_day_once(monkeypatch):
    from app import lab

    returns = [-0.0322119425129008, -0.01, 0.0, 0.01, 0.04099539873174926]
    monkeypatch.setattr(
        lab,
        "lab_history_summary",
        lambda: {"nav": [{"return": value} for value in returns]},
    )
    lab.return_distribution.cache_clear()

    result = lab.return_distribution()

    assert sum(row["count"] for row in result["bins"]) == len(returns)
    assert result["stats"]["sample_days"] == len(returns)
