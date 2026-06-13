"""Page route: backtest — HTML body only; CSS/JS in static/backtest.css and static/backtest.js."""
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from app.components import wrap_v4_layout
from app.i18n import get_lang

router = APIRouter(tags=["pages"])

_HEAD = '<link rel="stylesheet" href="/static/backtest.css" />'
_SCRIPTS = '<script src="/static/vendor/echarts.min.js"></script><script src="/static/backtest.js"></script>'

_BODY = r"""<div class="v4-hero">
  <div class="v4-hero-text">
    <h1>回测与优化</h1>
    <p>历史策略回测、有效前沿、蒙特卡洛模拟、因子暴露与组合优化建议。所有分析均基于当前持仓权重的模型回看，非真实账户现金流收益。</p>
  </div>
  <div style="display:flex;gap:8px;align-items:center;">
    <div id="btStatus" class="btn" style="pointer-events:none;color:var(--muted);font-size:12px;">点击刷新加载数据</div>
    <button id="btRefreshBtn" class="btn primary" onclick="loadBacktest()"><i class="fa-solid fa-arrows-rotate"></i> 刷新数据</button>
    <button id="aiAnalyzeBtn" class="btn primary" onclick="loadAiAnalysis()"><i class="fa-solid fa-robot"></i> AI 分析</button>
    <a class="btn" href="/lab"><i class="fa-solid fa-flask"></i> Portfolio Lab</a>
  </div>
</div>

<div class="dashboard-stack">

<section class="panel">
    <h2>今天先回答这 4 个问题</h2>
    <div class="question-grid">
        <div class="question-card"><span>历史回测</span><b>过去这套组合跑得怎么样？</b><p id="backtestTakeaway">等待历史净值...</p></div>
        <div class="question-card"><span>组合优化</span><b>优化真的值得换仓吗？</b><p id="frontierTakeaway">等待有效前沿...</p></div>
        <div class="question-card"><span>蒙特卡洛</span><b>未来结果的区间有多宽？</b><p id="monteTakeaway">等待模拟...</p></div>
        <div class="question-card"><span>因子分析</span><b>组合主要像什么因子？</b><p id="factorTakeaway">等待因子分析...</p></div>
    </div>
</section>

<section id="aiComparisonSection" class="panel" style="display:none;">
    <h2><i class="fa-solid fa-robot"></i> AI 分析对比 <span style="font-size:12px;color:var(--muted);font-weight:400;">程序结论 vs AI 独立解读</span></h2>
    <div class="ai-compare-grid">
        <div class="ai-compare-card" id="aiBacktestCard">
            <div class="ai-compare-head"><span>历史回测</span></div>
            <div class="ai-compare-body">
                <div class="ai-col"><div class="ai-col-label">程序</div><p id="aiProgBacktest"></p></div>
                <div class="ai-col"><div class="ai-col-label">AI</div><p id="aiAiBacktest"></p></div>
            </div>
        </div>
        <div class="ai-compare-card" id="aiFrontierCard">
            <div class="ai-compare-head"><span>组合优化</span></div>
            <div class="ai-compare-body">
                <div class="ai-col"><div class="ai-col-label">程序</div><p id="aiProgFrontier"></p></div>
                <div class="ai-col"><div class="ai-col-label">AI</div><p id="aiAiFrontier"></p></div>
            </div>
        </div>
        <div class="ai-compare-card" id="aiMonteCarloCard">
            <div class="ai-compare-head"><span>蒙特卡洛</span></div>
            <div class="ai-compare-body">
                <div class="ai-col"><div class="ai-col-label">程序</div><p id="aiProgMonteCarlo"></p></div>
                <div class="ai-col"><div class="ai-col-label">AI</div><p id="aiAiMonteCarlo"></p></div>
            </div>
        </div>
        <div class="ai-compare-card" id="aiFactorCard">
            <div class="ai-compare-head"><span>因子分析</span></div>
            <div class="ai-compare-body">
                <div class="ai-col"><div class="ai-col-label">程序</div><p id="aiProgFactors"></p></div>
                <div class="ai-col"><div class="ai-col-label">AI</div><p id="aiAiFactors"></p></div>
            </div>
        </div>
    </div>
    <div class="ai-review-box" id="aiReviewBox" style="display:none;">
        <div class="ai-review-head"><i class="fa-solid fa-comment-dots"></i> AI 对程序结论的评议</div>
        <p id="aiReviewText"></p>
    </div>
</section>

<div class="layout">
    <div class="stack">

        <section class="panel">
            <div class="chart-head"><h2>历史回测</h2><span>组合 vs 基准</span></div>
            <div id="backtestChart" class="chart"></div>
        </section>

        <section id="rebuild" class="panel">
            <div class="frontier-lab">
                <div class="chart-head"><h2>组合重建</h2><span>如果今天重建组合，哪些该加，哪些该减</span></div>
                <div class="frontier-summary">
                    <div class="score-card">
                        <div class="label">组合健康分</div>
                        <div id="overallScore" class="score">—</div>
                        <div class="score-caption">基于收益、风险和分散度的综合评分</div>
                    </div>
                    <div class="score-grid">
                        <div class="score-mini"><div class="label">收益评分</div><b id="returnScore">—</b></div>
                        <div class="score-mini"><div class="label">风险评分</div><b id="riskScore">—</b></div>
                        <div class="score-mini"><div class="label">分散度</div><b id="diversificationScore">—</b></div>
                    </div>
                </div>
                <div class="insight-strip">
                    <div class="insight"><span>我的组合</span><b id="betterThanText">等待优化结果...</b></div>
                    <div class="insight"><span>潜在改进空间</span><b id="improvementText">等待优化结果...</b></div>
                    <div class="insight"><span>风险水平</span><b id="riskLevelText">等待优化结果...</b></div>
                </div>
                <div class="preference">
                    <div class="preference-head"><b>风险偏好</b><span id="riskMode">均衡</span></div>
                    <div class="risk-tabs">
                        <button class="risk-tab btn" type="button" data-risk="0">保守</button>
                        <button class="risk-tab btn active" type="button" data-risk="1">均衡</button>
                        <button class="risk-tab btn" type="button" data-risk="2">激进</button>
                    </div>
                    <input id="riskPreference" class="risk-slider" type="range" min="0" max="2" step="1" value="1" />
                    <div class="slider-labels"><span>保守</span><span>均衡</span><span>激进</span></div>
                    <div class="preference-metrics">
                        <div class="preference-metric"><div class="label">预期收益变化</div><b id="targetReturn">—</b></div>
                        <div class="preference-metric"><div class="label">预期波动变化</div><b id="targetVolatility">—</b></div>
                        <div class="preference-metric"><div class="label">夏普改善</div><b id="targetSharpeDelta">—</b></div>
                    </div>
                </div>
                <div id="frontierChart" class="chart"></div>
                <div class="optimization-grid">
                    <div>
                        <h2>优化建议</h2>
                        <table class="allocation-table">
                            <thead><tr><th>持仓</th><th>当前</th><th>建议</th><th>变化</th></tr></thead>
                            <tbody id="allocationRows"></tbody>
                        </table>
                    </div>
                    <div class="why-list">
                        <div class="why-block"><b>组合效率主要贡献者</b><div id="contributorList" class="pill-list"></div></div>
                        <div class="why-block"><b>最大风险集中源</b><div id="riskConcentratorList" class="pill-list"></div></div>
                    </div>
                </div>
            </div>
        </section>

        <section id="risk-model" class="panel">
            <div class="chart-head"><h2>蒙特卡洛</h2><span>分位数区间 · 固定种子</span></div>
            <div id="monteCarloChart" class="chart"></div>
        </section>

    </div>

    <aside class="stack">

        <section class="panel">
            <h2>决策摘要</h2>
            <div class="brief">
                <div id="briefRisk" class="brief-line">正在生成风险摘要...</div>
                <div id="briefOptimization" class="brief-line">正在比较优化组合...</div>
                <div id="briefMonteCarlo" class="brief-line">正在读取未来分布...</div>
            </div>
        </section>

        <section class="panel">
            <h2>因子分析</h2>
            <div id="factorChart" class="small-chart"></div>
            <table>
                <thead><tr><th>因子</th><th>Beta</th><th>相关</th></tr></thead>
                <tbody id="factorRows"></tbody>
            </table>
        </section>

        <section class="panel">
            <h2>优化组合</h2>
            <table>
                <thead><tr><th>组合</th><th>收益</th><th>波动</th><th>Sharpe</th></tr></thead>
                <tbody id="optRows"></tbody>
            </table>
            <div id="weightList" class="weight-list"></div>
        </section>

    </aside>
</div>

</div>"""


@router.get("/backtest")
def backtest_page(request: Request):
    return HTMLResponse(
        wrap_v4_layout("回测与优化", _BODY + _SCRIPTS, "/backtest", get_lang(request), head_extra=_HEAD)
    )
