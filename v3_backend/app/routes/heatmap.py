"""Page route: heatmap — HTML body only; CSS/JS in static/heatmap.css and static/heatmap.js."""
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from app.components import wrap_v4_layout
from app.i18n import get_lang

router = APIRouter(tags=["pages"])

_HEAD = '<link rel="stylesheet" href="/static/heatmap.css" />'
_SCRIPTS = (
    '<script src="/static/vendor/echarts.min.js"></script>'
    '<script src="/static/heatmap.js"></script>'
)

_BODY = r"""<div class="v4-card" style="padding:16px;display:flex;flex-direction:column;gap:12px;">
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

<div id="hoverCard" class="hover-card"></div>"""


@router.get("/heatmap")
def heatmap_page(request: Request):
    return HTMLResponse(
        wrap_v4_layout("持仓热力图", _BODY + _SCRIPTS, "/heatmap", get_lang(request), head_extra=_HEAD)
    )
