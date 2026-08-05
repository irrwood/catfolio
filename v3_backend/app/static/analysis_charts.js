(() => {
  const isEnglish = document.documentElement.lang === "en";
  const copy = isEnglish ? {
    loading: "Loading analytics…",
    loadError: "Could not load analytics.",
    noData: "No data available",
    period: "Data range",
    days: "trading days",
    downDays: "down days",
    dailyAverage: "daily average",
    maxDrawdown: "max drawdown",
    correlation: "Correlation",
    monthContribution: "Monthly contribution",
    refresh: "Refresh",
    months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
    weekdays: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
    dayProfit: "Daily P/L",
    monthProfit: "Monthly P/L",
    summaryMonth: "Month",
    summaryYear: "Year",
    valuationLoading: "Loading valuation data…",
    valuationLoadError: "Could not load valuation data.",
    valuationRefreshing: "Refreshing valuation data…",
    valuationRefreshed: "Valuation data refreshed.",
    valuationEmpty: "No valuation data is available. Refresh fundamentals first.",
    valuationWaiting: "Waiting",
    asset: "Asset",
    sector: "Sector",
    epsGrowth: "EPS Growth",
    revenueGrowth: "Revenue Growth",
    weight: "Weight",
    relativeLevel: "Relative Level",
    portfolioMedian: "portfolio median P/E",
    valuationLevel: "Valuation level",
    showDetails: "Show details",
    hideDetails: "Hide details",
    holdingsWithPe: "holdings with P/E",
    growthRate: "Growth Rate",
  } : {
    loading: "正在加载分析数据…",
    loadError: "分析数据加载失败。",
    noData: "暂无可用数据",
    period: "数据区间",
    days: "个交易日",
    downDays: "天下跌",
    dailyAverage: "日均",
    maxDrawdown: "最大回撤",
    correlation: "相关性",
    monthContribution: "月度归因",
    refresh: "刷新",
    months: ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"],
    weekdays: ["日", "一", "二", "三", "四", "五", "六"],
    dayProfit: "当日盈亏",
    monthProfit: "当月盈亏",
    summaryMonth: "本月",
    summaryYear: "全年",
    valuationLoading: "正在加载估值数据…",
    valuationLoadError: "估值数据加载失败。",
    valuationRefreshing: "正在刷新估值数据…",
    valuationRefreshed: "估值数据已刷新。",
    valuationEmpty: "暂无可用估值数据，请先刷新 fundamentals。",
    valuationWaiting: "等待",
    asset: "资产",
    sector: "板块",
    epsGrowth: "EPS 成长",
    revenueGrowth: "营收成长",
    weight: "仓位",
    relativeLevel: "相对水位",
    portfolioMedian: "组合中位 P/E",
    valuationLevel: "估值水位",
    showDetails: "展开明细",
    hideDetails: "收起明细",
    holdingsWithPe: "个有 P/E 的持仓",
    growthRate: "成长率",
  };

  const chartIds = [
    "monthlyReturnsChart",
    "drawdownChart",
    "correlationChart",
    "valuationMatrixChart",
    "distributionChart",
    "waterfallChart",
  ];
  const instances = new Map();
  let latestData = null;
  let latestValuationData = null;
  let loading = false;
  let drawdownRange = "MAX";
  let calendarInitialized = false;
  const calendarState = { view: "month", year: new Date().getFullYear(), month: new Date().getMonth() + 1 };

  const css = name => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const palette = () => ({
    ink: css("--ink"),
    muted: css("--muted"),
    line: css("--line-strong"),
    panel: css("--panel"),
    soft: css("--soft"),
    hover: css("--panel-hover"),
    primary: css("--primary-strong"),
    positive: css("--positive"),
    negative: css("--negative"),
    indigo: css("--icon-indigo") || "#6068e8",
  });

  function chart(id) {
    const node = document.getElementById(id);
    if (!node || !window.echarts) return null;
    if (!instances.has(id)) instances.set(id, window.echarts.init(node));
    return instances.get(id);
  }

  function baseOption() {
    const colors = palette();
    const fontFamily = getComputedStyle(document.body).fontFamily;
    return {
      animationDuration: 260,
      animationEasing: "cubicOut",
      textStyle: { color: colors.ink, fontFamily },
      tooltip: {
        confine: true,
        backgroundColor: colors.panel,
        borderColor: colors.line,
        borderWidth: 1,
        textStyle: { color: colors.ink, fontFamily, fontSize: 12 },
        extraCssText: "border-radius:12px;box-shadow:0 6px 18px rgba(15,23,42,.06);",
      },
    };
  }

  function categoryAxis(extra = {}) {
    const colors = palette();
    return {
      type: "category",
      axisLine: { lineStyle: { color: colors.line } },
      axisTick: { show: false },
      axisLabel: { color: colors.muted, fontSize: 11 },
      ...extra,
    };
  }

  function valueAxis(extra = {}) {
    const colors = palette();
    return {
      type: "value",
      axisLine: { show: false },
      axisTick: { show: false },
      axisLabel: { color: colors.muted, fontSize: 11 },
      splitLine: { lineStyle: { color: colors.line, opacity: 0.55 } },
      ...extra,
    };
  }

  function finishChart(id) {
    document.getElementById(id)?.classList.remove("is-loading");
  }

  function emptyChart(id) {
    const target = chart(id);
    if (!target) return;
    const colors = palette();
    target.clear();
    target.setOption({
      ...baseOption(),
      title: {
        text: copy.noData,
        left: "center",
        top: "middle",
        textStyle: { color: colors.muted, fontSize: 13, fontWeight: 500 },
      },
    });
    finishChart(id);
  }

  function formatPct(value, digits = 1) {
    const number = Number(value || 0) * 100;
    return `${number >= 0 ? "+" : ""}${number.toFixed(digits)}%`;
  }

  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[character]));

  function finiteNumber(value) {
    if (value === null || value === undefined || value === "") return null;
    const number = Number(value);
    return Number.isFinite(number) ? number : null;
  }

  function formatMultiple(value) {
    const number = finiteNumber(value);
    return number !== null && number > 0 ? `${number.toFixed(1)}×` : "—";
  }

  function growthPercent(value) {
    const number = finiteNumber(value);
    if (number === null) return null;
    return Math.abs(number) <= 2 ? number * 100 : number;
  }

  function formatGrowth(value) {
    const number = growthPercent(value);
    return number === null ? "—" : `${number >= 0 ? "+" : ""}${number.toFixed(1)}%`;
  }

  function median(values) {
    const numbers = values.map(Number).filter(Number.isFinite).sort((left, right) => left - right);
    if (!numbers.length) return null;
    const middle = Math.floor(numbers.length / 2);
    return numbers.length % 2 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2;
  }

  function prepareValuationRows(payload) {
    const rows = (payload?.rows || []).map(row => {
      const trailingPe = finiteNumber(row.trailing_pe);
      const forwardPe = finiteNumber(row.forward_pe);
      const pe = forwardPe && forwardPe > 0 ? forwardPe : trailingPe;
      const epsGrowth = growthPercent(row.eps_growth_yoy);
      const revenueGrowth = growthPercent(row.revenue_growth_yoy);
      const growth = epsGrowth !== null ? epsGrowth : revenueGrowth;
      return {
        ...row,
        pe: pe && pe > 0 ? pe : null,
        priceToSales: finiteNumber(row.price_to_sales),
        priceToBook: finiteNumber(row.price_to_book),
        epsGrowth,
        revenueGrowth,
        growth,
        growthSource: epsGrowth !== null ? copy.epsGrowth : copy.revenueGrowth,
        weight: Number(row.weight || 0),
      };
    }).filter(row => row.pe || row.priceToSales || row.priceToBook || row.growth !== null);

    const peRows = rows.filter(row => row.pe);
    const portfolioMedian = median(peRows.map(row => row.pe));
    const bySector = new Map();
    peRows.forEach(row => {
      const sector = row.sector || "Other";
      if (!bySector.has(sector)) bySector.set(sector, []);
      bySector.get(sector).push(row.pe);
    });
    return rows.map(row => {
      if (!row.pe || !portfolioMedian) return { ...row, benchmark: null, premium: null };
      const sectorRows = bySector.get(row.sector || "Other") || [];
      const benchmark = sectorRows.length >= 3 ? median(sectorRows) : portfolioMedian;
      return { ...row, benchmark, premium: benchmark ? row.pe / benchmark - 1 : null };
    }).sort((left, right) => right.weight - left.weight);
  }

  function formatCalendarMoney(value, { signed = true, compact = false } = {}) {
    const number = Number(value || 0);
    const prefix = signed ? (number >= 0 ? "+" : "-") : (number < 0 ? "-" : "");
    return `${prefix}$${Math.abs(number).toLocaleString(isEnglish ? "en-GB" : "zh-CN", {
      minimumFractionDigits: compact ? 0 : 2,
      maximumFractionDigits: 2,
    })}`;
  }

  function calendarFill(value) {
    return value >= 0 ? "var(--calendar-positive-fill)" : "var(--calendar-negative-fill)";
  }

  function calendarRows(data) {
    return (data.profit_calendar?.rows || []).filter(row => row?.date && Number.isFinite(Number(row.pnl_usd)));
  }

  function updateCalendarIncome(data) {
    const income = data.profit_calendar?.income || {};
    const monthKey = `${calendarState.year}-${String(calendarState.month).padStart(2, "0")}`;
    const selected = calendarState.view === "year"
      ? (income.rows || []).find(row => Number(row.year) === calendarState.year) || {}
      : (income.monthly_rows || []).find(row => row.month === monthKey) || {};
    const dividendNode = document.getElementById("profitCalendarDividends");
    const interestNode = document.getElementById("profitCalendarInterest");
    if (dividendNode) dividendNode.textContent = formatCalendarMoney(selected.dividends_usd || 0);
    if (interestNode) interestNode.textContent = formatCalendarMoney(selected.cash_interest_usd || 0);
    document.querySelectorAll(".profit-calendar-summary-period").forEach(node => {
      node.textContent = calendarState.view === "year" ? copy.summaryYear : copy.summaryMonth;
    });
  }

  function renderProfitMonth(data) {
    const grid = document.getElementById("profitCalendarGrid");
    const weekdays = document.getElementById("profitCalendarWeekdays");
    if (!grid || !weekdays) return;
    weekdays.hidden = false;
    weekdays.innerHTML = copy.weekdays.map(day => `<div class="profit-calendar-weekday">${day}</div>`).join("");
    grid.className = "profit-calendar-grid";

    const byDate = new Map(calendarRows(data).map(row => [row.date, Number(row.pnl_usd)]));
    const daysInMonth = new Date(calendarState.year, calendarState.month, 0).getDate();
    const leadingDays = new Date(calendarState.year, calendarState.month - 1, 1).getDay();
    const cells = [];
    for (let index = 0; index < leadingDays; index += 1) {
      cells.push('<div class="profit-calendar-day is-outside" aria-hidden="true"></div>');
    }
    for (let day = 1; day <= daysInMonth; day += 1) {
      const date = `${calendarState.year}-${String(calendarState.month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
      const hasValue = byDate.has(date);
      const value = byDate.get(date) || 0;
      const classes = ["profit-calendar-day", hasValue ? "has-value" : "", value < 0 ? "is-negative" : ""].filter(Boolean).join(" ");
      const style = hasValue ? ` style="--calendar-fill:${calendarFill(value)}"` : "";
      const detail = hasValue ? `${copy.dayProfit} ${formatCalendarMoney(value)}` : copy.noData;
      cells.push(`<div class="${classes}" role="gridcell" aria-label="${date} ${detail}" title="${date} · ${detail}"${style}><span class="profit-calendar-day-number">${day}</span>${hasValue ? `<strong class="profit-calendar-day-value">${formatCalendarMoney(value, { compact: true })}</strong>` : ""}</div>`);
    }
    const totalCells = Math.ceil((leadingDays + daysInMonth) / 7) * 7;
    for (let index = leadingDays + daysInMonth; index < totalCells; index += 1) {
      cells.push('<div class="profit-calendar-day is-outside" aria-hidden="true"></div>');
    }
    grid.innerHTML = cells.join("");
  }

  function renderProfitYear(data) {
    const grid = document.getElementById("profitCalendarGrid");
    const weekdays = document.getElementById("profitCalendarWeekdays");
    if (!grid || !weekdays) return;
    weekdays.hidden = true;
    const totals = Array(12).fill(0);
    const counts = Array(12).fill(0);
    calendarRows(data).forEach(row => {
      const [year, month] = String(row.date).split("-").map(Number);
      if (year === calendarState.year && month >= 1 && month <= 12) {
        totals[month - 1] += Number(row.pnl_usd || 0);
        counts[month - 1] += 1;
      }
    });
    grid.className = "profit-calendar-grid is-year";
    grid.innerHTML = totals.map((value, index) => {
      const hasValue = counts[index] > 0;
      const classes = ["profit-calendar-month-tile", hasValue ? "has-value" : "", value < 0 ? "is-negative" : ""].filter(Boolean).join(" ");
      const style = hasValue ? ` style="--calendar-fill:${calendarFill(value)}"` : "";
      const detail = hasValue ? formatCalendarMoney(value) : copy.noData;
      return `<div class="${classes}" role="gridcell" aria-label="${calendarState.year} ${copy.months[index]} ${copy.monthProfit} ${detail}" title="${calendarState.year} ${copy.months[index]} · ${detail}"${style}><span>${copy.months[index]}</span><strong>${detail}</strong></div>`;
    }).join("");
  }

  function renderProfitCalendar(data) {
    const rows = calendarRows(data);
    if (!calendarInitialized) {
      const latest = rows.at(-1)?.date;
      if (latest) {
        const [year, month] = latest.split("-").map(Number);
        calendarState.year = year;
        calendarState.month = month;
      }
      calendarInitialized = true;
    }
    const periodMonth = document.getElementById("profitCalendarPeriodMonth");
    const periodYear = document.getElementById("profitCalendarPeriodYear");
    if (periodMonth) {
      periodMonth.hidden = calendarState.view === "year";
      periodMonth.textContent = copy.months[calendarState.month - 1];
    }
    if (periodYear) periodYear.textContent = String(calendarState.year);
    document.getElementById("profitCalendarMonth")?.classList.toggle("active", calendarState.view === "month");
    document.getElementById("profitCalendarYear")?.classList.toggle("active", calendarState.view === "year");
    document.getElementById("profitCalendarMonth")?.setAttribute("aria-pressed", calendarState.view === "month" ? "true" : "false");
    document.getElementById("profitCalendarYear")?.setAttribute("aria-pressed", calendarState.view === "year" ? "true" : "false");
    if (calendarState.view === "year") renderProfitYear(data); else renderProfitMonth(data);
    updateCalendarIncome(data);
  }

  function renderMonthly(data) {
    const rows = data.monthly_returns?.rows || [];
    if (!rows.length) return emptyChart("monthlyReturnsChart");
    const colors = palette();
    const years = [...new Set(rows.map(row => String(row.month).slice(0, 4)))].sort();
    const values = rows.map(row => [
      Number(String(row.month).slice(5, 7)) - 1,
      years.indexOf(String(row.month).slice(0, 4)),
      Number(row.return || 0) * 100,
    ]);
    const maxAbs = Math.max(1, ...values.map(row => Math.abs(row[2])));
    chart("monthlyReturnsChart").setOption({
      ...baseOption(),
      grid: { left: 54, right: 22, top: 18, bottom: 68 },
      xAxis: categoryAxis({ data: copy.months, splitArea: { show: true, areaStyle: { color: ["transparent"] } } }),
      yAxis: categoryAxis({ data: years, splitArea: { show: true, areaStyle: { color: ["transparent"] } } }),
      visualMap: {
        min: -maxAbs,
        max: maxAbs,
        orient: "horizontal",
        left: "center",
        bottom: 8,
        calculable: false,
        textStyle: { color: colors.muted, fontSize: 10 },
        formatter: value => `${value >= 0 ? "+" : ""}${Number(value).toFixed(1)}%`,
        inRange: { color: [colors.negative, colors.soft, colors.primary] },
      },
      series: [{
        type: "heatmap",
        data: values,
        itemStyle: { borderColor: colors.panel, borderWidth: 4, borderRadius: 7 },
        label: { show: true, color: colors.ink, fontSize: 10, formatter: params => `${params.value[2] >= 0 ? "+" : ""}${params.value[2].toFixed(1)}%` },
        emphasis: { itemStyle: { borderColor: colors.ink, borderWidth: 1 } },
      }],
      tooltip: { ...baseOption().tooltip, formatter: params => `${years[params.value[1]]} ${copy.months[params.value[0]]}<br><b>${params.value[2] >= 0 ? "+" : ""}${params.value[2].toFixed(2)}%</b>` },
    }, true);
    finishChart("monthlyReturnsChart");
  }

  function renderDrawdown(data) {
    const allRows = data.drawdown?.rows || [];
    if (!allRows.length) return emptyChart("drawdownChart");
    const colors = palette();
    const endDate = new Date(`${allRows.at(-1).date}T12:00:00`);
    const dayWindows = { "1D": 1, "1W": 7, "1M": 31, "3M": 93, "1Y": 366 };
    let rows = allRows;
    if (drawdownRange === "YTD") {
      rows = allRows.filter(row => String(row.date).slice(0, 4) === String(endDate.getFullYear()));
    } else if (dayWindows[drawdownRange]) {
      const startDate = new Date(endDate);
      startDate.setDate(startDate.getDate() - dayWindows[drawdownRange]);
      rows = allRows.filter(row => new Date(`${row.date}T12:00:00`) >= startDate);
    }
    if (rows.length < 2) rows = allRows.slice(-2);
    const values = rows.map(row => Number(row.drawdown || 0) * 100);
    const minimum = Math.min(...values);
    const axisMinimum = Math.min(-10, Math.floor(minimum / 10) * 10);
    const meta = document.getElementById("drawdownMeta");
    if (meta) meta.textContent = `${copy.maxDrawdown} ${formatPct(data.drawdown?.max_drawdown)}`;
    chart("drawdownChart").setOption({
      ...baseOption(),
      animationDuration: 180,
      grid: { left: 54, right: 0, top: 12, bottom: 8 },
      xAxis: categoryAxis({
        data: rows.map(row => row.date),
        boundaryGap: false,
        axisLine: { show: false },
        axisLabel: { show: false },
        splitLine: { show: false },
        axisPointer: {
          show: true,
          type: "line",
          lineStyle: { color: "#eaebed", width: 1 },
          label: { show: false },
        },
      }),
      yAxis: valueAxis({
        min: axisMinimum,
        max: 0,
        interval: 10,
        axisLabel: {
          color: "rgba(9,15,5,.6)",
          fontSize: 12,
          fontWeight: 700,
          margin: 18,
          formatter: value => `${value.toFixed(0)}%`,
        },
        splitLine: { lineStyle: { color: "#eaebed", width: 1, opacity: 1 } },
      }),
      series: [{
        type: "line",
        showSymbol: false,
        smooth: 0.18,
        data: values,
        lineStyle: { color: "#e40014", width: 2 },
        areaStyle: { color: "rgba(228,0,20,.10)" },
        emphasis: { focus: "series", scale: true, itemStyle: { color: "#e40014" } },
      }],
      tooltip: {
        trigger: "axis",
        confine: true,
        backgroundColor: "transparent",
        borderWidth: 0,
        padding: 0,
        axisPointer: { type: "line", lineStyle: { color: "#eaebed", width: 1 } },
        extraCssText: "box-shadow:none;",
        formatter: params => {
          const point = params[0];
          const date = new Date(`${point.axisValue}T12:00:00`);
          const dateLabel = date.toLocaleDateString(isEnglish ? "en-GB" : "zh-CN", {
            day: "2-digit", month: "short", year: "2-digit",
          }).toUpperCase();
          return `<div class="analytics-drawdown-tooltip"><span class="analytics-drawdown-tooltip-date">${escapeHtml(dateLabel)}</span><span class="analytics-drawdown-tooltip-value">${Number(point.value).toFixed(1)}%</span></div>`;
        },
      },
    }, true);
    finishChart("drawdownChart");
  }

  function renderCorrelation(data) {
    const corr = data.correlation_matrix || {};
    const symbols = corr.symbols || [];
    const matrix = corr.matrix || [];
    if (!symbols.length || !matrix.length) return emptyChart("correlationChart");
    const colors = palette();
    const values = matrix.flatMap((row, y) => row.map((value, x) => [x, y, Number(value)]));
    const shortened = value => value.length > 11 ? `${value.slice(0, 10)}…` : value;
    chart("correlationChart").setOption({
      ...baseOption(),
      grid: { left: 106, right: 30, top: 24, bottom: 104 },
      xAxis: categoryAxis({ data: symbols, axisLabel: { color: colors.muted, rotate: 38, fontSize: 10, formatter: shortened } }),
      yAxis: categoryAxis({ data: symbols, axisLabel: { color: colors.muted, fontSize: 10, formatter: shortened } }),
      visualMap: {
        min: -1,
        max: 1,
        orient: "horizontal",
        left: "center",
        bottom: 12,
        text: ["+1", "-1"],
        textStyle: { color: colors.muted, fontSize: 10 },
        inRange: { color: [colors.indigo, colors.soft, colors.primary] },
      },
      series: [{
        type: "heatmap",
        data: values,
        itemStyle: { borderColor: colors.panel, borderWidth: 2, borderRadius: 4 },
        label: { show: symbols.length <= 10, color: colors.ink, fontSize: 9, formatter: params => params.value[2].toFixed(2) },
        emphasis: { itemStyle: { borderColor: colors.ink, borderWidth: 1 } },
      }],
      tooltip: { ...baseOption().tooltip, formatter: params => `${symbols[params.value[1]]}<br>${symbols[params.value[0]]}<br>${copy.correlation} <b>${params.value[2].toFixed(2)}</b>` },
    }, true);
    finishChart("correlationChart");
  }

  function renderDistribution(data) {
    const distribution = data.return_distribution || {};
    const bins = distribution.bins || [];
    if (!bins.length) return emptyChart("distributionChart");
    const colors = palette();
    const stats = distribution.stats || {};
    const meta = document.getElementById("distributionMeta");
    if (meta) meta.textContent = `${stats.sample_days || 0} ${copy.days} · ${stats.negative_days || 0} ${copy.downDays} · ${copy.dailyAverage} ${formatPct(stats.mean, 2)}`;
    chart("distributionChart").setOption({
      ...baseOption(),
      grid: { left: 48, right: 18, top: 18, bottom: 50 },
      xAxis: categoryAxis({ data: bins.map(row => `${(Number(row.mid) * 100).toFixed(1)}%`), axisLabel: { color: colors.muted, hideOverlap: true, rotate: 35, fontSize: 9 } }),
      yAxis: valueAxis({ minInterval: 1 }),
      series: [{
        type: "bar",
        barMaxWidth: 28,
        data: bins.map(row => ({ value: row.count, itemStyle: { color: Number(row.mid) >= 0 ? colors.positive : colors.negative, opacity: 0.82, borderRadius: [5, 5, 2, 2] } })),
      }],
      tooltip: { ...baseOption().tooltip, trigger: "axis", formatter: params => `${params[0].name}<br><b>${params[0].value}</b> ${copy.days}` },
    }, true);
    finishChart("distributionChart");
  }

  function renderWaterfall(data) {
    const waterfall = data.waterfall || {};
    const rows = (waterfall.rows || []).filter(row => Number.isFinite(Number(row.contribution)));
    if (!rows.length) return emptyChart("waterfallChart");
    const colors = palette();
    let running = 0;
    const helper = [];
    const changes = [];
    const cumulative = [0];
    rows.forEach(row => {
      const contribution = Number(row.contribution);
      const next = running + contribution;
      helper.push(Math.min(running, next) * 100);
      changes.push({ value: Math.abs(contribution * 100), raw: contribution, itemStyle: { color: contribution >= 0 ? colors.positive : colors.negative, borderRadius: 4 } });
      running = next;
      cumulative.push(running * 100);
    });
    const yMin = Math.min(0, ...cumulative);
    const yMax = Math.max(0, ...cumulative);
    const meta = document.getElementById("waterfallMeta");
    if (meta) meta.textContent = `${copy.monthContribution} · ${waterfall.month || ""} · ${formatPct(running)}`;
    chart("waterfallChart").setOption({
      ...baseOption(),
      grid: { left: 54, right: 18, top: 18, bottom: 64 },
      xAxis: categoryAxis({ data: rows.map(row => row.symbol), axisLabel: { color: colors.muted, rotate: 34, fontSize: 9 } }),
      yAxis: valueAxis({
        min: Math.floor(yMin * 10) / 10,
        max: Math.ceil((yMax || 1) * 11) / 10,
        axisLabel: { color: colors.muted, formatter: value => `${value.toFixed(1)}%` },
      }),
      series: [
        { type: "bar", stack: "waterfall", silent: true, data: helper, itemStyle: { color: "transparent" }, emphasis: { disabled: true } },
        { type: "bar", stack: "waterfall", barMaxWidth: 24, data: changes },
      ],
      tooltip: { ...baseOption().tooltip, trigger: "axis", formatter: params => { const point = params.find(item => item.seriesIndex === 1); return point ? `${point.name}<br><b>${formatPct(point.data.raw, 2)}</b>` : ""; } },
    }, true);
    finishChart("waterfallChart");
  }

  function renderValuationTable(rows) {
    const head = document.getElementById("valuationTableHead");
    const body = document.getElementById("valuationTableBody");
    if (!head || !body) return;
    const toggle = document.getElementById("valuationTableToggle");
    if (toggle) {
      const expanded = toggle.getAttribute("aria-expanded") === "true";
      toggle.textContent = `${expanded ? copy.hideDetails : copy.showDetails} (${rows.length})`;
    }
    head.innerHTML = `<tr>
      <th scope="col">${escapeHtml(copy.asset)}</th>
      <th scope="col" class="numeric">P/E</th>
      <th scope="col" class="numeric">P/S</th>
      <th scope="col" class="numeric">P/B</th>
      <th scope="col" class="numeric">${escapeHtml(copy.epsGrowth)}</th>
      <th scope="col" class="numeric">${escapeHtml(copy.revenueGrowth)}</th>
      <th scope="col" class="numeric">${escapeHtml(copy.weight)}</th>
      <th scope="col" class="numeric">${escapeHtml(copy.relativeLevel)}</th>
    </tr>`;
    if (!rows.length) {
      body.innerHTML = `<tr><td class="valuation-table-empty" colspan="8">${escapeHtml(copy.valuationEmpty)}</td></tr>`;
      return;
    }
    body.innerHTML = rows.map(row => {
      const premium = row.premium;
      const tone = premium === null ? "" : premium >= 0 ? "expensive" : "cheap";
      const level = premium === null ? "—" : `${premium >= 0 ? "+" : ""}${(premium * 100).toFixed(1)}%`;
      return `<tr>
        <td><span class="valuation-asset"><strong>${escapeHtml(row.ticker || "—")}</strong><small>${escapeHtml(row.display_name || row.name || row.sector || "")}</small></span></td>
        <td class="numeric">${formatMultiple(row.pe)}</td>
        <td class="numeric">${formatMultiple(row.priceToSales)}</td>
        <td class="numeric">${formatMultiple(row.priceToBook)}</td>
        <td class="numeric ${row.epsGrowth !== null && row.epsGrowth < 0 ? "negative" : ""}">${formatGrowth(row.eps_growth_yoy)}</td>
        <td class="numeric ${row.revenueGrowth !== null && row.revenueGrowth < 0 ? "negative" : ""}">${formatGrowth(row.revenue_growth_yoy)}</td>
        <td class="numeric">${(row.weight * 100).toFixed(1)}%</td>
        <td class="numeric valuation-level ${tone}">${level}</td>
      </tr>`;
    }).join("");
  }

  function renderValuationMatrix(rows) {
    const target = chart("valuationMatrixChart");
    if (!target) return;
    const colors = palette();
    const chartRows = rows.filter(row => row.pe && row.growth !== null);
    target.clear();
    if (!chartRows.length) {
      target.setOption({
        ...baseOption(),
        title: {
          text: copy.valuationEmpty,
          left: "center",
          top: "middle",
          textStyle: { color: colors.muted, fontSize: 13, fontWeight: 500 },
        },
      });
      finishChart("valuationMatrixChart");
      return;
    }
    const sectorPalette = ["#89d663", "#f36d0d", "#708cff", "#2f8a3e", "#d49b27", "#7d68d8", "#1a9aa8"];
    const sectorColor = new Map();
    chartRows.forEach(row => {
      const sector = row.sector || "Other";
      if (!sectorColor.has(sector)) sectorColor.set(sector, sectorPalette[sectorColor.size % sectorPalette.length]);
    });
    const peValues = chartRows.map(row => row.pe);
    const growthValues = chartRows.map(row => row.growth);
    const xMinimum = Math.min(-10, Math.floor(Math.min(...peValues) / 10) * 10);
    const xMaximum = Math.max(50, Math.ceil(Math.max(...peValues) / 10) * 10);
    const growthSpan = Math.max(20, Math.max(...growthValues) - Math.min(...growthValues));
    const growthPadding = Math.max(10, growthSpan * 0.25);
    const yMinimum = Math.min(-60, Math.floor((Math.min(...growthValues) - growthPadding) / 10) * 10);
    const yMaximum = Math.max(0, Math.ceil((Math.max(...growthValues) + growthPadding) / 10) * 10);
    const xInterval = Math.max(10, Math.ceil(((xMaximum - xMinimum) / 6) / 10) * 10);
    const yInterval = Math.max(10, Math.ceil(((yMaximum - yMinimum) / 6) / 10) * 10);
    const maximumWeight = Math.max(...chartRows.map(row => row.weight), 0.0001);
    target.setOption({
      ...baseOption(),
      animationDuration: 220,
      grid: { left: 54, right: 18, top: 12, bottom: 39 },
      xAxis: valueAxis({
        min: xMinimum,
        max: xMaximum,
        interval: xInterval,
        axisLabel: {
          color: "rgba(9,15,5,.6)",
          fontSize: 12,
          fontWeight: 700,
          margin: 18,
          formatter: value => `${Number(value).toFixed(0)}×${Number(value) === xMaximum ? " P/E" : ""}`,
        },
        splitLine: { lineStyle: { color: "#eaebed", width: 1, opacity: 1 } },
      }),
      yAxis: valueAxis({
        min: yMinimum,
        max: yMaximum,
        interval: yInterval,
        axisLabel: {
          color: "rgba(9,15,5,.6)",
          fontSize: 12,
          fontWeight: 700,
          margin: 18,
          formatter: value => `${Number(value).toFixed(0)}%`,
        },
        splitLine: { lineStyle: { color: "#eaebed", width: 1, opacity: 1 } },
      }),
      series: [{
        type: "scatter",
        clip: false,
        data: chartRows.map(row => {
          const pointColor = sectorColor.get(row.sector || "Other");
          return {
            value: [row.pe, row.growth, row.weight],
            raw: row,
            itemStyle: { color: pointColor, opacity: 1 },
            label: { color: pointColor },
          };
        }),
        symbolSize: value => Math.max(20, Math.min(118, Math.sqrt(Number(value[2] || 0) / maximumWeight) * 118)),
        label: {
          show: true,
          formatter: params => params.data.raw.ticker,
          position: "top",
          distance: 4,
          fontSize: 11,
          fontWeight: 700,
        },
        emphasis: { scale: 1.04 },
      }],
      tooltip: {
        confine: true,
        backgroundColor: "#fff",
        borderColor: "#f1f1f1",
        borderWidth: 1,
        padding: 8,
        textStyle: { color: "#000", fontFamily: getComputedStyle(document.body).fontFamily, fontSize: 10 },
        extraCssText: "border-radius:8px;box-shadow:0 10px 9px rgba(0,0,0,.08);",
        formatter: params => {
          const row = params.data.raw;
          return `<div class="analytics-valuation-tooltip">
            <div class="analytics-valuation-tooltip-head"><span>${escapeHtml(row.ticker)}</span><span>${row.pe.toFixed(1)}×</span></div>
            <div class="analytics-valuation-tooltip-row"><span>${escapeHtml(row.growthSource)}</span><span>${row.growth >= 0 ? "+" : ""}${row.growth.toFixed(1)}%</span></div>
            <div class="analytics-valuation-tooltip-row"><span>${escapeHtml(copy.weight)}</span><span>${(row.weight * 100).toFixed(1)}%</span></div>
          </div>`;
        },
      },
    }, true);
    finishChart("valuationMatrixChart");
  }

  function renderValuation(payload) {
    latestValuationData = payload;
    const rows = prepareValuationRows(payload);
    renderValuationMatrix(rows);
    renderValuationTable(rows);
  }

  function toggleValuationTable() {
    const button = document.getElementById("valuationTableToggle");
    const panel = document.getElementById("valuationTablePanel");
    if (!button || !panel) return;
    const expanded = button.getAttribute("aria-expanded") !== "true";
    button.setAttribute("aria-expanded", expanded ? "true" : "false");
    panel.hidden = !expanded;
    button.closest(".analytics-valuation-card")?.classList.toggle("is-table-expanded", expanded);
    const rows = latestValuationData ? prepareValuationRows(latestValuationData) : [];
    button.textContent = `${expanded ? copy.hideDetails : copy.showDetails} (${rows.length})`;
    requestAnimationFrame(() => chart("valuationMatrixChart")?.resize());
  }

  function renderAll(data) {
    latestData = data;
    renderProfitCalendar(data);
    renderMonthly(data);
    renderDrawdown(data);
    renderCorrelation(data);
    renderDistribution(data);
    renderWaterfall(data);
    const range = data.monthly_returns?.date_range || {};
    const rangeNode = document.getElementById("analyticsRange");
    if (rangeNode) rangeNode.textContent = range.start && range.end ? `${copy.period}: ${range.start} – ${range.end}` : copy.period;
  }

  async function fetchJson(url, options = {}) {
    const response = await fetch(url, { headers: { Accept: "application/json" }, ...options });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  }

  async function load() {
    if (loading) return;
    loading = true;
    const button = document.getElementById("analyticsRefresh");
    const status = document.getElementById("analyticsStatus");
    button?.setAttribute("disabled", "");
    button?.classList.add("is-loading");
    status.textContent = copy.loading;
    status.className = "analytics-status is-visible";
    try {
      const [analyticsResult, valuationResult] = await Promise.allSettled([
        fetchJson("/api/analytics"),
        fetchJson("/api/holdings/heatmap"),
      ]);
      if (analyticsResult.status === "rejected") throw analyticsResult.reason;
      renderAll(analyticsResult.value);
      if (valuationResult.status === "fulfilled") {
        renderValuation(valuationResult.value);
        status.className = "analytics-status";
      } else {
        renderValuation({ rows: [] });
        status.textContent = `${copy.valuationLoadError} ${valuationResult.reason?.message || ""}`;
        status.className = "analytics-status is-visible is-error";
      }
    } catch (error) {
      status.textContent = `${copy.loadError} ${error.message || ""}`;
      status.className = "analytics-status is-visible is-error";
      chartIds.forEach(finishChart);
    } finally {
      loading = false;
      button?.removeAttribute("disabled");
      button?.classList.remove("is-loading");
    }
  }

  async function refreshValuation() {
    const button = document.getElementById("valuationRefresh");
    const status = document.getElementById("analyticsStatus");
    button?.setAttribute("disabled", "");
    button?.classList.add("is-loading");
    status.textContent = copy.valuationRefreshing;
    status.className = "analytics-status is-visible";
    try {
      await fetchJson("/api/refresh/fundamentals?force=true", { method: "POST" });
      renderValuation(await fetchJson("/api/holdings/heatmap"));
      status.textContent = copy.valuationRefreshed;
      status.className = "analytics-status is-visible";
    } catch (error) {
      status.textContent = `${copy.valuationLoadError} ${error.message || ""}`;
      status.className = "analytics-status is-visible is-error";
    } finally {
      button?.removeAttribute("disabled");
      button?.classList.remove("is-loading");
    }
  }

  document.getElementById("analyticsRefresh")?.addEventListener("click", load);
  document.getElementById("valuationRefresh")?.addEventListener("click", refreshValuation);
  document.getElementById("valuationTableToggle")?.addEventListener("click", toggleValuationTable);
  document.querySelectorAll("[data-drawdown-range]").forEach(button => {
    button.addEventListener("click", () => {
      drawdownRange = button.dataset.drawdownRange || "MAX";
      document.querySelectorAll("[data-drawdown-range]").forEach(option => {
        const active = option === button;
        option.classList.toggle("active", active);
        option.setAttribute("aria-pressed", active ? "true" : "false");
      });
      if (latestData) renderDrawdown(latestData);
    });
  });
  document.getElementById("profitCalendarMonth")?.addEventListener("click", () => {
    calendarState.view = "month";
    if (latestData) renderProfitCalendar(latestData);
  });
  document.getElementById("profitCalendarYear")?.addEventListener("click", () => {
    calendarState.view = "year";
    if (latestData) renderProfitCalendar(latestData);
  });
  document.getElementById("profitCalendarPrev")?.addEventListener("click", () => {
    if (calendarState.view === "year") calendarState.year -= 1;
    else if (calendarState.month === 1) { calendarState.month = 12; calendarState.year -= 1; }
    else calendarState.month -= 1;
    if (latestData) renderProfitCalendar(latestData);
  });
  document.getElementById("profitCalendarNext")?.addEventListener("click", () => {
    if (calendarState.view === "year") calendarState.year += 1;
    else if (calendarState.month === 12) { calendarState.month = 1; calendarState.year += 1; }
    else calendarState.month += 1;
    if (latestData) renderProfitCalendar(latestData);
  });
  window.addEventListener("resize", () => instances.forEach(instance => instance.resize()));
  new MutationObserver(mutations => {
    if (mutations.some(record => record.attributeName === "class")) {
      if (latestData) renderAll(latestData);
      if (latestValuationData) renderValuation(latestValuationData);
    }
  }).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });

  load();
})();
