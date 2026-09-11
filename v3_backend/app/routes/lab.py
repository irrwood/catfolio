"""Portfolio landing page based on the compact Figma workspace."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from app.components import render_layout
from app.i18n import get_lang, t_block

router = APIRouter(tags=["pages"])

_HEAD = '<link rel="stylesheet" href="/static/portfolio.css" />'
_SCRIPTS = (
    '<script src="/static/vendor/echarts.min.js"></script>'
    '<script src="/static/portfolio.js"></script>'
    '<script src="/static/volatility.js"></script>'
    '<script src="/static/portfolio-calendar.js"></script>'
    '<script src="/static/portfolio-holdings.js"></script>'
)

_COMPONENT_DEMO_HEAD = (
    '<link rel="stylesheet" href="/static/portfolio.css" />'
    '<link rel="stylesheet" href="/static/analysis_charts.css" />'
    '<link rel="stylesheet" href="/static/component-demo.css" />'
)

_COMPONENT_DEMO_BODY = r"""
<main class="component-demo-workspace" id="componentDemo">
  <section class="component-demo-stage" aria-roledescription="carousel" aria-label="投资组合组件演示" tabindex="0">
    <button class="component-demo-arrow component-demo-arrow-prev" id="componentDemoPrev" type="button" aria-label="上一个组件">
      <img src="/static/icons/analytics/arrow-left.svg" alt="" />
    </button>

    <div class="component-demo-viewport" id="componentDemoViewport">
      <div class="component-demo-track">
        <article class="component-demo-slide is-active" data-demo-slide="0" aria-labelledby="costValueTitle">
          <section class="portfolio-value-card" aria-labelledby="costValueTitle">
            <div class="portfolio-chart-head">
              <div>
                <h2 id="costValueTitle">成本与市值对比</h2>
                <p>当前股票持仓的成本与历史市值（USD，不含账户现金）</p>
              </div>
            </div>
            <div class="portfolio-chart-body">
              <div id="costValueChart" class="portfolio-value-chart" role="img" aria-label="股票持仓成本与历史市值曲线，不含账户现金"></div>
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
          </section>
        </article>

        <article class="component-demo-slide" data-demo-slide="1" aria-labelledby="profitCalendarTitle" aria-hidden="true" inert>
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
        </article>

        <article class="component-demo-slide" data-demo-slide="2" aria-labelledby="drawdownTitle" aria-hidden="true" inert>
          <article class="analytics-card analytics-drawdown-card" aria-labelledby="drawdownTitle">
            <header>
              <div><h2 id="drawdownTitle">回撤水下曲线</h2><p id="drawdownMeta">最大回撤</p></div>
            </header>
            <div class="analytics-drawdown-body">
              <div class="analytics-chart is-loading" id="drawdownChart" role="img" aria-label="回撤水下曲线"></div>
              <div class="analytics-drawdown-ranges" role="group" aria-label="回撤图表时间范围">
                <button type="button" data-drawdown-range="1D" aria-pressed="false">1D</button>
                <button type="button" data-drawdown-range="1W" aria-pressed="false">1W</button>
                <button type="button" data-drawdown-range="1M" aria-pressed="false">1M</button>
                <button type="button" data-drawdown-range="3M" aria-pressed="false">3M</button>
                <button type="button" data-drawdown-range="YTD" aria-pressed="false">YTD</button>
                <button type="button" data-drawdown-range="1Y" aria-pressed="false">1Y</button>
                <button type="button" data-drawdown-range="MAX" class="active" aria-pressed="true">MAX</button>
              </div>
            </div>
          </article>
        </article>

        <article class="component-demo-slide" data-demo-slide="3" aria-labelledby="portfolioHoldingsTitle" aria-hidden="true" inert>
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
        </article>
      </div>
    </div>

    <button class="component-demo-arrow component-demo-arrow-next" id="componentDemoNext" type="button" aria-label="下一个组件">
      <img src="/static/icons/analytics/arrow-right.svg" alt="" />
    </button>
  </section>

  <footer class="component-demo-footer" aria-label="组件切换控制">
    <span class="component-demo-position" id="componentDemoPosition" aria-live="polite">01 / 04</span>
    <div class="component-demo-dots" id="componentDemoDots" role="tablist" aria-label="选择组件">
      <button class="active" type="button" role="tab" data-demo-go="0" aria-label="成本与市值对比" aria-selected="true"></button>
      <button type="button" role="tab" data-demo-go="1" aria-label="收益日历" aria-selected="false"></button>
      <button type="button" role="tab" data-demo-go="2" aria-label="回撤水下曲线" aria-selected="false"></button>
      <button type="button" role="tab" data-demo-go="3" aria-label="持仓明细" aria-selected="false"></button>
    </div>
    <span aria-hidden="true"></span>
  </footer>
</main>
"""
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

  <section class="v4-card"><h2>板块轮动</h2><p>观察 11 个美股板块的中期相对强弱与近月动量。</p><a href="/rotation">查看四象限与历史轨迹 →</a></section>
<section class="v4-card" aria-labelledby="todayInsightTitle"><h2 id="todayInsightTitle">Today Insight</h2><p id="today-volatility-insight" aria-live="polite">正在读取行业情绪…</p><a href="/sentiment">查看半导体 Fear &amp; Greed →</a></section>
  <div class="portfolio-insights-row">
    <section class="portfolio-value-card" aria-labelledby="costValueTitle">
      <div class="portfolio-chart-head">
        <div>
          <h2 id="costValueTitle">成本与市值对比</h2>
          <p>当前股票持仓的成本与历史市值（USD，不含账户现金）</p>
        </div>
      </div>
      <div class="portfolio-chart-body">
        <div id="costValueChart" class="portfolio-value-chart" role="img" aria-label="股票持仓成本与历史市值曲线，不含账户现金"></div>
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


@router.get("/lab/component-demo")
def component_demo_page(request: Request):
    """Render the isolated four-component Figma demo with local fake data."""
    lang = get_lang(request)
    html_lang = "en" if lang == "en" else "zh-CN"
    component_body = t_block(_COMPONENT_DEMO_BODY, lang)
    html = f"""<!doctype html>
<html lang="{html_lang}" class="light-theme">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="icon" href="data:," />
  <title>Catfolio component demo</title>
  <link rel="stylesheet" href="/static/design-system.css" />
  {_COMPONENT_DEMO_HEAD}
</head>
<body class="component-demo-page page-lab">
  {component_body}
  <p id="portfolioStatus" class="component-demo-status" role="status" aria-live="polite">正在读取组合数据</p>
  <div class="component-demo-status" aria-hidden="true">
    <span id="portfolioValue"></span><span id="portfolioToday"></span>
    <span id="portfolioPnl"></span><span id="portfolioPnlRate"></span>
    <span id="portfolioCount"></span><span id="portfolioBreadth"></span>
    <span id="portfolioTopFive"></span><span id="portfolioTopOne"></span>
  </div>
  <div id="analyticsStatus" class="component-demo-status" aria-live="polite"></div>
  <script src="/static/component-demo.js"></script>
  <script src="/static/vendor/echarts.min.js"></script>
  <script src="/static/portfolio.js"></script>
  <script src="/static/portfolio-calendar.js"></script>
  <script src="/static/portfolio-holdings.js"></script>
  <script src="/static/analysis_charts.js"></script>
</body>
</html>"""
    return HTMLResponse(
        html
    )
