"""Page route: cash-flow-matched benchmark comparison."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from app.components import render_layout
from app.i18n import get_lang


router = APIRouter(tags=["pages"])


@router.get("/returns")
def returns_page(request: Request):
    content = """<div class="returns-page comparison-page">
  <header class="comparison-head">
    <h1>收益对比</h1>
    <button id="aiReturnsBtn" class="comparison-ai-button" type="button" onclick="loadReturnsAI()">
      <span class="ai-action-icon comparison-ai-icon" aria-hidden="true"></span>
      <span>AI 解读</span>
    </button>
  </header>

  <div id="aiReturnsStatus" class="comparison-ai-status" aria-live="polite"></div>
  <section id="aiReturnsResult" class="comparison-ai-result" hidden>
    <button class="comparison-ai-close" type="button" aria-label="关闭 AI 解读" onclick="closeReturnsAI()">×</button>
    <div id="aiReturnsPeriod" class="comparison-ai-period"></div>
    <p id="aiReturnsText"></p>
  </section>

  <section class="comparison-metrics" aria-label="现金流匹配收益摘要">
    <article class="comparison-metric-card">
      <span class="comparison-metric-label">组合净值</span>
      <strong id="comparisonPortfolioReturn" class="comparison-metric-value">—</strong>
      <span class="comparison-metric-note positive">基准：SPY</span>
    </article>
    <article class="comparison-metric-card">
      <span class="comparison-metric-label">基准净值</span>
      <strong id="comparisonBenchmarkReturn" class="comparison-metric-value">—</strong>
      <span class="comparison-metric-note">SPY</span>
    </article>
  </section>

  <section class="comparison-chart-card">
    <header class="comparison-chart-head">
      <h2>现金流匹配对比</h2>
      <p>按实际交易重放现金流，将组合总价值与同金额投入基准的结果进行比较。</p>
    </header>

    <div class="comparison-chart-stage">
      <div id="returnsChart" role="img" aria-label="现金流匹配的组合与基准对比图"></div>
      <div id="comparisonEndLabels" class="comparison-end-labels" aria-hidden="true"></div>
      <div id="comparisonCrosshairDate" class="comparison-crosshair-date" hidden></div>
      <div id="comparisonCrosshairValue" class="comparison-crosshair-value" hidden></div>
      <div id="returnsChartEmpty" class="comparison-chart-empty" hidden>需要交易流水才能绘制对比。</div>
    </div>

    <nav class="comparison-ranges" aria-label="图表时间范围">
      <button type="button" data-range="1d" aria-pressed="false">1天</button>
      <button type="button" data-range="1w" aria-pressed="false">1周</button>
      <button type="button" data-range="1m" aria-pressed="false">1个月</button>
      <button type="button" class="active" data-range="3m" aria-pressed="true">3个月</button>
      <button type="button" data-range="ytd" aria-pressed="false">年初至今</button>
      <button type="button" data-range="1y" aria-pressed="false">1年</button>
      <button type="button" data-range="max" aria-pressed="false">全部</button>
    </nav>
  </section>
</div>

<script src="/static/vendor/lightweight-charts.standalone.production.js"></script>
<script src="/static/returns.js"></script>"""

    return HTMLResponse(
        render_layout(
            request,
            "收益对比",
            content,
            "/returns",
            get_lang(request),
            head_extra='<link rel="stylesheet" href="/static/returns.css" />',
        )
    )
