(() => {
  const chartLang = document.documentElement.lang.startsWith("zh") ? "zh" : "en";
  const chartCopy = chartLang === "zh"
    ? {
        portfolio: "组合",
        loadError: (message) => `对比数据加载失败（${message}）。`,
        aiError: (message) => `AI 解读失败：${message}`,
      }
    : {
        portfolio: "Portfolio",
        loadError: (message) => `Comparison data could not be loaded (${message}).`,
        aiError: (message) => `AI explanation failed: ${message}`,
      };

  const COLORS = {
    portfolio: "#22c55e",
    SPY: "#f97316",
    QQQ: "#708cff",
    grid: "#eaebed",
    text: "rgba(9,15,5,0.60)",
  };

  const BENCHMARK_COLORS = {
    SPY: "#f97316",
    QQQ: "#708cff",
    VTI: "#8b5cf6",
    VOO: "#06b6d4",
    DIA: "#eab308",
    IWM: "#ec4899",
    VEU: "#a855f7",
    GLD: "#d89b22",
  };

  const container = document.getElementById("returnsChart");
  const empty = document.getElementById("returnsChartEmpty");
  const endLabels = document.getElementById("comparisonEndLabels");
  const crosshairDate = document.getElementById("comparisonCrosshairDate");
  const crosshairValue = document.getElementById("comparisonCrosshairValue");
  const rangeButtons = [...document.querySelectorAll(".comparison-ranges button")];
  let chart = null;
  let resizeObserver = null;
  let allDates = [];
  let portfolioSeries = null;
  let portfolioRows = [];
  let benchmarkRows = {};
  const seriesMeta = [];

  const themeColor = (name, fallback) => (
    getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback
  );

  function currentChartTheme() {
    return {
      background: "rgba(0, 0, 0, 0)",
      text: themeColor("--muted", COLORS.text),
      grid: themeColor("--line-strong", COLORS.grid),
      crosshairLabel: themeColor("--ink", "#000000"),
    };
  }

  function applyChartTheme() {
    if (!chart) return;
    const theme = currentChartTheme();
    chart.applyOptions({
      layout: {
        background: { type: "solid", color: theme.background },
        textColor: theme.text,
      },
      grid: {
        horzLines: { color: theme.grid },
      },
      crosshair: {
        vertLine: {
          visible: false,
          labelVisible: false,
        },
      },
    });
  }

  const finiteNumber = (value) => {
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  };

  const compactValue = (value) => {
    const number = Number(value) || 0;
    const absolute = Math.abs(number);
    if (absolute >= 1_000_000) return `${(number / 1_000_000).toFixed(1)}M`;
    if (absolute >= 1_000) return `${Math.round(number / 1_000)}K`;
    return Math.round(number).toLocaleString(chartLang === "zh" ? "zh-CN" : "en-US");
  };

  const compactRows = (dates, values) => dates
    .map((date, index) => ({ time: date, value: finiteNumber(values?.[index]) }))
    .filter((row) => row.time && row.value !== null);

  function formatReturn(value) {
    const number = finiteNumber(value);
    if (number === null) return { text: "—", className: "" };
    const percent = number * 100;
    return {
      text: `${percent >= 0 ? "+" : ""}${percent.toFixed(1)}%`,
      className: percent >= 0 ? "positive" : "negative",
    };
  }

  function updateSummary(summary = {}) {
    [
      ["comparisonPortfolioReturn", summary.portfolio_return],
      ["comparisonBenchmarkReturn", summary.benchmark_return],
    ].forEach(([id, value]) => {
      const node = document.getElementById(id);
      if (!node) return;
      const formatted = formatReturn(value);
      node.textContent = formatted.text;
      node.classList.remove("positive", "negative");
      if (formatted.className) node.classList.add(formatted.className);
    });
  }

  function setComparisonData(payload) {
    const dates = Array.isArray(payload?.dates) ? payload.dates : [];
    portfolioRows = compactRows(dates, payload?.portfolio || []);
    benchmarkRows = Object.fromEntries(
      Object.entries(payload?.benchmarks || {}).map(([symbol, values]) => [symbol, compactRows(dates, values)])
    );
    allDates = portfolioRows.map((row) => row.time);
    updateSummary(payload?.summary);
  }
  function chartHeight() {
    return Math.max(398, Math.round(container.getBoundingClientRect().height || 398));
  }

  function adaptiveAutoscale(baseImplementation) {
    const scale = baseImplementation();
    const range = scale?.priceRange;
    if (!range) return scale;
    const min = finiteNumber(range.minValue);
    const max = finiteNumber(range.maxValue);
    if (min === null || max === null) return scale;
    const magnitude = Math.max(Math.abs(min), Math.abs(max), 1);
    const span = Math.max(max - min, magnitude * 0.015);
    const padding = span * 0.08;
    return {
      ...scale,
      priceRange: {
        minValue: min - padding,
        maxValue: max + padding,
      },
    };
  }

  function createSeries(title, color, data, width = 2) {
    const series = chart.addLineSeries({
      title: "",
      color,
      lineWidth: width,
      lineType: LightweightCharts.LineType?.Curved ?? 2,
      crosshairMarkerVisible: true,
      crosshairMarkerRadius: title === "Portfolio" ? 4 : 3,
      crosshairMarkerBorderColor: color,
      crosshairMarkerBackgroundColor: color,
      lastValueVisible: false,
      priceLineVisible: false,
      priceFormat: { type: "custom", formatter: compactValue },
      autoscaleInfoProvider: adaptiveAutoscale,
    });
    series.setData(data);
    seriesMeta.push({
      title,
      color,
      data,
      series,
      primary: title === "Portfolio" || title === "SPY" || title === "QQQ",
    });
    return series;
  }

  function timeKey(time) {
    if (typeof time === "string") return time;
    if (!time || typeof time !== "object") return "";
    return `${time.year}-${String(time.month).padStart(2, "0")}-${String(time.day).padStart(2, "0")}`;
  }

  function rowAtVisibleEnd(meta, visibleTo) {
    if (!meta.data.length) return null;
    if (!visibleTo) return meta.data[meta.data.length - 1];
    for (let index = meta.data.length - 1; index >= 0; index -= 1) {
      if (meta.data[index].time <= visibleTo) return meta.data[index];
    }
    return null;
  }

  function ensureEndLabel(meta) {
    if (meta.label) return meta.label;
    const label = document.createElement("div");
    label.className = `comparison-end-label${meta.primary ? "" : " secondary"}`;
    label.style.background = meta.color;
    const name = document.createElement("span");
    name.textContent = meta.title;
    const value = document.createElement("span");
    value.className = "comparison-end-label-value";
    label.append(name, value);
    endLabels.appendChild(label);
    meta.label = label;
    meta.labelValue = value;
    return label;
  }

  function updateEndLabels() {
    if (!chart || !endLabels) return;
    const visibleTo = timeKey(chart.timeScale().getVisibleRange()?.to);
    const maxY = Math.max(20, container.clientHeight - 14);
    const positions = [];

    seriesMeta.forEach((meta) => {
      const label = ensureEndLabel(meta);
      const row = rowAtVisibleEnd(meta, visibleTo);
      const coordinate = row ? meta.series.priceToCoordinate(row.value) : null;
      const timeCoordinate = row ? chart.timeScale().timeToCoordinate(row.time) : null;
      if (coordinate === null || timeCoordinate === null || coordinate < -20 || coordinate > container.clientHeight + 20) {
        label.hidden = true;
        return;
      }
      meta.labelValue.textContent = compactValue(row.value);
      label.hidden = false;
      positions.push({ meta, target: Math.max(14, Math.min(maxY, coordinate)), y: 0, x: timeCoordinate });
    });

    positions.sort((a, b) => a.target - b.target);
    positions.forEach((item, index) => {
      const gap = item.meta.primary ? 24 : 21;
      item.y = index === 0 ? item.target : Math.max(item.target, positions[index - 1].y + gap);
    });
    if (positions.length && positions[positions.length - 1].y > maxY) {
      const overflow = positions[positions.length - 1].y - maxY;
      positions.forEach((item) => { item.y -= overflow; });
      for (let index = positions.length - 2; index >= 0; index -= 1) {
        const gap = positions[index + 1].meta.primary ? 24 : 21;
        positions[index].y = Math.min(positions[index].y, positions[index + 1].y - gap);
      }
    }
    positions.forEach((item) => {
      item.meta.label.style.top = `${Math.max(14, item.y)}px`;
      const labelWidth = item.meta.label.offsetWidth;
      const left = Math.max(0, Math.min(container.clientWidth - labelWidth - 2, item.x + 2));
      item.meta.label.style.left = `${left}px`;
    });
  }

  function crosshairDateLabel(time) {
    const raw = typeof time === "string"
      ? time
      : time && typeof time === "object"
        ? `${time.year}-${String(time.month).padStart(2, "0")}-${String(time.day).padStart(2, "0")}`
        : "";
    if (!raw) return "";
    const date = new Date(`${raw}T00:00:00Z`);
    if (Number.isNaN(date.getTime())) return "";
    return date.toLocaleDateString(chartLang === "zh" ? "zh-CN" : "en-GB", {
      day: "2-digit",
      month: "short",
      year: "2-digit",
      timeZone: "UTC",
    }).toUpperCase();
  }

  function hideCrosshairLabels() {
    crosshairDate.hidden = true;
    crosshairValue.hidden = true;
  }

  function positionCrosshairLabels(param) {
    if (!param?.point || !param.time || !portfolioSeries) {
      hideCrosshairLabels();
      return;
    }
    const dateX = Math.max(38, Math.min(container.clientWidth - 80, param.point.x));
    crosshairDate.textContent = crosshairDateLabel(param.time);
    crosshairDate.style.left = `${dateX}px`;
    crosshairDate.hidden = false;

    let closest = null;
    seriesMeta.forEach((meta) => {
      const point = param.seriesData?.get(meta.series);
      const value = finiteNumber(point?.value ?? point?.close);
      if (value === null) return;
      const coordinate = meta.series.priceToCoordinate(value);
      if (coordinate === null) return;
      const distance = Math.abs(coordinate - param.point.y);
      if (!closest || distance < closest.distance) closest = { meta, value, coordinate, distance };
    });

    if (!closest || closest.distance > 18) {
      crosshairValue.hidden = true;
      return;
    }

    crosshairValue.textContent = compactValue(closest.value);
    crosshairValue.style.background = closest.meta.color;
    crosshairValue.dataset.series = closest.meta.title;
    crosshairValue.hidden = false;
    const halfWidth = Math.max(20, crosshairValue.offsetWidth / 2);
    const valueX = Math.max(halfWidth + 4, Math.min(container.clientWidth - halfWidth - 4, param.point.x));
    const placeBelow = closest.coordinate < 42;
    crosshairValue.classList.toggle("is-below", placeBelow);
    crosshairValue.style.left = `${valueX}px`;
    crosshairValue.style.top = `${closest.coordinate + (placeBelow ? 8 : -8)}px`;
  }

  function visibleRangeFor(key) {
    if (!allDates.length) return null;
    const lastIndex = allDates.length - 1;
    const lastDate = new Date(`${allDates[lastIndex]}T00:00:00`);
    const cutoff = new Date(lastDate);

    if (key === "max") return { from: allDates[0], to: allDates[lastIndex] };
    if (key === "ytd") cutoff.setFullYear(lastDate.getFullYear(), 0, 1);
    else {
      const days = { "1d": 1, "1w": 7, "1m": 31, "3m": 93, "1y": 366 }[key] || 366;
      cutoff.setDate(cutoff.getDate() - days);
    }

    const cutoffValue = cutoff.toISOString().slice(0, 10);
    const firstVisible = allDates.find((date) => date >= cutoffValue) || allDates[Math.max(0, lastIndex - 1)];
    return { from: firstVisible, to: allDates[lastIndex] };
  }

  function setRange(key) {
    rangeButtons.forEach((button) => {
      const active = button.dataset.range === key;
      button.classList.toggle("active", active);
      button.setAttribute("aria-pressed", active ? "true" : "false");
    });
    const range = visibleRangeFor(key);
    if (range) {
      chart.timeScale().setVisibleRange(range);
      requestAnimationFrame(updateEndLabels);
    }
  }

  function buildChart() {
    if (!container || !window.LightweightCharts || !portfolioRows.length) {
      if (empty) empty.hidden = false;
      return;
    }

    empty.hidden = true;
    const theme = currentChartTheme();
    chart = LightweightCharts.createChart(container, {
      width: container.clientWidth,
      height: chartHeight(),
      layout: {
        background: { type: "solid", color: theme.background },
        textColor: theme.text,
        fontFamily: '"Nunito Local", "Nunito", sans-serif',
        fontSize: 12,
        attributionLogo: false,
      },
      localization: {
        priceFormatter: compactValue,
      },
      grid: {
        vertLines: { visible: false },
        horzLines: { visible: true, color: theme.grid, style: 0 },
      },
      crosshair: {
        mode: LightweightCharts.CrosshairMode.Normal,
        vertLine: {
          visible: false,
          labelVisible: false,
        },
        horzLine: { visible: false, labelVisible: false },
      },
      rightPriceScale: {
        visible: true,
        borderVisible: false,
        scaleMargins: { top: 0.08, bottom: 0.08 },
        minimumWidth: 52,
      },
      leftPriceScale: { visible: false },
      timeScale: {
        visible: false,
        borderVisible: false,
        rightOffset: 8,
        barSpacing: 5,
        minBarSpacing: 0.5,
        fixLeftEdge: false,
        fixRightEdge: false,
        lockVisibleTimeRangeOnResize: true,
        rightBarStaysOnScroll: false,
        secondsVisible: false,
        timeVisible: false,
      },
      handleScroll: {
        mouseWheel: true,
        pressedMouseMove: true,
        horzTouchDrag: true,
        vertTouchDrag: false,
      },
      handleScale: {
        axisPressedMouseMove: false,
        mouseWheel: false,
        pinch: true,
      },
      kineticScroll: { mouse: true, touch: true },
    });

    portfolioSeries = createSeries(chartCopy.portfolio, COLORS.portfolio, portfolioRows, 2);
    Object.entries(benchmarkRows).forEach(([symbol, rows], index) => {
      if (!rows.length) return;
      const fallbackColors = ["#8b5cf6", "#06b6d4", "#eab308", "#ec4899", "#a855f7", "#ef4444"];
      createSeries(symbol, BENCHMARK_COLORS[symbol] || fallbackColors[index % fallbackColors.length], rows, symbol === "SPY" ? 2 : 1);
    });
    chart.subscribeCrosshairMove(positionCrosshairLabels);
    chart.timeScale().subscribeVisibleTimeRangeChange(() => requestAnimationFrame(updateEndLabels));
    setRange("3m");
    requestAnimationFrame(updateEndLabels);

    rangeButtons.forEach((button) => {
      button.addEventListener("click", () => setRange(button.dataset.range));
    });

    container.addEventListener("pointerdown", () => container.classList.add("is-dragging"));
    window.addEventListener("pointerup", () => container.classList.remove("is-dragging"));
    container.addEventListener("pointercancel", () => container.classList.remove("is-dragging"));

    resizeObserver = new ResizeObserver(([entry]) => {
      if (!chart || !entry) return;
      chart.resize(Math.floor(entry.contentRect.width), chartHeight());
      requestAnimationFrame(updateEndLabels);
    });
    resizeObserver.observe(container);
  }

  async function loadComparison() {
    try {
      const response = await fetch("/api/comparison", { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      setComparisonData(await response.json());
      buildChart();
    } catch (error) {
      if (empty) {
        empty.textContent = chartCopy.loadError(error.message);
        empty.hidden = false;
      }
    }
  }

  window.closeReturnsAI = function closeReturnsAI() {
    document.getElementById("aiReturnsResult").hidden = true;
  };

  window.loadReturnsAI = async function loadReturnsAI() {
    const button = document.getElementById("aiReturnsBtn");
    const status = document.getElementById("aiReturnsStatus");
    const result = document.getElementById("aiReturnsResult");
    button.disabled = true;
    status.textContent = "";
    try {
      const response = await fetch("/api/ai/returns-explanation", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ lang: document.documentElement.lang || "en" }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      document.getElementById("aiReturnsText").textContent = data.explanation || "";
      document.getElementById("aiReturnsPeriod").textContent = data.period || "";
      result.hidden = false;
    } catch (error) {
      status.textContent = chartCopy.aiError(error.message);
    } finally {
      button.disabled = false;
    }
  };

  window.addEventListener("catfolio:themechange", applyChartTheme);
  loadComparison();
})();
