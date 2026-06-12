"""Page route: home."""
import json
from fastapi import APIRouter
from fastapi.responses import HTMLResponse
from datetime import datetime, timezone
from app.components import wrap_v4_layout
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
def index():
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
    <p>管理您的个人投资组合数据源。您可以同步 Trading 212 账户，刷新最新的 Yahoo 行情价格，并验证 API key 状态。</p>
  </div>
  <div class="btn" style="pointer-events:none"><i class="fa-solid fa-calendar-day"></i> 数据时间：{as_of}</div>
</div>

<div class="dashboard-stack">
<div class="v4-card" style="margin-top:0px;">
  <div class="v4-card-header">
    <div>
      <h2 class="v4-card-title"><i class="fa-solid fa-heart-pulse text-accent" style="color:var(--accent)"></i> 数据新鲜度监控</h2>
      <div class="v4-card-subtitle">监控各数据源同步状态，确保模型计算的有效性。</div>
    </div>
  </div>
  <div class="metrics-grid">
    <div class="metric-card">
      <span class="metric-label">Trading 212 同步</span>
      <div class="metric-value">{trading_positions} <span style="font-size:14px;color:var(--muted)">个持仓</span></div>
      <span class="metric-subtext"><i class="fa-solid fa-clock"></i> {fmt_unix(trading_unix)}</span>
    </div>
    <div class="metric-card">
      <span class="metric-label">Yahoo 实时行情</span>
      <div class="metric-value">{market_rows} <span style="font-size:14px;color:var(--muted)">个行情</span></div>
      <span class="metric-subtext"><i class="fa-solid fa-clock"></i> {fmt_unix(market_unix)}</span>
    </div>
    <div class="metric-card">
      <span class="metric-label">FMP 估值覆盖</span>
      <div class="metric-value">{fundamentals_rows}/{positions} <span style="font-size:14px;color:var(--muted)">已匹配</span></div>
      <span class="metric-subtext"><i class="fa-solid fa-triangle-exclamation warn" style="color:var(--warn)"></i> 告警数: {fundamentals_warnings}</span>
    </div>
    <div class="metric-card">
      <span class="metric-label">账户现金估算</span>
      <div class="metric-value">${cash_total:,.0f}</div>
      <span class="metric-subtext"><i class="fa-solid fa-wallet"></i> 现金占比: {(cash_total/(market+cash_total)*100) if (market+cash_total) else 0:.1f}%</span>
    </div>
  </div>
</div>

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
</div>

<div class="grid-2" style="margin-top:0px;">
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-arrows-rotate text-accent"></i> 核心同步动作</h2>
        <div class="v4-card-subtitle">手动触发与外部接口同步，过程为后台异步执行。</div>
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
          <strong style="display:block;margin-bottom:4px;">刷新行情最新现价</strong>
          <span style="font-size:12px;color:var(--muted)">拉取 Yahoo 现价以更新当前总市值与未实现浮盈亏。</span>
        </div>
        <button class="btn primary" id="marketRefreshButton">刷新行情</button>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div style="flex:1;padding-right:16px;">
          <strong style="display:block;margin-bottom:4px;">重新加载估值数据</strong>
          <span style="font-size:12px;color:var(--muted)">重新拉取 FMP 估值指标，刷新 PE vs 成长矩阵及水位曲线。</span>
        </div>
        <button class="btn" id="fundamentalsRefreshButton">刷新估值</button>
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

<div class="v4-card" style="margin-top:0px;">
  <div class="v4-card-header" style="margin-bottom:12px;cursor:pointer;" onclick="document.getElementById('developerAccordion').classList.toggle('hide')">
    <div>
      <h2 class="v4-card-title"><i class="fa-solid fa-code"></i> 本地 REST API 数据接口 (折叠)</h2>
      <div class="v4-card-subtitle">提供 JSON 接口供外部脚本或报表工具进行数据对接</div>
    </div>
  </div>
  <div id="developerAccordion" class="hide" style="display:flex;flex-direction:column;gap:12px;">
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>接口名称</th>
            <th>请求路径</th>
            <th>核心字段说明</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>组合汇总数据</td>
            <td><a href="/api/portfolio/summary" class="font-mono" style="color:var(--accent);">/api/portfolio/summary</a></td>
            <td>成本、市值、未实现盈亏、按账户统计现金及货币分布</td>
          </tr>
          <tr>
            <td>当前持仓明细</td>
            <td><a href="/api/holdings" class="font-mono" style="color:var(--accent);">/api/holdings</a></td>
            <td>持股数、均价、买入成本（原币种）、本地现价和市值比重</td>
          </tr>
          <tr>
            <td>ETF 穿透 (Look-through)</td>
            <td><a href="/api/etf-lookthrough" class="font-mono" style="color:var(--accent);">/api/etf-lookthrough</a></td>
            <td>将 S&P 500 等 ETF 穿透到底层股票暴露，支持 cost / market 口径</td>
          </tr>
          <tr>
            <td>相关性矩阵</td>
            <td><a href="/api/chart/exposure" class="font-mono" style="color:var(--accent);">/api/chart/exposure</a></td>
            <td>返回供前端渲染集中度与归因子相关的格式化数据</td>
          </tr>
        </tbody>
      </table>
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

<style>
  #developerAccordion.hide {{
    display: none !important;
  }}
</style>

<script>
  const refreshButton = document.getElementById("refreshButton");
  const marketRefreshButton = document.getElementById("marketRefreshButton");
  const fundamentalsRefreshButton = document.getElementById("fundamentalsRefreshButton");
  const refreshStatus = document.getElementById("refreshStatus");
  
  // Smart refresh: first click uses cache, second click forces
  function fmtAge(sec) {{ return sec == null ? "" : sec < 60 ? `${{sec}}秒前` : sec < 3600 ? `${{Math.floor(sec/60)}}分钟前` : `${{Math.floor(sec/3600)}}小时前`; }}

  let _forceRefresh = false;
  async function smartRefresh(button, label, url) {{
    button.disabled = true;
    const doFetch = async () => {{
      const sep = url.includes('?') ? '&' : '?';
      const u = _forceRefresh ? `${{url}}${{sep}}force=true` : url;
      return await fetch(u, {{ method: "POST" }});
    }};
    refreshStatus.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> ${{label}}...`;
    try {{
      let resp = await doFetch();
      let data = await resp.json();
      if (data.refresh?.cached || data.market?.cached || data.fundamentals?.cached) {{
        const age = data.refresh?.age_seconds || data.market?.age_seconds || data.fundamentals?.age_seconds;
        refreshStatus.className = "status";
        refreshStatus.innerHTML = `<i class="fa-solid fa-clock"></i> ${{label}}已缓存(${{fmtAge(age)}})。<a href="#" onclick="event.preventDefault();_forceRefresh=true;smartRefresh(${{button.id}},'${{label}}','${{url}}');return false" style="color:var(--accent);cursor:pointer;margin-left:8px;">强制刷新</a>`;
        button.disabled = false;
        return;
      }}
      _forceRefresh = false;
      refreshStatus.className = "status positive";
      refreshStatus.innerHTML = `<i class="fa-solid fa-circle-check"></i> ${{label}}完成！`;
      setTimeout(() => location.reload(), 1200);
    }} catch (error) {{
      _forceRefresh = false;
      refreshStatus.className = "status negative";
      refreshStatus.innerHTML = `<i class="fa-solid fa-circle-xmark"></i> ${{label}}失败：${{error.message}}`;
      button.disabled = false;
    }}
  }}

  marketRefreshButton?.addEventListener("click", () => smartRefresh(marketRefreshButton, "行情刷新", "/api/refresh/market"));
  refreshButton?.addEventListener("click", () => smartRefresh(refreshButton, "T212同步", "/api/refresh/trading212"));
  fundamentalsRefreshButton?.addEventListener("click", () => smartRefresh(fundamentalsRefreshButton, "估值刷新", "/api/refresh/fundamentals"));

  // ── After-Hours Unusual Activity ──
  async function loadAfterHours() {{
    const btn = document.querySelector("#afterHoursBtn");
    const status = document.querySelector("#afterHoursStatus");
    const result = document.querySelector("#afterHoursResult");
    const body = document.querySelector("#afterHoursBody");
    const quiet = document.querySelector("#afterHoursQuiet");
    const meta = document.querySelector("#afterHoursMeta");
    btn.disabled = true;
    btn.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> 正在拉取 Massive 盘后数据...`;
    status.innerHTML = "";
    result.style.display = "none";
    try {{
      const resp = await fetch("/api/refresh/after-hours", {{ method: "POST" }});
      if (!resp.ok) throw new Error(`HTTP ${{resp.status}}`);
      const json = await resp.json();
      const data = json.data || json;
      const rows = data.rows || [];
      const warnings = data.warnings || [];

      if (rows.length === 0) {{
        quiet.style.display = "block";
        body.innerHTML = "";
      }} else {{
        quiet.style.display = "none";
        body.innerHTML = rows.map(r => {{
          const cls = r.change_pct >= 0 ? "positive" : "negative";
          const sign = r.change_pct >= 0 ? "+" : "";
          return `<tr>
            <td><b>${{r.ticker}}</b></td>
            <td>${{r.close?.toFixed(2) || "—"}}</td>
            <td>${{r.after_hours?.toFixed(2) || "—"}}</td>
            <td class="${{cls}}">${{sign}}${{r.change_pct?.toFixed(2)}}%</td>
            <td>${{r.volume?.toLocaleString() || "—"}}</td>
          </tr>`;
        }}).join("");
      }}

      meta.textContent = `共检查 ${{data.total_checked || rows.length}} 只美股 · ${{data.date || ""}} · ${{warnings.length ? warnings[0] : "Massive API"}}`;
      btn.innerHTML = `<i class="fa-solid fa-arrows-rotate"></i> 刷新盘后数据`;
      status.innerHTML = "";
      result.style.display = "block";
    }} catch(e) {{
      status.innerHTML = `<span style="color:var(--negative)">拉取失败：${{e.message}} <button class="btn" onclick="loadAfterHours()" style="font-size:11px;padding:2px 8px;">重试</button></span>`;
      btn.innerHTML = `<i class="fa-solid fa-arrows-rotate"></i> 刷新盘后数据`;
    }} finally {{
      btn.disabled = false;
    }}
  }}
</script>
""",
            "/"
        )
    )

