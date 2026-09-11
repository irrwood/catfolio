"""Dedicated portfolio analytics charts page."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from app.components import render_layout
from app.data_store import demo_mode
from app.i18n import get_lang
from app.routes.backtest import _BODY as _BACKTEST_BODY

router = APIRouter(tags=["pages"])

_HEAD = (
    '<link rel="stylesheet" href="/static/analysis_charts.css" />'
    '<link rel="stylesheet" href="/static/backtest.css" />'
)
_SCRIPTS = (
    '<script src="/static/vendor/echarts.min.js"></script>'
    '<script src="/static/analysis_charts.js"></script>'
    '<script src="/static/backtest.js"></script>'
)

_BODY = r"""
<div class="analytics-page">
  <header class="analytics-head">
    <div>
      <h1>分析图表</h1>
      <p id="analyticsRange">正在加载</p>
    </div>
    <button class="btn analytics-refresh" id="analyticsRefresh" type="button">
      <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-refresh"></use></svg>
      <span>刷新</span>
    </button>
  </header>

  <div class="analytics-status" id="analyticsStatus" aria-live="polite"></div>

  <section class="analytics-grid" aria-label="分析图表">
    <div class="analytics-figma-charts">
      <article class="analytics-card analytics-drawdown-card">
        <header>
          <div><h2>回撤水下曲线</h2><p id="drawdownMeta">最大回撤</p></div>
          <a class="analytics-ai-link" href="/ai" aria-label="用 AI 解读回撤水下曲线" title="AI 解读">
            <span class="ai-action-icon" aria-hidden="true"></span>
          </a>
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

      <article class="analytics-card analytics-valuation-card">
        <header>
          <div><h2>估值矩阵 (P/E vs 成长)</h2><p>气泡大小 = 仓位权重</p></div>
          <a class="analytics-ai-link" href="/ai" aria-label="用 AI 解读估值矩阵" title="AI 解读">
            <span class="ai-action-icon" aria-hidden="true"></span>
          </a>
          <div class="analytics-valuation-actions">
            <button class="btn analytics-valuation-details" id="valuationTableToggle" type="button" aria-expanded="false" aria-controls="valuationTablePanel">展开明细</button>
            <button class="btn analytics-valuation-refresh" id="valuationRefresh" type="button">刷新估值</button>
          </div>
        </header>
        <div class="analytics-valuation-chart-wrap">
          <div class="analytics-chart valuation-matrix-chart is-loading" id="valuationMatrixChart" role="img" aria-label="估值矩阵 (P/E vs 成长)"></div>
        </div>
        <div class="valuation-table-wrap" id="valuationTablePanel" tabindex="0" aria-label="持仓估值明细" hidden>
          <table class="valuation-table">
            <thead id="valuationTableHead"></thead>
            <tbody id="valuationTableBody">
              <tr><td class="valuation-table-empty">正在加载估值数据…</td></tr>
            </tbody>
          </table>
        </div>
      </article>
    </div>

    <article class="analytics-card">
      <header>
        <div><h2>月度收益热图</h2><p id="monthlyReturnMeta">年 × 月盈亏%</p></div>
      </header>
      <div class="analytics-chart is-loading" id="monthlyReturnsChart" role="img" aria-label="月度收益热图"></div>
    </article>

    <article class="analytics-card">
      <header>
        <div><h2>收益率分布</h2><p id="distributionMeta">模型日收益</p></div>
      </header>
      <div class="analytics-chart is-loading" id="distributionChart" role="img" aria-label="收益率分布"></div>
    </article>

    <article class="analytics-card analytics-wide">
      <header>
        <div><h2>持仓相关性矩阵</h2><p>颜色越深，越容易同涨同跌</p></div>
      </header>
      <div class="analytics-chart analytics-correlation is-loading" id="correlationChart" role="img" aria-label="持仓相关性矩阵"></div>
    </article>

    <article class="analytics-card analytics-wide">
      <header>
        <div><h2>模型归因 Waterfall</h2><p id="waterfallMeta">模型口径 · 当月权重收益%（非真实盈亏）</p></div>
      </header>
      <div class="analytics-chart is-loading" id="waterfallChart" role="img" aria-label="模型归因 Waterfall"></div>
    </article>
  </section>

  <section class="analytics-backtest-section" id="backtest-optimize" aria-label="回测与优化">
    """ + _BACKTEST_BODY + r"""
  </section>
</div>
"""


@router.get("/analytics")
def analysis_charts_page(request: Request):
    lang = get_lang(request)
    demo_flag = '<script>window.CATFOLIO_DEMO = true;</script>' if demo_mode() else ""
    return HTMLResponse(
        render_layout(
            request,
            "分析图表",
            _BODY + demo_flag + _SCRIPTS,
            "/analytics",
            lang,
            head_extra=_HEAD,
        )
    )
