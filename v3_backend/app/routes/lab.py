"""Portfolio landing page based on the compact Figma workspace."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from app.components import render_layout
from app.i18n import get_lang

router = APIRouter(tags=["pages"])

_HEAD = '<link rel="stylesheet" href="/static/portfolio.css" />'
_SCRIPTS = (
    '<script src="/static/vendor/echarts.min.js"></script>'
    '<script src="/static/portfolio.js"></script>'
    '<script src="/static/portfolio-calendar.js"></script>'
    '<script src="/static/portfolio-holdings.js"></script>'
)
_BODY = r"""
<main class="portfolio-workspace">
  <header class="portfolio-page-head">
    <h1>Catfolio</h1>
    <p id="portfolioStatus" class="portfolio-visually-hidden" role="status" aria-live="polite">正在读取组合数据</p>
  </header>

  <section class="portfolio-metrics" aria-label="组合核心概览">
    <article class="portfolio-metric-card">
      <span>总市值</span>
      <strong id="portfolioValue">—</strong>
      <small id="portfolioToday">—</small>
    </article>
    <article class="portfolio-metric-card">
      <span>未实现盈亏</span>
      <strong id="portfolioPnl">—</strong>
      <small id="portfolioPnlRate">—</small>
    </article>
    <article class="portfolio-metric-card">
      <span>持仓数</span>
      <strong id="portfolioCount">—</strong>
      <small id="portfolioBreadth">—</small>
    </article>
    <article class="portfolio-metric-card">
      <span>前五大仓位</span>
      <strong id="portfolioTopFive">—</strong>
      <small id="portfolioTopOne">—</small>
    </article>
  </section>

  <div class="portfolio-insights-row">
    <section class="portfolio-value-card" aria-labelledby="costValueTitle">
      <div class="portfolio-chart-head">
        <div>
          <h2 id="costValueTitle">成本与市值对比</h2>
          <p>净投入成本与当前总市值（USD）</p>
        </div>
      </div>
      <div class="portfolio-chart-body">
        <div id="costValueChart" class="portfolio-value-chart" role="img" aria-label="净投入成本与当前总市值折线图"></div>
        <div class="portfolio-ranges" role="group" aria-label="图表时间范围">
          <button type="button" data-range="1d" aria-pressed="false">1D</button>
          <button type="button" data-range="1w">1W</button>
          <button type="button" data-range="1m">1M</button>
          <button type="button" class="active" data-range="3m" aria-pressed="true">3M</button>
          <button type="button" data-range="ytd">YTD</button>
          <button type="button" data-range="1y">1Y</button>
          <button type="button" data-range="max">MAX</button>
        </div>
      </div>
      <div class="portfolio-chart-legend" aria-label="图表图例">
        <span><i class="market"></i>当前总市值</span>
        <span><i class="cost"></i>净投入成本</span>
      </div>
    </section>

    <article class="portfolio-profit-calendar-card" aria-labelledby="profitCalendarTitle">
      <header class="profit-calendar-head">
        <h2 id="profitCalendarTitle">收益日历</h2>
        <div class="profit-calendar-controls">
          <div class="profit-calendar-range" role="group" aria-label="日历范围">
            <button class="profit-calendar-range-button active" id="profitCalendarDay" type="button" aria-pressed="true" title="查看当月每日盈亏">D</button>
            <button class="profit-calendar-range-button" id="profitCalendarMonth" type="button" aria-pressed="false" title="查看全年逐月盈亏">M</button>
            <button class="profit-calendar-range-button" id="profitCalendarYear" type="button" aria-pressed="false" title="查看全年每日盈亏">Y</button>
          </div>
          <div class="profit-calendar-period-nav">
            <button id="profitCalendarPrev" type="button" aria-label="上一个周期"><img src="/static/icons/analytics/arrow-left.svg" alt="" /></button>
            <span id="profitCalendarPeriod" aria-live="polite"><span id="profitCalendarPeriodMonth">—</span><span id="profitCalendarPeriodYear">—</span></span>
            <button id="profitCalendarNext" type="button" aria-label="下一个周期"><img src="/static/icons/analytics/arrow-right.svg" alt="" /></button>
          </div>
        </div>
      </header>
      <div class="profit-calendar-body">
        <div class="profit-calendar-weekdays" id="profitCalendarWeekdays" aria-hidden="true"></div>
        <div class="profit-calendar-grid is-loading" id="profitCalendarGrid" role="grid" aria-label="每日投资组合盈亏"></div>
      </div>
      <footer class="profit-calendar-summary">
        <div class="profit-calendar-summary-item">
          <img src="/static/icons/analytics/dividend.svg" alt="" />
          <span class="profit-calendar-summary-label">股息</span>
          <strong id="profitCalendarDividends">+$0.00</strong>
          <span class="profit-calendar-summary-period">本月</span>
        </div>
        <div class="profit-calendar-summary-item">
          <img src="/static/icons/analytics/cash-interest.svg" alt="" />
          <span class="profit-calendar-summary-label">现金利息</span>
          <strong id="profitCalendarInterest">+$0.00</strong>
          <span class="profit-calendar-summary-period">本月</span>
        </div>
      </footer>
    </article>
  </div>

  <section class="portfolio-holdings-card" aria-labelledby="portfolioHoldingsTitle">
    <header class="portfolio-holdings-head">
      <div class="portfolio-holdings-title">
        <h2 id="portfolioHoldingsTitle">持仓明细</h2>
        <p id="portfolioHoldingsMeta" aria-live="polite">正在读取持仓…</p>
      </div>
      <div class="portfolio-holdings-mode" role="tablist" aria-label="持仓视图">
        <button class="active" type="button" role="tab" aria-selected="true" data-portfolio-holdings-mode="direct">原始持仓</button>
        <button type="button" role="tab" aria-selected="false" data-portfolio-holdings-mode="lookthrough">ETF 穿透</button>
      </div>
    </header>

    <div class="portfolio-holdings-scroll" tabindex="0" aria-label="持仓明细列表">
      <table class="portfolio-holdings-table">
        <thead id="portfolioHoldingsHead"></thead>
        <tbody id="portfolioHoldingsRows">
          <tr class="portfolio-holdings-message"><td>正在读取持仓…</td></tr>
        </tbody>
      </table>
    </div>
  </section>
</main>
"""


@router.get("/lab")
def lab_page(request: Request):
    return HTMLResponse(
        render_layout(request, "Portfolio", _BODY + _SCRIPTS, "/lab", get_lang(request), head_extra=_HEAD)
    )
