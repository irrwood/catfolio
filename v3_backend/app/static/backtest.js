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
    const currentLang = () => (document.documentElement.lang || "zh").startsWith("en") ? "en" : "zh";
    const isEn = () => currentLang() === "en";
    const ui = {
        analyzing: () => isEn() ? "AI analyzing..." : "AI 分析中...",
        done: () => isEn() ? "AI analysis complete" : "AI 分析完成",
        failed: () => isEn() ? "AI analysis failed" : "AI 分析失败",
        analyzeCard: () => isEn() ? "AI is analyzing..." : "AI 正在解读…",
        cardFailed: () => isEn() ? "AI analysis failed: " : "AI 解读失败：",
        configureKey: () => isEn() ? "Configure an AI API key in Settings first." : "请先在「设置」页配置 AI API Key（DeepSeek 或 Grok）",
        loadFailed: () => isEn() ? "Analysis failed: " : "分析失败: ",
    };

    const chartById = new Map();
    const chartInstances = [];
    let catfolioThemeRegistered = false;
    function ensureCatfolioTheme() {
        // ECharts' default splitLine "#E0E6F1" is near-white (built for light backgrounds).
        // Charts that override yAxis without re-setting splitLine fall back to it, giving
        // glaring white gridlines on the dark theme. Register a theme whose default axis/
        // grid lines are semi-transparent grey — subtle on both dark and light backgrounds.
        if (catfolioThemeRegistered || !window.echarts) return;
        const axisDef = {
            axisLine: { lineStyle: { color: "rgba(128,128,128,0.28)" } },
            splitLine: { lineStyle: { color: "rgba(128,128,128,0.14)" } },
        };
        window.echarts.registerTheme("catfolio", { categoryAxis: axisDef, valueAxis: axisDef });
        catfolioThemeRegistered = true;
    }
    function isDark() { return !document.documentElement.classList.contains('light-theme'); }
    function chart(id) {
        const node = document.querySelector(id);
        if (!node) return { setOption() {}, resize() {} };
        if (chartById.has(id)) return chartById.get(id);
        ensureCatfolioTheme();
        const instance = window.echarts.init(node, "catfolio");
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
        btStatus.innerHTML = `<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> 正在加载...`;
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
                color: ['#27a648', '#9ca3af', '#f97316', '#8b5cf6'],
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
                color: [isLight ? "#9ca3af" : "#707580", "#27a648", "#f97316"],
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

            btStatus.innerHTML = `<svg class="hi hi-inline" style="color:var(--positive)" aria-hidden="true" focusable="false"><use href="#hi-check-circle"></use></svg> 已完成 · ${navDays} 个交易日`;

            // Cache fresh result for next visit
            if (!cachedData) {
                try { localStorage.setItem(BT_CACHE_KEY, JSON.stringify({ history, frontier, monteCarlo, factors, backtest, cachedAt: Date.now() })); } catch(_) {}
            }
        } catch(e) {
            btStatus.innerHTML = `<svg class="hi hi-inline" style="color:var(--negative)" aria-hidden="true" focusable="false"><use href="#hi-x-circle"></use></svg> 加载失败：${e.message}`;
            console.error(e);
        }
    }
  // — AI Analysis —
  let _aiRunning = false;
  async function loadAiAnalysis() {
    if (_aiRunning) return;
    const btn = document.querySelector("#aiAnalyzeBtn");
    const section = document.querySelector("#aiComparisonSection");
    const reviewBox = document.querySelector("#aiReviewBox");
    _aiRunning = true;
    btn.disabled = true;
    btn.innerHTML = `<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> ${ui.analyzing()}`;
    section.style.display = "block";
    reviewBox.style.display = "none";
    try {
      const lang = (document.documentElement.lang || "zh").startsWith("en") ? "en" : "zh";
      const resp = await fetch("/api/lab/ai-analysis", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ lang }),
      });
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
      btn.innerHTML = `<svg class="hi hi-inline" style="color:var(--positive)" aria-hidden="true" focusable="false"><use href="#hi-check-circle"></use></svg> ${ui.done()}`;
    } catch (e) {
      document.querySelector("#aiAiBacktest").textContent = `${ui.loadFailed()}${e.message}`;
      btn.innerHTML = `<svg class="hi hi-inline" style="color:var(--negative)" aria-hidden="true" focusable="false"><use href="#hi-x-circle"></use></svg> ${ui.failed()}`;
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
          btStatus.innerHTML = `<svg class="hi hi-inline" style="color:var(--muted)" aria-hidden="true" focusable="false"><use href="#hi-clock"></use></svg> 缓存数据 · ${fmtCacheAge(cached.cachedAt)}`;
          loadBacktest(cached);
          return;
        }
      }
    } catch(_) {}
    btStatus.innerHTML = `<span style="color:var(--muted)">点击 <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-refresh"></use></svg> 刷新数据 加载分析</span>`;
  })();

// ── Per-card AI 解读 (magic-wand) ──────────────────────────────────────────
(function () {
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  async function ask(question) {
    const res = await fetch("/api/ai/ask", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question, lang: currentLang() }),
    });
    if (!res.ok) throw new Error(res.status === 500 ? ui.configureKey() : `HTTP ${res.status}`);
    return res.json();
  }

  // Per-card focus so each card's AI answer addresses its own topic.
  const AI_BASE_ZH = "用中文回答，3-4 句话，直接给结论、不要客套；只围绕本卡片的主题展开，避免重复其他卡片已讲过的仓位集中度/单票占比等泛泛内容。";
  const AI_BASE_EN = "Answer in English in 3-4 sentences. Give direct conclusions, no pleasantries. Focus only on this card's topic and avoid repeating generic concentration comments from other cards.";
  const AI_FOCUS = [
    ["历史回测", "Historical Backtest", "聚焦回测表现 vs 基准：年化收益、波动、夏普、最大回撤相比 SPY/QQQ 等是否划算，风险调整后收益如何", "Focus on backtest performance versus benchmarks: annual return, volatility, Sharpe, max drawdown, and whether risk-adjusted return is worthwhile versus SPY/QQQ."],
    ["组合重建", "Portfolio Reconstruction", "聚焦优化方向：当前组合相对优化组合的差距、哪些该加/该减、调仓是否值得", "Focus on optimization direction: the gap between the current and optimized portfolios, what changed, and whether the rebalance is meaningful."],
    ["蒙特卡洛", "Monte Carlo", "聚焦未来收益情景：乐观/中性/悲观区间有多宽、极端下行风险有多大", "Focus on future return scenarios: optimistic/base/pessimistic ranges and extreme downside risk."],
    ["决策摘要", "Decision Summary", "给出总体决策建议：当前组合最该关注、最该采取行动的 1-2 件事", "Summarize the 1-2 most important portfolio issues to watch or act on."],
    ["因子分析", "Factor Analysis", "聚焦因子暴露：组合主要受哪些因子驱动（Beta、成长、动量等）、是否存在隐性的因子集中", "Focus on factor exposure: beta, growth, momentum, and hidden factor concentration."],
    ["优化组合", "Optimized Portfolio", "聚焦优化结果：优化后组合相比当前的收益/风险改善、权重调整背后的逻辑", "Focus on optimization results: return/risk improvement versus the current portfolio and the logic behind weight changes."],
  ];
  function aiPrompt(title) {
    const hit = AI_FOCUS.find(([zh, en]) => title.includes(zh) || title.includes(en));
    if (isEn()) {
      const focus = hit ? hit[3] : `Interpret the key information in "${title}".`;
      return `Based on my portfolio data, ${focus} ${AI_BASE_EN}`;
    }
    const focus = hit ? hit[2] : `解读「${title}」中的关键信息`;
    return `请基于我的真实持仓数据，${focus}。${AI_BASE_ZH}`;
  }

  const panels = Array.from(document.querySelectorAll("section.panel"));
  panels.forEach((panel) => {
    if (panel.id === "aiComparisonSection") return;             // already AI
    const chartHead = panel.querySelector(".chart-head");
    const h2 = (chartHead || panel).querySelector("h2");
    if (!h2 || panel.querySelector(".ai-card-btn")) return;
    const title = h2.textContent.trim();
    if (!title || title.includes("今天先回答")) return;          // skip the 4-question summary

    const btn = document.createElement("button");
    btn.className = "ai-card-btn" + (chartHead ? "" : " abs");
    btn.title = "AI 解读";
    btn.setAttribute("aria-label", "AI 解读");
    btn.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-wand-sparkles"></use></svg>';
    if (chartHead) { btn.style.marginLeft = "auto"; chartHead.appendChild(btn); }
    else { panel.appendChild(btn); }

    const result = document.createElement("div");
    result.className = "ai-card-result";
    result.hidden = true;
    panel.appendChild(result);

    let loaded = false;
    btn.addEventListener("click", async () => {
      if (loaded) { result.hidden = !result.hidden; return; }
      result.hidden = false;
      result.classList.remove("err");
      result.innerHTML = `<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> ${ui.analyzeCard()}`;
      btn.disabled = true;
      try {
        const data = await ask(aiPrompt(title));
        result.innerHTML = '<span class="ai-card-tag"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-wand-sparkles"></use></svg></span>' + esc(data.answer);
        loaded = true;
      } catch (e) {
        result.classList.add("err");
        result.innerHTML = ui.cardFailed() + esc(e.message);
      } finally {
        btn.disabled = false;
      }
    });
  });
})();
