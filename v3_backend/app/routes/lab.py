"""Page route: lab."""
import json
from fastapi import APIRouter, Query
from fastapi.responses import HTMLResponse
from app.components import wrap_v4_layout, data_health_bar
from app.data_store import current_snapshot, refresh_market_quotes, refresh_trading212, refresh_fundamentals
from app.analytics import holdings_detail, holdings_heatmap, pnl_contribution, portfolio_summary, sector_concentration
from app.lab import lab_history_summary

router = APIRouter(tags=["pages"])


@router.get("/lab")
def lab_page():
    content = """<style>
    /* Lab Dashboard — v4 Dark Theme */
    .lab-hero { display: flex; justify-content: space-between; gap: 18px; align-items: flex-start; margin-bottom: 16px; }
    .lab-hero h1 { margin: 0 0 8px; font-size: 32px; line-height: 1.12; letter-spacing: -0.01em; }
    .lab-hero p { margin: 0; color: var(--muted); line-height: 1.6; max-width: 72ch; }
    .toolbar { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
    .toolbar a, .toolbar button {
        display: inline-flex; align-items: center; height: 34px; padding: 0 12px;
        border: 1px solid var(--line); border-radius: 999px; background: var(--panel);
        color: var(--ink); text-decoration: none; font-weight: 680; font-size: 13px;
        cursor: pointer; font-family: inherit;
    }
    .toolbar a:hover, .toolbar button:hover { border-color: var(--line-strong); background: var(--soft); }
    .toolbar button { background: var(--accent); color: #fff; border-color: var(--accent); }
    .toolbar button:hover { background: var(--accent-strong); box-shadow: var(--shadow-glow); }
    .toolbar button:disabled { opacity: .65; cursor: wait; }

    /* Data health row */
    .data-health-row { display: none !important; }
    .data-health-chip { border: 1px solid var(--line); border-radius: 14px; padding: 10px 12px; background: var(--panel); display: grid; gap: 4px; min-width: 0; }
    .data-health-chip b { font-size: 12px; color: var(--ink); }
    .data-health-chip span { color: var(--muted); font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

    /* Snapshot cards — premium dark cards */
    .snapshot-grid { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 12px; margin: 16px 0; }
    .snapshot-card {
        min-height: 178px; border: 1px solid var(--line); border-radius: 16px; padding: 18px;
        background: var(--panel);
        color: var(--ink); display: grid; align-content: space-between;
    }
    .snapshot-label { color: var(--muted); font-size: 12px; font-weight: 700; }
    .snapshot-card-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; min-width: 0; }
    .snapshot-control {
        height: 28px; max-width: 96px; border: 1px solid var(--line); border-radius: 999px;
        padding: 0 24px 0 10px; background: var(--bg); color: var(--ink);
        font: inherit; font-size: 12px; font-weight: 720; outline: none;
    }
    .snapshot-control:focus { border-color: var(--accent); }
    .snapshot-value { margin-top: 18px; font-size: clamp(30px, 3.5vw, 42px); line-height: .95; font-weight: 780; white-space: nowrap; }
    .snapshot-value.small { font-size: clamp(24px, 2.9vw, 34px); }
    .snapshot-sub { margin-top: 16px; color: var(--muted); font-size: 12px; line-height: 1.35; }
    .snapshot-sub.positive, .snapshot-value.positive { color: var(--positive); }
    .snapshot-sub.negative, .snapshot-value.negative { color: var(--negative); }
    .snapshot-spark { width: 100%; height: 34px; margin-top: 18px; overflow: visible; }
    .snapshot-spark polyline { fill: none; stroke: var(--positive); stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; opacity: .95; }
    .snapshot-spark.muted polyline { stroke: var(--accent); }
    .snapshot-spark.negative polyline { stroke: var(--negative); }

    /* Daily PnL panel */
    .daily-pnl-panel {
        border: 1px solid var(--line); border-radius: 18px; padding: 24px;
        margin: 16px 0; background: var(--panel);
        color: var(--ink);
    }
    .daily-pnl-head { display: flex; justify-content: space-between; gap: 16px; align-items: flex-start; margin-bottom: 12px; }
    .daily-pnl-title { font-size: 16px; line-height: 1.2; font-weight: 650; color: var(--ink); }
    .daily-pnl-sub { margin-top: 4px; color: var(--muted); font-size: 12px; }
    .daily-pnl-note { color: var(--muted); font-size: 12px; text-align: right; max-width: 260px; line-height: 1.45; }
    .daily-pnl-chart { width: 100%; height: 420px; min-width: 0; }
    .monthly-return-chart { width: 100%; height: 440px; min-width: 0; }
    .valuation-matrix-chart { width: 100%; height: 500px; min-width: 0; }

    /* Valuation waterline */
    .valuation-waterline {
        display: none !important;
        margin-top: 18px; border: 1px solid var(--line-strong); border-radius: 16px;
        overflow: hidden; background: var(--panel);
    }
    .valuation-waterline-summary {
        display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 14px; align-items: end;
        padding: 20px 24px; border-bottom: 1px solid var(--line);
    }
    .valuation-waterline-summary .kicker { color: var(--muted); font-size: 20px; line-height: 1.35; font-weight: 780; letter-spacing: .04em; text-transform: uppercase; }
    .valuation-waterline-summary b { color: var(--ink); font-size: 28px; line-height: 1; font-weight: 800; font-family: var(--font-mono); }
    .valuation-waterline-summary b.cheap { color: var(--positive); }
    .valuation-waterline-summary b.expensive { color: var(--negative); }
    .valuation-waterline-summary span { grid-column: 1 / -1; color: var(--muted); font-size: 12px; line-height: 1.45; max-width: 72ch; }
    .valuation-waterline-list { display: grid; }
    .valuation-waterline-row {
        display: grid; grid-template-columns: 82px minmax(0, 1fr) 88px; gap: 20px;
        align-items: center; min-height: 82px; padding: 0 24px; border-bottom: 1px solid var(--line); color: var(--ink);
    }
    .valuation-waterline-row:last-child { border-bottom: 0; }
    .valuation-waterline-row b { color: var(--ink); font-size: 15px; font-weight: 780; }
    .valuation-waterline-track {
        position: relative; height: 12px; border-radius: 999px;
        background: color-mix(in oklch, var(--bg) 60%, var(--line)); overflow: visible;
    }
    .valuation-waterline-track::after {
        content: ""; position: absolute; left: 50%; top: -9px; width: 2px; height: 30px;
        border-radius: 999px; background: var(--muted); box-shadow: 0 0 18px var(--line-strong);
    }
    .valuation-waterline-fill { position: absolute; top: 0; height: 100%; border-radius: 999px; background: var(--positive); }
    .valuation-waterline-fill.expensive { background: var(--negative); }
    .valuation-waterline-value { text-align: right; font-family: var(--font-mono); font-size: 15px; font-weight: 780; }
    .valuation-waterline-value.cheap { color: var(--positive); }
    .valuation-waterline-value.expensive { color: var(--negative); }

    .panel { background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius-lg); padding: 16px; }
    .panel h2 { margin: 0 0 12px; font-size: 14px; font-weight: 700; color: var(--ink); }
    .panel table td:first-child, .panel table th:first-child { padding-left: 0; }
    .panel table td:last-child, .panel table th:last-child { padding-right: 0; }
    .metric { min-height: 90px; background: var(--soft); border: 1px solid var(--line); border-radius: 16px; padding: 16px; display: grid; align-content: space-between; }
    .label { color: var(--muted); font-size: 12px; font-weight: 650; }
    .value { font-size: 22px; font-weight: 720; margin-top: 8px; }
    .layout { display: grid; grid-template-columns: minmax(0, 1fr) 340px; gap: 12px; align-items: start; }
    .stack { display: grid; gap: 12px; }

    /* 4 questions */
    .question-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; margin: 12px 0; }
    .question-card { border: 1px solid var(--line); border-radius: 12px; padding: 16px; background: var(--soft); min-height: 118px; }
    .question-card span { color: var(--muted); font-size: 12px; font-weight: 650; }
    .question-card b { display: block; margin: 8px 0 6px; font-size: 15px; }
    .question-card p { font-size: 13px; line-height: 1.45; color: var(--muted); }

    /* Portfolio Rebuild section */
    .frontier-lab { display: grid; gap: 12px; }
    .frontier-summary { display: grid; grid-template-columns: 150px minmax(0, 1fr); gap: 12px; align-items: stretch; }
    .score-card { border: 1px solid var(--line); border-radius: var(--radius-lg); padding: 16px; background: var(--soft); display: grid; align-content: center; justify-items: center; min-height: 150px; }
    .score-card .score { font-size: 42px; line-height: 1; font-weight: 760; margin: 8px 0 4px; color: var(--accent); }
    .score-card .score-caption { color: var(--muted); font-size: 11px; text-align: center; line-height: 1.4; }
    .score-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
    .score-mini { border: 1px solid var(--line); border-radius: 8px; padding: 12px; background: var(--soft); }
    .score-mini b { display: block; font-size: 20px; margin-top: 6px; }
    .insight-strip { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
    .insight { border: 1px solid var(--line); border-radius: 8px; padding: 12px; background: var(--panel); }
    .insight span { color: var(--muted); font-size: 12px; font-weight: 650; }
    .insight b { display: block; margin-top: 6px; font-size: 15px; line-height: 1.35; }
    .preference { border: 1px solid var(--line); border-radius: var(--radius-lg); padding: 16px; background: var(--soft); }
    .preference-head { display: flex; justify-content: space-between; gap: 12px; align-items: baseline; margin-bottom: 10px; }
    .preference-head b { font-size: 15px; }
    .preference-head span { color: var(--muted); font-size: 12px; }
    .risk-slider { width: 100%; accent-color: var(--accent); }
    .risk-tabs { display: grid; grid-template-columns: repeat(3, 1fr); gap: 6px; margin-bottom: 10px; }
    .risk-tab { justify-content: center; border-color: var(--line); background: var(--panel); color: var(--muted); border-radius: 8px; cursor: pointer; }
    .risk-tab.active { border-color: var(--accent); background: var(--accent); color: var(--bg); }
    .slider-labels { display: flex; justify-content: space-between; color: var(--muted); font-size: 12px; margin-top: 5px; }
    .preference-metrics { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; margin-top: 12px; }
    .preference-metric { border: 1px solid var(--line); border-radius: 8px; padding: 12px; background: var(--panel); }
    .preference-metric b { display: block; margin-top: 5px; font-size: 16px; }
    .optimization-grid { display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(260px, .85fr); gap: 12px; }
    .allocation-table td, .allocation-table th { text-align: right; }
    .allocation-table td:first-child, .allocation-table th:first-child { text-align: left; }
    .delta-up { color: var(--positive); }
    .delta-down { color: var(--negative); }
    .why-list { display: grid; gap: 12px; }
    .why-block { border: 1px solid var(--line); border-radius: 8px; padding: 12px; background: var(--panel); }
    .why-block b { display: block; margin-bottom: 8px; }
    .pill-list { display: flex; flex-wrap: wrap; gap: 6px; }
    .pill { border: 1px solid var(--line); border-radius: 999px; padding: 5px 8px; background: var(--soft); font-size: 12px; color: var(--ink); }

    /* Command Center */
    .command-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; min-width: 0; }
    .command-grid > * { min-width: 0; }
    .command-wide { grid-column: 1 / -1; }
    .quality-banner { border: 1px solid var(--line); border-radius: var(--radius-lg); background: var(--soft); padding: 12px 14px; margin-bottom: 12px; display: grid; gap: 6px; color: var(--muted); line-height: 1.45; }
    .quality-banner b { color: var(--ink); }
    .section-kicker { color: var(--muted); font-size: 12px; font-weight: 700; margin: 6px 0 2px; text-transform: uppercase; letter-spacing: .03em; }
    .source-badge { display: inline-flex; align-items: center; border: 1px solid var(--line); border-radius: 999px; padding: 3px 8px; color: var(--muted); background: var(--soft); font-size: 11px; font-weight: 650; white-space: nowrap; }

    /* Charts */
    .mini-chart { width: 100%; min-width: 0; height: 280px; border: 1px solid var(--line-strong); border-radius: var(--radius-lg); background: var(--panel); }
    .heatmap-chart { width: 100%; min-width: 0; height: 360px; border: 1px solid var(--line-strong); border-radius: var(--radius-lg); background: var(--panel); }
    .chart { height: 420px; border: 1px solid var(--line-strong); border-radius: var(--radius-lg); background: var(--bg); }
    .small-chart { height: 300px; border: 1px solid var(--line-strong); border-radius: var(--radius-lg); background: var(--panel); }
    .chart-head { display: flex; justify-content: space-between; gap: 12px; align-items: baseline; margin-bottom: 10px; }
    .chart-head h2 { margin: 0; font-size: 14px; }
    .chart-head span { color: var(--muted); font-size: 11px; }

    /* Tables */
    .table-wrap { overflow: auto; border: 1px solid var(--line); border-radius: var(--radius-lg); }
    .table-wrap table { min-width: 840px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    td, th { padding: 8px 10px; border-bottom: 1px solid var(--line); text-align: right; white-space: nowrap; }
    td:first-child, th:first-child { text-align: left; }
    th { color: var(--muted); font-size: 12px; font-weight: 600; }
    tr:hover td { background: var(--panel-hover); }

    /* Position bars */
    .position-bar { height: 8px; border-radius: 999px; background: var(--soft); border: 1px solid var(--line); overflow: hidden; min-width: 90px; }
    .position-bar i { display: block; height: 100%; background: var(--accent); }
    .week-position-range { position: relative; height: 8px; border-radius: 999px; border: 1px solid var(--line); background: linear-gradient(90deg, var(--negative-soft), var(--soft), var(--positive-soft)); overflow: hidden; min-width: 90px; }
    .week-position-marker { position: absolute; top: -3px; width: 4px; height: 14px; border-radius: 999px; background: var(--ink); transform: translateX(-50%); }
    .week-position-pct { color: var(--muted); text-align: right; font-variant-numeric: tabular-nums; }

    /* Asset heatmap */
    .asset-heatmap {
        min-height: 760px; height: auto; display: grid;
        grid-template-columns: repeat(12, minmax(0, 1fr)); grid-auto-rows: 92px;
        grid-auto-flow: dense; gap: 6px; padding: 10px; overflow: visible;
        background: color-mix(in oklch, var(--panel) 72%, var(--soft));
    }
    .sector-tile { border: 1px solid var(--line); border-radius: 12px; background: var(--soft); padding: 8px; min-width: 0; overflow: hidden; display: grid; grid-template-rows: auto minmax(0, 1fr); gap: 6px; }
    .sector-tile-head { display: flex; justify-content: space-between; gap: 8px; align-items: baseline; font-size: 12px; font-weight: 740; min-width: 0; }
    .sector-tile-head span:first-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .sector-tile-head span:last-child { white-space: nowrap; }
    .sector-inner-grid { display: grid; grid-template-columns: repeat(8, minmax(0, 1fr)); grid-auto-rows: 46px; grid-auto-flow: dense; gap: 3px; min-height: 0; }
    .asset-tile { border: 1px solid color-mix(in oklch, var(--line) 70%, transparent); border-radius: 3px; display: grid; place-items: center; align-content: center; gap: 2px; min-width: 0; overflow: hidden; color: var(--ink); text-align: center; }
    .asset-logo { width: 24px; height: 24px; border-radius: 50%; background: var(--soft); color: var(--accent); display: grid; place-items: center; font-size: 10px; font-weight: 800; }
    .asset-ticker { font-size: 18px; line-height: 1; font-weight: 760; max-width: 100%; overflow: hidden; text-overflow: ellipsis; }
    .asset-name { max-width: 92%; color: var(--muted); font-size: 10px; line-height: 1.2; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .asset-change { font-size: 15px; font-weight: 760; line-height: 1; }
    .asset-weight { color: var(--muted); font-size: 10px; font-weight: 650; }
    .asset-tile.small { gap: 1px; padding: 1px; }
    .asset-tile.small .asset-logo { display: none; }
    .asset-tile.small .asset-ticker { font-size: 11px; }
    .asset-tile.small .asset-name { display: none; }
    .asset-tile.small .asset-change { font-size: 10px; }
    .asset-tile.small .asset-weight { display: none; }

    /* Decision brief */
    .brief { display: grid; gap: 10px; }
    .brief-line { border-top: 1px solid var(--line); padding-top: 10px; color: var(--muted); line-height: 1.55; }
    .brief-line:first-child { border-top: 0; padding-top: 0; }
    .brief-line b { color: var(--ink); }
    .status { color: var(--muted); font-size: 13px; min-height: 20px; }
    .percentile-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-top: 10px; }
    .percentile { border: 1px solid var(--line); border-radius: 8px; padding: 10px; background: var(--soft); }
    .percentile span { color: var(--muted); font-size: 12px; }
    .percentile b { display: block; margin-top: 6px; font-size: 16px; }
    .weight-list { display: grid; gap: 12px; margin-top: 12px; }
    .weight-row { display: grid; grid-template-columns: minmax(92px, 116px) 1fr 48px; gap: 8px; align-items: center; font-size: 12px; }
    .weight-row span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .track { height: 8px; border-radius: 999px; overflow: hidden; background: var(--soft); border: 1px solid var(--line); }
    .fill { height: 100%; background: var(--accent); }

    /* Responsive */
    @media (max-width: 1100px) { .snapshot-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); } }
    @media (max-width: 900px) { .lab-hero, .layout { display: block; } .question-grid, .score-grid, .insight-strip, .optimization-grid, .command-grid { grid-template-columns: 1fr 1fr; } .frontier-summary { grid-template-columns: 1fr; } .toolbar { justify-content: flex-start; margin-top: 12px; } }
    @media (max-width: 760px) {
        .asset-heatmap { grid-template-columns: repeat(6, minmax(0, 1fr)); grid-auto-rows: 62px; min-height: 940px; }
        .asset-heatmap .sector-tile, .sector-inner-grid .asset-tile { grid-column: auto !important; grid-row: auto !important; }
        .sector-inner-grid { grid-template-columns: repeat(4, minmax(0, 1fr)); }
    }
    @media (max-width: 560px) {
        .snapshot-grid, .question-grid, .percentile-grid, .score-grid, .insight-strip, .optimization-grid, .preference-metrics, .command-grid { grid-template-columns: minmax(0, 1fr) !important; }
        .data-health-row { grid-template-columns: minmax(0, 1fr); }
        .command-wide { grid-column: 1 !important; }
        .chart-head { display: grid; align-items: start; }
        .source-badge { white-space: normal; }
        .daily-pnl-panel { padding: 18px 14px 14px; }
        .daily-pnl-head { display: grid; }
        .daily-pnl-note { text-align: left; }
        .daily-pnl-chart { height: 320px; }
        .monthly-return-chart { height: 340px; }
        .valuation-matrix-chart { height: 360px; }
        .valuation-waterline-summary { grid-template-columns: minmax(0, 1fr); padding: 18px 16px; }
        .valuation-waterline-row { grid-template-columns: 54px minmax(0, 1fr) 68px; gap: 10px; min-height: 70px; padding: 0 16px; }
        .valuation-waterline-summary .kicker { font-size: 18px; }
    </style>
    <script src="/static/vendor/echarts.min.js"></script>
<header id="overview" class="lab-hero">
        <div>
            <h1>Portfolio Lab</h1>
            <p>组合分析、量化回测与优化</p>
        </div>
        <div class="toolbar">
            <button id="refreshHistory" class="btn">刷新历史价格</button>
        </div>
    </header>
    <div class="dashboard-stack">
    <div class="data-health-row">
        <div class="data-health-chip"><b><span class="status-dot"></span>Trading 212</b><span id="healthTrading212">读取中...</span></div>
        <div class="data-health-chip"><b><span class="status-dot"></span>Yahoo 行情</b><span id="healthMarket">读取中...</span></div>
        <div class="data-health-chip"><b><span id="healthFundamentalsDot" class="status-dot warn"></span>FMP 估值</b><span id="healthFundamentals">读取中...</span></div>
        <div class="data-health-chip"><b><span class="status-dot"></span>历史价格</b><span id="healthHistory">读取中...</span></div>
    </div>
    <div class="snapshot-grid">
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">总市值</div>
                <div id="snapshotMarketValue" class="snapshot-value">—</div>
                <div id="snapshotMarketSub" class="snapshot-sub">等待持仓...</div>
            </div>
            <svg id="snapshotMarketSpark" class="snapshot-spark muted" viewBox="0 0 120 34" preserveAspectRatio="none"></svg>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">总浮盈</div>
                <div id="snapshotTotalPnl" class="snapshot-value positive">—</div>
                <div id="annualReturn" class="snapshot-sub positive">—</div>
            </div>
            <svg id="snapshotPnlSpark" class="snapshot-spark" viewBox="0 0 120 34" preserveAspectRatio="none"></svg>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">今日盈亏</div>
                <div id="snapshotTodayPnl" class="snapshot-value positive">—</div>
                <div id="annualVol" class="snapshot-sub positive">—</div>
            </div>
            <svg id="snapshotTodaySpark" class="snapshot-spark" viewBox="0 0 120 34" preserveAspectRatio="none"></svg>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">持仓股数</div>
                <div id="snapshotHoldingsCount" class="snapshot-value">—</div>
                <div id="snapshotBreadth" class="snapshot-sub">等待涨跌分布...</div>
            </div>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">夏普比率</div>
                <div id="sharpe" class="snapshot-value">—</div>
                <div id="snapshotSharpeSub" class="snapshot-sub positive">等待基准...</div>
            </div>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-card-head">
                    <div class="snapshot-label">最大回撤</div>
                    <select id="drawdownRangeSelect" class="snapshot-control" aria-label="最大回撤统计时间">
                        <option value="all">全部</option>
                        <option value="252">1 年</option>
                        <option value="126">6 月</option>
                        <option value="63">3 月</option>
                        <option value="21">1 月</option>
                    </select>
                </div>
                <div id="maxDrawdown" class="snapshot-value negative">—</div>
                <div id="snapshotDrawdownSub" class="snapshot-sub">样本期</div>
            </div>
        </div>
    </div>
    <section class="daily-pnl-panel">
        <div class="daily-pnl-head">
            <div>
                <div class="daily-pnl-title">每日盈亏</div>
                <div class="daily-pnl-sub">过去 30 天</div>
            </div>
            <div class="daily-pnl-note">按当前仓位模型估算，不是现金流口径账户收益。</div>
        </div>
        <div id="dailyPnlChart" class="daily-pnl-chart"></div>
    </section>
    <section class="daily-pnl-panel">
        <div class="daily-pnl-head">
            <div>
                <div class="daily-pnl-title">月度收益热图</div>
                <div class="daily-pnl-sub">年 × 月盈亏%</div>
            </div>
            <div class="daily-pnl-note">按当前仓位模型估算，适合看月份节奏和波动，不代表完整账户现金流收益。</div>
        </div>
        <div id="monthlyReturnDarkChart" class="monthly-return-chart"></div>
    </section>
    <section class="daily-pnl-panel">
        <div class="daily-pnl-head">
            <div>
                <div class="daily-pnl-title">估值矩阵 (P/E vs 成长)</div>
                <div class="daily-pnl-sub">气泡大小 = 仓位权重</div>
            </div>
            <div class="daily-pnl-note">优先使用 EPS 成长率；缺失时使用营收同比成长率。需要 fundamentals 数据源刷新。</div>
        </div>
        <div id="valuationMatrixChart" class="valuation-matrix-chart"></div>
        <div class="valuation-waterline">
            <div class="valuation-waterline-summary">
                <div class="kicker">估值水位<br>(PREMIUM/DISCOUNT)</div>
                <b id="valuationWaterlineOverall">—</b>
                <span id="valuationWaterlineNote">刷新 FMP fundamentals 后，显示持仓相对同板块/组合中位估值的 premium 或 discount。</span>
            </div>
            <div id="valuationWaterlineList" class="valuation-waterline-list"></div>
        </div>
    </section>

    <div class="chart-head"><h2>Portfolio Command Center</h2><span>集中度、盈亏、收益和风险</span></div>
    <div id="qualityBanner" class="quality-banner">
        <b>数据口径</b>
        <span>正在读取数据说明...</span>
    </div>

    <div class="section-kicker">真实持仓数据</div>

    <section class="command-card">
        <div class="chart-head"><h2>持仓分类集中度</h2><span><span class="source-badge">真实持仓 + 本地分类</span></span></div>
        <div id="sectorChart" class="mini-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>个股盈亏贡献</h2><span><span class="source-badge">成本 vs 现价</span></span></div>
        <div id="pnlChart" class="mini-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>持仓明细</h2><span>成本、现价、今日涨跌、浮盈和仓位</span></div>
        <div class="table-wrap">
            <table>
                <thead><tr><th>代码</th><th>名称</th><th>成本</th><th>现价</th><th>今日</th><th>浮盈%</th><th>52周</th><th>仓位</th></tr></thead>
                <tbody id="holdingRows"></tbody>
            </table>
        </div>
    </section>

    <div class="section-kicker">模型分析，按当前仓位回看历史，不是现金流口径真实收益</div>

    <section class="command-card">
        <div class="chart-head"><h2>收益率分布</h2><span>模型日收益</span></div>
        <div id="distributionChart" class="mini-chart"></div>
        <div id="distributionNote" style="font-size:11px;color:var(--muted);text-align:center;margin-top:4px;"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>回撤水下曲线</h2><span>模型组合跌离高点</span></div>
        <div id="drawdownChart" class="mini-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>持仓相关性矩阵</h2><span>颜色越深，越容易同涨同跌</span></div>
        <div id="correlationChart" class="heatmap-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>模型归因 Waterfall</h2><span>本月当前权重贡献</span></div>
        <div id="waterfallChart" class="mini-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>累计收益对比</h2><span id="cumulativeRange">TWR / 现金流镜像</span></div>
        <div id="cumulativeChart" style="width:100%;height:280px;"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>月度收益热力图</h2><span id="monthlyRange">按日历月</span></div>
        <div id="monthlyHeatmapChart" style="width:100%;height:340px;"></div>
    </section>

    <aside class="stack">
        <section class="panel">
            <h2>资产归并</h2>
            <table>
                <thead><tr><th>底层暴露</th><th>成员</th><th>权重</th></tr></thead>
                <tbody id="groupRows"></tbody>
            </table>
        </section>
        <section class="panel" style="display: none;">
            <h2>Monte Carlo Range</h2>
            <div id="percentileGrid" class="percentile-grid"></div>
        </section>
        <section class="panel" style="display: none;">
            <h2>状态</h2>
            <p id="status">正在加载 Portfolio Lab...</p>
        </section>
    </aside>
    </div>

<script src="/static/vendor/echarts.min.js"></script>
<script>
    const fmtPct = value => `${(Number(value || 0) * 100).toFixed(1)}%`;
    const fmtNum = value => Number(value || 0).toFixed(2);
    const statusEl = document.querySelector("#status");
    const groupRows = document.querySelector("#groupRows");
    const percentileGrid = document.querySelector("#percentileGrid");
    const qualityBanner = document.querySelector("#qualityBanner");
    const monthlyRange = document.querySelector("#monthlyRange");
    const cumulativeRange = document.querySelector("#cumulativeRange");
    const returnBasisNote = document.querySelector("#returnBasisNote");
    const returnBasisButtons = Array.from(document.querySelectorAll("[data-return-basis]"));
    const snapshotMarketValue = document.querySelector("#snapshotMarketValue");
    const snapshotMarketSub = document.querySelector("#snapshotMarketSub");
    const snapshotTotalPnl = document.querySelector("#snapshotTotalPnl");
    const snapshotTodayPnl = document.querySelector("#snapshotTodayPnl");
    const snapshotHoldingsCount = document.querySelector("#snapshotHoldingsCount");
    const snapshotBreadth = document.querySelector("#snapshotBreadth");
    const maxDrawdown = document.querySelector("#maxDrawdown");
    const snapshotSharpeSub = document.querySelector("#snapshotSharpeSub");
    const snapshotDrawdownSub = document.querySelector("#snapshotDrawdownSub");
    const drawdownRangeSelect = document.querySelector("#drawdownRangeSelect");
    const valuationWaterlineOverall = document.querySelector("#valuationWaterlineOverall");
    const valuationWaterlineNote = document.querySelector("#valuationWaterlineNote");
    const valuationWaterlineList = document.querySelector("#valuationWaterlineList");
    const healthTrading212 = document.querySelector("#healthTrading212");
    const healthMarket = document.querySelector("#healthMarket");
    const healthFundamentals = document.querySelector("#healthFundamentals");
    const healthFundamentalsDot = document.querySelector("#healthFundamentalsDot");
    const healthHistory = document.querySelector("#healthHistory");
    const snapshotMarketSpark = document.querySelector("#snapshotMarketSpark");
    const snapshotPnlSpark = document.querySelector("#snapshotPnlSpark");
    const snapshotTodaySpark = document.querySelector("#snapshotTodaySpark");
    const annualReturn = document.querySelector("#annualReturn");
    const annualVol = document.querySelector("#annualVol");
    const sharpe = document.querySelector("#sharpe");
    const refreshHistory = document.querySelector("#refreshHistory");
    let latestCommandCenter = null;
    let latestNavRows = [];
    let currentReturnBasis = "twr";

    // ---- Chart engine: ECharts ----
    const chartById = new Map();
    const chartInstances = [];
    let helmThemeRegistered = false;
    function ensureHelmTheme() {
        // ECharts' built-in default splitLine is "#E0E6F1" (near-white), designed for
        // light backgrounds. Charts that override yAxis without re-setting splitLine fall
        // back to it, producing glaring white gridlines on the dark theme. Register a
        // theme whose default axis/grid lines are semi-transparent grey — subtle on both
        // dark and light backgrounds — so every chart inits safely regardless.
        if (helmThemeRegistered || !window.echarts) return;
        const axisDef = {
            axisLine: { lineStyle: { color: "rgba(128,128,128,0.28)" } },
            splitLine: { lineStyle: { color: "rgba(128,128,128,0.14)" } },
        };
        window.echarts.registerTheme("helm", { categoryAxis: axisDef, valueAxis: axisDef });
        helmThemeRegistered = true;
    }

    function isDark() { return !document.documentElement.classList.contains('light-theme'); }

    async function ensureEcharts() {
        if (window.echarts) return window.echarts;
        return new Promise((resolve) => {
            const timer = setInterval(() => {
                if (window.echarts) {
                    clearInterval(timer);
                    resolve(window.echarts);
                }
            }, 50);
        });
    }
    function chart(id) {
        const node = document.querySelector(id);
        if (!node) return { setOption() {}, resize() {} };
        if (chartById.has(id)) return chartById.get(id);
        ensureHelmTheme();
        const instance = window.echarts.init(node, "helm");
        chartInstances.push(instance);
        chartById.set(id, instance);
        return instance;
    }
    function diag(msg) {}
    window.addEventListener("resize", () => {
        chartInstances.forEach(i => i.resize());
    });
    const usd = value => `$${Number(value || 0).toLocaleString("en-GB", { maximumFractionDigits: 0 })}`;
    const signedUsd = value => `${Number(value || 0) >= 0 ? "+" : "-"}${usd(Math.abs(Number(value || 0)))}`;
    function clamp(value, min, max) { return Math.max(min, Math.min(max, value)); }
    function fmtUnixTime(value) {
        if (!value) return "未刷新";
        return new Date(Number(value) * 1000).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
    }
    function setTone(element, value) {
        if (!element) return;
        element.classList.toggle("positive", Number(value || 0) >= 0);
        element.classList.toggle("negative", Number(value || 0) < 0);
    }
    function renderWeekPositionCell(row) {
        if (!row || row.position === null || row.position === undefined) return "—";
        const pos = Math.max(0, Math.min(1, Number(row.position || 0)));
        return `<div class="week-position-range" title="低点 ${fmtNum(row.low)}，现价 ${fmtNum(row.current)}，高点 ${fmtNum(row.high)}"><i class="week-position-marker" style="left:${(pos * 100).toFixed(1)}%"></i></div><span class="week-position-pct">${Math.round(pos * 100)}%</span>`;
    }
    function renderSparkline(svg, values, tone = "") {
        if (!svg) return;
        const nums = (values || []).map(Number).filter(Number.isFinite);
        if (nums.length < 2) { svg.innerHTML = ""; return; }
        const min = Math.min(...nums); const max = Math.max(...nums); const span = max - min || 1;
        const points = nums.map((value, index) => {
            const x = nums.length === 1 ? 0 : index / (nums.length - 1) * 120;
            const y = 30 - ((value - min) / span * 24);
            return `${x.toFixed(1)},${y.toFixed(1)}`;
        }).join(" ");
        svg.classList.toggle("negative", tone === "negative");
        svg.classList.toggle("muted", tone === "muted");
        svg.innerHTML = `<polyline points="${points}"></polyline>`;
    }
    function selectedDrawdownWindow() {
        const value = drawdownRangeSelect?.value || "all"; return value === "all" ? null : Number(value);
    }
    function drawdownWindowLabel(days, available) {
        if (!days) return `全部样本 · ${available} 个交易日`;
        const labels = { 252: "近 1 年", 126: "近 6 个月", 63: "近 3 个月", 21: "近 1 个月" };
        return `${labels[days] || `近 ${days} 日`} · ${Math.min(days, available)} 个交易日`;
    }
    function computeDrawdownRows(navRows, days = null) {
        const rows = (navRows || []).filter(row => Number.isFinite(Number(row.nav)));
        const scoped = days ? rows.slice(-days) : rows;
        let peak = null; let maxDrawdownValue = 0;
        const drawdownRows = scoped.map(row => {
            const nav = Number(row.nav); peak = peak === null ? nav : Math.max(peak, nav);
            const drawdown = peak ? nav / peak - 1 : 0;
            maxDrawdownValue = Math.min(maxDrawdownValue, drawdown);
            return { date: row.date, drawdown };
        });
        return { rows: drawdownRows, maxDrawdown: maxDrawdownValue, available: rows.length };
    }
    function renderDrawdownChart(drawdownRows) {
        chart("#drawdownChart").setOption({ ...baseOption(), grid: { left: 54, right: 18, top: 12, bottom: 34 }, xAxis: { type: "category", data: drawdownRows.map(row => row.date), axisLabel: { hideOverlap: true } }, yAxis: { type: "value", axisLabel: { formatter: v => (v != null ? (v * 100).toFixed(1) + '%' : '') } }, series: [{ type: "line", showSymbol: false, areaStyle: { opacity: 0.1 }, data: drawdownRows.map(row => row.drawdown), itemStyle: { color: "#e54d5e" } }] });
    }
    function updateDrawdownRange() {
        const days = selectedDrawdownWindow();
        const result = computeDrawdownRows(latestNavRows, days);
        maxDrawdown.textContent = fmtPct(result.maxDrawdown);
        snapshotDrawdownSub.textContent = drawdownWindowLabel(days, result.available);
        setTone(maxDrawdown, result.maxDrawdown);
        renderDrawdownChart(result.rows);
    }
    function median(values) {
        const nums = values.map(Number).filter(Number.isFinite).sort((a, b) => a - b);
        if (!nums.length) return null;
        const mid = Math.floor(nums.length / 2);
        return nums.length % 2 ? nums[mid] : (nums[mid - 1] + nums[mid]) / 2;
    }
    function renderValuationWaterline(rows) {
        if (!valuationWaterlineOverall || !valuationWaterlineList) return;
        const valid = (rows || []).filter(row => Number.isFinite(Number(row.pe)) && Number(row.pe) > 0);
        if (!valid.length) {
            valuationWaterlineOverall.textContent = "—"; valuationWaterlineOverall.className = "";
            valuationWaterlineNote.textContent = "暂无可用 P/E 数据。先刷新估值数据源。";
            valuationWaterlineList.innerHTML = `<div class="valuation-waterline-row"><b>等待</b><div class="valuation-waterline-track"></div><span class="valuation-waterline-value">—</span></div>`;
            return;
        }
        const allMedian = median(valid.map(row => row.pe)) || 1;
        const bySector = new Map();
        valid.forEach(row => { const key = row.sector || "Other"; if (!bySector.has(key)) bySector.set(key, []); bySector.get(key).push(row.pe); });
        const enriched = valid.map(row => {
            const sectorRows = bySector.get(row.sector || "Other") || [];
            const benchmark = sectorRows.length >= 3 ? median(sectorRows) : allMedian;
            return { ...row, benchmark, premium: benchmark ? row.pe / benchmark - 1 : 0 };
        });
        const weightedTotal = enriched.reduce((sum, row) => sum + Number(row.weight || 0), 0) || 1;
        const weightedPremium = enriched.reduce((sum, row) => sum + Number(row.premium || 0) * Number(row.weight || 0), 0) / weightedTotal;
        const overallClass = weightedPremium >= 0 ? "expensive" : "cheap";
        valuationWaterlineOverall.className = overallClass;
        valuationWaterlineOverall.textContent = `${weightedPremium >= 0 ? "+" : ""}${(weightedPremium * 100).toFixed(1)}%`;
        valuationWaterlineNote.textContent = `基于 ${enriched.length} 个有 P/E 的持仓；同板块样本不足时使用组合中位 P/E ${fmtNum(allMedian)}。`;
        valuationWaterlineList.innerHTML = enriched.sort((a, b) => Number(b.weight || 0) - Number(a.weight || 0)).slice(0, 6).map(row => {
            const premium = Math.max(-0.6, Math.min(0.6, Number(row.premium || 0)));
            const width = Math.max(4, Math.min(50, Math.abs(premium) / 0.6 * 50));
            const left = premium >= 0 ? 50 : 50 - width; const tone = premium >= 0 ? "expensive" : "cheap";
            return `<div class="valuation-waterline-row" title="${row.ticker} P/E ${fmtNum(row.pe)}，基准 ${fmtNum(row.benchmark)}"><b>${row.ticker}</b><div class="valuation-waterline-track"><i class="valuation-waterline-fill ${tone}" style="left:${left.toFixed(1)}%;width:${width.toFixed(1)}%;"></i></div><span class="valuation-waterline-value ${tone}">${premium >= 0 ? "+" : ""}${(premium * 100).toFixed(1)}%</span></div>`;
        }).join("");
    }
    function heatColor(change) {
        const value = Number(change || 0);
        const strength = clamp(Math.abs(value) / 3, 0.10, 0.72);
        const base = value >= 0 ? "var(--positive)" : "var(--negative)";
        return `color-mix(in oklch, ${base} ${Math.round(strength * 56)}%, var(--panel))`;
    }
    function tileSpan(weight) {
        const pct = Number(weight || 0) * 100;
        if (pct >= 18) return [8, 5]; if (pct >= 10) return [5, 4]; if (pct >= 6) return [4, 3];
        if (pct >= 3) return [3, 2]; if (pct >= 1.5) return [2, 2]; if (pct >= 0.7) return [2, 2]; return [1, 1];
    }
    function sectorSpan(weight) {
        const pct = Number(weight || 0) * 100;
        if (pct >= 35) return [5, 6]; if (pct >= 25) return [4, 5]; if (pct >= 12) return [4, 4];
        if (pct >= 6) return [3, 3]; if (pct >= 2) return [2, 2]; return [1, 2];
    }
    function renderAssetHeatmap(rows) {
        const container = document.querySelector("#holdingHeatmapChart");
        if (!container) return;
        container.classList.add("asset-heatmap");
        const grouped = new Map();
        (rows || []).forEach(row => { const sector = row.sector || "Other / Unclassified"; if (!grouped.has(sector)) grouped.set(sector, []); grouped.get(sector).push(row); });
        const sectors = Array.from(grouped.entries()).map(([sector, holdings]) => {
            const weight = holdings.reduce((sum, row) => sum + Number(row.weight || 0), 0);
            const change = holdings.reduce((sum, row) => sum + Number(row.today_change_percent || 0) * Number(row.weight || 0), 0) / (weight || 1);
            holdings.sort((a, b) => Number(b.weight || 0) - Number(a.weight || 0));
            return { sector, holdings, weight, change };
        }).sort((a, b) => b.weight - a.weight);
        container.innerHTML = sectors.map(group => {
            const [sectorCol, sectorRow] = sectorSpan(group.weight);
            const inner = group.holdings.map(row => {
                const localWeight = Number(row.weight || 0) / (group.weight || 1);
                const [col, rowSpan] = tileSpan(localWeight);
                const change = Number(row.today_change_percent || 0);
                const small = col <= 1 || rowSpan <= 1;
                const ticker = row.ticker || ""; const displayName = row.display_name || row.name || ticker;
                return `<div class="asset-tile ${small ? "small" : ""}" title="${ticker} | ${displayName} | ${fmtPct(row.weight)} weight | ${change.toFixed(2)}% today" style="grid-column: span ${col}; grid-row: span ${rowSpan}; background:${heatColor(change)};"><div class="asset-logo">${ticker.slice(0, 2)}</div><div class="asset-ticker">${ticker}</div><div class="asset-name">${displayName}</div><div class="asset-change ${change >= 0 ? "delta-up" : "delta-down"}">${change >= 0 ? "+" : ""}${change.toFixed(2)}%</div><div class="asset-weight">${fmtPct(row.weight)}</div></div>`;
            }).join("");
            return `<section class="sector-tile" style="grid-column: span ${sectorCol}; grid-row: span ${sectorRow};"><div class="sector-tile-head"><span>${group.sector}</span><span class="${group.change >= 0 ? "delta-up" : "delta-down"}">${group.change >= 0 ? "+" : ""}${group.change.toFixed(2)}%</span></div><div class="sector-inner-grid">${inner}</div></section>`;
        }).join("");
    }
    function setReturnBasis(mode) { currentReturnBasis = mode || "twr"; syncReturnBasisButtons(); if (latestCommandCenter) renderCumulativeReturnChart(latestCommandCenter); }
    function syncReturnBasisButtons() { returnBasisButtons.forEach(button => { button.classList.toggle("active", button.dataset.returnBasis === currentReturnBasis); }); }
    function renderCumulativeReturnChart(data) {
        const isLight = document.documentElement.classList.contains("light-theme");
        const modes = data.cumulative_return_modes || { twr: data.cumulative_vs_benchmark };
        if (!modes[currentReturnBasis]) currentReturnBasis = modes.default || "twr";
        syncReturnBasisButtons();
        const twr = modes.twr || data.cumulative_vs_benchmark || {};
        const selected = currentReturnBasis === "cash_flow_mirror" ? modes.cash_flow_mirror : twr;
        const note = selected?.note || (currentReturnBasis === "cash_flow_mirror" ? "复制你的真实入金出金节奏，用于比较真实账户表现。" : "剔除现金流影响，用于衡量策略本身表现。");
        if (returnBasisNote) returnBasisNote.textContent = note;
        if (currentReturnBasis === "cash_flow_mirror" && (!selected?.available || !(selected.rows || []).length)) {
            if (cumulativeRange) cumulativeRange.textContent = "现金流镜像 · 等待日期流水";
            chart("#cumulativeChart").setOption({
                ...baseOption(),
                title: {
                    text: "需要入金 / 出金日期",
                    subtext: selected?.message || "现金流镜像需要逐日现金流流水，当前只能看到汇总金额。",
                    left: "center",
                    top: "middle",
                    textStyle: { color: isLight ? "#1f2937" : "#e8edf3", fontSize: 15, fontWeight: 760 },
                    subtextStyle: { color: isLight ? "#64748b" : "#8d97a4", fontSize: 12, lineHeight: 18 },
                    itemGap: 8,
                },
                legend: { show: false },
                tooltip: { show: false },
                xAxis: { show: false, type: "category", data: [] },
                yAxis: { show: false, type: "value" },
                series: [],
            }, true);
            return;
        }
        const cumulative = selected?.rows || [];
        if (cumulativeRange) cumulativeRange.textContent = `${selected?.date_range?.start || "—"} 起点重置`;
        if (!cumulative.length) return;
        const isCashFlow = currentReturnBasis === "cash_flow_mirror";
        const portfolioKey = isCashFlow ? "adjusted_portfolio_value" : "portfolio";
        const benchmarkKey = isCashFlow ? "adjusted_benchmark_value" : "benchmark";

        const seriesData = [{
            name: "Portfolio",
            type: "line",
            showSymbol: false,
            data: cumulative.map(row => row[portfolioKey] ?? row.portfolio ?? null),
            lineStyle: { width: 2.2 },
            itemStyle: { color: "#27a648" }
        }];
        if (cumulative[0] && (cumulative[0][benchmarkKey] !== undefined || cumulative[0].benchmark !== undefined)) {
            seriesData.push({
                name: selected?.benchmark || "SPY",
                type: "line",
                showSymbol: false,
                data: cumulative.map(row => row[benchmarkKey] ?? row.benchmark ?? null),
                lineStyle: { width: 1.5, opacity: 0.75 },
                itemStyle: { color: "#3b82f6" }
            });
        }
        if (cumulative[0] && cumulative[0].excess !== undefined) {
            seriesData.push({
                name: "Relative Excess",
                type: "line",
                showSymbol: false,
                data: cumulative.map(row => row.excess !== null ? row.excess + 1 : null),
                lineStyle: { width: 1.5, opacity: 0.8 },
                itemStyle: { color: "#f59e0b" }
            });
        }
        chart("#cumulativeChart").setOption({
            ...baseOption(),
            title: { show: false },
            color: ["#27a648", "#3b82f6", "#f59e0b"],
            legend: { bottom: 0, textStyle: { color: isLight ? "#374151" : "#9ca3af" } },
            grid: { left: 54, right: 18, top: 12, bottom: 42 },
            xAxis: { type: "category", data: cumulative.map(row => row.date), axisLabel: { hideOverlap: true } },
            yAxis: { type: "value", axisLabel: { formatter: v => isCashFlow ? (v >= 1000 ? '$'+(v/1000).toFixed(1)+'k' : '$'+Math.round(v)) : v.toFixed(2) + 'x' } },
            series: seriesData
        }, true);
    }
    function renderCommandCenter(data) {
        if (!latestCommandCenter) currentReturnBasis = data.cumulative_return_modes?.default || "twr";
        latestCommandCenter = data;
        const isLight = document.documentElement.classList.contains("light-theme");
        const quality = data.data_quality || {};
        qualityBanner.innerHTML = `<b>数据口径</b><span>持仓、现价、成本、浮盈亏是账户数据；收益热图、累计收益、相关性、回撤和 Waterfall 是当前仓位模型，非真实账户收益。样本 ${quality.history_start || "—"} 到 ${quality.history_end || "—"}，共 ${quality.history_days || 0} 个交易日。</span>`;
        if (monthlyRange) monthlyRange.textContent = `${data.monthly_returns?.date_range?.start || "—"} 到 ${data.monthly_returns?.date_range?.end || "—"}`;

        // 1. Sector Concentration
        const sectorRows = data.sector_concentration?.rows || [];
        chart("#sectorChart").setOption({
            ...baseOption(),
            grid: { left: 132, right: 18, top: 12, bottom: 28 },
            xAxis: { type: "value", axisLabel: { formatter: value => `${Math.round(value * 100)}%` } },
            yAxis: { type: "category", inverse: true, data: sectorRows.map(row => row.sector) },
            series: [{ type: "bar", data: sectorRows.map(row => row.weight), itemStyle: { color: "#27a648" } }],
            tooltip: { trigger: "axis", valueFormatter: value => fmtPct(value) }
        });

        // 2. P&L Contribution
        const pnlRows = (data.pnl_contribution?.rows || []).slice(0, 14).reverse();
        chart("#pnlChart").setOption({
            ...baseOption(),
            grid: { left: 72, right: 28, top: 12, bottom: 28 },
            xAxis: { type: "value", axisLabel: { formatter: value => usd(value) } },
            yAxis: { type: "category", data: pnlRows.map(row => row.ticker) },
            series: [{ type: "bar", data: pnlRows.map(row => row.unrealized_usd), itemStyle: { color: params => params.value >= 0 ? "#27a648" : "#e54d5e" } }],
            tooltip: { trigger: "axis", valueFormatter: value => usd(value) }
        });

        // 3. Monthly Return Heatmap
        const monthly = (data.monthly_returns?.rows || []).filter(row => row && typeof row.month === "string");
        const years = [...new Set(monthly.map(row => row.month.slice(0, 4)))];
        const monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        chart("#monthlyHeatmapChart").setOption({
            ...baseOption(),
            grid: { left: 48, right: 16, top: 18, bottom: 42 },
            visualMap: { min: -0.08, max: 0.08, orient: "horizontal", left: "center", bottom: 2, inRange: { color: ["#e54d5e", isLight ? "#f3f4f6" : "#1f2937", "#27a648"] } },
            xAxis: { type: "category", data: monthNames },
            yAxis: { type: "category", data: years },
            series: [{ type: "heatmap", data: monthly.map(row => [Number(row.month.slice(5, 7)) - 1, years.indexOf(row.month.slice(0, 4)), row.return]), label: { show: true, formatter: params => (params && params.value) ? fmtPct(params.value[2]) : "" } }],
            tooltip: { formatter: params => {
                if (!params || !params.value) return "";
                return `${years[params.value[1]] || ""} ${monthNames[params.value[0]] || ""}<br/>${fmtPct(params.value[2])}`;
            } }
        });

        // 4. Cumulative Return
        renderCumulativeReturnChart(data);

        // 5. Return Distribution
        const dist = data.return_distribution?.bins || [];
        const distStats = data.return_distribution?.stats || {};
        chart("#distributionChart").setOption({
            ...baseOption(),
            grid: { left: 48, right: 18, top: 12, bottom: 34 },
            xAxis: { type: "category", data: dist.map(row => `${(row.mid * 100).toFixed(1)}%`), axisLabel: { hideOverlap: true, rotate: 45, fontSize: 10 } },
            yAxis: { type: "value", name: "天数", nameTextStyle: { fontSize: 11 } },
            series: [{ type: "bar", data: dist.map(row => ({ value: row.count, itemStyle: { color: row.mid >= 0 ? "#27a648" : "#e54d5e", opacity: 0.78 } })) }],
            tooltip: { trigger: "axis", formatter: params => { const v = params[0]; return `${v.name}<br/>${v.value} 天`; } }
        });
        const distNote = document.querySelector("#distributionNote");
        if (distNote) distNote.textContent = `${distStats.sample_days || 0} 个交易日 · ${distStats.negative_days || 0} 天收跌 (${(distStats.negative_days / Math.max(1, distStats.sample_days) * 100).toFixed(0)}%) · 日均 ${fmtPct(distStats.mean)}`;

        // 6. Drawdown
        const drawdown = data.drawdown?.rows || [];
        renderDrawdownChart(drawdown);

        // 7. Correlation matrix
        const corr = data.correlation_matrix || {};
        chart("#correlationChart").setOption({
            ...baseOption(),
            grid: { left: 94, right: 24, top: 48, bottom: 72 },
            visualMap: { min: -1, max: 1, orient: "horizontal", left: "center", bottom: 8, inRange: { color: ["#3b82f6", isLight ? "#f3f4f6" : "#1f2937", "#dc2626"] } },
            xAxis: { type: "category", data: corr.symbols || [], axisLabel: { rotate: 45 } },
            yAxis: { type: "category", data: corr.symbols || [] },
            series: [{ type: "heatmap", data: (corr.matrix || []).flatMap((row, y) => row.map((value, x) => [x, y, value])) }],
            tooltip: { formatter: params => {
                if (!params || !params.value) return "";
                return `${corr.symbols?.[params.value[0]] || ""} / ${corr.symbols?.[params.value[1]] || ""}<br/>Corr ${fmtNum(params.value[2])}`;
            } }
        });

        // 8. Asset Heatmap
        renderAssetHeatmap(data.holdings_heatmap?.rows || []);

        // 9. Waterfall Chart
        const waterfall = (data.waterfall?.rows || []).filter(row => row && Number.isFinite(Number(row.contribution)));
        let running = 0; const helper = []; const values = [];
        waterfall.forEach(row => { helper.push(running); values.push(row.contribution); running += row.contribution; });
        chart("#waterfallChart").setOption({
            ...baseOption(),
            grid: { left: 56, right: 18, top: 12, bottom: 52 },
            xAxis: { type: "category", data: waterfall.map(row => row.symbol), axisLabel: { rotate: 35 } },
            yAxis: { type: "value", axisLabel: { formatter: value => fmtPct(value) } },
            series: [
                { type: "bar", stack: "total", itemStyle: { color: "transparent" }, emphasis: { disabled: true }, data: helper },
                { type: "bar", stack: "total", data: values, itemStyle: { color: params => params.value >= 0 ? "#27a648" : "#e54d5e" } }
            ]
        });

        // 10. Price Position Chart & Rows (Safe guard)
        const positions = data.fifty_two_week?.rows || [];
        const topPositions = positions.slice(0, 12);
        if (document.querySelector("#pricePositionChart")) {
            chart("#pricePositionChart").setOption({
                ...baseOption(),
                grid: { left: 62, right: 34, top: 18, bottom: 38 },
                xAxis: { type: "value", min: 0, max: 1, axisLabel: { formatter: value => `${Math.round(value * 100)}%` } },
                yAxis: { type: "category", inverse: true, data: topPositions.map(row => row.ticker) },
                tooltip: {
                    trigger: "axis",
                    formatter: params => {
                        if (!params || !params[0] || !topPositions) return "";
                        const row = topPositions[params[0].dataIndex];
                        if (!row) return "";
                        return `${row.ticker}<br/>52周低点 ${fmtNum(row.low)}<br/>现价 ${fmtNum(row.current)}<br/>52周高点 ${fmtNum(row.high)}<br/>位置 ${fmtPct(row.position)}<br/>离高点 ${fmtPct(row.distance_from_high)}`;
                    }
                },
                series: [
                    { name: "区间", type: "bar", data: topPositions.map(() => 1), barWidth: 8, itemStyle: { color: isLight ? "#e5e7eb" : "#374151", borderRadius: 999 }, silent: true },
                    { name: "现价位置", type: "scatter", symbolSize: 12, data: topPositions.map((row, index) => [row.position, row.ticker]), itemStyle: { color: params => params.value[0] >= 0.8 ? "#e54d5e" : params.value[0] <= 0.25 ? "#27a648" : "#3b82f6" } }
                ]
            });
        }
        const pricePositionRows = document.querySelector("#pricePositionRows");
        if (pricePositionRows) {
            pricePositionRows.innerHTML = topPositions.slice(0, 8).map(row => {
                const pos = Math.max(0, Math.min(1, Number(row.position || 0)));
                return `
                    <div class="week-position-row" title="低点 ${fmtNum(row.low)}，现价 ${fmtNum(row.current)}，高点 ${fmtNum(row.high)}">
                        <b>${row.ticker}</b>
                        <div class="week-position-range"><i class="week-position-marker" style="left:${(pos * 100).toFixed(1)}%"></i></div>
                        <span class="week-position-pct">${Math.round(pos * 100)}%</span>
                    </div>
                `;
            }).join("");
        }

        // 11. Fundamentals Chart (Safe guard)
        if (document.querySelector("#fundamentalsChart")) {
            chart("#fundamentalsChart").setOption({
                title: { text: "P/E 和成长率需要 fundamentals API", left: "center", top: "middle", textStyle: { fontSize: 13, color: isLight ? "#6b7280" : "#9ca3af" } },
                xAxis: { show: false },
                yAxis: { show: false },
                series: []
            });
        }

        // 12. Holding Rows
        const weekPositionByTicker = Object.fromEntries((data.fifty_two_week?.rows || []).map(row => [row.ticker, row]));
        const holdingRows = document.querySelector("#holdingRows");
        if (holdingRows) {
            holdingRows.innerHTML = (data.holdings_detail?.rows || []).slice(0, 40).map(row => {
                const yahoo = row.yahoo_symbol || row.ticker;
                const yahooUrl = `https://finance.yahoo.com/quote/${encodeURIComponent(yahoo)}`;
                const nameHtml = `<a href="${yahooUrl}" target="_blank" rel="noopener" style="color:var(--accent);text-decoration:none;" title="在 Yahoo Finance 查看 ${row.display_name || row.name}">${row.display_name || row.name}</a>`;
                return `<tr><td><a href="${yahooUrl}" target="_blank" rel="noopener" style="color:var(--text);text-decoration:none;font-weight:600;" title="Yahoo: ${yahoo}">${row.ticker}</a></td><td>${nameHtml}</td><td>${usd(row.cost_usd)}</td><td>${row.quote_price === null || row.quote_price === undefined ? "—" : Number(row.quote_price).toFixed(2)} ${row.quote_currency || ""}</td><td class="${(row.today_change_percent || 0) >= 0 ? "delta-up" : "delta-down"}">${row.today_change_percent === null || row.today_change_percent === undefined ? "—" : `${row.today_change_percent.toFixed(2)}%`}</td><td class="${(row.unrealized_percent || 0) >= 0 ? "delta-up" : "delta-down"}">${row.unrealized_percent === null || row.unrealized_percent === undefined ? "—" : `${row.unrealized_percent.toFixed(1)}%`}</td><td>${renderWeekPositionCell(weekPositionByTicker[row.ticker])}</td><td><div class="position-bar"><i style="width:${Math.max(2, row.weight * 100).toFixed(1)}%"></i></div>${fmtPct(row.weight)}</td></tr>`;
              }).join("");
        }
    }
    async function getJson(url, options) { const res = await fetch(url, options); if (!res.ok) throw new Error(`HTTP ${res.status}`); return res.json(); }
    function baseOption() {
        const L = document.documentElement.classList.contains("light-theme");
        const c = {
            bg: "transparent",
            tooltipBg: L ? "rgba(255,255,255,.96)" : "rgba(10,14,18,.96)",
            tooltipBorder: L ? "rgba(0,0,0,0.08)" : "rgba(255,255,255,0.08)",
            tooltipText: L ? "#111113" : "#ededef",
            axis: L ? "#6b7280" : "#707580",
            axisLine: L ? "#d1d5db" : "rgba(255,255,255,0.06)",
            splitLine: L ? "#e5e7eb" : "rgba(255,255,255,0.05)",
            text: L ? "#374151" : "#9ca3af",
        };
        return {
            backgroundColor: c.bg,
            tooltip: { trigger: "axis", backgroundColor: c.tooltipBg, borderColor: c.tooltipBorder, textStyle: { color: c.tooltipText } },
            grid: { left: 54, right: 18, top: 30, bottom: 42 },
            xAxis: { axisLine: { lineStyle: { color: c.axisLine } }, axisLabel: { color: c.axis }, splitLine: { show: false } },
            yAxis: { splitLine: { lineStyle: { color: c.splitLine } }, axisLabel: { color: c.axis } },
        };
    }
    async function loadLab() {
        diag("loadLab-start");
        const isLight = document.documentElement.classList.contains("light-theme");
        statusEl.textContent = "正在读取历史价格和分析结果...";
        await ensureEcharts();
        diag("echarts-loaded");
        diag("fetching-data");
        try {
        const [history, commandCenter, summary, lookthrough] = await Promise.all([
            getJson("/api/lab/history"), getJson("/api/command-center"), getJson("/api/portfolio/summary"), getJson("/api/etf-lookthrough?basis=market"),
        ]);
        const stats = history.stats || {}; latestNavRows = history.nav || [];
        const holdingsRows = commandCenter.holdings_detail?.rows || [];
        const quality = commandCenter.data_quality || {}; const meta = quality.sources || {};
        healthTrading212.textContent = `${meta.trading212?.positions || summary.open_positions || holdingsRows.length || 0} 持仓 · ${fmtUnixTime(meta.trading212?.as_of_unix)}`;
        healthMarket.textContent = `${meta.market?.rows || 0} 行情 · ${fmtUnixTime(meta.market?.as_of_unix)}`;
        healthFundamentals.textContent = `${meta.fundamentals?.provider || "FMP"} ${meta.fundamentals?.coverage || "0/0"} · ${fmtUnixTime(meta.fundamentals?.as_of_unix)}`;
        healthFundamentalsDot.classList.toggle("warn", Number(meta.fundamentals?.rows || 0) < Math.max(1, Number(meta.fundamentals?.total || 0)));
        healthHistory.textContent = `${history.nav?.length || 0} 交易日 · ${fmtUnixTime(history.history_as_of_unix)}`;
        const todayPnl = holdingsRows.reduce((sum, row) => { const change = Number(row.today_change_percent); const value = Number(row.market_value_usd || 0); if (!Number.isFinite(change) || !Number.isFinite(value)) return sum; const rate = change / 100; return sum + (value - value / (1 + rate)); }, 0);
        const previousMarketValue = Number(summary.market_value_usd || 0) - todayPnl;
        const todayReturn = previousMarketValue ? todayPnl / previousMarketValue : 0;
        const upCount = holdingsRows.filter(row => Number(row.today_change_percent || 0) > 0).length;
        const downCount = holdingsRows.filter(row => Number(row.today_change_percent || 0) < 0).length;
        const sharpeDelta = null;
        snapshotMarketValue.textContent = usd(summary.market_value_usd);
        snapshotMarketSub.textContent = `${signedUsd(todayPnl)} 今日`;
        snapshotTotalPnl.textContent = signedUsd(summary.unrealized_usd);
        annualReturn.textContent = `▲ ${fmtPct((summary.unrealized_usd || 0) / (summary.total_cost_usd_standard || 1))} 总收益率`;
        snapshotTodayPnl.textContent = signedUsd(todayPnl);
        annualVol.textContent = `▲ ${fmtPct(todayReturn)}`;
        snapshotHoldingsCount.textContent = summary.open_positions || holdingsRows.length || "—";
        snapshotBreadth.textContent = `↔ 上涨 ${upCount} / 下跌 ${downCount}`;
        sharpe.textContent = fmtNum(stats.sharpe);
        snapshotSharpeSub.textContent = sharpeDelta === null ? "基准数据不足" : `${sharpeDelta >= 0 ? "▲" : "▼"} vs SPY ${fmtNum(Math.abs(sharpeDelta))}`;
        setTone(snapshotMarketSub, todayPnl); setTone(snapshotTotalPnl, summary.unrealized_usd); setTone(annualReturn, summary.unrealized_usd);
        setTone(snapshotTodayPnl, todayPnl); setTone(annualVol, todayReturn); setTone(snapshotSharpeSub, sharpeDelta || 0);
        renderSparkline(snapshotMarketSpark, (history.nav || []).slice(-60).map(row => row.nav), "muted");
        renderSparkline(snapshotPnlSpark, (history.nav || []).slice(-60).map(row => row.nav - 1), Number(summary.unrealized_usd || 0) >= 0 ? "" : "negative");
        renderSparkline(snapshotTodaySpark, (history.nav || []).slice(-40).map(row => row.return), todayPnl >= 0 ? "" : "negative");
        const dailyPnlRows = (history.nav || []).slice(-30).map(row => ({ date: row.date, value: Number(summary.market_value_usd || 0) * Number(row.return || 0) }));
        chart("#dailyPnlChart").setOption({ ...baseOption(), xAxis: { type: "category", data: dailyPnlRows.map(r => r.date), axisLabel: { formatter: v => { const p=String(v).split("-"); return p[1]+'/'+p[2]; } } }, yAxis: { type: "value", axisLabel: { formatter: v => { const a=Math.abs(v||0); return (v<0?"-$":"$")+(a>=1e3?(a/1e3).toFixed(1)+"k":a.toFixed(0)); } } }, series: [{ type: "bar", data: dailyPnlRows.map(r => ({ value: r.value, itemStyle: { color: r.value >= 0 ? "#27a648" : "#e54d5e" } })) }] }, true);

        const monthlyModelRows = commandCenter.monthly_returns?.rows || [];
        const monthLabels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        const yearLabels = [...new Set(monthlyModelRows.map(row => String(row.month || "").slice(0, 4)).filter(Boolean))].sort();
        const monthlyByYear = Object.fromEntries(yearLabels.map(year => [year, Array(12).fill(null)]));
        monthlyModelRows.forEach(row => {
            const year = String(row.month || "").slice(0, 4);
            const monthIndex = Number(String(row.month || "").slice(5, 7)) - 1;
            if (monthlyByYear[year] && monthIndex >= 0 && monthIndex < 12) monthlyByYear[year][monthIndex] = Number(row.return || 0);
        });

        chart("#monthlyReturnDarkChart").setOption({
            ...baseOption(),
            legend: { show: true, textStyle: { color: isLight ? "#374151" : "#9ca3af" } },
            xAxis: { type: "category", data: monthLabels },
            yAxis: { type: "value", axisLabel: { formatter: v => (v>=0?'+':'')+v.toFixed(1)+'%' } },
            series: yearLabels.map(year => ({
                name: year,
                type: "line",
                showSymbol: false,
                data: monthlyByYear[year] ? monthlyByYear[year].map(v => v != null ? v*100 : null) : []
            }))
        }, true);

        const sectorPalette = ["#8b5cf6", "#06b6d4", "#22c55e", "#f59e0b", "#ef4444", "#a855f7", "#14b8a6", "#f97316", "#3b82f6"];
        const sectorColor = new Map();
        function growthValue(row) { const eps = Number(row.eps_growth_yoy); const revenue = Number(row.revenue_growth_yoy); const raw = Number.isFinite(eps) && eps !== 0 ? eps : revenue; if (!Number.isFinite(raw)) return null; return Math.abs(raw) <= 2 ? raw * 100 : raw; }
        const valuationRows = (commandCenter.holdings_heatmap?.rows || []).map(row => { const pe = Number(row.forward_pe || row.trailing_pe); const growth = growthValue(row); return { ...row, pe, growth, growthSource: row.eps_growth_yoy ? "EPS 成长" : "营收成长" }; }).filter(row => Number.isFinite(row.pe) && row.pe > 0 && Number.isFinite(row.growth));
        valuationRows.forEach(row => { if (!sectorColor.has(row.sector)) sectorColor.set(row.sector, sectorPalette[sectorColor.size % sectorPalette.length]); });
        if (valuationRows.length) {
            renderValuationWaterline(valuationRows);
            chart("#valuationMatrixChart").setOption({ backgroundColor: "transparent", tooltip: { trigger: "item", backgroundColor: isLight ? "rgba(255,255,255,.96)" : "rgba(10,14,18,.96)", borderColor: isLight ? "rgba(0,0,0,0.1)" : "rgba(255,255,255,0.1)", textStyle: { color: isLight ? "#1a1a1a" : "#ededef" }, formatter: params => { const row = params.data.raw; return `${row.ticker}<br/>P/E ${fmtNum(row.pe)}<br/>${row.growthSource} ${fmtNum(row.growth)}%<br/>仓位 ${fmtPct(row.weight)}<br/>${row.display_name || row.name || ""}`; } }, grid: { left: 74, right: 28, top: 36, bottom: 58 }, xAxis: { type: "value", name: "P/E 倍数", nameLocation: "middle", nameGap: 36, nameTextStyle: { color: isLight ? "#6b7280" : "#9ca3af", fontSize: 14 }, splitLine: { lineStyle: { color: isLight ? "#e5e7eb" : "#1f2937" } }, axisLine: { lineStyle: { color: isLight ? "#d1d5db" : "#374151" } }, axisLabel: { color: isLight ? "#6b7280" : "#9ca3af", fontSize: 13 } }, yAxis: { type: "value", name: "成长率 %", nameLocation: "middle", nameGap: 50, nameTextStyle: { color: isLight ? "#374151" : "#9ca3af", fontSize: 14 }, splitLine: { lineStyle: { color: isLight ? "#e5e7eb" : "#1f2937" } }, axisLine: { lineStyle: { color: isLight ? "#d1d5db" : "#374151" } }, axisLabel: { color: isLight ? "#6b7280" : "#9ca3af", fontSize: 13 } }, series: [{ type: "scatter", data: valuationRows.map(row => ({ value: [row.pe, row.growth, row.weight], raw: row, itemStyle: { color: sectorColor.get(row.sector), borderColor: sectorColor.get(row.sector), borderWidth: 2, opacity: 0.72 } })), symbolSize: value => Math.max(12, Math.min(46, Math.sqrt(Number(value[2] || 0)) * 130)), label: { show: true, formatter: params => params.data.raw.ticker, position: "top", color: isLight ? "#4b5563" : "#aab4c1", fontSize: 11 } }] });
        } else {
            renderValuationWaterline([]);
            chart("#valuationMatrixChart").setOption({ backgroundColor: "transparent", title: { text: "估值数据还没更新", subtext: "刷新 fundamentals 后会显示 P/E、成长率和仓位气泡", left: "center", top: "middle", textStyle: { color: isLight ? "#1a1a1a" : "#f7f8f8", fontSize: 20, fontWeight: 700 }, subtextStyle: { color: isLight ? "#6b7280" : "#9ca3af", fontSize: 13, lineHeight: 20 } }, xAxis: { show: false }, yAxis: { show: false }, series: [] });
        }
        renderCommandCenter(commandCenter);
        updateDrawdownRange();
        // Populate Asset Merge (ETF Lookthrough Exposure) Table
        if (groupRows && lookthrough && lookthrough.rows) {
            const totalVal = Number(summary.market_value_usd || 1);
            groupRows.innerHTML = lookthrough.rows.slice(0, 10).map(row => {
                let memberText = "直接持仓";
                if (row.direct_usd > 0 && row.from_etf_usd > 0) {
                    memberText = "直接持仓 + ETF";
                } else if (row.direct_usd === 0 && row.from_etf_usd > 0) {
                    memberText = "ETF 穿透";
                }
                const w = row.total_usd / totalVal;
                return `
                  <tr>
                    <td><b>${row.ticker}</b> <span style="font-size:10px;color:var(--muted);">${row.name || ""}</span></td>
                    <td>${memberText}</td>
                    <td>${fmtPct(w)}</td>
                  </tr>
                `;
            }).join("");
        }

        diag("render-done");
        statusEl.textContent = `完成：${history.nav?.length || 0} 个交易日，${summary.open_positions || holdingsRows.length || 0} 个持仓`;
    } catch(e) {
        diag("ERROR:"+e.message);
        statusEl.innerHTML = `<span style="color:var(--negative)">渲染失败：${e.message}<br><small>${e.stack}</small></span>`;
        console.error(e);
        fetch("/api/log-error", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message: e.message, stack: e.stack })
        }).catch(() => {});
    }
    }
    refreshHistory.addEventListener("click", async () => { refreshHistory.disabled = true; statusEl.textContent = "正在刷新历史价格..."; try { await getJson("/api/lab/refresh-history?force=true", { method: "POST" }); await loadLab(); } catch (error) { statusEl.textContent = `刷新失败：${error.message}`; } finally { refreshHistory.disabled = false; } });
    drawdownRangeSelect?.addEventListener("change", updateDrawdownRange);
    returnBasisButtons.forEach(btn => btn.addEventListener("click", () => setReturnBasis(btn.dataset.returnBasis)));
    loadLab().catch(error => {
        statusEl.textContent = `加载失败：${error.message}`;
        console.error(error);
        fetch("/api/log-error", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message: error.message, stack: error.stack })
        }).catch(() => {});
    });


</script>"""
    return HTMLResponse(wrap_v4_layout("Portfolio Lab", content, "/lab"))
