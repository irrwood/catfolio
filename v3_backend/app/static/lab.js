    const fmtPct = value => `${(Number(value || 0) * 100).toFixed(1)}%`;
    const fmtNum = value => Number(value || 0).toFixed(2);
    const statusEl = document.querySelector("#status");
    const groupRows = document.querySelector("#groupRows");
    const percentileGrid = document.querySelector("#percentileGrid");
    const qualityBanner = document.querySelector("#qualityBanner");
    const cumulativeRange = document.querySelector("#cumulativeRange");
    const returnBasisNote = document.querySelector("#returnBasisNote");
    const returnBasisButtons = Array.from(document.querySelectorAll("[data-return-basis]"));
    const snapshotMarketValue = document.querySelector("#snapshotMarketValue");
    const snapshotMarketSub = document.querySelector("#snapshotMarketSub");
    const snapshotTotalPnl = document.querySelector("#snapshotTotalPnl");
    const snapshotTodayPnl = document.querySelector("#snapshotTodayPnl");
    const snapshotHoldingsCount = document.querySelector("#snapshotHoldingsCount");
    const snapshotBreadth = document.querySelector("#snapshotBreadth");
    const maxDrawdown = document.querySelector("#maxDrawdown");
    const snapshotSharpeSub = document.querySelector("#snapshotSharpeSub");
    const snapshotDrawdownSub = document.querySelector("#snapshotDrawdownSub");
    const drawdownRangeSelect = document.querySelector("#drawdownRangeSelect");
    const valuationWaterlineOverall = document.querySelector("#valuationWaterlineOverall");
    const valuationWaterlineNote = document.querySelector("#valuationWaterlineNote");
    const valuationWaterlineList = document.querySelector("#valuationWaterlineList");
    const healthTrading212 = document.querySelector("#healthTrading212");
    const healthMarket = document.querySelector("#healthMarket");
    const healthFundamentals = document.querySelector("#healthFundamentals");
    const healthFundamentalsDot = document.querySelector("#healthFundamentalsDot");
    const healthHistory = document.querySelector("#healthHistory");
    const snapshotMarketSpark = document.querySelector("#snapshotMarketSpark");
    const snapshotPnlSpark = document.querySelector("#snapshotPnlSpark");
    const snapshotTodaySpark = document.querySelector("#snapshotTodaySpark");
    const annualReturn = document.querySelector("#annualReturn");
    const annualVol = document.querySelector("#annualVol");
    const sharpe = document.querySelector("#sharpe");
    const refreshHistory = document.querySelector("#refreshHistory");
    let latestCommandCenter = null;
    let latestNavRows = [];
    let currentReturnBasis = "twr";

    // ---- Chart engine: ECharts ----
    const chartById = new Map();
    const chartInstances = [];
    let helmThemeRegistered = false;
    function ensureHelmTheme() {
        // ECharts' built-in default splitLine is "#E0E6F1" (near-white), designed for
        // light backgrounds. Charts that override yAxis without re-setting splitLine fall
        // back to it, producing glaring white gridlines on the dark theme. Register a
        // theme whose default axis/grid lines are semi-transparent grey — subtle on both
        // dark and light backgrounds — so every chart inits safely regardless.
        if (helmThemeRegistered || !window.echarts) return;
        const axisDef = {
            axisLine: { lineStyle: { color: "rgba(128,128,128,0.28)" } },
            splitLine: { lineStyle: { color: "rgba(128,128,128,0.14)" } },
        };
        window.echarts.registerTheme("helm", { categoryAxis: axisDef, valueAxis: axisDef });
        helmThemeRegistered = true;
    }

    function isDark() { return !document.documentElement.classList.contains('light-theme'); }

    async function ensureEcharts() {
        if (window.echarts) return window.echarts;
        return new Promise((resolve) => {
            const timer = setInterval(() => {
                if (window.echarts) {
                    clearInterval(timer);
                    resolve(window.echarts);
                }
            }, 50);
        });
    }
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
    function diag(msg) {}
    window.addEventListener("resize", () => {
        chartInstances.forEach(i => i.resize());
    });
    const usd = value => `$${Number(value || 0).toLocaleString("en-GB", { maximumFractionDigits: 0 })}`;
    const signedUsd = value => `${Number(value || 0) >= 0 ? "+" : "-"}${usd(Math.abs(Number(value || 0)))}`;
    function clamp(value, min, max) { return Math.max(min, Math.min(max, value)); }
    function fmtUnixTime(value) {
        if (!value) return "未刷新";
        return new Date(Number(value) * 1000).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
    }
    function setTone(element, value) {
        if (!element) return;
        element.classList.toggle("positive", Number(value || 0) >= 0);
        element.classList.toggle("negative", Number(value || 0) < 0);
    }
    function renderWeekPositionCell(row) {
        if (!row || row.position === null || row.position === undefined) return "—";
        const pos = Math.max(0, Math.min(1, Number(row.position || 0)));
        return `<div class="week-position-range" title="低点 ${fmtNum(row.low)}，现价 ${fmtNum(row.current)}，高点 ${fmtNum(row.high)}"><i class="week-position-marker" style="left:${(pos * 100).toFixed(1)}%"></i></div><span class="week-position-pct">${Math.round(pos * 100)}%</span>`;
    }
    function renderSparkline(svg, values, tone = "") {
        if (!svg) return;
        const nums = (values || []).map(Number).filter(Number.isFinite);
        if (nums.length < 2) { svg.innerHTML = ""; return; }
        const min = Math.min(...nums); const max = Math.max(...nums); const span = max - min || 1;
        const points = nums.map((value, index) => {
            const x = nums.length === 1 ? 0 : index / (nums.length - 1) * 120;
            const y = 30 - ((value - min) / span * 24);
            return `${x.toFixed(1)},${y.toFixed(1)}`;
        }).join(" ");
        svg.classList.toggle("negative", tone === "negative");
        svg.classList.toggle("muted", tone === "muted");
        svg.innerHTML = `<polyline points="${points}"></polyline>`;
    }
    function selectedDrawdownWindow() {
        const value = drawdownRangeSelect?.value || "all"; return value === "all" ? null : Number(value);
    }
    function drawdownWindowLabel(days, available) {
        if (!days) return `全部样本 · ${available} 个交易日`;
        const labels = { 252: "近 1 年", 126: "近 6 个月", 63: "近 3 个月", 21: "近 1 个月" };
        return `${labels[days] || `近 ${days} 日`} · ${Math.min(days, available)} 个交易日`;
    }
    function computeDrawdownRows(navRows, days = null) {
        const rows = (navRows || []).filter(row => Number.isFinite(Number(row.nav)));
        const scoped = days ? rows.slice(-days) : rows;
        let peak = null; let maxDrawdownValue = 0;
        const drawdownRows = scoped.map(row => {
            const nav = Number(row.nav); peak = peak === null ? nav : Math.max(peak, nav);
            const drawdown = peak ? nav / peak - 1 : 0;
            maxDrawdownValue = Math.min(maxDrawdownValue, drawdown);
            return { date: row.date, drawdown };
        });
        return { rows: drawdownRows, maxDrawdown: maxDrawdownValue, available: rows.length };
    }
    function renderDrawdownChart(drawdownRows) {
        chart("#drawdownChart").setOption({ ...baseOption(), grid: { left: 54, right: 18, top: 12, bottom: 34 }, xAxis: { type: "category", data: drawdownRows.map(row => row.date), axisLabel: { hideOverlap: true } }, yAxis: { type: "value", axisLabel: { formatter: v => (v != null ? (v * 100).toFixed(1) + '%' : '') } }, series: [{ type: "line", showSymbol: false, areaStyle: { opacity: 0.1 }, data: drawdownRows.map(row => row.drawdown), itemStyle: { color: "#e54d5e" } }] });
    }
    function updateDrawdownRange() {
        const days = selectedDrawdownWindow();
        const result = computeDrawdownRows(latestNavRows, days);
        maxDrawdown.textContent = fmtPct(result.maxDrawdown);
        snapshotDrawdownSub.textContent = drawdownWindowLabel(days, result.available);
        setTone(maxDrawdown, result.maxDrawdown);
        renderDrawdownChart(result.rows);
    }
    function median(values) {
        const nums = values.map(Number).filter(Number.isFinite).sort((a, b) => a - b);
        if (!nums.length) return null;
        const mid = Math.floor(nums.length / 2);
        return nums.length % 2 ? nums[mid] : (nums[mid - 1] + nums[mid]) / 2;
    }
    function renderValuationWaterline(rows) {
        if (!valuationWaterlineOverall || !valuationWaterlineList) return;
        const valid = (rows || []).filter(row => Number.isFinite(Number(row.pe)) && Number(row.pe) > 0);
        if (!valid.length) {
            valuationWaterlineOverall.textContent = "—"; valuationWaterlineOverall.className = "";
            valuationWaterlineNote.textContent = "暂无可用 P/E 数据。先刷新估值数据源。";
            valuationWaterlineList.innerHTML = `<div class="valuation-waterline-row"><b>等待</b><div class="valuation-waterline-track"></div><span class="valuation-waterline-value">—</span></div>`;
            return;
        }
        const allMedian = median(valid.map(row => row.pe)) || 1;
        const bySector = new Map();
        valid.forEach(row => { const key = row.sector || "Other"; if (!bySector.has(key)) bySector.set(key, []); bySector.get(key).push(row.pe); });
        const enriched = valid.map(row => {
            const sectorRows = bySector.get(row.sector || "Other") || [];
            const benchmark = sectorRows.length >= 3 ? median(sectorRows) : allMedian;
            return { ...row, benchmark, premium: benchmark ? row.pe / benchmark - 1 : 0 };
        });
        const weightedTotal = enriched.reduce((sum, row) => sum + Number(row.weight || 0), 0) || 1;
        const weightedPremium = enriched.reduce((sum, row) => sum + Number(row.premium || 0) * Number(row.weight || 0), 0) / weightedTotal;
        const overallClass = weightedPremium >= 0 ? "expensive" : "cheap";
        valuationWaterlineOverall.className = overallClass;
        valuationWaterlineOverall.textContent = `${weightedPremium >= 0 ? "+" : ""}${(weightedPremium * 100).toFixed(1)}%`;
        valuationWaterlineNote.textContent = `基于 ${enriched.length} 个有 P/E 的持仓；同板块样本不足时使用组合中位 P/E ${fmtNum(allMedian)}。`;
        valuationWaterlineList.innerHTML = enriched.sort((a, b) => Number(b.weight || 0) - Number(a.weight || 0)).slice(0, 6).map(row => {
            const premium = Math.max(-0.6, Math.min(0.6, Number(row.premium || 0)));
            const width = Math.max(4, Math.min(50, Math.abs(premium) / 0.6 * 50));
            const left = premium >= 0 ? 50 : 50 - width; const tone = premium >= 0 ? "expensive" : "cheap";
            return `<div class="valuation-waterline-row" title="${row.ticker} P/E ${fmtNum(row.pe)}，基准 ${fmtNum(row.benchmark)}"><b>${row.ticker}</b><div class="valuation-waterline-track"><i class="valuation-waterline-fill ${tone}" style="left:${left.toFixed(1)}%;width:${width.toFixed(1)}%;"></i></div><span class="valuation-waterline-value ${tone}">${premium >= 0 ? "+" : ""}${(premium * 100).toFixed(1)}%</span></div>`;
        }).join("");
    }
    function heatColor(change) {
        const value = Number(change || 0);
        const strength = clamp(Math.abs(value) / 3, 0.10, 0.72);
        const base = value >= 0 ? "var(--positive)" : "var(--negative)";
        return `color-mix(in oklch, ${base} ${Math.round(strength * 56)}%, var(--panel))`;
    }
    function tileSpan(weight) {
        const pct = Number(weight || 0) * 100;
        if (pct >= 18) return [8, 5]; if (pct >= 10) return [5, 4]; if (pct >= 6) return [4, 3];
        if (pct >= 3) return [3, 2]; if (pct >= 1.5) return [2, 2]; if (pct >= 0.7) return [2, 2]; return [1, 1];
    }
    function sectorSpan(weight) {
        const pct = Number(weight || 0) * 100;
        if (pct >= 35) return [5, 6]; if (pct >= 25) return [4, 5]; if (pct >= 12) return [4, 4];
        if (pct >= 6) return [3, 3]; if (pct >= 2) return [2, 2]; return [1, 2];
    }
    function renderAssetHeatmap(rows) {
        const container = document.querySelector("#holdingHeatmapChart");
        if (!container) return;
        container.classList.add("asset-heatmap");
        const grouped = new Map();
        (rows || []).forEach(row => { const sector = row.sector || "Other / Unclassified"; if (!grouped.has(sector)) grouped.set(sector, []); grouped.get(sector).push(row); });
        const sectors = Array.from(grouped.entries()).map(([sector, holdings]) => {
            const weight = holdings.reduce((sum, row) => sum + Number(row.weight || 0), 0);
            const change = holdings.reduce((sum, row) => sum + Number(row.today_change_percent || 0) * Number(row.weight || 0), 0) / (weight || 1);
            holdings.sort((a, b) => Number(b.weight || 0) - Number(a.weight || 0));
            return { sector, holdings, weight, change };
        }).sort((a, b) => b.weight - a.weight);
        container.innerHTML = sectors.map(group => {
            const [sectorCol, sectorRow] = sectorSpan(group.weight);
            const inner = group.holdings.map(row => {
                const localWeight = Number(row.weight || 0) / (group.weight || 1);
                const [col, rowSpan] = tileSpan(localWeight);
                const change = Number(row.today_change_percent || 0);
                const small = col <= 1 || rowSpan <= 1;
                const ticker = row.ticker || ""; const displayName = row.display_name || row.name || ticker;
                return `<div class="asset-tile ${small ? "small" : ""}" title="${ticker} | ${displayName} | ${fmtPct(row.weight)} weight | ${change.toFixed(2)}% today" style="grid-column: span ${col}; grid-row: span ${rowSpan}; background:${heatColor(change)};"><div class="asset-logo">${ticker.slice(0, 2)}</div><div class="asset-ticker">${ticker}</div><div class="asset-name">${displayName}</div><div class="asset-change ${change >= 0 ? "delta-up" : "delta-down"}">${change >= 0 ? "+" : ""}${change.toFixed(2)}%</div><div class="asset-weight">${fmtPct(row.weight)}</div></div>`;
            }).join("");
            return `<section class="sector-tile" style="grid-column: span ${sectorCol}; grid-row: span ${sectorRow};"><div class="sector-tile-head"><span>${group.sector}</span><span class="${group.change >= 0 ? "delta-up" : "delta-down"}">${group.change >= 0 ? "+" : ""}${group.change.toFixed(2)}%</span></div><div class="sector-inner-grid">${inner}</div></section>`;
        }).join("");
    }
    function setReturnBasis(mode) { currentReturnBasis = mode || "twr"; syncReturnBasisButtons(); if (latestCommandCenter) renderCumulativeReturnChart(latestCommandCenter); }
    function syncReturnBasisButtons() { returnBasisButtons.forEach(button => { button.classList.toggle("active", button.dataset.returnBasis === currentReturnBasis); }); }
    function renderCumulativeReturnChart(data) {
        const isLight = document.documentElement.classList.contains("light-theme");
        const modes = data.cumulative_return_modes || { twr: data.cumulative_vs_benchmark };
        if (!modes[currentReturnBasis]) currentReturnBasis = modes.default || "twr";
        syncReturnBasisButtons();
        const twr = modes.twr || data.cumulative_vs_benchmark || {};
        const selected = currentReturnBasis === "cash_flow_mirror" ? modes.cash_flow_mirror : twr;
        const note = selected?.note || (currentReturnBasis === "cash_flow_mirror" ? "复制你的真实入金出金节奏，用于比较真实账户表现。" : "剔除现金流影响，用于衡量策略本身表现。");
        if (returnBasisNote) returnBasisNote.textContent = note;
        if (currentReturnBasis === "cash_flow_mirror" && (!selected?.available || !(selected.rows || []).length)) {
            if (cumulativeRange) cumulativeRange.textContent = "现金流镜像 · 等待日期流水";
            chart("#cumulativeChart").setOption({
                ...baseOption(),
                title: {
                    text: "需要入金 / 出金日期",
                    subtext: selected?.message || "现金流镜像需要逐日现金流流水，当前只能看到汇总金额。",
                    left: "center",
                    top: "middle",
                    textStyle: { color: isLight ? "#1f2937" : "#e8edf3", fontSize: 15, fontWeight: 760 },
                    subtextStyle: { color: isLight ? "#64748b" : "#8d97a4", fontSize: 12, lineHeight: 18 },
                    itemGap: 8,
                },
                legend: { show: false },
                tooltip: { show: false },
                xAxis: { show: false, type: "category", data: [] },
                yAxis: { show: false, type: "value" },
                series: [],
            }, true);
            return;
        }
        const cumulative = selected?.rows || [];
        if (cumulativeRange) cumulativeRange.textContent = `${selected?.date_range?.start || "—"} 起点重置`;
        if (!cumulative.length) return;
        const isCashFlow = currentReturnBasis === "cash_flow_mirror";
        const portfolioKey = isCashFlow ? "adjusted_portfolio_value" : "portfolio";
        const benchmarkKey = isCashFlow ? "adjusted_benchmark_value" : "benchmark";

        const seriesData = [{
            name: "Portfolio",
            type: "line",
            showSymbol: false,
            data: cumulative.map(row => row[portfolioKey] ?? row.portfolio ?? null),
            lineStyle: { width: 2.2 },
            itemStyle: { color: "#27a648" }
        }];
        if (cumulative[0] && (cumulative[0][benchmarkKey] !== undefined || cumulative[0].benchmark !== undefined)) {
            seriesData.push({
                name: selected?.benchmark || "SPY",
                type: "line",
                showSymbol: false,
                data: cumulative.map(row => row[benchmarkKey] ?? row.benchmark ?? null),
                lineStyle: { width: 1.5, opacity: 0.75 },
                itemStyle: { color: "#3b82f6" }
            });
        }
        if (cumulative[0] && cumulative[0].excess !== undefined) {
            seriesData.push({
                name: "Relative Excess",
                type: "line",
                showSymbol: false,
                data: cumulative.map(row => row.excess !== null ? row.excess + 1 : null),
                lineStyle: { width: 1.5, opacity: 0.8 },
                itemStyle: { color: "#f59e0b" }
            });
        }
        chart("#cumulativeChart").setOption({
            ...baseOption(),
            title: { show: false },
            color: ["#27a648", "#3b82f6", "#f59e0b"],
            legend: { bottom: 0, textStyle: { color: isLight ? "#374151" : "#9ca3af" } },
            grid: { left: 54, right: 18, top: 12, bottom: 42 },
            xAxis: { type: "category", data: cumulative.map(row => row.date), axisLabel: { hideOverlap: true } },
            yAxis: { type: "value", axisLabel: { formatter: v => isCashFlow ? (v >= 1000 ? '$'+(v/1000).toFixed(1)+'k' : '$'+Math.round(v)) : v.toFixed(2) + 'x' } },
            series: seriesData
        }, true);
    }
    function renderCommandCenter(data) {
        if (!latestCommandCenter) currentReturnBasis = data.cumulative_return_modes?.default || "twr";
        latestCommandCenter = data;
        const isLight = document.documentElement.classList.contains("light-theme");
        const quality = data.data_quality || {};
        qualityBanner.innerHTML = `<b>数据口径</b><span>持仓、现价、成本、浮盈亏是账户数据；收益热图、累计收益、相关性、回撤和 Waterfall 是当前仓位模型，非真实账户收益。样本 ${quality.history_start || "—"} 到 ${quality.history_end || "—"}，共 ${quality.history_days || 0} 个交易日。</span>`;

        // 1. Sector Concentration
        const sectorRows = data.sector_concentration?.rows || [];
        chart("#sectorChart").setOption({
            ...baseOption(),
            grid: { left: 132, right: 18, top: 12, bottom: 28 },
            xAxis: { type: "value", axisLabel: { formatter: value => `${Math.round(value * 100)}%` } },
            yAxis: { type: "category", inverse: true, data: sectorRows.map(row => row.sector) },
            series: [{ type: "bar", data: sectorRows.map(row => row.weight), itemStyle: { color: "#27a648" } }],
            tooltip: { trigger: "axis", valueFormatter: value => fmtPct(value) }
        });

        // 2. P&L Contribution
        const pnlRows = (data.pnl_contribution?.rows || []).slice(0, 14).reverse();
        chart("#pnlChart").setOption({
            ...baseOption(),
            grid: { left: 72, right: 28, top: 12, bottom: 28 },
            xAxis: { type: "value", axisLabel: { formatter: value => usd(value) } },
            yAxis: { type: "category", data: pnlRows.map(row => row.ticker) },
            series: [{ type: "bar", data: pnlRows.map(row => row.unrealized_usd), itemStyle: { color: params => params.value >= 0 ? "#27a648" : "#e54d5e" } }],
            tooltip: { trigger: "axis", valueFormatter: value => usd(value) }
        });

        // 3. (Monthly heatmap removed — covered by the year×month line chart above)

        // 4. Cumulative Return
        renderCumulativeReturnChart(data);

        // 5. Return Distribution
        const dist = data.return_distribution?.bins || [];
        const distStats = data.return_distribution?.stats || {};
        chart("#distributionChart").setOption({
            ...baseOption(),
            grid: { left: 48, right: 18, top: 12, bottom: 34 },
            xAxis: { type: "category", data: dist.map(row => `${(row.mid * 100).toFixed(1)}%`), axisLabel: { hideOverlap: true, rotate: 45, fontSize: 10 } },
            yAxis: { type: "value", name: "天数", nameTextStyle: { fontSize: 11 } },
            series: [{ type: "bar", data: dist.map(row => ({ value: row.count, itemStyle: { color: row.mid >= 0 ? "#27a648" : "#e54d5e", opacity: 0.78 } })) }],
            tooltip: { trigger: "axis", formatter: params => { const v = params[0]; return `${v.name}<br/>${v.value} 天`; } }
        });
        const distNote = document.querySelector("#distributionNote");
        if (distNote) distNote.textContent = `${distStats.sample_days || 0} 个交易日 · ${distStats.negative_days || 0} 天收跌 (${(distStats.negative_days / Math.max(1, distStats.sample_days) * 100).toFixed(0)}%) · 日均 ${fmtPct(distStats.mean)}`;

        // 6. Drawdown
        const drawdown = data.drawdown?.rows || [];
        renderDrawdownChart(drawdown);

        // 7. Correlation matrix
        const corr = data.correlation_matrix || {};
        chart("#correlationChart").setOption({
            ...baseOption(),
            grid: { left: 94, right: 24, top: 48, bottom: 72 },
            visualMap: { min: -1, max: 1, orient: "horizontal", left: "center", bottom: 8, inRange: { color: ["#3b82f6", isLight ? "#f3f4f6" : "#1f2937", "#dc2626"] } },
            xAxis: { type: "category", data: corr.symbols || [], axisLabel: { rotate: 45 } },
            yAxis: { type: "category", data: corr.symbols || [] },
            series: [{ type: "heatmap", data: (corr.matrix || []).flatMap((row, y) => row.map((value, x) => [x, y, value])) }],
            tooltip: { formatter: params => {
                if (!params || !params.value) return "";
                return `${corr.symbols?.[params.value[0]] || ""} / ${corr.symbols?.[params.value[1]] || ""}<br/>Corr ${fmtNum(params.value[2])}`;
            } }
        });

        // 8. Asset Heatmap
        renderAssetHeatmap(data.holdings_heatmap?.rows || []);

        // 9. Waterfall Chart
        const waterfall = (data.waterfall?.rows || []).filter(row => row && Number.isFinite(Number(row.contribution)));
        let running = 0; const helper = []; const values = [];
        waterfall.forEach(row => { helper.push(running); values.push(row.contribution); running += row.contribution; });
        chart("#waterfallChart").setOption({
            ...baseOption(),
            grid: { left: 56, right: 18, top: 12, bottom: 52 },
            xAxis: { type: "category", data: waterfall.map(row => row.symbol), axisLabel: { rotate: 35 } },
            yAxis: { type: "value", axisLabel: { formatter: value => fmtPct(value) } },
            series: [
                { type: "bar", stack: "total", itemStyle: { color: "transparent" }, emphasis: { disabled: true }, data: helper },
                { type: "bar", stack: "total", data: values, itemStyle: { color: params => params.value >= 0 ? "#27a648" : "#e54d5e" } }
            ]
        });

        // 10. Price Position Chart & Rows (Safe guard)
        const positions = data.fifty_two_week?.rows || [];
        const topPositions = positions.slice(0, 12);
        if (document.querySelector("#pricePositionChart")) {
            chart("#pricePositionChart").setOption({
                ...baseOption(),
                grid: { left: 62, right: 34, top: 18, bottom: 38 },
                xAxis: { type: "value", min: 0, max: 1, axisLabel: { formatter: value => `${Math.round(value * 100)}%` } },
                yAxis: { type: "category", inverse: true, data: topPositions.map(row => row.ticker) },
                tooltip: {
                    trigger: "axis",
                    formatter: params => {
                        if (!params || !params[0] || !topPositions) return "";
                        const row = topPositions[params[0].dataIndex];
                        if (!row) return "";
                        return `${row.ticker}<br/>52周低点 ${fmtNum(row.low)}<br/>现价 ${fmtNum(row.current)}<br/>52周高点 ${fmtNum(row.high)}<br/>位置 ${fmtPct(row.position)}<br/>离高点 ${fmtPct(row.distance_from_high)}`;
                    }
                },
                series: [
                    { name: "区间", type: "bar", data: topPositions.map(() => 1), barWidth: 8, itemStyle: { color: isLight ? "#e5e7eb" : "#374151", borderRadius: 999 }, silent: true },
                    { name: "现价位置", type: "scatter", symbolSize: 12, data: topPositions.map((row, index) => [row.position, row.ticker]), itemStyle: { color: params => params.value[0] >= 0.8 ? "#e54d5e" : params.value[0] <= 0.25 ? "#27a648" : "#3b82f6" } }
                ]
            });
        }
        const pricePositionRows = document.querySelector("#pricePositionRows");
        if (pricePositionRows) {
            pricePositionRows.innerHTML = topPositions.slice(0, 8).map(row => {
                const pos = Math.max(0, Math.min(1, Number(row.position || 0)));
                return `
                    <div class="week-position-row" title="低点 ${fmtNum(row.low)}，现价 ${fmtNum(row.current)}，高点 ${fmtNum(row.high)}">
                        <b>${row.ticker}</b>
                        <div class="week-position-range"><i class="week-position-marker" style="left:${(pos * 100).toFixed(1)}%"></i></div>
                        <span class="week-position-pct">${Math.round(pos * 100)}%</span>
                    </div>
                `;
            }).join("");
        }

        // 11. Fundamentals Chart (Safe guard)
        if (document.querySelector("#fundamentalsChart")) {
            chart("#fundamentalsChart").setOption({
                title: { text: "P/E 和成长率需要 fundamentals API", left: "center", top: "middle", textStyle: { fontSize: 13, color: isLight ? "#475569" : "#9ca3af" } },
                xAxis: { show: false },
                yAxis: { show: false },
                series: []
            });
        }

        // 12. Holding Rows
        const weekPositionByTicker = Object.fromEntries((data.fifty_two_week?.rows || []).map(row => [row.ticker, row]));
        const holdingRows = document.querySelector("#holdingRows");
        if (holdingRows) {
            holdingRows.innerHTML = (data.holdings_detail?.rows || []).slice(0, 40).map(row => {
                const yahoo = row.yahoo_symbol || row.ticker;
                const yahooUrl = `https://finance.yahoo.com/quote/${encodeURIComponent(yahoo)}`;
                const nameHtml = `<a href="${yahooUrl}" target="_blank" rel="noopener" style="color:var(--accent);text-decoration:none;" title="在 Yahoo Finance 查看 ${row.display_name || row.name}">${row.display_name || row.name}</a>`;
                return `<tr><td><a href="${yahooUrl}" target="_blank" rel="noopener" style="color:var(--text);text-decoration:none;font-weight:600;" title="Yahoo: ${yahoo}">${row.ticker}</a></td><td>${nameHtml}</td><td>${usd(row.cost_usd)}</td><td>${row.quote_price === null || row.quote_price === undefined ? "—" : Number(row.quote_price).toFixed(2)} ${row.quote_currency || ""}</td><td class="${(row.today_change_percent || 0) >= 0 ? "delta-up" : "delta-down"}">${row.today_change_percent === null || row.today_change_percent === undefined ? "—" : `${row.today_change_percent.toFixed(2)}%`}</td><td class="${(row.unrealized_percent || 0) >= 0 ? "delta-up" : "delta-down"}">${row.unrealized_percent === null || row.unrealized_percent === undefined ? "—" : `${row.unrealized_percent.toFixed(1)}%`}</td><td>${renderWeekPositionCell(weekPositionByTicker[row.ticker])}</td><td><div class="position-bar"><i style="width:${Math.max(2, row.weight * 100).toFixed(1)}%"></i></div>${fmtPct(row.weight)}</td></tr>`;
              }).join("");
        }
    }
    async function getJson(url, options) { const res = await fetch(url, options); if (!res.ok) throw new Error(`HTTP ${res.status}`); return res.json(); }
    function baseOption() {
        const L = document.documentElement.classList.contains("light-theme");
        const c = {
            bg: "transparent",
            tooltipBg: L ? "rgba(255,255,255,.96)" : "rgba(10,14,18,.96)",
            tooltipBorder: L ? "rgba(0,0,0,0.08)" : "rgba(255,255,255,0.08)",
            tooltipText: L ? "#111113" : "#ededef",
            axis: L ? "#475569" : "#707580",
            axisLine: L ? "#cbd5e1" : "rgba(255,255,255,0.06)",
            splitLine: L ? "#e5e7eb" : "rgba(255,255,255,0.05)",
            text: L ? "#334155" : "#9ca3af",
        };
        return {
            backgroundColor: c.bg,
            // Global default text color — charts that spread baseOption() and then
            // replace xAxis/yAxis wholesale lose the per-axis label color, so this
            // top-level textStyle keeps their labels legible (esp. in light mode).
            textStyle: { color: c.axis },
            tooltip: { trigger: "axis", backgroundColor: c.tooltipBg, borderColor: c.tooltipBorder, textStyle: { color: c.tooltipText } },
            grid: { left: 54, right: 18, top: 30, bottom: 42 },
            xAxis: { axisLine: { lineStyle: { color: c.axisLine } }, axisLabel: { color: c.axis }, splitLine: { show: false } },
            yAxis: { splitLine: { lineStyle: { color: c.splitLine } }, axisLabel: { color: c.axis } },
        };
    }
    async function loadLab() {
        diag("loadLab-start");
        const isLight = document.documentElement.classList.contains("light-theme");
        statusEl.textContent = "正在读取历史价格和分析结果...";
        await ensureEcharts();
        diag("echarts-loaded");
        diag("fetching-data");
        try {
        const [history, commandCenter, summary, lookthrough] = await Promise.all([
            getJson("/api/lab/history"), getJson("/api/command-center"), getJson("/api/portfolio/summary"), getJson("/api/etf-lookthrough?basis=market"),
        ]);
        const stats = history.stats || {}; latestNavRows = history.nav || [];
        const holdingsRows = commandCenter.holdings_detail?.rows || [];
        const quality = commandCenter.data_quality || {}; const meta = quality.sources || {};
        healthTrading212.textContent = `${meta.trading212?.positions || summary.open_positions || holdingsRows.length || 0} 持仓 · ${fmtUnixTime(meta.trading212?.as_of_unix)}`;
        healthMarket.textContent = `${meta.market?.rows || 0} 行情 · ${fmtUnixTime(meta.market?.as_of_unix)}`;
        healthFundamentals.textContent = `${meta.fundamentals?.provider || "FMP"} ${meta.fundamentals?.coverage || "0/0"} · ${fmtUnixTime(meta.fundamentals?.as_of_unix)}`;
        healthFundamentalsDot.classList.toggle("warn", Number(meta.fundamentals?.rows || 0) < Math.max(1, Number(meta.fundamentals?.total || 0)));
        healthHistory.textContent = `${history.nav?.length || 0} 交易日 · ${fmtUnixTime(history.history_as_of_unix)}`;
        const todayPnl = holdingsRows.reduce((sum, row) => { const change = Number(row.today_change_percent); const value = Number(row.market_value_usd || 0); if (!Number.isFinite(change) || !Number.isFinite(value)) return sum; const rate = change / 100; return sum + (value - value / (1 + rate)); }, 0);
        const previousMarketValue = Number(summary.market_value_usd || 0) - todayPnl;
        const todayReturn = previousMarketValue ? todayPnl / previousMarketValue : 0;
        const upCount = holdingsRows.filter(row => Number(row.today_change_percent || 0) > 0).length;
        const downCount = holdingsRows.filter(row => Number(row.today_change_percent || 0) < 0).length;
        const sharpeDelta = null;
        snapshotMarketValue.textContent = usd(summary.market_value_usd);
        snapshotMarketSub.textContent = `${signedUsd(todayPnl)} 今日`;
        snapshotTotalPnl.textContent = signedUsd(summary.unrealized_usd);
        annualReturn.textContent = `▲ ${fmtPct((summary.unrealized_usd || 0) / (summary.total_cost_usd_standard || 1))} 总收益率`;
        snapshotTodayPnl.textContent = signedUsd(todayPnl);
        annualVol.textContent = `▲ ${fmtPct(todayReturn)}`;
        snapshotHoldingsCount.textContent = summary.open_positions || holdingsRows.length || "—";
        snapshotBreadth.textContent = `↔ 上涨 ${upCount} / 下跌 ${downCount}`;
        sharpe.textContent = fmtNum(stats.sharpe);
        snapshotSharpeSub.textContent = sharpeDelta === null ? "基准数据不足" : `${sharpeDelta >= 0 ? "▲" : "▼"} vs SPY ${fmtNum(Math.abs(sharpeDelta))}`;
        setTone(snapshotMarketSub, todayPnl); setTone(snapshotTotalPnl, summary.unrealized_usd); setTone(annualReturn, summary.unrealized_usd);
        setTone(snapshotTodayPnl, todayPnl); setTone(annualVol, todayReturn); setTone(snapshotSharpeSub, sharpeDelta || 0);
        renderSparkline(snapshotMarketSpark, (history.nav || []).slice(-60).map(row => row.nav), "muted");
        renderSparkline(snapshotPnlSpark, (history.nav || []).slice(-60).map(row => row.nav - 1), Number(summary.unrealized_usd || 0) >= 0 ? "" : "negative");
        renderSparkline(snapshotTodaySpark, (history.nav || []).slice(-40).map(row => row.return), todayPnl >= 0 ? "" : "negative");
        // Daily P&L Calendar
        const _calNavRows = history.nav || [];
        const _calMv = Number(summary.market_value_usd || 0);
        const _calByDate = {};
        _calNavRows.forEach(row => { _calByDate[row.date] = _calMv * Number(row.return || 0); });
        const _now = new Date();
        let _calYear = _now.getFullYear(), _calMonth = _now.getMonth() + 1;
        // Jump to the most recent month that has data
        const _allDates = Object.keys(_calByDate).sort();
        if (_allDates.length) {
            const last = _allDates[_allDates.length - 1].split("-");
            _calYear = Number(last[0]); _calMonth = Number(last[1]);
        }
        function _fmtCalVal(v) {
            const a = Math.abs(v);
            return (v >= 0 ? "+" : "-") + (a >= 1000 ? "$" + (a / 1000).toFixed(1) + "k" : "$" + a.toFixed(0));
        }
        function _setCalStats(total, pos, neg, best, worst) {
            const t = document.querySelector("#calMonthTotal"); if (t) { t.textContent = _fmtCalVal(total); t.className = `pnl-cal-stat-value ${total >= 0 ? "positive" : "negative"}`; }
            const p = document.querySelector("#calPosDays"); if (p) p.textContent = pos + " 天";
            const n = document.querySelector("#calNegDays"); if (n) n.textContent = neg + " 天";
            const bd = document.querySelector("#calBestDay"); if (bd) bd.textContent = best !== null ? _fmtCalVal(best) : "—";
            const wd = document.querySelector("#calWorstDay"); if (wd) wd.textContent = worst !== null ? _fmtCalVal(worst) : "—";
        }
        function _renderMonthCal(year, month) {
            const container = document.querySelector("#pnlCalendar");
            if (!container) return;
            container.className = "pnl-cal-grid";
            const monthNames = ["一月","二月","三月","四月","五月","六月","七月","八月","九月","十月","十一月","十二月"];
            const calMonthLabel = document.querySelector("#calMonthLabel");
            if (calMonthLabel) calMonthLabel.textContent = `${year} 年 ${monthNames[month - 1]}`;
            const totalLabel = document.querySelector("#calTotalLabel"); if (totalLabel) totalLabel.textContent = "当月盈亏";
            const daysInMonth = new Date(year, month, 0).getDate();
            const startDow = new Date(year, month - 1, 1).getDay();
            let monthTotal = 0, posCount = 0, negCount = 0, bestDay = null, worstDay = null;
            for (let d = 1; d <= daysInMonth; d++) {
                const ds = `${year}-${String(month).padStart(2,"0")}-${String(d).padStart(2,"0")}`;
                const v = _calByDate[ds];
                if (v !== undefined) {
                    monthTotal += v;
                    if (v >= 0) posCount++; else negCount++;
                    if (bestDay === null || v > bestDay) bestDay = v;
                    if (worstDay === null || v < worstDay) worstDay = v;
                }
            }
            const weekdays = ["日","一","二","三","四","五","六"];
            let html = weekdays.map(d => `<div class="pnl-cal-weekday">${d}</div>`).join("");
            for (let i = 0; i < startDow; i++) html += `<div></div>`;
            for (let d = 1; d <= daysInMonth; d++) {
                const ds = `${year}-${String(month).padStart(2,"0")}-${String(d).padStart(2,"0")}`;
                const v = _calByDate[ds];
                if (v !== undefined) {
                    const pct = Math.max(8, Math.min(68, Math.abs(v) / Math.max(1, Math.abs(bestDay || worstDay || 1)) * 68));
                    const bg = `color-mix(in oklch, ${v >= 0 ? "#27a648" : "#e54d5e"} ${Math.round(pct)}%, var(--panel))`;
                    const col = v >= 0 ? "#27a648" : "#e54d5e";
                    html += `<div class="pnl-cal-day" style="background:${bg}" title="${ds}"><div class="pnl-cal-day-num">${d}</div><div class="pnl-cal-day-val" style="color:${col}">${_fmtCalVal(v)}</div></div>`;
                } else {
                    // No data (weekend, holiday, or future day) — same gray cell with the date
                    html += `<div class="pnl-cal-day no-trade"><div class="pnl-cal-day-num">${d}</div></div>`;
                }
            }
            container.innerHTML = html;
            _setCalStats(monthTotal, posCount, negCount, bestDay, worstDay);
        }
        function _renderYearCal(year) {
            const container = document.querySelector("#pnlCalendar");
            if (!container) return;
            container.className = "";
            const calMonthLabel = document.querySelector("#calMonthLabel");
            if (calMonthLabel) calMonthLabel.textContent = `${year} 年`;
            const totalLabel = document.querySelector("#calTotalLabel"); if (totalLabel) totalLabel.textContent = "全年盈亏";
            const isLeap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
            const daysInYear = isLeap ? 366 : 365;
            const ROWS = 5; // weekdays only (Mon–Fri); weekends never trade, so skip them
            let total = 0, pos = 0, neg = 0, best = null, worst = null, maxAbs = 1;
            const workdays = [];
            for (let i = 0; i < daysInYear; i++) {
                const dt = new Date(year, 0, 1 + i);
                const dow = dt.getDay();
                if (dow === 0 || dow === 6) continue; // skip Sat/Sun
                const ds = `${year}-${String(dt.getMonth() + 1).padStart(2,"0")}-${String(dt.getDate()).padStart(2,"0")}`;
                const v = _calByDate[ds];
                workdays.push({ ds, v, dow, month: dt.getMonth() });
                if (v !== undefined) { total += v; if (v >= 0) pos++; else neg++; if (best === null || v > best) best = v; if (worst === null || v < worst) worst = v; maxAbs = Math.max(maxAbs, Math.abs(v)); }
            }
            const leadBlanks = workdays.length ? (workdays[0].dow - 1) : 0; // Mon=row0 … Fri=row4
            let cells = "";
            for (let i = 0; i < leadBlanks; i++) cells += `<div class="pnl-cal-ycell blank"></div>`;
            for (const info of workdays) {
                if (info.v !== undefined) {
                    const pct = Math.max(12, Math.min(85, Math.abs(info.v) / maxAbs * 85));
                    const bg = `color-mix(in oklch, ${info.v >= 0 ? "#27a648" : "#e54d5e"} ${Math.round(pct)}%, var(--panel))`;
                    cells += `<div class="pnl-cal-ycell" style="background:${bg}" title="${info.ds}  ${_fmtCalVal(info.v)}"></div>`;
                } else {
                    cells += `<div class="pnl-cal-ycell" title="${info.ds}"></div>`;
                }
            }
            const monthShort = ["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"];
            const weekCols = Math.ceil((leadBlanks + workdays.length) / ROWS);
            let labels = "", lastMonth = -1;
            for (let w = 0; w < weekCols; w++) {
                const firstIdx = w * ROWS - leadBlanks;
                const idx = Math.max(0, Math.min(workdays.length - 1, firstIdx));
                const m = workdays[idx].month;
                if (firstIdx >= 0 && m !== lastMonth) { labels += `<div class="pnl-cal-ymlabel">${monthShort[m]}</div>`; lastMonth = m; }
                else labels += `<div class="pnl-cal-ymlabel"></div>`;
            }
            const cols = `repeat(${weekCols}, 13px)`;
            container.innerHTML = `<div class="pnl-cal-year-wrap"><div class="pnl-cal-ymonths" style="grid-template-columns:${cols}">${labels}</div><div class="pnl-cal-year" style="grid-template-columns:${cols}">${cells}</div></div>`;
            _setCalStats(total, pos, neg, best, worst);
        }
        let _calView = "month";
        function _renderCurrent() { if (_calView === "year") _renderYearCal(_calYear); else _renderMonthCal(_calYear, _calMonth); }
        _renderCurrent();
        document.querySelector("#calPrev")?.addEventListener("click", () => {
            if (_calView === "year") { _calYear--; } else { _calMonth--; if (_calMonth < 1) { _calMonth = 12; _calYear--; } }
            _renderCurrent();
        });
        document.querySelector("#calNext")?.addEventListener("click", () => {
            if (_calView === "year") { _calYear++; } else { _calMonth++; if (_calMonth > 12) { _calMonth = 1; _calYear++; } }
            _renderCurrent();
        });
        const _calTabMonth = document.querySelector("#calViewMonth"), _calTabYear = document.querySelector("#calViewYear");
        function _setCalView(view) {
            _calView = view;
            _calTabMonth?.classList.toggle("active", view === "month");
            _calTabYear?.classList.toggle("active", view === "year");
            _renderCurrent();
        }
        _calTabMonth?.addEventListener("click", () => _setCalView("month"));
        _calTabYear?.addEventListener("click", () => _setCalView("year"));

        const monthlyModelRows = commandCenter.monthly_returns?.rows || [];
        const monthLabels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        const yearLabels = [...new Set(monthlyModelRows.map(row => String(row.month || "").slice(0, 4)).filter(Boolean))].sort();
        const monthlyByYear = Object.fromEntries(yearLabels.map(year => [year, Array(12).fill(null)]));
        monthlyModelRows.forEach(row => {
            const year = String(row.month || "").slice(0, 4);
            const monthIndex = Number(String(row.month || "").slice(5, 7)) - 1;
            if (monthlyByYear[year] && monthIndex >= 0 && monthIndex < 12) monthlyByYear[year][monthIndex] = Number(row.return || 0);
        });

        chart("#monthlyReturnDarkChart").setOption({
            ...baseOption(),
            legend: { show: true, textStyle: { color: isLight ? "#374151" : "#9ca3af" } },
            xAxis: { type: "category", data: monthLabels },
            yAxis: { type: "value", axisLabel: { formatter: v => (v>=0?'+':'')+v.toFixed(1)+'%' } },
            series: yearLabels.map(year => ({
                name: year,
                type: "line",
                showSymbol: false,
                data: monthlyByYear[year] ? monthlyByYear[year].map(v => v != null ? v*100 : null) : []
            }))
        }, true);

        const sectorPalette = ["#8b5cf6", "#06b6d4", "#22c55e", "#f59e0b", "#ef4444", "#a855f7", "#14b8a6", "#f97316", "#3b82f6"];
        const sectorColor = new Map();
        function growthValue(row) { const eps = Number(row.eps_growth_yoy); const revenue = Number(row.revenue_growth_yoy); const raw = Number.isFinite(eps) && eps !== 0 ? eps : revenue; if (!Number.isFinite(raw)) return null; return Math.abs(raw) <= 2 ? raw * 100 : raw; }
        const valuationRows = (commandCenter.holdings_heatmap?.rows || []).map(row => { const pe = Number(row.forward_pe || row.trailing_pe); const growth = growthValue(row); return { ...row, pe, growth, growthSource: row.eps_growth_yoy ? "EPS 成长" : "营收成长" }; }).filter(row => Number.isFinite(row.pe) && row.pe > 0 && Number.isFinite(row.growth));
        valuationRows.forEach(row => { if (!sectorColor.has(row.sector)) sectorColor.set(row.sector, sectorPalette[sectorColor.size % sectorPalette.length]); });
        if (valuationRows.length) {
            renderValuationWaterline(valuationRows);
            chart("#valuationMatrixChart").setOption({ backgroundColor: "transparent", tooltip: { trigger: "item", backgroundColor: isLight ? "rgba(255,255,255,.96)" : "rgba(10,14,18,.96)", borderColor: isLight ? "rgba(0,0,0,0.1)" : "rgba(255,255,255,0.1)", textStyle: { color: isLight ? "#1a1a1a" : "#ededef" }, formatter: params => { const row = params.data.raw; return `${row.ticker}<br/>P/E ${fmtNum(row.pe)}<br/>${row.growthSource} ${fmtNum(row.growth)}%<br/>仓位 ${fmtPct(row.weight)}<br/>${row.display_name || row.name || ""}`; } }, grid: { left: 74, right: 28, top: 36, bottom: 58 }, xAxis: { type: "value", name: "P/E 倍数", nameLocation: "middle", nameGap: 36, nameTextStyle: { color: isLight ? "#475569" : "#9ca3af", fontSize: 14 }, splitLine: { lineStyle: { color: isLight ? "#e5e7eb" : "rgba(255,255,255,0.05)" } }, axisLine: { lineStyle: { color: isLight ? "#d1d5db" : "rgba(255,255,255,0.06)" } }, axisLabel: { color: isLight ? "#475569" : "#9ca3af", fontSize: 13 } }, yAxis: { type: "value", name: "成长率 %", nameLocation: "middle", nameGap: 50, nameTextStyle: { color: isLight ? "#374151" : "#9ca3af", fontSize: 14 }, splitLine: { lineStyle: { color: isLight ? "#e5e7eb" : "rgba(255,255,255,0.05)" } }, axisLine: { lineStyle: { color: isLight ? "#d1d5db" : "rgba(255,255,255,0.06)" } }, axisLabel: { color: isLight ? "#475569" : "#9ca3af", fontSize: 13 } }, series: [{ type: "scatter", data: valuationRows.map(row => ({ value: [row.pe, row.growth, row.weight], raw: row, itemStyle: { color: sectorColor.get(row.sector), borderColor: sectorColor.get(row.sector), borderWidth: 2, opacity: 0.72 } })), symbolSize: value => Math.max(12, Math.min(46, Math.sqrt(Number(value[2] || 0)) * 130)), label: { show: true, formatter: params => params.data.raw.ticker, position: "top", color: isLight ? "#4b5563" : "#aab4c1", fontSize: 11 } }] });
        } else {
            renderValuationWaterline([]);
            chart("#valuationMatrixChart").setOption({ backgroundColor: "transparent", title: { text: "估值数据还没更新", subtext: "刷新 fundamentals 后会显示 P/E、成长率和仓位气泡", left: "center", top: "middle", textStyle: { color: isLight ? "#1a1a1a" : "#f7f8f8", fontSize: 20, fontWeight: 700 }, subtextStyle: { color: isLight ? "#475569" : "#9ca3af", fontSize: 13, lineHeight: 20 } }, xAxis: { show: false }, yAxis: { show: false }, series: [] });
        }
        renderCommandCenter(commandCenter);
        updateDrawdownRange();
        // Populate Asset Merge (ETF Lookthrough Exposure) Table
        if (groupRows && lookthrough && lookthrough.rows) {
            const totalVal = Number(summary.market_value_usd || 1);
            groupRows.innerHTML = lookthrough.rows.slice(0, 10).map(row => {
                let memberText = "直接持仓";
                if (row.direct_usd > 0 && row.from_etf_usd > 0) {
                    memberText = "直接持仓 + ETF";
                } else if (row.direct_usd === 0 && row.from_etf_usd > 0) {
                    memberText = "ETF 穿透";
                }
                const w = row.total_usd / totalVal;
                return `
                  <tr>
                    <td><b>${row.ticker}</b> <span style="font-size:10px;color:var(--muted);">${row.name || ""}</span></td>
                    <td>${memberText}</td>
                    <td>${fmtPct(w)}</td>
                  </tr>
                `;
            }).join("");
        }

        diag("render-done");
        statusEl.textContent = `完成：${history.nav?.length || 0} 个交易日，${summary.open_positions || holdingsRows.length || 0} 个持仓`;
    } catch(e) {
        diag("ERROR:"+e.message);
        statusEl.innerHTML = `<span style="color:var(--negative)">渲染失败：${e.message}<br><small>${e.stack}</small></span>`;
        console.error(e);
        fetch("/api/log-error", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message: e.message, stack: e.stack })
        }).catch(() => {});
    }
    }
    refreshHistory.addEventListener("click", async () => { refreshHistory.disabled = true; statusEl.textContent = "正在刷新历史价格..."; try { await getJson("/api/lab/refresh-history?force=true", { method: "POST" }); await loadLab(); } catch (error) { statusEl.textContent = `刷新失败：${error.message}`; } finally { refreshHistory.disabled = false; } });
    drawdownRangeSelect?.addEventListener("change", updateDrawdownRange);
    returnBasisButtons.forEach(btn => btn.addEventListener("click", () => setReturnBasis(btn.dataset.returnBasis)));
    loadLab().catch(error => {
        statusEl.textContent = `加载失败：${error.message}`;
        console.error(error);
        fetch("/api/log-error", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ message: error.message, stack: error.stack })
        }).catch(() => {});
    });

// ── Per-card AI 解读 ────────────────────────────────────────────────────────
// Injects an "AI 解读" button into every analysis card's header. Clicking asks
// the AI to interpret that specific chart (grounded in the live portfolio data
// via /api/ai/ask). Results render inline in the card; re-clicking toggles.
(function () {
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));

  async function ask(question) {
    const res = await fetch("/api/ai/ask", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question }),
    });
    if (!res.ok) {
      throw new Error(res.status === 500
        ? "请先在「设置」页配置 AI API Key（DeepSeek 或 Grok）"
        : `HTTP ${res.status}`);
    }
    return res.json();
  }

  // Per-card focus: steer the AI to THIS card's topic so answers don't all
  // converge on the same generic concentration/NVDA summary.
  const AI_BASE = "用中文回答，3-4 句话，直接给结论、不要客套；只围绕本图表的主题展开，避免重复其他图表已讲过的仓位集中度/单票占比等泛泛内容。";
  const AI_FOCUS = [
    ["集中度", "聚焦行业/板块集中度：最大的板块敞口是什么、是否过度集中于某行业、板块分散性如何"],
    ["盈亏贡献", "聚焦盈亏来源：主要盈利来自哪几只、谁在拖累、盈亏是否集中在少数标的"],
    ["估值矩阵", "聚焦估值：哪些持仓偏贵（高 P/E、低成长）、哪些便宜（低 P/E、高成长）、组合整体估值是否健康"],
    ["相关性", "聚焦相关性与真实分散度：哪些标的高度同涨同跌、是否存在“假分散”"],
    ["回撤", "聚焦下行风险：最大回撤幅度与持续时间、当前是否仍处于回撤、回撤控制是否合理"],
    ["收益率分布", "聚焦日收益分布形态：日波动幅度、上涨/下跌天数比例、是否存在肥尾或极端单日"],
    ["月度收益", "聚焦月度收益节奏：哪些月份强/弱、是否存在季节性、波动是否集中在特定月份"],
    ["Waterfall", "聚焦当月收益归因：哪几只标的拉高、哪几只拖累了当月收益"],
    ["归因", "聚焦当月收益归因：哪几只标的拉高、哪几只拖累了当月收益"],
    ["累计收益", "聚焦相对基准的累计表现：跑赢还是跑输、主要发生在哪些阶段、超额收益是否稳定"],
    ["持仓明细", "聚焦个股层面：仓位最大的几只、成本与现价偏离最大的、今日异动明显的标的"],
  ];
  function aiPrompt(title) {
    const hit = AI_FOCUS.find(([k]) => title.includes(k));
    const focus = hit ? hit[1] : `解读「${title}」中的关键信息`;
    return `请基于我的真实持仓数据，${focus}。${AI_BASE}`;
  }

  const cards = Array.from(document.querySelectorAll(".command-card, .daily-pnl-panel"));
  cards.forEach((card) => {
    if (card.querySelector("#pnlCalendar")) return;            // calendar has its own controls
    const head = card.querySelector(".chart-head, .daily-pnl-head");
    if (!head || head.querySelector(".ai-card-btn")) return;
    const titleEl = head.querySelector("h2, .daily-pnl-title");
    const title = (titleEl?.textContent || "").trim();
    if (!title) return;

    const btn = document.createElement("button");
    btn.className = "ai-card-btn";
    btn.style.marginLeft = "auto";
    btn.title = "AI 解读";
    btn.setAttribute("aria-label", "AI 解读");
    btn.innerHTML = '<i class="fa-solid fa-wand-magic-sparkles"></i>';
    head.appendChild(btn);

    const result = document.createElement("div");
    result.className = "ai-card-result";
    result.hidden = true;
    card.appendChild(result);

    let loaded = false;
    btn.addEventListener("click", async () => {
      if (loaded) { result.hidden = !result.hidden; return; }   // toggle once loaded
      result.hidden = false;
      result.classList.remove("err");
      result.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> AI 正在解读…';
      btn.disabled = true;
      try {
        const data = await ask(aiPrompt(title));
        result.innerHTML = '<span class="ai-card-tag"><i class="fa-solid fa-wand-magic-sparkles"></i></span>' + esc(data.answer);
        loaded = true;
      } catch (e) {
        result.classList.add("err");
        result.innerHTML = "AI 解读失败：" + esc(e.message);
      } finally {
        btn.disabled = false;
      }
    });
  });
})();
