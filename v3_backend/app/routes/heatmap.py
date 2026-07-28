"""Page route: Figma-aligned portfolio heatmap."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from app.components import render_layout
from app.i18n import get_lang


router = APIRouter(tags=["pages"])

_HEAD = '<link rel="stylesheet" href="/static/heatmap.css" />'
_SCRIPTS = (
    '<script src="/static/vendor/echarts.min.js"></script>'
    '<script src="/static/heatmap.js"></script>'
)

_BODY = r"""<div class="heatmap-page">
  <header class="heatmap-page-head">
    <h1>持仓热力图</h1>
    <span id="status" class="market-status-badge" aria-live="polite"><span class="status-dot"></span> 更新中...</span>
  </header>

  <div class="heatmap-controls">
    <div class="heatmap-filter-group">
      <div class="layout-dropdown" id="layoutDropdown">
        <div class="layout-dropdown-trigger" id="layoutTrigger" role="button" tabindex="0">
          <span id="layoutLabel">按大小</span><img class="arrow" src="/static/icons/portfolio-sort.svg" alt="" aria-hidden="true" />
        </div>
        <div class="layout-dropdown-menu" id="layoutMenu">
          <div class="group-label">布局</div>
          <div class="menu-item active" data-layout="size" data-label="按大小">按大小<span class="check">✓</span></div>
          <div class="menu-item" data-layout="sector" data-label="按板块">按板块<span class="check">✓</span></div>
        </div>
      </div>

      <div class="size-dropdown" id="sizeDropdown">
        <div class="size-dropdown-trigger" id="sizeTrigger" role="button" tabindex="0">
          <span id="sizeLabel">市值</span><img class="arrow" src="/static/icons/portfolio-sort.svg" alt="" aria-hidden="true" />
        </div>
        <div class="size-dropdown-menu" id="sizeMenu">
          <div class="group-label">大小</div>
          <div class="menu-item active" data-size="marketcap" data-label="市值">市值<span class="check">✓</span></div>
          <div class="menu-item" data-size="equal" data-label="相同大小">相同大小<span class="check">✓</span></div>
          <div class="divider"></div>
          <div class="group-label">成交量</div>
          <div class="menu-item" data-size="vol1d" data-label="成交量1天">成交量1天<span class="check">✓</span></div>
          <div class="menu-item" data-size="turnover1d" data-label="成交额1天">成交额1天<span class="check">✓</span></div>
        </div>
      </div>

      <div class="currency-dropdown" id="currencyDropdown">
        <div class="currency-dropdown-trigger" id="currencyTrigger" role="button" tabindex="0">
          <span id="currencyLabel">USD</span><img class="arrow" src="/static/icons/portfolio-sort.svg" alt="" aria-hidden="true" />
        </div>
        <div class="currency-dropdown-menu" id="currencyMenu">
          <div class="group-label">货币</div>
          <div class="menu-item active" data-currency="USD" data-label="USD">USD<span class="check">✓</span></div>
          <div class="menu-item" data-currency="GBP" data-label="GBP">GBP<span class="check">✓</span></div>
        </div>
      </div>

      <div class="name-dropdown" id="nameDropdown">
        <div class="name-dropdown-trigger" id="nameTrigger" role="button" tabindex="0">
          <span id="nameLabel">代码</span><img class="arrow" src="/static/icons/portfolio-sort.svg" alt="" aria-hidden="true" />
        </div>
        <div class="name-dropdown-menu" id="nameMenu">
          <div class="group-label">标签</div>
          <div class="menu-item active" data-name="ticker">代码<span class="check">✓</span></div>
          <div class="menu-item" data-name="logo">Logo + 代码<span class="check">✓</span></div>
        </div>
      </div>

      <div class="color-dropdown" id="colorDropdown">
        <div class="color-dropdown-trigger" id="colorTrigger" role="button" tabindex="0">
          <span class="heat-icon" aria-hidden="true"><span></span><span></span><span></span><span></span></span>
          <span id="colorLabel">涨跌1天, %</span><img class="arrow" src="/static/icons/portfolio-sort.svg" alt="" aria-hidden="true" />
        </div>
        <div class="color-dropdown-menu" id="colorMenu">
          <div class="group-label">涨跌</div>
          <div class="menu-item active" data-color="day" data-label="涨跌1天, %">涨跌1天, %<span class="check">✓</span></div>
          <div class="divider"></div>
          <div class="group-label">表现</div>
          <div class="menu-item" data-color="week" data-label="涨跌1周, %">1W<span class="check">✓</span></div>
          <div class="menu-item" data-color="month" data-label="涨跌1月, %">1M<span class="check">✓</span></div>
          <div class="menu-item" data-color="quarter" data-label="涨跌3月, %">3M<span class="check">✓</span></div>
          <div class="menu-item" data-color="halfyear" data-label="涨跌6月, %">6M<span class="check">✓</span></div>
          <div class="menu-item" data-color="ytd" data-label="今年以来 YTD, %">YTD<span class="check">✓</span></div>
          <div class="menu-item" data-color="year" data-label="涨跌1年, %">1Y<span class="check">✓</span></div>
          <div class="divider"></div>
          <div class="group-label">估值 &amp; 盈亏</div>
          <div class="menu-item" data-color="valuation" data-label="估值 P/E">估值 P/E<span class="check">✓</span></div>
          <div class="menu-item" data-color="pnl" data-label="浮动盈亏, %">浮动盈亏, %<span class="check">✓</span></div>
          <div class="menu-item" data-color="relvolume" data-label="相对成交量">相对成交量<span class="check">✓</span></div>
        </div>
      </div>
    </div>

    <div class="heatmap-action-group">
      <button id="fullscreenBtn" class="heatmap-scan-button" type="button" aria-label="切换全屏">
        <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-expand"></use></svg>
      </button>
      <div class="segmented heatmap-mode-switch" role="group" aria-label="持仓视图">
        <button id="rawHoldingsBtn" class="active" type="button" aria-pressed="true">原始持仓</button>
        <button id="etfUnwrapBtn" type="button" aria-pressed="false">ETF 穿透</button>
      </div>
    </div>
  </div>

  <div id="heatmap" role="img" aria-label="投资组合持仓热力图"></div>

  <div class="heatmap-hidden-control" hidden>
    <div id="legendBar" class="legend-bar"></div>
    <div id="legendLabels" class="legend-labels"></div>
    <div id="legendNote"></div>
  </div>
</div>

<div id="hoverCard" class="hover-card"></div>"""


@router.get("/heatmap")
def heatmap_page(request: Request):
    return HTMLResponse(
        render_layout(
            request,
            "持仓热力图",
            _BODY + _SCRIPTS,
            "/heatmap",
            get_lang(request),
            head_extra=_HEAD,
        )
    )
