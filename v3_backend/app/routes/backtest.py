"""Page route: backtest."""
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from app.components import wrap_v4_layout
from app.i18n import get_lang
from app.data_store import current_snapshot
from app.lab import lab_history_summary

router = APIRouter(tags=["pages"])


@router.get("/backtest")
def backtest_page(request: Request):
    content = """<div class="v4-hero">
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

</div>

<script src="/static/vendor/echarts.min.js"></script>
<script>
    const fmtPct = value => `${(Number(value || 0) * 100).toFixed(1)}%`;
    const fmtNum = value => Number(value || 0).toFixed(2);
    const btStatus = document.querySelector("#btStatus");
    const backtestTakeaway = document.querySelector("#backtestTakeaway");
    const frontierTakeaway = document.querySelector("#frontierTakeaway");
    const monteTakeaway = document.querySelector("#monteTakeaway");
    const factorTakeaway = document.querySelector("#factorTakeaway");
    const briefRisk = document.querySelector("#briefRisk");
    const briefOptimization = document.querySelector("#briefOptimization");
    const briefMonteCarlo = document.querySelector("#briefMonteCarlo");
    const factorRows = document.querySelector("#factorRows");
    const weightList = document.querySelector("#weightList");
    const overallScore = document.querySelector("#overallScore");
    const returnScore = document.querySelector("#returnScore");
    const riskScore = document.querySelector("#riskScore");
    const diversificationScore = document.querySelector("#diversificationScore");
    const betterThanText = document.querySelector("#betterThanText");
    const improvementText = document.querySelector("#improvementText");
    const riskLevelText = document.querySelector("#riskLevelText");
    const riskPreference = document.querySelector("#riskPreference");
    const riskMode = document.querySelector("#riskMode");
    const targetReturn = document.querySelector("#targetReturn");
    const targetVolatility = document.querySelector("#targetVolatility");
    const targetSharpeDelta = document.querySelector("#targetSharpeDelta");
    const allocationRows = document.querySelector("#allocationRows");
    const contributorList = document.querySelector("#contributorList");
    const riskConcentratorList = document.querySelector("#riskConcentratorList");
    const riskTabs = Array.from(document.querySelectorAll(".risk-tab"));

    const chartById = new Map();
    const chartInstances = [];
    let helmThemeRegistered = false;
    function ensureHelmTheme() {
        // ECharts' default splitLine "#E0E6F1" is near-white (built for light backgrounds).
        // Charts that override yAxis without re-setting splitLine fall back to it, giving
        // glaring white gridlines on the dark theme. Register a theme whose default axis/
        // grid lines are semi-transparent grey — subtle on both dark and light backgrounds.
        if (helmThemeRegistered || !window.echarts) return;
        const axisDef = {
            axisLine: { lineStyle: { color: "rgba(128,128,128,0.28)" } },
            splitLine: { lineStyle: { color: "rgba(128,128,128,0.14)" } },
        };
        window.echarts.registerTheme("helm", { categoryAxis: axisDef, valueAxis: axisDef });
        helmThemeRegistered = true;
    }
    function isDark() { return !document.documentElement.classList.contains('light-theme'); }
    function chart(id) {
        const node = document.querySelector(id);
        if (!node) return { setOption() {}, resize() {} };
        if (chartById.has(id)) return chartById.get(id);
        ensureHelmTheme();
        const instance = window.echarts.init(node, "helm");
        chartInstances.push(instance);
        chartById.set(id, instance);
        return instance;
    }
    window.addEventListener("resize", () => { chartInstances.forEach(i => i.resize()); });

    const fmtPctVal = v => (v != null ? (v * 100).toFixed(1) + '%' : '');
    function clamp(value, min, max) { return Math.max(min, Math.min(max, value)); }
    function scorePct(value) { return `${Math.round(clamp(value, 0, 100))}`; }
    function riskLabel(volatility) {
        if (volatility < 0.13) return "低"; if (volatility < 0.22) return "中"; return "高";
    }
    function percentileRank(points, value, key, higherBetter = true) {
        const rows = (points || []).filter(row => Number.isFinite(Number(row[key])));
        if (!rows.length) return 0;
        const better = rows.filter(row => higherBetter ? Number(row[key]) <= value : Number(row[key]) >= value).length;
        return better / rows.length * 100;
    }
    function effectiveDiversification(weights) {
        const values = Object.values(weights || {});
        const concentration = values.reduce((sum, w) => sum + w * w, 0);
        return concentration ? 1 / concentration : 0;
    }
    function pickTargets(frontier) {
        const points = frontier.points || [];
        const maxReturn = points.reduce((best, p) => !best || p.annual_return > best.annual_return ? p : best, null);
        return [
            { mode: "保守", label: "最低风险", row: frontier.optimized?.min_volatility },
            { mode: "均衡", label: "最佳风险收益", row: frontier.optimized?.max_sharpe },
            { mode: "激进", label: "最高收益", row: maxReturn || frontier.optimized?.max_sharpe },
        ];
    }
    function renderPills(node, items) {
        node.innerHTML = (items || []).length ? items.map(item => `<span class="pill">${item}</span>`).join("") : `<span class="pill">无明显信号</span>`;
    }
    async function getJson(url) { const res = await fetch(url); if (!res.ok) throw new Error(`HTTP ${res.status}`); return res.json(); }
    function baseOption() {
        const L = document.documentElement.classList.contains("light-theme");
        const c = {
            bg: "transparent",
            tooltipBg: L ? "rgba(255,255,255,.96)" : "rgba(10,14,18,.96)",
            tooltipBorder: L ? "rgba(0,0,0,0.08)" : "rgba(255,255,255,0.08)",
            tooltipText: L ? "#111113" : "#ededef",
            axis: L ? "#6b7280" : "#707580",
            axisLine: L ? "#d1d5db" : "rgba(255,255,255,0.06)",
            splitLine: L ? "#e5e7eb" : "rgba(255,255,255,0.05)",
            text: L ? "#374151" : "#9ca3af",
        };
        return {
            backgroundColor: c.bg,
            tooltip: { trigger: "axis", backgroundColor: c.tooltipBg, borderColor: c.tooltipBorder, textStyle: { color: c.tooltipText } },
            grid: { left: 54, right: 18, top: 30, bottom: 42 },
            xAxis: { axisLine: { lineStyle: { color: c.axisLine } }, axisLabel: { color: c.axis }, splitLine: { show: false } },
            yAxis: { splitLine: { lineStyle: { color: c.splitLine } }, axisLabel: { color: c.axis } },
        };
    }

    const BT_CACHE_KEY = "bt_cache_v2";
    function fmtCacheAge(ts) { const s = Math.round((Date.now() - ts) / 1000); return s < 60 ? `${s}秒前` : s < 3600 ? `${Math.floor(s/60)}分钟前` : `${Math.floor(s/3600)}小时前`; }

    async function loadBacktest(cachedData) {
        const isLight = document.documentElement.classList.contains("light-theme");
        btStatus.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> 正在加载...`;
        let history, frontier, monteCarlo, factors, backtest;
        try {
            if (cachedData) {
                ({ history, frontier, monteCarlo, factors, backtest } = cachedData);
            } else {
                [history, frontier, monteCarlo, factors, backtest] = await Promise.all([
                    getJson("/api/lab/history"),
                    getJson("/api/lab/efficient-frontier"),
                    getJson("/api/lab/monte-carlo?years=5&paths=500"),
                    getJson("/api/lab/factor-analysis"),
                    getJson("/api/lab/backtest"),
                ]);
            }

            const stats = history.stats || {};
            const currentWeights = history.weights || {};
            const targets = pickTargets(frontier);
            const currentPortfolio = frontier.optimized?.current || stats;
            const pct = monteCarlo.final_percentiles || {};
            const navDays = history.nav?.length || backtest.portfolio?.nav?.length || 0;
            const fRows = factors.rows || [];
            const topFactor = fRows[0];

            const returnRank = percentileRank(frontier.points, currentPortfolio.annual_return, "annual_return", true);
            const riskRank = percentileRank(frontier.points, currentPortfolio.annual_volatility, "annual_volatility", false);
            const sharpeRank = percentileRank(frontier.points, currentPortfolio.sharpe, "sharpe", true);
            const diversification = effectiveDiversification(currentWeights);
            const diversificationRank = clamp(diversification / 12 * 100, 0, 100);
            const overall = returnRank * 0.35 + riskRank * 0.35 + diversificationRank * 0.30;
            const similarRisk = (frontier.points || []).filter(p => p.annual_volatility <= currentPortfolio.annual_volatility * 1.05);
            const bestSimilarRisk = similarRisk.reduce((best, p) => !best || p.annual_return > best.annual_return ? p : best, null);
            const improvement = bestSimilarRisk ? bestSimilarRisk.annual_return - currentPortfolio.annual_return : 0;
            const maxSharpe = frontier.optimized?.max_sharpe;

            // — 4 question takeaways —
            backtestTakeaway.textContent = `共同样本 ${navDays} 个交易日，组合年化 ${fmtPct(stats.annual_return)}，最大回撤 ${fmtPct(stats.max_drawdown)}。`;
            frontierTakeaway.textContent = maxSharpe ? `你的组合好于约 ${Math.round(sharpeRank)}% 的模拟组合。若按同等风险重建，潜在收益改善约 ${fmtPct(improvement)}。` : "有效前沿样本不足。";
            monteTakeaway.textContent = pct.p50 ? `5 年模拟中位数约 ${fmtNum(pct.p50)}x，悲观 p5 约 ${fmtNum(pct.p5)}x。` : "蒙特卡洛样本不足。";
            factorTakeaway.textContent = topFactor ? `最接近 ${topFactor.factor}，beta ${fmtNum(topFactor.beta)}，相关 ${fmtNum(topFactor.correlation)}。` : "因子样本不足。";

            // — Decision Brief —
            briefRisk.innerHTML = `<b>风险：</b>年化波动 ${fmtPct(stats.annual_volatility)}，最大回撤 ${fmtPct(stats.max_drawdown)}。`;
            briefOptimization.innerHTML = maxSharpe ? `<b>优化：</b>当前健康分 ${scorePct(overall)}/100。均衡目标收益 ${fmtPct(maxSharpe.annual_return)}，波动 ${fmtPct(maxSharpe.annual_volatility)}。` : `<b>优化：</b>当前数据不足，暂时不建议根据优化器调仓。`;
            briefMonteCarlo.innerHTML = pct.p50 ? `<b>未来分布：</b>p5 ${fmtNum(pct.p5)}x / p50 ${fmtNum(pct.p50)}x / p95 ${fmtNum(pct.p95)}x。` : `<b>未来分布：</b>等待更多历史价格。`;

            // — Health scores —
            overallScore.textContent = scorePct(overall);
            returnScore.textContent = scorePct(returnRank);
            riskScore.textContent = scorePct(riskRank);
            diversificationScore.textContent = scorePct(diversificationRank);
            betterThanText.textContent = `优于 ${Math.round(sharpeRank)}% 的模拟组合`;
            improvementText.textContent = improvement > 0 ? `潜在改进：同等风险下收益 +${fmtPct(improvement)}` : `当前收益在同等风险水平下已较优`;
            riskLevelText.textContent = `${riskLabel(currentPortfolio.annual_volatility)}风险 · ${fmtPct(currentPortfolio.annual_volatility)} 年化波动`;

            // — Backtesting chart —
            chart("#backtestChart").setOption({
                ...baseOption(),
                color: ['#27a648', '#3b82f6', '#f97316', '#8b5cf6'],
                legend: { bottom: 0, textStyle: { color: isLight ? "#374151" : "#9ca3af" } },
                grid: { left: 54, right: 18, top: 18, bottom: 48 },
                xAxis: { type: "category", data: (backtest.portfolio?.nav || []).map(r => r.date), axisLabel: { hideOverlap: true } },
                yAxis: { type: "value", axisLabel: { formatter: v => v.toFixed(2) + 'x' } },
                series: [
                    { name: "Portfolio", type: "line", showSymbol: false, lineStyle: { width: 2.2 }, data: (backtest.portfolio?.nav || []).map(r => r.nav) },
                    ...(backtest.benchmarks || []).filter(b => b && Array.isArray(b.nav)).map(b => ({
                        name: b.symbol, type: "line", showSymbol: false,
                        lineStyle: { width: 1.5, opacity: 0.75 },
                        data: b.nav.map(r => r.nav)
                    }))
                ]
            }, true);

            // — Efficient Frontier chart —
            chart("#frontierChart").setOption({
                ...baseOption(),
                color: [isLight ? "#9ca3af" : "#707580", "#3b82f6", "#27a648", "#f97316"],
                legend: { bottom: 0, textStyle: { color: isLight ? "#374151" : "#9ca3af" } },
                grid: { left: 58, right: 18, top: 18, bottom: 58 },
                tooltip: { trigger: "item", formatter: params => {
                    const v = params.value || [];
                    return `${params.seriesName}<br/>波动率：${fmtPctVal(v[0])}<br/>年化收益：${fmtPctVal(v[1])}${v[2] !== undefined ? '<br/>Sharpe：'+fmtNum(v[2]) : ''}`;
                }},
                xAxis: { type: "value", name: "波动率", nameLocation: "middle", nameGap: 32, axisLabel: { formatter: v => (v*100).toFixed(0)+'%' } },
                yAxis: { type: "value", name: "年化收益", nameLocation: "middle", nameGap: 42, axisLabel: { formatter: v => (v*100).toFixed(0)+'%' } },
                series: [
                    { name: "Simulated portfolios", type: "scatter", symbolSize: 5, itemStyle: { opacity: 0.18 }, data: (frontier.points || []).map(p => [p.annual_volatility, p.annual_return, p.sharpe]) },
                    { name: "My Portfolio", type: "scatter", symbolSize: 22, label: { show: true, formatter: "My Portfolio", position: "top", fontWeight: 700 }, data: currentPortfolio?.annual_volatility !== undefined ? [[currentPortfolio.annual_volatility, currentPortfolio.annual_return, currentPortfolio.sharpe]] : [] },
                    { name: "最佳风险收益", type: "scatter", symbolSize: 18, label: { show: true, formatter: "最佳风险收益", position: "right" }, data: frontier.optimized?.max_sharpe?.annual_volatility !== undefined ? [[frontier.optimized.max_sharpe.annual_volatility, frontier.optimized.max_sharpe.annual_return, frontier.optimized.max_sharpe.sharpe]] : [] }
                ]
            });

            // — Monte Carlo chart —
            const mcPaths = monteCarlo.sampled_paths || monteCarlo.paths || [];
            const pctPaths = monteCarlo.percentile_paths || [];
            if (mcPaths.length > 0) {
                const mcSeries = mcPaths.slice(0, 20).map((pathObj, i) => {
                    const points = pathObj.points || pathObj || [];
                    return { name: `Path ${i + 1}`, type: "line", showSymbol: false, data: Array.isArray(points) ? points.map(pt => pt.nav ?? pt) : [], lineStyle: { width: 0.5, opacity: 0.12 }, itemStyle: { color: "#8d97a4" } };
                });
                if (pctPaths.length > 0) {
                    mcSeries.push({ name: "乐观 (p95)", type: "line", showSymbol: false, data: pctPaths.map(pt => pt.p95), lineStyle: { width: 1.8, type: "dashed", opacity: 0.8 }, itemStyle: { color: "#27a648" } });
                    mcSeries.push({ name: "中位数 (p50)", type: "line", showSymbol: false, data: pctPaths.map(pt => pt.p50), lineStyle: { width: 2.5, opacity: 0.95 }, itemStyle: { color: "#3b82f6" } });
                    mcSeries.push({ name: "悲观 (p5)", type: "line", showSymbol: false, data: pctPaths.map(pt => pt.p5), lineStyle: { width: 1.8, type: "dashed", opacity: 0.8 }, itemStyle: { color: "#e54d5e" } });
                }
                const dataLen = pctPaths.length || (mcSeries[0]?.data?.length || 0);
                chart("#monteCarloChart").setOption({
                    ...baseOption(),
                    legend: { show: true, bottom: 0, textStyle: { color: isLight ? "#374151" : "#9ca3af" }, data: ["乐观 (p95)", "中位数 (p50)", "悲观 (p5)"] },
                    xAxis: { show: false, type: "category", data: Array.from({ length: dataLen }, (_, i) => `第 ${i + 1} 月`) },
                    yAxis: { type: "value", axisLabel: { formatter: v => v.toFixed(2)+'x' } },
                    series: mcSeries
                }, true);
            }

            // — Factor chart & table —
            if (fRows.length) {
                chart("#factorChart").setOption({
                    ...baseOption(),
                    grid: { left: 54, right: 18, top: 12, bottom: 34 },
                    xAxis: { type: "category", data: fRows.map(r => r.factor) },
                    yAxis: { type: "value" },
                    series: [{ type: "bar", data: fRows.map(r => ({ value: r.beta, itemStyle: { color: (r.beta||0) >= 0 ? "#27a648" : "#e54d5e" } })) }]
                }, true);
                if (factorRows) factorRows.innerHTML = fRows.map(row => `<tr><td><b>${row.factor}</b></td><td>${fmtNum(row.beta)}</td><td>${fmtNum(row.correlation)}</td></tr>`).join("");
            }

            // — Optimized portfolios table —
            const optRows = document.querySelector("#optRows");
            if (optRows) {
                const optArr = [
                    { name: "当前组合", return: currentPortfolio.annual_return ?? stats.annual_return, vol: currentPortfolio.annual_volatility ?? stats.annual_volatility, sharpe: currentPortfolio.sharpe ?? stats.sharpe },
                    { name: "最佳夏普", return: frontier.optimized?.max_sharpe?.annual_return, vol: frontier.optimized?.max_sharpe?.annual_volatility, sharpe: frontier.optimized?.max_sharpe?.sharpe },
                    { name: "最小波动", return: frontier.optimized?.min_volatility?.annual_return, vol: frontier.optimized?.min_volatility?.annual_volatility, sharpe: frontier.optimized?.min_volatility?.sharpe }
                ];
                optRows.innerHTML = optArr.map(row => `<tr><td><b>${row.name}</b></td><td>${row.return != null ? fmtPct(row.return) : "—"}</td><td>${row.vol != null ? fmtPct(row.vol) : "—"}</td><td>${row.sharpe != null ? fmtNum(row.sharpe) : "—"}</td></tr>`).join("");
            }

            // — Optimization suggestion table (risk mode) —
            function renderOptimizationTarget(index) {
                const target = targets[index] || targets[1] || {};
                const row = target.row || {};
                riskPreference.value = String(index);
                riskTabs.forEach(tab => tab.classList.toggle("active", Number(tab.dataset.risk) === index));
                const targetWeights = row.weights || {};
                riskMode.textContent = target.mode || "均衡";
                const returnDelta = (row.annual_return ?? 0) - (currentPortfolio.annual_return ?? 0);
                const volDelta = (row.annual_volatility ?? 0) - (currentPortfolio.annual_volatility ?? 0);
                targetReturn.textContent = row.annual_return !== undefined ? `${returnDelta >= 0 ? "+" : ""}${fmtPct(returnDelta)} (${fmtPct(row.annual_return)})` : "—";
                targetVolatility.textContent = row.annual_volatility !== undefined ? `${volDelta >= 0 ? "+" : ""}${fmtPct(volDelta)} (${fmtPct(row.annual_volatility)})` : "—";
                targetSharpeDelta.textContent = row.sharpe !== undefined ? `${row.sharpe >= (currentPortfolio.sharpe ?? 0) ? "+" : ""}${fmtNum(row.sharpe - (currentPortfolio.sharpe ?? 0))}` : "—";
                const symbols = Array.from(new Set([...Object.keys(currentWeights), ...Object.keys(targetWeights)]));
                const changes = symbols.map(s => ({ symbol: s, current: currentWeights[s] || 0, target: targetWeights[s] || 0, delta: (targetWeights[s] || 0) - (currentWeights[s] || 0) })).sort((a, b) => Math.abs(b.delta) - Math.abs(a.delta));
                allocationRows.innerHTML = changes.slice(0, 10).map(r => `<tr><td>${r.symbol}</td><td>${fmtPct(r.current)}</td><td>${fmtPct(r.target)}</td><td class="${r.delta >= 0 ? "delta-up" : "delta-down"}">${r.delta >= 0 ? "+" : ""}${fmtPct(r.delta)}</td></tr>`).join("");
                renderPills(contributorList, changes.filter(r => r.delta > 0.025).slice(0, 5).map(r => r.symbol));
                renderPills(riskConcentratorList, Object.entries(currentWeights).sort((a, b) => b[1] - a[1]).slice(0, 5).map(([s]) => s));
            }
            riskPreference.oninput = () => renderOptimizationTarget(Number(riskPreference.value || 1));
            riskTabs.forEach(tab => tab.addEventListener("click", () => renderOptimizationTarget(Number(tab.dataset.risk || 1))));
            renderOptimizationTarget(Number(riskPreference.value || 1));

            btStatus.innerHTML = `<i class="fa-solid fa-circle-check" style="color:var(--positive)"></i> 已完成 · ${navDays} 个交易日`;

            // Cache fresh result for next visit
            if (!cachedData) {
                try { localStorage.setItem(BT_CACHE_KEY, JSON.stringify({ history, frontier, monteCarlo, factors, backtest, cachedAt: Date.now() })); } catch(_) {}
            }
        } catch(e) {
            btStatus.innerHTML = `<i class="fa-solid fa-circle-xmark" style="color:var(--negative)"></i> 加载失败：${e.message}`;
            console.error(e);
        }
    }

</script>

<style>
  .ai-compare-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 16px; }
  .ai-compare-card { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
  .ai-compare-head { padding: 10px 14px; font-weight: 700; font-size: 13px; border-bottom: 1px solid var(--line); background: var(--bg); }
  .ai-compare-head span { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; }
  .ai-compare-body { display: grid; grid-template-rows: auto auto; }
  .ai-col { padding: 10px 14px; }
  .ai-col + .ai-col { border-top: 1px solid var(--line); }
  .ai-col-label { font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; color: var(--muted); margin-bottom: 4px; font-weight: 600; }
  .ai-col p { font-size: 13px; line-height: 1.5; color: var(--text); margin: 0; }
  .ai-review-box { background: var(--surface); border: 1px solid var(--accent); border-radius: 10px; padding: 16px; margin-top: 4px; }
  .ai-review-head { font-weight: 700; font-size: 13px; margin-bottom: 8px; color: var(--accent); }
  .ai-review-box p { font-size: 13px; line-height: 1.6; color: var(--text); margin: 0; }
  @media (max-width: 900px) { .ai-compare-grid { grid-template-columns: repeat(2, 1fr); } }
  @media (max-width: 500px) { .ai-compare-grid { grid-template-columns: 1fr; } }
</style>

<script>
  // — AI Analysis —
  let _aiRunning = false;
  async function loadAiAnalysis() {
    if (_aiRunning) return;
    const btn = document.querySelector("#aiAnalyzeBtn");
    const section = document.querySelector("#aiComparisonSection");
    const reviewBox = document.querySelector("#aiReviewBox");
    _aiRunning = true;
    btn.disabled = true;
    btn.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> AI 分析中...`;
    section.style.display = "block";
    reviewBox.style.display = "none";
    try {
      const resp = await fetch("/api/lab/ai-analysis", { method: "POST" });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      const prog = data.programmatic || {};
      const ai = data.ai || {};

      document.querySelector("#aiProgBacktest").textContent = prog.backtest || "—";
      document.querySelector("#aiProgFrontier").textContent = prog.frontier || "—";
      document.querySelector("#aiProgMonteCarlo").textContent = prog.monte_carlo || "—";
      document.querySelector("#aiProgFactors").textContent = prog.factors || "—";

      document.querySelector("#aiAiBacktest").textContent = ai.backtest || "—";
      document.querySelector("#aiAiFrontier").textContent = ai.frontier || "—";
      document.querySelector("#aiAiMonteCarlo").textContent = ai.monte_carlo || "—";
      document.querySelector("#aiAiFactors").textContent = ai.factors || "—";

      if (data.ai_review) {
        reviewBox.style.display = "block";
        document.querySelector("#aiReviewText").textContent = data.ai_review;
      }
      btn.innerHTML = `<i class="fa-solid fa-circle-check" style="color:var(--positive)"></i> AI 分析完成`;
    } catch (e) {
      document.querySelector("#aiAiBacktest").textContent = `分析失败: ${e.message}`;
      btn.innerHTML = `<i class="fa-solid fa-circle-xmark" style="color:var(--negative)"></i> AI 分析失败`;
      console.error(e);
    } finally {
      _aiRunning = false;
      btn.disabled = false;
    }
  }

  // Restore from cache or show prompt
  (function init() {
    try {
      const raw = localStorage.getItem(BT_CACHE_KEY);
      if (raw) {
        const cached = JSON.parse(raw);
        if (cached.history && cached.frontier) {
          btStatus.innerHTML = `<i class="fa-solid fa-clock" style="color:var(--muted)"></i> 缓存数据 · ${fmtCacheAge(cached.cachedAt)}`;
          loadBacktest(cached);
          return;
        }
      }
    } catch(_) {}
    btStatus.innerHTML = `<span style="color:var(--muted)">点击 <i class="fa-solid fa-arrows-rotate"></i> 刷新数据 加载分析</span>`;
  })();
</script>"""
    return HTMLResponse(wrap_v4_layout("回测与优化", content, "/backtest", get_lang(request)))
