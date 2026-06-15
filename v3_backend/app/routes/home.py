"""Page route: home."""
import json
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from datetime import datetime, timezone
from app.components import wrap_v4_layout
from app.i18n import get_lang
from app.data_store import current_snapshot
from app.analytics import portfolio_summary
from app.alerts import check_alerts


router = APIRouter(tags=["pages"])


@router.get("/test-lw")
def test_lw():
    html = """<!doctype html>
<html><head><meta charset="utf-8"><title>LW Test</title>
<style>body{background:#0b0d0f;color:#ededef;font-family:sans-serif;padding:20px}</style>
</head><body>
<h2>LW Charts Test</h2>
<div id="chart" style="width:800px;height:400px;border:1px solid #333;"></div>
<div id="msg"></div>
<script src="/static/vendor/lightweight-charts.standalone.production.js"></script>
<script>
const el = document.getElementById('chart');
const msg = document.getElementById('msg');
try {
    if (typeof LightweightCharts === 'undefined') throw new Error('LightweightCharts not loaded');
    msg.textContent = 'LW Charts loaded v' + (LightweightCharts.version || '?');
    const chart = LightweightCharts.createChart(el, {
        width: el.clientWidth, height: 400,
        layout: { background: { color: '#0b0d0f' }, textColor: '#707580' },
        grid: { vertLines: { color: 'rgba(255,255,255,0.05)' }, horzLines: { color: 'rgba(255,255,255,0.05)' } },
    });
    const line = chart.addLineSeries({ color: '#5e6ad2', lineWidth: 2 });
    const data = [];
    for (let i = 0; i < 100; i++) {
        data.push({ time: new Date(2023, 0, i+1).toISOString().slice(0,10), value: 100 + Math.sin(i*0.1)*20 + i*0.5 });
    }
    line.setData(data);    msg.textContent += ' — Chart created with ' + data.length + ' points ✓';
} catch(e) {
    msg.innerHTML = '<b style="color:red">ERROR: ' + e.message + '</b><br><pre>' + (e.stack||'') + '</pre>';
}
</script>
</body></html>"""

    if False:  # noop, alerts handled in index()
        pass
    if False:
        for a in alerts:
            sev = a.get("severity", "info")
            alerts_html += f'<div class="alert-item {sev}">{a.get("message")}</div>'
    else:
        alerts_html = '<div style="color:var(--muted);padding:8px 0;">当前无提醒。</div>'

    return HTMLResponse(html)


@router.get("/")
def index(request: Request):
    snapshot = current_snapshot()
    alerts = check_alerts()

    alerts_html = ""
    if alerts:
        for a in alerts:
            sev = a.get("severity", "info")
            alerts_html += f'<div class="alert-item {sev}">' + a.get("message") + "</div>"
    else:
        alerts_html = '<div style="color:var(--muted);padding:8px 0;">当前无提醒。</div>'
    summary = portfolio_summary(snapshot)
    cost = float(summary.get("total_cost_usd_standard") or 0)
    market = float(summary.get("market_value_usd") or 0)
    pnl = float(summary.get("unrealized_usd") or 0)
    pnl_pct = (pnl / cost * 100) if cost else 0
    cash = summary.get("cash") or {}
    cash_total = float(cash.get("total") or 0)
    positions = int(summary.get("open_positions") or 0)
    as_of = summary.get("as_of") or "unknown"
    pnl_class = "positive" if pnl >= 0 else "negative"
    market_rows = len(snapshot["market"].get("rows", []))
    fundamentals_rows = len(snapshot["fundamentals"].get("rows", []))
    fundamentals_warnings = len(snapshot["fundamentals"].get("warnings", []))
    trading_positions = len(snapshot["trading212"].get("positions", []))
    market_unix = snapshot["market"].get("as_of_unix")
    fundamentals_unix = snapshot["fundamentals"].get("as_of_unix")
    trading_unix = snapshot["trading212"].get("as_of_unix")

    def fmt_unix(value):
        if not value:
            return "未刷新"
        return datetime.fromtimestamp(int(value), tz=timezone.utc).astimezone().strftime("%H:%M")


    if False:  # noop, alerts handled in index()
        pass
    if False:
        for a in alerts:
            sev = a.get("severity", "info")
            alerts_html += f'<div class="alert-item {sev}">{a.get("message")}</div>'
    else:
        alerts_html = '<div style="color:var(--muted);padding:8px 0;">当前无提醒。</div>'

    return HTMLResponse(
        wrap_v4_layout(
            "数据控制台",
            f"""<div class="v4-hero">
  <div class="v4-hero-text">
    <h1>数据与控制中心</h1>
    <p>组合总览与持仓同步。数据源刷新、API key、AI 提供方等配置请前往「系统设置」。</p>
  </div>
  <div class="btn" style="pointer-events:none"><i class="fa-solid fa-calendar-day"></i> 数据时间：{as_of}</div>
</div>

<div class="dashboard-stack">
<div class="metrics-grid" style="margin-top:0px;">
  <div class="metric-card">
    <span class="metric-label">当前持仓数</span>
    <div class="metric-value">{positions}</div>
  </div>
  <div class="metric-card">
    <span class="metric-label">投入成本价 (USD)</span>
    <div class="metric-value">${cost:,.0f}</div>
  </div>
  <div class="metric-card">
    <span class="metric-label">当前总市值 (USD)</span>
    <div class="metric-value">${market:,.0f}</div>
  </div>
  <div class="metric-card">
    <span class="metric-label">未实现浮盈亏</span>
    <div class="metric-value {pnl_class}">${pnl:,.0f} <span style="font-size:14px">({pnl_pct:,.1f}%)</span></div>
  </div>
  <div class="metric-card">
    <span class="metric-label">账户现金估算</span>
    <div class="metric-value">${cash_total:,.0f}</div>
    <span class="metric-subtext"><i class="fa-solid fa-wallet"></i> 现金占比: {(cash_total/(market+cash_total)*100) if (market+cash_total) else 0:.1f}%</span>
  </div>
</div>

<div class="grid-2" style="margin-top:0px;">
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-arrows-rotate text-accent"></i> 同步持仓</h2>
        <div class="v4-card-subtitle">从券商拉取最新持仓，并刷新 Yahoo 实时现价。估值、历史等刷新在「系统设置」。</div>
      </div>
    </div>
    <div style="display:flex;flex-direction:column;gap:16px;">
      <div style="display:flex;justify-content:space-between;align-items:center;padding-bottom:12px;border-bottom:1px solid var(--line);">
        <div style="flex:1;padding-right:16px;">
          <strong style="display:block;margin-bottom:4px;">同步 Trading 212 数据</strong>
          <span style="font-size:12px;color:var(--muted)">重新拉取持仓和平均买入成本。此操作会验证 API 凭证。</span>
        </div>
        <button class="btn primary" id="refreshButton">立即同步</button>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;padding-bottom:12px;border-bottom:1px solid var(--line);">
        <div style="flex:1;padding-right:16px;">
          <strong style="display:block;margin-bottom:4px;">Yahoo 实时现价刷新</strong>
          <span style="font-size:12px;color:var(--muted)">拉取最新 Yahoo 现价，用于更新总市值、今日涨跌和浮盈亏。</span>
        </div>
        <button class="btn" id="marketRefreshButton"><i class="fa-solid fa-arrows-rotate"></i> 刷新行情</button>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div style="flex:1;padding-right:16px;">
          <strong style="display:block;margin-bottom:4px;">手动导入数据 (CSV)</strong>
          <span style="font-size:12px;color:var(--muted)">没有 API key？上传任意券商的交易记录 CSV，自动计算持仓与平均成本。</span>
        </div>
        <a class="btn" href="/import"><i class="fa-solid fa-file-import"></i> 手动导入数据</a>
      </div>
    </div>
    <div id="refreshStatus" class="status" style="margin-top:16px;"></div>
  </div>
  
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-circle-info"></i> 产品与文档链接</h2>
        <div class="v4-card-subtitle">系统主要页面分析指引。</div>
      </div>
    </div>
    <div style="display:flex;flex-direction:column;gap:14px;">
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div>
          <strong style="display:block;font-size:13.5px;margin-bottom:2px;">Portfolio Lab (组合分析)</strong>
          <span style="font-size:12px;color:var(--muted)">查看量化指标，优化组合权重，分析因子暴露。</span>
        </div>
        <a class="btn" href="/lab">打开 Lab</a>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div>
          <strong style="display:block;font-size:13.5px;margin-bottom:2px;">持仓热力图 (全屏盯盘)</strong>
          <span style="font-size:12px;color:var(--muted)">以图形化色块呈现今日涨跌幅和持仓权重。</span>
        </div>
        <a class="btn" href="/heatmap">打开热力图</a>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div>
          <strong style="display:block;font-size:13.5px;margin-bottom:2px;">收益对比 (Benchmark)</strong>
          <span style="font-size:12px;color:var(--muted)">查看相对于标普500、纳指等历史业绩对比。</span>
        </div>
        <a class="btn" href="/returns">收益对比</a>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div>
          <strong style="display:block;font-size:13.5px;margin-bottom:2px;">审计对账报表 (Report)</strong>
          <span style="font-size:12px;color:var(--muted)">查看持仓的历史买入卖出对账记录，支持 CSV 导出。</span>
        </div>
        <a class="btn" href="/report">Audit Report</a>
      </div>
    </div>
  </div>
</div>

<!-- ── After-Hours Unusual Activity ── -->
<section class="panel" style="margin-top:16px;">
  <div class="chart-head" style="display:flex;justify-content:space-between;align-items:center;">
    <div>
      <h2><i class="fa-solid fa-moon"></i> 盘后异动 <span style="font-size:11px;color:var(--muted);font-weight:400;">Massive · After-Hours Movers</span></h2>
      <div style="font-size:11px;color:var(--muted);">盘后价 vs 收盘价涨跌超过 ±1% 的持仓</div>
    </div>
    <button id="afterHoursBtn" class="btn primary" onclick="loadAfterHours()" style="font-size:12px;"><i class="fa-solid fa-arrows-rotate"></i> 刷新盘后数据</button>
  </div>
  <div id="afterHoursStatus" style="padding:8px 0;font-size:12px;color:var(--muted);">点击刷新获取最新盘后数据</div>
  <div id="afterHoursResult" style="display:none;">
    <div class="table-wrap">
      <table>
        <thead><tr><th>代码</th><th>收盘价</th><th>盘后价</th><th>盘后涨跌</th><th>成交量</th></tr></thead>
        <tbody id="afterHoursBody"></tbody>
      </table>
    </div>
    <div id="afterHoursQuiet" style="display:none;padding:16px;text-align:center;color:var(--muted);font-size:14px;">
      <i class="fa-solid fa-circle-check" style="color:var(--positive)"></i> 盘后无异常波动，所有持仓盘后变化均小于 1%
    </div>
    <div id="afterHoursMeta" style="font-size:11px;color:var(--muted);margin-top:8px;"></div>
  </div>
</section>

</div>



<script src="/static/home.js"></script>
""",
            "/",
            get_lang(request),
            head_extra='<link rel="stylesheet" href="/static/home.css" />',
        )
    )
