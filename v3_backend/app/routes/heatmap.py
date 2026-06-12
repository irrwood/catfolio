"""Page route: heatmap."""
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from app.components import wrap_v4_layout, data_health_bar
from app.data_store import current_snapshot
from app.i18n import get_lang

router = APIRouter(tags=["pages"])


@router.get("/heatmap")
def heatmap_page(request: Request):
    return HTMLResponse(
        wrap_v4_layout(
            "持仓热力图",
            """<style>
  .segmented {
    display: inline-flex;
    align-items: center;
    border: 1px solid var(--line);
    border-radius: 99px;
    background: var(--soft);
    padding: 2px;
    gap: 2px;
  }
  .segmented button {
    border: 0;
    border-radius: 99px;
    background: transparent;
    color: var(--muted);
    min-height: 26px;
    padding: 0 10px;
    font: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s;
  }
  .segmented button.active {
    background: var(--panel);
    color: var(--ink);
    box-shadow: inset 0 0 0 1px var(--line);
  }
  #heatmap {
    width: 100%;
    height: 640px;
    min-height: 500px;
    overflow: hidden;
  }
  .v4-card.fullscreen-mode {
    position: fixed !important;
    inset: 0 !important;
    z-index: 9999 !important;
    background: var(--bg) !important;
    padding: 12px 16px !important;
    margin: 0 !important;
    border-radius: 0 !important;
    border: none !important;
    display: flex !important;
    flex-direction: column !important;
    gap: 12px !important;
    width: 100vw !important;
    height: 100vh !important;
    height: 100dvh !important;
  }
  .v4-card.fullscreen-mode #heatmap {
    flex: 1 !important;
    height: 100% !important;
  }
  .v4-card.fullscreen-mode #heatmapSummary {
    display: none !important;
  }
  .legend-bar {
    display: flex;
    align-items: center;
    gap: 0;
    height: 20px;
    border-radius: 4px;
    overflow: hidden;
    width: 100%;
    max-width: 420px;
    border: 1px solid var(--line);
  }
  .legend-stop {
    flex: 1;
    height: 100%;
    position: relative;
  }
  .legend-labels {
    display: flex;
    justify-content: space-between;
    width: 100%;
    max-width: 420px;
    font-size: 11px;
    color: var(--muted);
    margin-top: 4px;
  }
  .hover-card {
    position: fixed;
    left: 0;
    top: 0;
    width: min(340px, calc(100vw - 32px));
    border: 1px solid var(--line);
    border-radius: 12px;
    background: var(--panel);
    box-shadow: 0 8px 32px rgba(0,0,0,0.5);
    padding: 14px;
    pointer-events: none;
    transform: translate(-999px, -999px);
    opacity: 0;
    transition: opacity 100ms ease;
    z-index: 9999;
  }
  .hover-card.visible { opacity: 1; }
  .hover-card h2 {
    margin: 0 0 3px;
    font-size: 16px;
    line-height: 1.15;
    font-family: var(--font-title);
  }
  .hover-card .hover-name {
    color: var(--muted);
    font-size: 13px;
    line-height: 1.35;
    margin-bottom: 10px;
  }
  .detail-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 6px;
  }
  .detail {
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 8px;
    background: var(--bg);
  }
  .detail span {
    display: block;
    color: var(--muted);
    font-size: 10px;
    margin-bottom: 2px;
  }
  .detail b {
    display: block;
    font-size: 13px;
    line-height: 1.1;
  }
  /* Unified dropdown styling */
  .layout-dropdown, .currency-dropdown, .size-dropdown, .color-dropdown, .name-dropdown { position: relative; display: inline-block; }
  .layout-dropdown-trigger, .currency-dropdown-trigger, .size-dropdown-trigger, .color-dropdown-trigger, .name-dropdown-trigger {
    display: flex; align-items: center; gap: 8px;
    height: 32px; padding: 0 12px;
    background: var(--soft); color: var(--ink-secondary);
    border: 1px solid var(--line); border-radius: 8px;
    cursor: pointer; font-size: 12px; font-weight: 550;
    white-space: nowrap; user-select: none;
    transition: all 0.15s;
    outline: none;
    -webkit-appearance: none;
    appearance: none;
  }
  .layout-dropdown-trigger:hover, .currency-dropdown-trigger:hover, .size-dropdown-trigger:hover, .color-dropdown-trigger:hover, .name-dropdown-trigger:hover {
    border-color: var(--line-strong);
    background: var(--panel-hover);
    color: var(--ink);
  }
  .layout-dropdown-trigger .arrow, .currency-dropdown-trigger .arrow, .size-dropdown-trigger .arrow, .color-dropdown-trigger .arrow, .name-dropdown-trigger .arrow { font-size: 10px; color: var(--muted); margin-left: 2px; }
  
  .layout-dropdown-menu, .currency-dropdown-menu, .size-dropdown-menu, .color-dropdown-menu, .name-dropdown-menu {
    position: absolute; top: 100%; left: 0; margin-top: 4px;
    min-width: 140px; background: var(--panel-raised); border: 1px solid var(--line); border-radius: 8px;
    box-shadow: var(--shadow-md); padding: 6px 0;
    z-index: 300; display: none;
  }
  .size-dropdown-menu { min-width: 240px; }
  .color-dropdown-menu { min-width: 200px; }
  
  .layout-dropdown-menu.open, .currency-dropdown-menu.open, .size-dropdown-menu.open, .color-dropdown-menu.open, .name-dropdown-menu.open { display: block; }
  
  .layout-dropdown-menu .group-label, .currency-dropdown-menu .group-label, .size-dropdown-menu .group-label, .color-dropdown-menu .group-label, .name-dropdown-menu .group-label {
    padding: 8px 14px 4px; font-size: 11px; font-weight: 600;
    color: var(--muted); text-transform: none;
  }
  .layout-dropdown-menu .menu-item, .currency-dropdown-menu .menu-item, .size-dropdown-menu .menu-item, .color-dropdown-menu .menu-item, .name-dropdown-menu .menu-item {
    display: flex; align-items: center; justify-content: space-between;
    padding: 7px 14px; font-size: 12px; color: var(--ink);
    cursor: pointer; transition: background 0.1s; white-space: nowrap;
  }
  .layout-dropdown-menu .menu-item:hover, .currency-dropdown-menu .menu-item:hover, .size-dropdown-menu .menu-item:hover, .color-dropdown-menu .menu-item:hover, .name-dropdown-menu .menu-item:hover {
    background: var(--panel-hover);
  }
  
  .layout-dropdown-menu .menu-item.active, .currency-dropdown-menu .menu-item.active, .size-dropdown-menu .menu-item.active, .color-dropdown-menu .menu-item.active, .name-dropdown-menu .menu-item.active {
    background: var(--accent); color: #fff; border-radius: 4px; margin: 0 6px; padding: 7px 8px;
  }
  .layout-dropdown-menu .menu-item .check, .currency-dropdown-menu .menu-item .check, .size-dropdown-menu .menu-item .check, .color-dropdown-menu .menu-item .check, .name-dropdown-menu .menu-item .check { color: var(--accent); font-size: 12px; display: none; }
  .layout-dropdown-menu .menu-item.active .check, .currency-dropdown-menu .menu-item.active .check, .size-dropdown-menu .menu-item.active .check, .color-dropdown-menu .menu-item.active .check, .name-dropdown-menu .menu-item.active .check { display: inline; color: #fff; }
  
  .color-dropdown-trigger .heat-icon { display: flex; gap: 1px; }
  .color-dropdown-trigger .heat-icon span { width: 8px; height: 14px; border-radius: 2px; }
  .size-dropdown-menu .divider, .color-dropdown-menu .divider { height: 1px; background: var(--line); margin: 4px 0; }
  .size-dropdown-menu .disabled, .color-dropdown-menu .disabled { color: var(--muted); cursor: default; pointer-events: none; }

  .heatmap-controls {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    border-bottom: 1px solid var(--line);
    padding-bottom: 12px;
  }
  .v4-card.fullscreen-mode .heatmap-controls {
    border-bottom: none !important;
    padding-bottom: 0 !important;
  }
</style>

<div class="v4-card" style="padding:16px;display:flex;flex-direction:column;gap:12px;">
    <div style="display:flex;justify-content:space-between;align-items:flex-end;margin-bottom:8px;">
    <div>
      <h1 style="font-size:20px;font-weight:700;margin:0 0 4px;color:var(--ink);">持仓热力图</h1>
      <p style="font-size:12px;color:var(--muted);margin:0;">面积 = 仓位权重 · 颜色 = 所选指标 · 鼠标悬停查看详情</p>
    </div>
    <div id="coverageNote" style="font-size:11px;color:var(--muted);"></div>
  </div>

  <div class="heatmap-controls">
    <div style="display:flex;flex-wrap:wrap;align-items:center;gap:10px;font-size:12px;">
      <div class="layout-dropdown" id="layoutDropdown">
        <div class="layout-dropdown-trigger" id="layoutTrigger">
          <span id="layoutLabel">按大小</span>
          <span class="arrow">▾</span>
        </div>
        <div class="layout-dropdown-menu" id="layoutMenu">
          <div class="group-label">布局方式</div>
          <div class="menu-item active" data-layout="size" data-label="按大小">按大小<span class="check">✓</span></div>
          <div class="menu-item" data-layout="sector" data-label="按板块">按板块<span class="check">✓</span></div>
        </div>
      </div>
      <div class="size-dropdown" id="sizeDropdown">
        <div class="size-dropdown-trigger" id="sizeTrigger">
          <span id="sizeLabel">市值</span>
          <span class="arrow">▾</span>
        </div>
        <div class="size-dropdown-menu" id="sizeMenu">
          <div class="group-label">大小</div>
          <div class="menu-item active" data-size="marketcap" data-label="市值">市值<span class="check">✓</span></div>
          <div class="menu-item" data-size="equal" data-label="相同大小">相同大小<span class="check">✓</span></div>
          <div class="divider"></div>
          <div class="group-label">成交量</div>
          <div class="menu-item" data-size="vol1d" data-label="成交量1天">成交量1天<span class="check">✓</span></div>
          <div class="menu-item" data-size="turnover1d" data-label="成交额1天">成交额1天<span class="check">✓</span></div>
          <div class="divider"></div>
          <div class="group-label">转手</div>
          <div class="menu-item disabled" data-size="turnover1d">价格×成交量 1天</div>
          <div class="menu-item disabled" data-size="turnover1w">价格×成交量 1周</div>
          <div class="menu-item disabled" data-size="turnover1m">价格×成交量 1月</div>
        </div>
      </div>
      <div class="currency-dropdown" id="currencyDropdown">
        <div class="currency-dropdown-trigger" id="currencyTrigger">
          <span id="currencyLabel">USD</span>
          <span class="arrow">▾</span>
        </div>
        <div class="currency-dropdown-menu" id="currencyMenu">
          <div class="group-label">货币选择</div>
          <div class="menu-item active" data-currency="USD" data-label="USD">USD<span class="check">✓</span></div>
          <div class="menu-item" data-currency="GBP" data-label="GBP">GBP<span class="check">✓</span></div>
        </div>
      </div>
      <div class="color-dropdown" id="colorDropdown">
        <div class="color-dropdown-trigger" id="colorTrigger">
          <span class="heat-icon">
            <span style="background:#ef4444"></span>
            <span style="background:#f97316"></span>
            <span style="background:#eab308"></span>
            <span style="background:#22c55e"></span>
          </span>
          <span id="colorLabel">涨跌1天, %</span>
          <span class="arrow">▾</span>
        </div>
        <div class="color-dropdown-menu" id="colorMenu">
          <div class="group-label">涨跌</div>
          <div class="menu-item active" data-color="day" data-label="涨跌1天, %">涨跌1天, %<span class="check">✓</span></div>
          <div class="divider"></div>
          <div class="group-label">表现</div>
          <div class="menu-item" data-color="week" data-label="涨跌1周, %">1周<span class="check">✓</span></div>
          <div class="menu-item" data-color="month" data-label="涨跌1月, %">1月<span class="check">✓</span></div>
          <div class="menu-item" data-color="quarter" data-label="涨跌3月, %">3月<span class="check">✓</span></div>
          <div class="menu-item" data-color="halfyear" data-label="涨跌6月, %">6月<span class="check">✓</span></div>
          <div class="menu-item" data-color="ytd" data-label="今年以来 YTD, %">YTD<span class="check">✓</span></div>
          <div class="menu-item" data-color="year" data-label="涨跌1年, %">1年<span class="check">✓</span></div>
          <div class="divider"></div>
          <div class="group-label">估值 & 盈亏</div>
          <div class="menu-item" data-color="valuation" data-label="估值 P/E">估值 P/E<span class="check">✓</span></div>
          <div class="menu-item" data-color="pnl" data-label="浮动盈亏, %">浮动盈亏, %<span class="check">✓</span></div>
          <div class="divider"></div>
          <div class="group-label">其他</div>
          <div class="menu-item" data-color="relvolume" data-label="相对成交量">相对成交量<span class="check">✓</span></div>
          <div class="menu-item disabled" data-color="premarket">盘前涨跌</div>
          <div class="menu-item disabled" data-color="afterhours">盘后涨跌</div>
          <div class="menu-item disabled" data-color="volatility">波动率1天</div>
          <div class="menu-item disabled" data-color="gap">跳空</div>
        </div>
      </div>
      <div class="name-dropdown" id="nameDropdown">
        <div class="name-dropdown-trigger" id="nameTrigger">
          <span id="nameLabel">中文</span>
          <span class="arrow">▾</span>
        </div>
        <div class="name-dropdown-menu" id="nameMenu">
          <div class="group-label">名称显示</div>
          <div class="menu-item active" data-name="cn" data-label="中文">中文<span class="check">✓</span></div>
          <div class="menu-item" data-name="en" data-label="英文">英文<span class="check">✓</span></div>
          <div class="menu-item" data-name="hidden" data-label="隐藏">隐藏<span class="check">✓</span></div>
        </div>
      </div>
      <div class="segmented" aria-label="ETF穿透">
        <button id="etfUnwrapBtn" type="button">穿透ETF</button>
      </div>
    </div>
    <div style="display:flex;align-items:center;gap:8px;">
      <span id="status" class="market-status-badge"><div class="status-dot"></div> 读取中...</span>
      <button id="fullscreenBtn" class="btn" type="button" style="height:32px;font-size:12px;"><i class="fa-solid fa-expand"></i></button>
      <button id="refreshMarket" class="btn" type="button" style="height:32px;font-size:12px;">行情</button>
      <button id="refreshValuation" class="btn" type="button" style="height:32px;font-size:12px;">估值</button>
      <button id="refreshHoldings" class="btn" type="button" style="height:32px;font-size:12px;">同步</button>
    </div>
  </div>

  <div id="heatmapSummary" style="display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:8px;margin-top:2px;"></div>

  <div id="heatmap"></div>

  <div style="display:none;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;">
    <div style="display:flex;flex-direction:column;gap:2px;">
      <div id="legendBar" class="legend-bar"></div>
      <div id="legendLabels" class="legend-labels"></div>
    </div>
    <div id="legendNote" style="font-size:11px;color:var(--muted);"></div>
  </div>

</div>

<div id="hoverCard" class="hover-card"></div>

<script src="/static/vendor/echarts.min.js"></script>
<script>
    const heatmap = document.querySelector("#heatmap");
    const statusEl = document.querySelector("#status");
    let statusTimeout = null;
    function setStatus(html, autoHide = false) {
      if (statusTimeout) { clearTimeout(statusTimeout); statusTimeout = null; }
      statusEl.style.display = "inline-flex";
      statusEl.style.opacity = "1";
      statusEl.style.transition = "none";
      statusEl.innerHTML = html;
      if (autoHide) {
        statusTimeout = setTimeout(() => {
          statusEl.style.transition = "opacity 0.5s ease";
          statusEl.style.opacity = "0";
          statusTimeout = setTimeout(() => {
            statusEl.style.display = "none";
          }, 500);
        }, 1500);
      }
    }
    const hoverCard = document.querySelector("#hoverCard");
    const layoutTrigger = document.querySelector("#layoutTrigger");
    const layoutMenu = document.querySelector("#layoutMenu");
    const layoutLabel = document.querySelector("#layoutLabel");
    const currencyTrigger = document.querySelector("#currencyTrigger");
    const currencyMenu = document.querySelector("#currencyMenu");
    const currencyLabel = document.querySelector("#currencyLabel");
    const colorTrigger = document.querySelector("#colorTrigger");
    const colorMenu = document.querySelector("#colorMenu");
    const colorLabel = document.querySelector("#colorLabel");
    const sizeTrigger = document.querySelector("#sizeTrigger");
    const sizeMenu = document.querySelector("#sizeMenu");
    const sizeLabel = document.querySelector("#sizeLabel");
    const nameTrigger = document.querySelector("#nameTrigger");
    const nameMenu = document.querySelector("#nameMenu");
    const nameLabel = document.querySelector("#nameLabel");
    const etfUnwrapBtn = document.querySelector("#etfUnwrapBtn");
    const fullscreenBtn = document.querySelector("#fullscreenBtn");
    const refreshMarketButton = document.querySelector("#refreshMarket");
    const refreshValuationButton = document.querySelector("#refreshValuation");
    const refreshHoldingsButton = document.querySelector("#refreshHoldings");
    const legendBar = document.querySelector("#legendBar");
    const legendLabels = document.querySelector("#legendLabels");
    const legendNote = document.querySelector("#legendNote");
    let heatmapChart = null;
    let currentRows = [];
    let layoutMode = "size";
    let currencyMode = "USD";
    let colorMode = "day";
    let sizeMode_value = "marketcap";
    let nameMode = "cn";
    let etfUnwrap = false;
    let rawRows = [];
    let lookthroughData = null;
    let isFullscreen = false;
    if (localStorage.getItem("theme") === "light") {
      document.documentElement.classList.add("light-theme");
    }
    function cssVar(name) {
      return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    }
    function htmlEscape(str) {
      if (!str) return "";
      return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");
    }
    function fmtPct(val) { return `${(Number(val || 0) * 100).toFixed(2)}%`; }
    function fmtDay(val) { const num = Number(val || 0); return `${num >= 0 ? "+" : ""}${num.toFixed(2)}%`; }
    function fmtMoney(val) {
      const rate = currencyMode === "GBP" ? 1.0 / 1.3460 : 1.0;
      const prefix = currencyMode === "GBP" ? "£" : "$";
      return `${prefix}${Number((val || 0) * rate).toLocaleString("en-GB", { maximumFractionDigits: 0 })}`;
    }
    const fmtRatio = val => val === null || val === undefined ? "—" : val.toFixed(1);
    const fmtNum = val => val === null || val === undefined ? "—" : Number(val).toFixed(2);
    function fmtAge(unix) {
      if (!unix) return "无估值";
      const seconds = Math.floor(Date.now() / 1000 - Number(unix));
      if (seconds < 60) return "刚才";
      if (seconds < 3600) return `${Math.floor(seconds / 60)}分钟前`;
      return `${Math.floor(seconds / 3600)}小时前`;
    }
    function colorMetric(row) {
      if (colorMode === "valuation") { const pe = valuationPe(row); if (pe === null) return 0; return pe > 22 ? -1.5 : 1.5; }
      if (colorMode === "pnl") { return row.unrealized_percent === null ? 0 : Number(row.unrealized_percent); }
      if (colorMode === "relvolume") { const vol = Number(row.volume || 0); const avg = Number(row.avg_volume_3m || 1); return avg > 0 ? (vol / avg - 1) : 0; }
      if (colorMode === "week") { return row.return_1w === null || row.return_1w === undefined ? 0 : Number(row.return_1w); }
      if (colorMode === "month") { return row.return_1m === null || row.return_1m === undefined ? 0 : Number(row.return_1m); }
      if (colorMode === "quarter") { return row.return_3m === null || row.return_3m === undefined ? 0 : Number(row.return_3m); }
      if (colorMode === "halfyear") { return row.return_6m === null || row.return_6m === undefined ? 0 : Number(row.return_6m); }
      if (colorMode === "ytd") { return row.return_ytd === null || row.return_ytd === undefined ? 0 : Number(row.return_ytd); }
      if (colorMode === "year") { return row.return_1y === null || row.return_1y === undefined ? 0 : Number(row.return_1y); }
      return row.today_change_percent === null ? 0 : Number(row.today_change_percent);
    }
    function colorMetricLimit() {
      if (colorMode === "valuation") return 2;
      if (colorMode === "pnl") return 20;
      if (colorMode === "relvolume") return 1.5;
      if (colorMode === "week") return 5;
      if (colorMode === "month") return 10;
      if (colorMode === "quarter") return 15;
      if (colorMode === "halfyear") return 20;
      if (colorMode === "ytd") return 25;
      if (colorMode === "year") return 30;
      return 2;
    }
    function heatColor(val, limit) {
      const isDark = isDarkMode();
      if (colorMode === "valuation") {
        return val >= 0 ? (isDark ? "#22c55e" : "#1b5e20") : (isDark ? "#ef4444" : "#b71c1c");
      }
      const t = Math.max(-1, Math.min(1, val / limit));
      if (isDark) {
        if (t >= 0) {
          const r = Math.round(18 + t * (34 - 18));
          const g = Math.round(22 + t * (197 - 22));
          const b = Math.round(32 + t * (94 - 32));
          return `rgb(${r},${g},${b})`;
        } else {
          const a = Math.abs(t);
          const r = Math.round(18 + a * (239 - 18));
          const g = Math.round(22 + a * (68 - 22));
          const b = Math.round(32 + a * (68 - 32));
          return `rgb(${r},${g},${b})`;
        }
      } else {
        if (t >= 0) {
          const r = Math.round(240 - t * (240 - 27));
          const g = Math.round(243 - t * (243 - 94));
          const b = Math.round(250 - t * (250 - 32));
          return `rgb(${r},${g},${b})`;
        } else {
          const a = Math.abs(t);
          const r = Math.round(240 - a * (240 - 183));
          const g = Math.round(243 - a * (243 - 28));
          const b = Math.round(250 - a * (250 - 28));
          return `rgb(${r},${g},${b})`;
        }
      }
    }
    function valuationPe(row) { const pe = Number(row.trailing_pe || 0); if (pe > 0 && pe < 300) return pe; return null; }
    function metricLabel(row) {
      if (colorMode === "valuation") { const pe = valuationPe(row); return pe === null ? "P/E —" : `P/E ${pe.toFixed(1)}`; }
      if (colorMode === "pnl") { const val = row.unrealized_percent; return val === null ? "—" : `${val >= 0 ? "+" : ""}${Number(val).toFixed(1)}%`; }
      if (colorMode === "relvolume") { const vol = Number(row.volume||0); const avg = Number(row.avg_volume_3m||1); const rv = avg>0 ? vol/avg : 0; return `Vol ${rv.toFixed(1)}x`; }
      let val = null;
      if (colorMode === "week") val = row.return_1w;
      else if (colorMode === "month") val = row.return_1m;
      else if (colorMode === "quarter") val = row.return_3m;
      else if (colorMode === "halfyear") val = row.return_6m;
      else if (colorMode === "ytd") val = row.return_ytd;
      else if (colorMode === "year") val = row.return_1y;
      else val = row.today_change_percent;
      return val === null || val === undefined ? "—" : `${val >= 0 ? "+" : ""}${Number(val).toFixed(2)}%`;
    }
    function labelCompanyName(row) {
      if (nameMode === "hidden") return "";
      const display = row.display_name || row.name || "";
      if (nameMode === "en") return row.name || "";
      return display;
    }
    function groupRows(rows) {
      const map = {};
      rows.forEach(row => { const sector = row.sector || "Other"; if (!map[sector]) map[sector] = []; map[sector].push(row); });
      return Object.entries(map).map(([sector, list]) => {
        const totalValue = list.reduce((sum, r) => sum + Number(r.market_value_usd || 0), 0) || 1;
        const weightedChange = list.reduce((sum, r) => sum + Number(r.today_change_percent || 0) * Number(r.market_value_usd || 0), 0) / totalValue;
        const weightedPnl = list.reduce((sum, r) => sum + Number(r.unrealized_percent || 0) * Number(r.market_value_usd || 0), 0) / totalValue;
        
        let targetKey = "today_change_percent";
        if (colorMode === "week") targetKey = "return_1w";
        else if (colorMode === "month") targetKey = "return_1m";
        else if (colorMode === "quarter") targetKey = "return_3m";
        else if (colorMode === "halfyear") targetKey = "return_6m";
        else if (colorMode === "ytd") targetKey = "return_ytd";
        else if (colorMode === "year") targetKey = "return_1y";
        
        const weightedValue = list.reduce((sum, r) => sum + Number(r[targetKey] || 0) * Number(r.market_value_usd || 0), 0) / totalValue;
        let peWeightSum = 0, peValueSum = 0;
        list.forEach(r => { const pe = valuationPe(r); if (pe !== null) { peValueSum += pe * Number(r.market_value_usd || 0); peWeightSum += Number(r.market_value_usd || 0); } });
        const weightedPe = peWeightSum > 0 ? peValueSum / peWeightSum : null;
        const count = list.length;
        return { sector, holdings: list, weightedChange, weightedPnl, weightedValue, weightedPe, count };
      }).sort((a, b) => b.holdings.reduce((s, r) => s + Number(r.market_value_usd || 0), 0) - a.holdings.reduce((s, r) => s + Number(r.market_value_usd || 0), 0));
    }
    function labelSize(row) {
      if (sizeMode_value === "equal") {
        return { fontSize: 10, lineHeight: 12 };
      }
      const pct = Number(row.weight || 0) * 100;
      if (pct >= 8) return { fontSize: 13, lineHeight: 16 };
      if (pct >= 4) return { fontSize: 11, lineHeight: 13 };
      if (pct >= 2) return { fontSize: 9, lineHeight: 11 };
      if (pct >= 1) return { fontSize: 8, lineHeight: 10 };
      if (pct >= 0.5) return { fontSize: 7, lineHeight: 9 };
      return { fontSize: 6, lineHeight: 8 };
    }
    function isDarkMode() {
      return !document.documentElement.classList.contains("light-theme");
    }
    function labelColor() {
      return isDarkMode() ? "#f0f0f0" : "#1a1a1a";
    }
    function leafNode(row) {
      const metric = colorMetric(row);
      const size = labelSize(row);
      const lc = labelColor();
      let value;
      if (sizeMode_value === "equal") value = 1;
      else if (sizeMode_value === "vol1d") value = Math.max(Number(row.volume || 0), 1);
      else if (sizeMode_value === "turnover1d") value = Math.max(Number(row.volume || 0) * Number(row.quote_price || row.avg_cost_usd || 1), 1);
      else if (sizeMode_value === "marketcap") value = Math.max(Number(row.market_cap || row.market_value_usd || 0), 1);
      else value = Math.max(Number(row.market_value_usd || 0), 1);
      return {
        name: row.ticker,
        value,
        raw: row,
        itemStyle: { color: heatColor(metric, colorMetricLimit()), borderColor: cssVar("--line"), borderWidth: 1, gapWidth: 1 },
        label: {
          show: true, color: lc, position: "insideTopLeft", align: "left", verticalAlign: "top",
          padding: [4, 4, 0, 4], overflow: "truncate",
          formatter: params => {
            const item = params.data.raw || {};
            const pct = Number(item.weight || 0) * 100;
            if (pct < 0.35) return item.ticker || "";
            if (pct < 1) return `${item.ticker}`;
            if (pct < 2) return `${item.ticker}\n${metricLabel(item)}`;
            const company = labelCompanyName(item);
            return company ? `${item.ticker}\n${metricLabel(item)}\n${company}` : `${item.ticker}\n${metricLabel(item)}`;
          },
          fontWeight: 800, fontSize: size.fontSize, lineHeight: size.lineHeight,
        },
        emphasis: { itemStyle: { shadowBlur: 0, shadowColor: "transparent" }, label: { color: lc } },
      };
    }
    function buildSizeData(rows) {
      return rows.sort((a, b) => Number(b.market_value_usd || 0) - Number(a.market_value_usd || 0)).map(row => leafNode(row));
    }
    function buildSectorData(rows) {
      return groupRows(rows).map(group => {
        const children = group.holdings.map(leafNode);
        const childrenSum = children.reduce((sum, child) => sum + child.value, 0);
        return {
          name: `${group.sector}\n${group.count}只 · ${fmtMoney(group.holdings.reduce((s, r) => s + Number(r.market_value_usd || 0), 0))}\n${colorMode === "valuation" ? (group.weightedPe ? `P/E ${group.weightedPe.toFixed(1)}` : "P/E —") : colorMode === "pnl" ? fmtDay(group.weightedPnl) : (colorMode === "day" ? fmtDay(group.weightedChange) : fmtDay(group.weightedValue))}`,
          value: childrenSum,
          itemStyle: { borderColor: cssVar("--line"), borderWidth: 2, gapWidth: 3 },
          upperLabel: {
            show: true, height: 52, align: "left", padding: [6, 6, 0, 6],
            color: isDarkMode() ? "#e0e0e0" : "#2a2a2a", fontSize: 12, fontWeight: 800,
            overflow: "truncate",
          },
          children,
        };
      });
    }
    function buildLegend() {
      const limit = colorMetricLimit();
      let stops, labels;
      if (colorMode === "valuation") {
        stops = ["#ef4444", "#22c55e"];
        labels = ["高估", "低估"];
      } else {
        const steps = 7;
        stops = [];
        labels = [];
        for (let i = 0; i < steps; i++) {
          const t = (i / (steps - 1)) * 2 - 1;
          const a = Math.abs(t);
          if (t >= 0) {
            stops.push(`rgb(${Math.round(22 + a * 200)},${Math.round(163 + a * 85)},${Math.round(86 + a * 60)})`);
          } else {
            stops.push(`rgb(${Math.round(200 + a * 55)},${Math.round(68 + a * 30)},${Math.round(68 + a * 30)})`);
          }
        }
        labels = [`${(-limit).toFixed(0)}%`, "", "0%", "", `${limit.toFixed(0)}%`];
      }
      legendBar.innerHTML = stops.map(s => `<div class="legend-stop" style="background:${s}"></div>`).join("");
      legendLabels.innerHTML = labels.map(l => `<span>${l}</span>`).join("");
      const label = colorMode === "valuation" ? "估值 P/E" : colorMode === "pnl" ? "浮动盈亏 %" : colorMode === "relvolume" ? "相对成交量(量/均量)" : "今日涨跌 %";
      legendNote.textContent = label;
    }
    function tooltipHtml(row) {
      const day = Number(row.today_change_percent || 0);
      const metric = colorMetric(row);
      const pnl = Number(row.unrealized_usd || 0);
      const pnlPct = row.unrealized_percent === null ? "—" : `${Number(row.unrealized_percent).toFixed(1)}%`;
      const pe = valuationPe(row);
      const forwardPe = Number(row.forward_pe || 0) > 0 ? Number(row.forward_pe) : null;
      const sales = Number(row.price_to_sales || 0) > 0 ? Number(row.price_to_sales) : null;
      const valuationAge = fmtAge(row.valuation_as_of_unix);
      const text = cssVar("--ink"); const muted = cssVar("--muted");
      const up = "var(--positive)"; const down = "var(--negative)";
      const fmtReturn = val => {
        if (val === null || val === undefined) return "—";
        const num = Number(val);
        return `<span style="color:${num >= 0 ? up : down}; font-weight: 700;">${num >= 0 ? "+" : ""}${num.toFixed(2)}%</span>`;
      };
      return `<div style="width:260px;border:1px solid var(--line);border-radius:10px;background:var(--panel);box-shadow:0 8px 32px rgba(0,0,0,0.5);padding:10px 11px;color:${text};">
        <div style="display:flex;align-items:baseline;justify-content:space-between;gap:10px;border-bottom:1px solid var(--line);padding-bottom:7px;margin-bottom:7px;">
          <div style="min-width:0;">
            <div style="font-weight:850;font-size:14px;line-height:1.1;">${htmlEscape(row.ticker)}</div>
            <div style="color:${muted};font-size:10px;line-height:1.25;margin-top:3px;">${htmlEscape(row.display_name || row.name || row.ticker)}</div>
          </div>
          <div style="font-weight:850;font-size:13px;color:${metric >= 0 ? up : down};">${metricLabel(row)}</div>
        </div>
        <div style="display:grid;gap:5px;font-size:11px;line-height:1.25;">
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">板块</span><b style="font-weight:650;text-align:right;">${htmlEscape(row.sector || "Other")}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">仓位</span><b style="font-weight:750;">${fmtPct(row.weight)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">今日</span><b style="font-weight:750;color:${day >= 0 ? up : down};">${fmtDay(day)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">P/E</span><b style="font-weight:750;color:${pe === null ? muted : pe <= 22 ? up : down};">${fmtRatio(pe)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">Forward P/E</span><b style="font-weight:750;">${fmtRatio(forwardPe)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">P/S</span><b style="font-weight:750;">${fmtRatio(sales)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;border-top:1px solid var(--line);padding-top:5px;margin-top:2px;"><span style="color:${muted};">估值更新</span><b style="font-weight:650;color:${muted};">${valuationAge}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">市值</span><b style="font-weight:750;">${fmtMoney(row.market_value_usd)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">浮盈亏</span><b style="font-weight:750;color:${pnl >= 0 ? up : down};">${fmtMoney(pnl)} / ${pnlPct}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">成本</span><b style="font-weight:750;">${fmtMoney(row.cost_usd)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">现价</span><b style="font-weight:750;">${fmtNum(row.quote_price)} ${htmlEscape(row.quote_currency || "")}</b></div>
          ${row._etf_only ? `<div style="display:flex;justify-content:space-between;gap:14px;border-top:1px solid var(--line);padding-top:5px;margin-top:2px;"><span style="color:var(--accent);">来源</span><b style="font-weight:650;color:var(--accent);">全部来自 ETF</b></div>` : row._etf_portion ? `<div style="display:flex;justify-content:space-between;gap:14px;border-top:1px solid var(--line);padding-top:5px;margin-top:2px;"><span style="color:var(--accent);">含 ETF</span><b style="font-weight:650;color:var(--accent);">+${fmtMoney(row._etf_portion)}</b></div>` : ""}
          
          <div style="display:flex;justify-content:space-between;gap:14px;border-top:1px solid var(--line);padding-top:5px;margin-top:2px;"><span style="color:${muted}; font-weight:700;">历史表现</span></div>
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px 10px;font-size:10px;margin-top:2px;">
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">1周</span><b>${fmtReturn(row.return_1w)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">1月</span><b>${fmtReturn(row.return_1m)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">3月</span><b>${fmtReturn(row.return_3m)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">6月</span><b>${fmtReturn(row.return_6m)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">YTD</span><b>${fmtReturn(row.return_ytd)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">1年</span><b>${fmtReturn(row.return_1y)}</b></div>
          </div>
        </div>
      </div>`;
    }

    function renderSummary(rows) {
      const el = document.getElementById("heatmapSummary");
      if (!el) return;
      const total = rows.reduce((s, r) => s + Number(r.market_value_usd || 0), 0);
      const dayPnl = rows.reduce((s, r) => { const ch = Number(r.today_change_percent||0)/100; const v = Number(r.market_value_usd||0); return s + (v - v/(1+ch)); }, 0);
      const up = rows.filter(r => Number(r.today_change_percent||0) > 0).length;
      const down = rows.filter(r => Number(r.today_change_percent||0) < 0).length;
      const upColor = dayPnl >= 0 ? "var(--positive)" : "var(--negative)";
      el.innerHTML = `<div class="detail" style="padding:10px 14px;"><span>持仓数</span><b>${rows.length}</b></div>
        <div class="detail" style="padding:10px 14px;"><span>总市值</span><b>${fmtMoney(total)}</b></div>
        <div class="detail" style="padding:10px 14px;"><span>今日盈亏</span><b style="color:${upColor}">${fmtMoney(dayPnl)}</b></div>
        <div class="detail" style="padding:10px 14px;"><span>涨跌比</span><b>↑${up} / ↓${down}</b></div>
        <div class="detail" style="padding:10px 14px;"><span>日涨跌%</span><b style="color:${upColor}">${total ? (dayPnl/(total-dayPnl)*100).toFixed(2) : "—"}%</b></div>
        <div class="detail" style="padding:10px 14px;"><span>ETF穿透</span><b>${etfUnwrap ? "已开启" : "关闭"}</b></div>`;
    }

    function renderDailyTrend(rows) {
      try {
      const el = document.getElementById("dailyTrendChart");
      if (!el || !window.LightweightCharts) return;
      if (el._lwChart) { el._lwChart.remove(); el._lwChart = null; }
      const d = document.documentElement.classList.contains("light-theme");
      const chart = LightweightCharts.createChart(el, {
        width: el.clientWidth, height: 220,
        layout: { background: { color: d ? '#ffffff' : '#0b0d0f' }, textColor: d ? '#5d6068' : '#707580' },
        grid: { vertLines: { color: d ? 'rgba(0,0,0,0.06)' : 'rgba(255,255,255,0.05)' }, horzLines: { color: d ? 'rgba(0,0,0,0.06)' : 'rgba(255,255,255,0.05)' } },
        rightPriceScale: { borderColor: d ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.05)' },
        timeScale: { borderColor: d ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.05)', timeVisible: false },
        crosshair: { mode: 0 },
      });
      el._lwChart = chart;
      const sorted = [...rows].filter(r => Number.isFinite(Number(r.today_change_percent)))
        .sort((a, b) => Number(b.today_change_percent || 0) - Number(a.today_change_percent || 0));
      if (!sorted.length) return;
      const fmtPctVal = v => (v != null ? (v >= 0 ? '+' : '') + v.toFixed(2) + '%' : '');
      // Use epoch seconds as time so LW Charts renders correctly
      const baseTime = Math.floor(Date.now() / 86400) * 86400;
      const series = chart.addHistogramSeries({
        priceFormat: { type: 'custom', formatter: fmtPctVal },
      });
      series.setData(sorted.map((r, i) => ({
        time: baseTime + i * 60,
        value: Number(r.today_change_percent || 0),
        color: (Number(r.today_change_percent) || 0) >= 0 ? '#27a648' : '#e54d5e',
      })));      } catch(e) { /* daily trend chart optional */ }
    }
    function getActiveRows() {
      if (!etfUnwrap || !lookthroughData) return rawRows;
      const etfTickers = new Set(lookthroughData.etf_tickers);
      const ltRows = lookthroughData.rows || [];
      const merged = {};
      rawRows.forEach(r => {
        if (!etfTickers.has(r.ticker)) merged[r.ticker] = Object.assign({}, r);
      });
      ltRows.forEach(lt => {
        if (merged[lt.ticker]) {
          merged[lt.ticker].market_value_usd = (Number(merged[lt.ticker].market_value_usd) || 0) + (lt.from_etf_usd || 0);
          merged[lt.ticker]._etf_portion = lt.from_etf_usd;
        } else {
          merged[lt.ticker] = {
            ticker: lt.ticker,
            name: lt.name,
            display_name: lt.name,
            sector: "ETF穿透",
            market_value_usd: lt.total_usd || 0,
            today_change_percent: null,
            unrealized_percent: null,
            unrealized_usd: null,
            cost_usd: null,
            shares: null,
            weight: 0,
            quote_price: null,
            quote_currency: "USD",
            _etf_only: true,
          };
        }
      });
      const result = Object.values(merged);
      const totalValue = result.reduce((s, r) => s + (Number(r.market_value_usd) || 0), 0);
      result.forEach(r => { r.weight = totalValue > 0 ? (Number(r.market_value_usd) || 0) / totalValue : 0; });
      return result;
    }
    function render() {
      const rows = getActiveRows();
      if (!window.echarts) {
        setStatus('<div class="status-dot danger"></div> 图表库加载失败');
        heatmap.innerHTML = '<div style="padding:24px;color:#a9364b;font-weight:800;">图表库加载失败</div>';
        return;
      }
      currentRows = rows;
      layoutLabel.textContent = layoutMode === "sector" ? "按板块" : "按大小";
      layoutMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.layout === layoutMode);
      });
      currencyLabel.textContent = currencyMode;
      currencyMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.currency === currencyMode);
      });
      colorLabel.textContent = colorMode === "valuation" ? "估值 P/E" : colorMode === "pnl" ? "浮动盈亏, %" : colorMode === "relvolume" ? "相对成交量" : "涨跌1天, %";
      colorMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.color === colorMode);
      });
      sizeMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.size === sizeMode_value);
      });
      nameLabel.textContent = nameMode === "cn" ? "中文" : nameMode === "en" ? "英文" : "隐藏";
      nameMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.name === nameMode);
      });
      if (!heatmapChart) {
        heatmapChart = echarts.init(heatmap, null, { renderer: "canvas" });
        window.addEventListener("resize", () => { heatmapChart?.resize(); });
      }
      const data = layoutMode === "sector" ? buildSectorData(rows) : buildSizeData(rows);
      heatmapChart.setOption({
        animationDuration: 450, animationDurationUpdate: 420,
        tooltip: {
          trigger: "item", confine: true, borderWidth: 0, padding: 0, backgroundColor: "transparent",
          formatter: params => { const row = params.data.raw; if (!row) return ""; return tooltipHtml(row); },
        },
        series: [{
          type: "treemap", roam: false, nodeClick: false, breadcrumb: { show: false },
          visibleMin: 1, left: 0, top: 0, right: 0, bottom: 0, squareRatio: 1.15,
          levels: [
            { itemStyle: { borderWidth: 1, gapWidth: 1, borderColor: cssVar("--line") } },
            { upperLabel: { show: layoutMode === "sector" }, itemStyle: { borderWidth: 1, gapWidth: 2, borderColor: cssVar("--line") } },
            { itemStyle: { borderWidth: 1, gapWidth: 1, borderColor: cssVar("--line") } },
          ],
          data,
        }],
      }, true);
      const valuationRows = rows.filter(row => valuationPe(row) !== null);
      const coverage = `${valuationRows.length}/${rows.length}`;
      const totalValue = rows.reduce((s, r) => s + Number(r.market_value_usd || 0), 0);
      const etfTag = etfUnwrap ? " · ETF已穿透" : "";
      setStatus('<div class="status-dot"></div> 已就绪', true);
      buildLegend();
      renderSummary(rows);
    }
    function toggleFullscreen() {
      isFullscreen = !isFullscreen;
      heatmap.parentElement.classList.toggle("fullscreen-mode", isFullscreen);
      fullscreenBtn.innerHTML = isFullscreen ? '<i class="fa-solid fa-compress"></i>' : '<i class="fa-solid fa-expand"></i>';
      setTimeout(() => heatmapChart?.resize(), 100);
    }
    fullscreenBtn.addEventListener("click", toggleFullscreen);
    document.addEventListener("keydown", e => { if (e.key === "Escape" && isFullscreen) toggleFullscreen(); });
    function closeAllMenus() {
      colorMenu.classList.remove("open");
      sizeMenu.classList.remove("open");
      nameMenu.classList.remove("open");
      layoutMenu.classList.remove("open");
      currencyMenu.classList.remove("open");
    }
    colorTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = colorMenu.classList.contains("open"); closeAllMenus(); if (!open) colorMenu.classList.add("open"); });
    document.addEventListener("click", () => { closeAllMenus(); });
    colorMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        colorMode = item.dataset.color;
        closeAllMenus();
        render();
      });
    });
    sizeTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = sizeMenu.classList.contains("open"); closeAllMenus(); if (!open) sizeMenu.classList.add("open"); });
    sizeMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        sizeMode_value = item.dataset.size;
        closeAllMenus();
        render();
      });
    });
    nameTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = nameMenu.classList.contains("open"); closeAllMenus(); if (!open) nameMenu.classList.add("open"); });
    nameMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        nameMode = item.dataset.name;
        closeAllMenus();
        render();
      });
    });
    layoutTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = layoutMenu.classList.contains("open"); closeAllMenus(); if (!open) layoutMenu.classList.add("open"); });
    layoutMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        layoutMode = item.dataset.layout;
        closeAllMenus();
        render();
      });
    });
    currencyTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = currencyMenu.classList.contains("open"); closeAllMenus(); if (!open) currencyMenu.classList.add("open"); });
    currencyMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        currencyMode = item.dataset.currency;
        closeAllMenus();
        render();
      });
    });
    etfUnwrapBtn.addEventListener("click", () => {
      if (!lookthroughData) return;
      etfUnwrap = !etfUnwrap;
      etfUnwrapBtn.classList.toggle("active", etfUnwrap);
      render();
    });
    async function boot() {
      const [cc, s, lt] = await Promise.all([fetch("/api/command-center"), fetch("/api/portfolio/summary"), fetch("/api/etf-lookthrough?basis=market")]);
      if (!cc.ok) throw new Error(`HTTP ${cc.status}`);
      if (!s.ok) throw new Error(`HTTP ${s.status}`);
      const data = await cc.json();
      const summary = await s.json();
      fxToUsd = { USD: 1, GBP: Number(summary.report_fx_to_usd?.GBP || 1.346) };
      rawRows = data.holdings_heatmap?.rows || [];
      if (!rawRows.length) throw new Error("没有持仓热力图数据");
      if (lt.ok) lookthroughData = await lt.json();
      render();
    }
    async function refreshAndReload(button, label, url) {
      button.disabled = true;
      setStatus(`<div class="status-dot"></div> ${label}中...`);
      try {
        const r = await fetch(url, { method: "POST" });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const p = await r.json();
        if (p.refresh?.ok === false) throw new Error(p.refresh?.warning || "没有可用数据");
        await boot();
      } catch (e) {
        setStatus(`<div class="status-dot danger"></div> ${label}失败：${e.message}`);
        if (currentRows.length) {
          setTimeout(() => {
            setStatus('<div class="status-dot"></div> 已就绪', true);
          }, 2200);
        }
      }
      finally { button.disabled = false; }
    }
    refreshMarketButton.addEventListener("click", () => refreshAndReload(refreshMarketButton, "刷新行情", "/api/refresh/market?force=true"));
    refreshValuationButton.addEventListener("click", () => refreshAndReload(refreshValuationButton, "刷新估值", "/api/refresh/fundamentals?force=true"));
    refreshHoldingsButton.addEventListener("click", () => refreshAndReload(refreshHoldingsButton, "同步持仓", "/api/refresh/trading212"));
    boot().catch(error => {
      setStatus(`<div class="status-dot danger"></div> 加载失败：${error.message}`);
      heatmap.innerHTML = `<div style="color:#a9364b;font-weight:700;">${htmlEscape(error.message)}</div>`;
    });
  </script>
""",
            "/heatmap",
            get_lang(request),
        )
    )
