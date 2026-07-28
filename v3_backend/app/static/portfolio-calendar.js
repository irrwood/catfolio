(() => {
  const grid = document.getElementById("profitCalendarGrid");
  if (!grid) return;

  const isEnglish = (document.documentElement.lang || "zh").startsWith("en");
  const locale = isEnglish ? "en-GB" : "zh-CN";
  const copy = isEnglish ? {
    loadError: "Could not load the profit calendar.",
    noData: "No data available",
    months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
    weekdays: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
    dayProfit: "Daily P/L",
    summaryMonth: "Month",
    summaryYear: "Year",
  } : {
    loadError: "收益日历加载失败。",
    noData: "暂无可用数据",
    months: ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"],
    weekdays: ["日", "一", "二", "三", "四", "五", "六"],
    dayProfit: "当日盈亏",
    summaryMonth: "本月",
    summaryYear: "全年",
  };

  const state = { view: "day", year: new Date().getFullYear(), month: new Date().getMonth() + 1 };
  let latestData = null;
  let initialized = false;

  const FIGMA_HEAT_PALETTE = {
    positive: ["#ffffff", "#edffe0", "#d0f6b7", "#a6e585", "#89d663"],
    negative: ["#ffffff", "#ffeff1", "#ffd3d9", "#ff97a8", "#ff889e"],
  };
  const DARK_HEAT_PALETTE = {
    positive: ["#111713", "#17331d", "#205329", "#2b7436", "#389547"],
    negative: ["#191315", "#35191f", "#57232d", "#78303e", "#963d4d"],
  };

  function formatMoney(value, { compact = false } = {}) {
    const number = Number(value || 0);
    const prefix = number >= 0 ? "+" : "-";
    return `${prefix}$${Math.abs(number).toLocaleString(locale, {
      minimumFractionDigits: compact ? 0 : 2,
      maximumFractionDigits: 2,
    })}`;
  }

  function paletteColor(amount, colors) {
    const value = Math.max(0, Math.min(1, amount));
    const index = value <= 0.025 ? 0 : value < 0.18 ? 1 : value < 0.42 ? 2 : value < 0.72 ? 3 : 4;
    return colors[index];
  }

  function calendarFill(value, limit) {
    const normalized = Math.max(-1, Math.min(1, Number(value || 0) / Math.max(limit, 0.001)));
    const palette = document.documentElement.classList.contains("light-theme")
      ? FIGMA_HEAT_PALETTE
      : DARK_HEAT_PALETTE;
    return normalized >= 0
      ? paletteColor(normalized, palette.positive)
      : paletteColor(Math.abs(normalized), palette.negative);
  }

  function rowReturnPercent(row) {
    const value = Number(row?.return);
    return Number.isFinite(value) ? value * 100 : 0;
  }

  function formatTileMoney(value) {
    const number = Number(value || 0);
    const prefix = number < 0 ? "-" : "";
    return `${prefix}$${Math.round(Math.abs(number)).toLocaleString(locale)}`;
  }

  function calendarRows(data) {
    return (data.profit_calendar?.rows || []).filter(row => row?.date && Number.isFinite(Number(row.pnl_usd)));
  }

  function updateIncome(data) {
    const income = data.profit_calendar?.income || {};
    const monthKey = `${state.year}-${String(state.month).padStart(2, "0")}`;
    const selected = state.view === "day"
      ? (income.monthly_rows || []).find(row => row.month === monthKey) || {}
      : (income.rows || []).find(row => Number(row.year) === state.year) || {};
    const dividends = document.getElementById("profitCalendarDividends");
    const interest = document.getElementById("profitCalendarInterest");
    if (dividends) dividends.textContent = formatMoney(selected.dividends_usd || 0);
    if (interest) interest.textContent = formatMoney(selected.cash_interest_usd || 0);
    document.querySelectorAll(".profit-calendar-summary-period").forEach(node => {
      node.textContent = state.view === "day" ? copy.summaryMonth : copy.summaryYear;
    });
  }

  function renderDay(data) {
    const weekdays = document.getElementById("profitCalendarWeekdays");
    if (!weekdays) return;
    weekdays.hidden = false;
    weekdays.innerHTML = copy.weekdays.map(day => `<div class="profit-calendar-weekday">${day}</div>`).join("");
    grid.className = "profit-calendar-grid";

    const byDate = new Map(calendarRows(data).map(row => [row.date, row]));
    const daysInMonth = new Date(state.year, state.month, 0).getDate();
    const leadingDays = new Date(state.year, state.month - 1, 1).getDay();
    const cells = [];
    for (let index = 0; index < leadingDays; index += 1) {
      cells.push('<div class="profit-calendar-day is-outside" aria-hidden="true"></div>');
    }
    for (let day = 1; day <= daysInMonth; day += 1) {
      const date = `${state.year}-${String(state.month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
      const hasValue = byDate.has(date);
      const row = byDate.get(date);
      const value = Number(row?.pnl_usd || 0);
      const returnPercent = rowReturnPercent(row);
      const classes = ["profit-calendar-day", hasValue ? "has-value" : "", returnPercent < 0 ? "is-negative" : ""].filter(Boolean).join(" ");
      const style = hasValue ? ` style="--calendar-fill:${calendarFill(returnPercent, 2)}"` : "";
      const detail = hasValue ? `${copy.dayProfit} ${formatMoney(value)}` : copy.noData;
      cells.push(`<div class="${classes}" role="gridcell" aria-label="${date} ${detail}" title="${date} · ${detail}"${style}><span class="profit-calendar-day-number">${day}</span>${hasValue ? `<strong class="profit-calendar-day-value">${formatTileMoney(value)}</strong>` : ""}</div>`);
    }
    const totalCells = Math.ceil((leadingDays + daysInMonth) / 7) * 7;
    for (let index = leadingDays + daysInMonth; index < totalCells; index += 1) {
      cells.push('<div class="profit-calendar-day is-outside" aria-hidden="true"></div>');
    }
    grid.innerHTML = cells.join("");
  }

  function renderMonths(data) {
    const weekdays = document.getElementById("profitCalendarWeekdays");
    if (!weekdays) return;
    weekdays.hidden = true;
    const totals = new Map();
    calendarRows(data)
      .filter(row => Number(String(row.date).slice(0, 4)) === state.year)
      .forEach(row => {
        const month = Number(String(row.date).slice(5, 7));
        const total = totals.get(month) || { pnl: 0, growth: 1 };
        total.pnl += Number(row.pnl_usd || 0);
        total.growth *= 1 + Number(row.return || 0);
        totals.set(month, total);
      });
    grid.className = "profit-calendar-grid is-months";
    grid.innerHTML = copy.months.map((label, index) => {
      const month = index + 1;
      const hasValue = totals.has(month);
      const total = totals.get(month) || { pnl: 0, growth: 1 };
      const value = total.pnl;
      const returnPercent = (total.growth - 1) * 100;
      const classes = ["profit-calendar-month-tile", hasValue ? "has-value" : "", returnPercent < 0 ? "is-negative" : ""].filter(Boolean).join(" ");
      const style = hasValue ? ` style="--calendar-fill:${calendarFill(returnPercent, 10)}"` : "";
      const detail = hasValue ? `${label} ${formatMoney(value)}` : label;
      return `<div class="${classes}" role="gridcell" aria-label="${detail}"${style}><span>${label}</span>${hasValue ? `<strong>${formatMoney(value)}</strong>` : ""}</div>`;
    }).join("");
  }

  function renderYear(data) {
    const weekdays = document.getElementById("profitCalendarWeekdays");
    if (!weekdays) return;
    weekdays.hidden = true;
    const rows = calendarRows(data)
      .filter(row => Number(String(row.date).slice(0, 4)) === state.year)
      .sort((left, right) => String(left.date).localeCompare(String(right.date)));
    const cells = rows.slice(0, 272).map(row => {
      const value = Number(row.pnl_usd || 0);
      const returnPercent = rowReturnPercent(row);
      const tone = returnPercent < 0 ? "is-negative" : "is-positive";
      const detail = `${copy.dayProfit} ${formatMoney(value)}`;
      return `<div class="profit-calendar-year-day has-value ${tone}" role="gridcell" aria-label="${detail}" title="${formatMoney(value)}" style="--calendar-fill:${calendarFill(returnPercent, 2)}"></div>`;
    });

    while (cells.length < 272) {
      cells.push('<div class="profit-calendar-year-day is-empty" aria-hidden="true"></div>');
    }

    grid.className = "profit-calendar-grid is-year";
    grid.style.removeProperty("--calendar-week-count");
    grid.innerHTML = cells.join("");
  }

  function render(data) {
    const rows = calendarRows(data);
    if (!initialized) {
      const latest = rows.at(-1)?.date;
      if (latest) [state.year, state.month] = latest.split("-").map(Number);
      initialized = true;
    }
    const periodMonth = document.getElementById("profitCalendarPeriodMonth");
    const periodYear = document.getElementById("profitCalendarPeriodYear");
    if (periodMonth) periodMonth.textContent = copy.months[state.month - 1];
    if (periodYear) periodYear.textContent = String(state.year);
    const dayButton = document.getElementById("profitCalendarDay");
    const monthButton = document.getElementById("profitCalendarMonth");
    const yearButton = document.getElementById("profitCalendarYear");
    dayButton?.classList.toggle("active", state.view === "day");
    monthButton?.classList.toggle("active", state.view === "month");
    yearButton?.classList.toggle("active", state.view === "year");
    dayButton?.setAttribute("aria-pressed", state.view === "day" ? "true" : "false");
    monthButton?.setAttribute("aria-pressed", state.view === "month" ? "true" : "false");
    yearButton?.setAttribute("aria-pressed", state.view === "year" ? "true" : "false");
    if (state.view === "year") renderYear(data);
    else if (state.view === "month") renderMonths(data);
    else renderDay(data);
    updateIncome(data);
  }

  document.getElementById("profitCalendarDay")?.addEventListener("click", () => {
    state.view = "day";
    if (latestData) render(latestData);
  });
  document.getElementById("profitCalendarMonth")?.addEventListener("click", () => {
    state.view = "month";
    if (latestData) render(latestData);
  });
  document.getElementById("profitCalendarYear")?.addEventListener("click", () => {
    state.view = "year";
    if (latestData) render(latestData);
  });
  document.getElementById("profitCalendarPrev")?.addEventListener("click", () => {
    if (state.view !== "day") state.year -= 1;
    else if (state.month === 1) { state.month = 12; state.year -= 1; }
    else state.month -= 1;
    if (latestData) render(latestData);
  });
  document.getElementById("profitCalendarNext")?.addEventListener("click", () => {
    if (state.view !== "day") state.year += 1;
    else if (state.month === 12) { state.month = 1; state.year += 1; }
    else state.month += 1;
    if (latestData) render(latestData);
  });
  window.addEventListener("catfolio:themechange", () => {
    if (latestData) render(latestData);
  });

  fetch("/api/profit-calendar", { headers: { Accept: "application/json" } })
    .then(response => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    })
    .then(data => {
      latestData = data;
      render(data);
    })
    .catch(error => {
      grid.className = "profit-calendar-grid";
      grid.innerHTML = `<div class="portfolio-calendar-error">${copy.loadError} ${error.message || ""}</div>`;
    });
})();
