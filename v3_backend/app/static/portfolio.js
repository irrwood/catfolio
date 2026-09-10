(function () {
  const isEnglish = (document.documentElement.lang || "zh").startsWith("en");
  const locale = isEnglish ? "en-GB" : "zh-CN";
  const copy = isEnglish ? {
    loading: "Reading portfolio data",
    ready: "Portfolio is up to date",
    failed: "Portfolio data unavailable",
    today: "today",
    totalReturn: "total return",
    up: "Up",
    down: "Down",
    largest: "Largest position",
    noHistory: "Cost and market-value history is not available yet",
    market: "Current Market Value",
    cost: "Net Invested Cost",
  } : {
    loading: "正在读取组合数据",
    ready: "组合数据已更新",
    failed: "组合数据暂时不可用",
    today: "今日",
    totalReturn: "总收益率",
    up: "上涨",
    down: "下跌",
    largest: "最大单一仓位",
    noHistory: "暂无可用的成本与市值历史数据",
    market: "当前总市值",
    cost: "净投入成本",
  };

  const elements = {
    status: document.querySelector("#portfolioStatus"),
    value: document.querySelector("#portfolioValue"),
    today: document.querySelector("#portfolioToday"),
    pnl: document.querySelector("#portfolioPnl"),
    pnlRate: document.querySelector("#portfolioPnlRate"),
    count: document.querySelector("#portfolioCount"),
    breadth: document.querySelector("#portfolioBreadth"),
    topFive: document.querySelector("#portfolioTopFive"),
    topOne: document.querySelector("#portfolioTopOne"),
    chart: document.querySelector("#costValueChart"),
    ranges: Array.from(document.querySelectorAll("[data-range]")),
  };

  const RANGE_DAYS = { "1d": 2, "1w": 5, "1m": 21, "3m": 63, "1y": 252 };
  const CHART_COLORS = {
    market: "#2F8A3E",
    cost: "#708CFF",
    grid: "#EAEBED",
    date: "#000000",
  };
  const cssVar = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  function syncChartColors() {
    CHART_COLORS.market = cssVar("--positive") || "#2F8A3E";
    CHART_COLORS.grid = cssVar("--line-strong") || "#EAEBED";
    CHART_COLORS.date = cssVar("--ink") || "#000000";
  }
  let activeRange = "3m";
  let valueRows = [];
  let chartInstance = null;
  let highlightedIndex = null;
  let pendingHighlightIndex = null;
  let highlightFrame = null;
  let chartHoverLayer = null;
  let marketHoverBubble = null;
  let costHoverBubble = null;
  let dateHoverBubble = null;
  let marketHoverDot = null;
  let costHoverDot = null;
  const metricAnimations = new WeakMap();

  const numeric = (row, keys, fallback = 0) => {
    for (const key of keys) {
      const raw = row?.[key];
      if (raw === undefined || raw === null || raw === "") continue;
      const value = Number(raw);
      if (Number.isFinite(value)) return value;
    }
    return fallback;
  };
  const money = value => `$${Math.abs(Number(value || 0)).toLocaleString(locale, { maximumFractionDigits: 0 })}`;
  const signedMoney = value => `${Number(value || 0) >= 0 ? "+" : "-"}${money(value)}`;
  const ratioPct = value => `${(Number(value || 0) * 100).toFixed(1)}%`;
  const signedRatioPct = value => `${Number(value || 0) >= 0 ? "+" : ""}${ratioPct(value)}`;

  function setTone(element, value) {
    if (!element) return;
    element.classList.toggle("positive", Number(value || 0) >= 0);
    element.classList.toggle("negative", Number(value || 0) < 0);
  }

  function animateMetric(element, targetValue, formatter, delay = 0) {
    if (!element) return;

    const previous = metricAnimations.get(element);
    if (previous?.timer) window.clearTimeout(previous.timer);
    if (previous?.frame) window.cancelAnimationFrame(previous.frame);

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      element.textContent = formatter(targetValue);
      metricAnimations.set(element, { value: targetValue, timer: null, frame: null });
      return;
    }

    const startValue = Number.isFinite(previous?.value) ? previous.value : 0;
    const state = { value: startValue, timer: null, frame: null };
    element.textContent = formatter(startValue);

    state.timer = window.setTimeout(() => {
      const startedAt = performance.now();
      const duration = 720;

      const tick = now => {
        const progress = Math.min(1, (now - startedAt) / duration);
        const eased = 1 - Math.pow(1 - progress, 4);
        state.value = startValue + (targetValue - startValue) * eased;
        element.textContent = formatter(state.value);

        if (progress < 1) {
          state.frame = window.requestAnimationFrame(tick);
        } else {
          state.value = targetValue;
          state.frame = null;
          element.textContent = formatter(targetValue);
        }
      };

      state.timer = null;
      state.frame = window.requestAnimationFrame(tick);
    }, delay);
    metricAnimations.set(element, state);
  }

  function normalizeValueRows(payload) {
    const cashFlow = payload?.cash_flow_mirror || {};
    const rows = (cashFlow.rows || []).map(row => ({
      date: row.date,
      market: numeric(row, ["portfolio_value", "adjusted_portfolio_value", "portfolio"], null),
      cost: numeric(row, ["net_cash_flow", "invested_cost_usd", "buy_total", "buy_total_usd"], null),
    })).filter(row => row.date && Number.isFinite(row.market) && Number.isFinite(row.cost));

    const current = payload?.current_point || {};
    const currentRow = {
      date: current.date,
      market: numeric(current, ["market_value_usd"], null),
      cost: numeric(current, ["cost_usd"], null),
    };
    if (currentRow.date && Number.isFinite(currentRow.market) && Number.isFinite(currentRow.cost)) {
      const existingIndex = rows.findIndex(row => row.date === currentRow.date);
      if (existingIndex >= 0) {
        rows[existingIndex] = currentRow;
      } else {
        rows.push(currentRow);
        rows.sort((left, right) => String(left.date).localeCompare(String(right.date)));
      }
    }
    return rows;
  }

  function visibleRows() {
    if (activeRange === "max") return valueRows;
    if (activeRange === "ytd") {
      const year = new Date().getFullYear();
      const rows = valueRows.filter(row => Number(String(row.date).slice(0, 4)) === year);
      return rows.length ? rows : valueRows.slice(-252);
    }
    return valueRows.slice(-RANGE_DAYS[activeRange]);
  }

  function axisMoney(value) {
    const abs = Math.abs(Number(value || 0));
    if (abs >= 1_000_000) return `${(value / 1_000_000).toFixed(abs >= 10_000_000 ? 0 : 1)}M`;
    if (abs >= 1_000) {
      const thousands = value / 1_000;
      const integer = Math.round(thousands);
      return `${Math.abs(thousands - integer) < 0.05 ? integer : thousands.toFixed(1)}K`;
    }
    return Math.round(value).toLocaleString(locale);
  }

  function monthLabel(value) {
    const date = new Date(`${value}T00:00:00`);
    if (Number.isNaN(date.getTime())) return value;
    if (date.getMonth() === 0) return String(date.getFullYear());
    return ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"][date.getMonth()];
  }

  function dayLabel(value) {
    const date = new Date(`${value}T00:00:00`);
    if (Number.isNaN(date.getTime())) return value;
    const month = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"][date.getMonth()];
    return `${String(date.getDate()).padStart(2, "0")} ${month}`;
  }

  function sampledIndices(indices, limit) {
    if (indices.length <= limit) return indices;
    const step = Math.ceil(indices.length / limit);
    return indices.filter((_, position) => position % step === 0);
  }

  function timeAxis(rows) {
    const allIndices = rows.map((_, index) => index);
    if (activeRange === "1d" || activeRange === "1w") {
      return { indices: new Set(allIndices), formatter: dayLabel };
    }
    if (activeRange === "1m") {
      return { indices: new Set(sampledIndices(allIndices, 6)), formatter: dayLabel };
    }

    const monthIndices = [];
    let previousMonth = "";
    rows.forEach((row, index) => {
      const month = String(row.date).slice(0, 7);
      if (month !== previousMonth) {
        monthIndices.push(index);
        previousMonth = month;
      }
    });
    const limit = activeRange === "3m" ? 4 : 8;
    return { indices: new Set(sampledIndices(monthIndices, limit)), formatter: monthLabel };
  }

  function chartSeries(rows) {
    const bounds = chartBounds(rows);
    return [
      {
        name: copy.market,
        type: "line",
        z: 5,
        data: rows.map(row => [row.date, row.market]),
        showSymbol: false,
        smooth: 0.32,
        clip: false,
        lineStyle: { color: CHART_COLORS.market, width: 2, cap: "round" },
        itemStyle: { color: CHART_COLORS.market },
        emphasis: { disabled: true },
        markLine: {
          silent: true,
          symbol: ["none", "none"],
          animation: false,
          label: { show: false },
          lineStyle: { color: CHART_COLORS.grid, width: 1, type: "solid", cap: "round" },
          data: visibleYAxisValues(bounds).map(value => ({ yAxis: value })),
        },
      },
      {
        name: copy.cost,
        type: "line",
        z: 5,
        data: rows.map(row => [row.date, row.cost]),
        showSymbol: false,
        smooth: 0.32,
        clip: false,
        lineStyle: { color: CHART_COLORS.cost, width: 2, cap: "round" },
        itemStyle: { color: CHART_COLORS.cost },
        emphasis: { disabled: true },
      },
    ];
  }

  function ensureChartHoverLayer() {
    if (chartHoverLayer || !elements.chart) return;
    chartHoverLayer = document.createElement("div");
    chartHoverLayer.className = "portfolio-chart-hover-layer";
    chartHoverLayer.setAttribute("aria-hidden", "true");
    const create = (className) => {
      const node = document.createElement("span");
      node.className = className;
      node.hidden = true;
      chartHoverLayer.appendChild(node);
      return node;
    };
    marketHoverDot = create("portfolio-chart-hover-dot market");
    costHoverDot = create("portfolio-chart-hover-dot cost");
    marketHoverBubble = create("portfolio-chart-hover-bubble market");
    costHoverBubble = create("portfolio-chart-hover-bubble cost is-below");
    dateHoverBubble = create("portfolio-chart-hover-date");
    elements.chart.appendChild(chartHoverLayer);
  }

  function hideChartHover() {
    [marketHoverDot, costHoverDot, marketHoverBubble, costHoverBubble, dateHoverBubble]
      .forEach(node => { if (node) node.hidden = true; });
  }

  function hoverDateLabel(date) {
    return new Intl.DateTimeFormat(isEnglish ? "en-GB" : "zh-CN", {
      day: "2-digit", month: "short", year: "2-digit",
    }).format(new Date(`${date}T00:00:00`)).toUpperCase();
  }

  function clampedHoverX(node, x) {
    const halfWidth = Math.max(20, node.offsetWidth / 2);
    return Math.max(halfWidth + 2, Math.min(elements.chart.clientWidth - halfWidth - 2, x));
  }

  function positionChartHover(rows, markerIndex) {
    if (!chartInstance || !rows.length) return;
    ensureChartHoverLayer();
    const index = Math.max(0, Math.min(rows.length - 1, markerIndex));
    const point = rows[index];
    const bounds = chartBounds(rows);
    const marketPixel = chartInstance.convertToPixel({ xAxisIndex: 0, yAxisIndex: 0 }, [point.date, point.market]);
    const costPixel = chartInstance.convertToPixel({ xAxisIndex: 0, yAxisIndex: 0 }, [point.date, point.cost]);
    const datePixel = chartInstance.convertToPixel({ xAxisIndex: 0, yAxisIndex: 0 }, [point.date, bounds.max]);
    if (![marketPixel, costPixel, datePixel].every(pixel => Array.isArray(pixel) && pixel.every(Number.isFinite))) {
      hideChartHover();
      return;
    }

    marketHoverBubble.textContent = axisMoney(point.market);
    costHoverBubble.textContent = axisMoney(point.cost);
    dateHoverBubble.textContent = hoverDateLabel(point.date);
    [marketHoverDot, costHoverDot, marketHoverBubble, costHoverBubble, dateHoverBubble]
      .forEach(node => { node.hidden = false; });

    marketHoverDot.style.left = `${marketPixel[0]}px`;
    marketHoverDot.style.top = `${marketPixel[1]}px`;
    costHoverDot.style.left = `${costPixel[0]}px`;
    costHoverDot.style.top = `${costPixel[1]}px`;
    marketHoverBubble.style.left = `${clampedHoverX(marketHoverBubble, marketPixel[0])}px`;
    marketHoverBubble.style.top = `${marketPixel[1]}px`;
    costHoverBubble.style.left = `${clampedHoverX(costHoverBubble, costPixel[0])}px`;
    costHoverBubble.style.top = `${costPixel[1]}px`;
    dateHoverBubble.style.left = `${clampedHoverX(dateHoverBubble, datePixel[0])}px`;
    dateHoverBubble.style.top = `${Math.max(14, datePixel[1])}px`;
  }

  function chartBounds(rows) {
    const values = rows.flatMap(row => [row.market, row.cost]).filter(Number.isFinite);
    const low = Math.min(...values);
    const high = Math.max(...values);
    const rawSpan = Math.max(1, high - low);
    const paddedLow = Math.max(0, low - rawSpan * 0.12);
    const paddedHigh = high + rawSpan * 0.12;
    const roughStep = Math.max(1, (paddedHigh - paddedLow) / 6);
    const power = 10 ** Math.floor(Math.log10(roughStep));
    const normalized = roughStep / power;
    const factor = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
    const interval = factor * power;
    const min = Math.floor(paddedLow / interval) * interval;
    const max = Math.ceil(paddedHigh / interval) * interval;
    const intervalCount = Math.max(1, Math.round((max - min) / interval));
    const axisInterval = intervalCount % 2 === 0 ? interval : interval / 2;
    return {
      min,
      max,
      interval: axisInterval,
    };
  }

  function visibleYAxisValues(bounds) {
    const lastIndex = Math.max(0, Math.round((bounds.max - bounds.min) / bounds.interval));
    const values = [];
    for (let index = 0; index <= lastIndex; index += 1) {
      if (index === 0 || index === lastIndex || index % 2 === 0) {
        values.push(bounds.min + bounds.interval * index);
      }
    }
    return values;
  }

  function isVisibleYAxisValue(value, bounds) {
    const index = Math.round((Number(value) - bounds.min) / bounds.interval);
    const lastIndex = Math.max(0, Math.round((bounds.max - bounds.min) / bounds.interval));
    return index === 0 || index === lastIndex || index % 2 === 0;
  }

  function showEmptyState() {
    syncChartColors();
    hideChartHover();
    chartInstance?.clear();
    chartInstance?.setOption({
      graphic: [{
        type: "text",
        left: "center",
        top: "middle",
        style: { text: copy.noHistory, fill: cssVar("--muted") || "#888", font: "12px Nunito, system-ui" },
      }],
    });
  }

  function renderChart() {
    if (!window.echarts || !elements.chart) return;
    if (highlightFrame !== null) {
      window.cancelAnimationFrame(highlightFrame);
      highlightFrame = null;
    }
    pendingHighlightIndex = null;
    syncChartColors();
    if (!chartInstance) {
      chartInstance = window.echarts.init(elements.chart);
      ensureChartHoverLayer();
      chartInstance.on("updateAxisPointer", event => {
        const rows = visibleRows();
        const axisValue = event.axesInfo?.[0]?.value;
        const index = Number.isInteger(axisValue)
          ? axisValue
          : rows.findIndex(row => row.date === axisValue);
        if (index < 0 || index === highlightedIndex) return;
        pendingHighlightIndex = index;
        if (highlightFrame !== null) return;
        highlightFrame = window.requestAnimationFrame(() => {
          highlightFrame = null;
          const nextIndex = pendingHighlightIndex;
          pendingHighlightIndex = null;
          if (!Number.isInteger(nextIndex) || nextIndex === highlightedIndex) return;
          highlightedIndex = nextIndex;
          positionChartHover(rows, nextIndex);
        });
      });
    }

    const rows = visibleRows();
    if (!rows.length) {
      showEmptyState();
      return;
    }

    highlightedIndex = rows.length - 1;
    const bounds = chartBounds(rows);
    chartInstance.setOption({
      animation: true,
      animationDuration: 420,
      animationDurationUpdate: 220,
      animationEasing: "cubicOut",
      animationEasingUpdate: "cubicOut",
      backgroundColor: "transparent",
      textStyle: { fontFamily: "Nunito Local, Nunito, sans-serif" },
      grid: { left: 0, right: 8, top: 14, bottom: 8, containLabel: true },
      axisPointer: { z: 1, animation: false, animationDurationUpdate: 0 },
      tooltip: {
        trigger: "axis",
        showContent: false,
        confine: true,
        transitionDuration: 0,
        axisPointer: {
          z: 1,
          type: "line",
          snap: true,
          animation: false,
          lineStyle: { color: CHART_COLORS.grid, width: 1, type: "solid", cap: "round" },
          label: {
            show: false,
          },
        },
      },
      xAxis: {
        type: "category",
        position: "top",
        boundaryGap: false,
        data: rows.map(row => row.date),
        axisLine: { show: false },
        axisTick: { show: false },
        axisLabel: { show: false },
        axisPointer: {
          show: true,
          z: 1,
          label: { show: false },
        },
      },
      yAxis: {
        type: "value",
        min: bounds.min,
        max: bounds.max,
        interval: bounds.interval,
        axisLine: { show: false },
        axisTick: { show: false },
        axisLabel: {
          color: cssVar("--muted"),
          fontSize: 12,
          fontWeight: 700,
          margin: 20,
          formatter: value => isVisibleYAxisValue(value, bounds) ? axisMoney(value) : "",
        },
        splitLine: { show: false },
      },
      series: chartSeries(rows),
    }, true);

    requestAnimationFrame(() => {
      positionChartHover(rows, highlightedIndex);
      chartInstance.dispatchAction({ type: "showTip", seriesIndex: 0, dataIndex: highlightedIndex });
    });
  }

  function renderOverview(overview) {
    const summary = overview.summary || {};
    const holdings = overview.top_holdings || [];
    const marketValue = Number(summary.market_value_usd || 0);
    const todayPnl = Number(overview.today_pnl_usd || 0);
    const previousValue = marketValue - todayPnl;
    const totalPnl = Number(summary.unrealized_usd || 0);
    const totalCost = Number(summary.total_cost_usd_standard || 0);
    const topFive = holdings.slice(0, 5).reduce((sum, row) => sum + Number(row.weight || 0), 0);
    const topOne = Number(holdings[0]?.weight || 0);

    animateMetric(elements.value, marketValue, money, 0);
    elements.today.textContent = `${signedMoney(todayPnl)} ${copy.today}`;
    animateMetric(elements.pnl, Math.abs(totalPnl), value => `${totalPnl >= 0 ? "+" : "-"}${money(value)}`, 55);
    elements.pnlRate.textContent = `${signedRatioPct(totalCost ? totalPnl / totalCost : 0)} ${copy.totalReturn}`;
    animateMetric(elements.count, Number(summary.open_positions ?? holdings.length), value => String(Math.round(value)), 110);
    elements.breadth.textContent = `${copy.up} ${overview.breadth?.up || 0} / ${copy.down} ${overview.breadth?.down || 0}`;
    animateMetric(elements.topFive, topFive, ratioPct, 165);
    elements.topOne.textContent = `${copy.largest} ${ratioPct(topOne)}`;

    setTone(elements.today, todayPnl);
    setTone(elements.pnl, totalPnl);
    setTone(elements.pnlRate, totalPnl);
    if (previousValue === 0) elements.today.textContent = `${signedMoney(todayPnl)} ${copy.today}`;
  }

  function syncRangeButtons() {
    elements.ranges.forEach(button => {
      const active = button.dataset.range === activeRange;
      button.classList.toggle("active", active);
      button.setAttribute("aria-pressed", active ? "true" : "false");
    });
  }

  function selectRange(range) {
    activeRange = range;
    syncRangeButtons();
    renderChart();
  }

  async function loadPortfolio() {
    elements.status.textContent = copy.loading;
    try {
      const [overviewResponse, returnsResponse] = await Promise.all([
        fetch("/api/portfolio/overview"),
        fetch("/api/portfolio/chart", { cache: "no-store" }),
      ]);
      if (!overviewResponse.ok || !returnsResponse.ok) {
        throw new Error(`HTTP ${overviewResponse.status}/${returnsResponse.status}`);
      }
      const [overview, returns] = await Promise.all([overviewResponse.json(), returnsResponse.json()]);
      renderOverview(overview);
      valueRows = normalizeValueRows(returns);
      renderChart();
      elements.status.textContent = copy.ready;
    } catch (error) {
      elements.status.textContent = `${copy.failed}: ${error.message}`;
      showEmptyState();
    }
  }

  elements.ranges.forEach(button => button.addEventListener("click", () => selectRange(button.dataset.range)));
  window.addEventListener("resize", () => chartInstance?.resize());
  window.addEventListener("catfolio:themechange", () => {
    if (chartInstance) renderChart();
  });

  syncRangeButtons();
  loadPortfolio();
})();
