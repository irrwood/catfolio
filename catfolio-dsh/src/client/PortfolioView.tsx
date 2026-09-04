/**
 * Portfolio view — port of the Catfolio `/lab` page: metric cards, the
 * cost-vs-market-value chart, the profit calendar, and the holdings table
 * (direct / ETF look-through) with volume-profile hover popovers.
 */
import { useEffect, useRef, useState, useCallback, useMemo } from "react";
import * as echarts from "echarts";
import {
  COPY, t, escapeHtml, numeric, money, signedMoney, signedPercent, ratioPercent,
  preciseMoney, nativePrice, rangePrice, rangePosition, tickerHue, formatNumber, currentLang, localeString,
} from "./copy.js";
import { ICON_ARROW_LEFT, ICON_ARROW_RIGHT, ICON_DIVIDEND, ICON_CASH_INTEREST, ICON_SORT } from "./styles.js";

export type Row = Record<string, unknown>;

const RANGE_DAYS: Record<string, number> = { "1d": 2, "1w": 5, "1m": 21, "3m": 63, "1y": 252 };

const CHART_COLORS = {
  market: "#2F8A3E",
  cost: "#708CFF",
  negative: "#E40014",
  grid: "#EAEBED",
  date: "#000000",
};

const FIGMA_HEAT_PALETTE = {
  positive: ["#ffffff", "#edffe0", "#d0f6b7", "#a6e585", "#89d663"],
  negative: ["#ffffff", "#ffeff1", "#ffd3d9", "#ff97a8", "#ff889e"],
};
const DARK_HEAT_PALETTE = {
  positive: ["#111713", "#17331d", "#205329", "#2b7436", "#389547"],
  negative: ["#191315", "#35191f", "#57232d", "#78303e", "#963d4d"],
};

function cssVar(name: string, fallback: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;
}

function syncChartColors(root: HTMLElement | null) {
  if (!root) return;
  const style = getComputedStyle(root);
  CHART_COLORS.market = style.getPropertyValue("--positive").trim() || "#2F8A3E";
  CHART_COLORS.negative = style.getPropertyValue("--negative").trim() || "#E40014";
  CHART_COLORS.grid = style.getPropertyValue("--line-strong").trim() || "#EAEBED";
  CHART_COLORS.date = style.getPropertyValue("--ink").trim() || "#000000";
}

function isDarkTheme(): boolean {
  return document.body.hasAttribute("data-ds-dark-theme");
}

function paletteColor(amount: number, colors: string[]): string {
  const value = Math.max(0, Math.min(1, amount));
  const index = value <= 0.025 ? 0 : value < 0.18 ? 1 : value < 0.42 ? 2 : value < 0.72 ? 3 : 4;
  return colors[index];
}

function calendarFill(value: number, limit: number): string {
  const normalized = Math.max(-1, Math.min(1, numeric(value) / Math.max(limit, 0.001)));
  const palette = isDarkTheme() ? DARK_HEAT_PALETTE : FIGMA_HEAT_PALETTE;
  return normalized >= 0
    ? paletteColor(normalized, palette.positive)
    : paletteColor(Math.abs(normalized), palette.negative);
}

function formatMoney(value: number, { compact = false } = {}): string {
  const number = Number(value || 0);
  const prefix = number >= 0 ? "+" : "-";
  return `${prefix}$${Math.abs(number).toLocaleString(localeString(), {
    minimumFractionDigits: compact ? 0 : 2,
    maximumFractionDigits: 2,
  })}`;
}

function formatTileMoney(value: number): string {
  const number = Number(value || 0);
  const prefix = number < 0 ? "-" : "";
  return `${prefix}$${Math.round(Math.abs(number)).toLocaleString(localeString())}`;
}

// ── metric cards ────────────────────────────────────────────────────────────

function MetricCard({ label, value, note, tone }: { label: string; value: string; note?: string; tone?: "positive" | "negative" }) {
  return (
    <article className="catfolio-metric-card">
      <span>{label}</span>
      <strong className={tone ?? ""}>{value}</strong>
      {note ? <small className={tone ?? ""}>{note}</small> : <small>&nbsp;</small>}
    </article>
  );
}

function renderOverview(overview: Row) {
  const summary = (overview.summary ?? {}) as Row;
  const holdings = (overview.top_holdings ?? []) as Row[];
  const marketValue = numeric(summary.market_value_usd);
  const todayPnl = numeric(overview.today_pnl_usd);
  const totalPnl = numeric(summary.unrealized_usd);
  const totalCost = numeric(summary.total_cost_usd_standard);
  const topFive = holdings.slice(0, 5).reduce((sum, row) => sum + numeric(row.weight), 0);
  const topOne = numeric(holdings[0]?.weight);
  return {
    value: `$${Math.abs(marketValue).toLocaleString(localeString(), { maximumFractionDigits: 0 })}`,
    today: `${signedMoney(todayPnl)} ${t("today")}`,
    todayTone: todayPnl >= 0 ? "positive" : "negative",
    pnl: `${totalPnl >= 0 ? "+" : "-"}$${Math.abs(totalPnl).toLocaleString(localeString(), { maximumFractionDigits: 0 })}`,
    pnlTone: totalPnl >= 0 ? "positive" : "negative",
    pnlRate: `${signedPercent(totalCost ? (totalPnl / totalCost) * 100 : 0)} ${t("totalReturn")}`,
    count: String(Math.round(numeric(summary.open_positions ?? holdings.length))),
    breadth: `${t("up")} ${numeric((overview.breadth as Row)?.up)} / ${t("down")} ${numeric((overview.breadth as Row)?.down)}`,
    topFive: ratioPercent(topFive),
    topOne: `${t("largest")} ${ratioPercent(topOne)}`,
  };
}

// ── cost vs value chart ─────────────────────────────────────────────────────

function normalizeValueRows(payload: Row): { date: string; market: number | null; cost: number | null }[] {
  const positionHistory = (payload.position_history ?? {}) as Row;
  const rows = ((positionHistory.rows ?? []) as Row[])
    .map((row) => ({
      date: String(row.date ?? ""),
      market: numeric(row.market_value_usd),
      cost: numeric(row.cost_usd),
    }))
    .filter((row) => row.date && Number.isFinite(row.market) && Number.isFinite(row.cost));
  const current = (payload.current_point ?? {}) as Row;
  const currentRow = {
    date: String(current.date ?? ""),
    market: numeric(current.market_value_usd),
    cost: numeric(current.cost_usd),
  };
  if (currentRow.date && Number.isFinite(currentRow.market) && Number.isFinite(currentRow.cost)) {
    const existingIndex = rows.findIndex((row) => row.date === currentRow.date);
    if (existingIndex >= 0) rows[existingIndex] = currentRow;
    else rows.push(currentRow);
  }
  return rows.sort((left, right) => String(left.date).localeCompare(String(right.date)));
}

function visibleRows(rows: { date: string; market: number; cost: number }[], range: string) {
  if (range === "max") return rows;
  if (range === "ytd") {
    const year = new Date().getFullYear();
    const filtered = rows.filter((row) => Number(String(row.date).slice(0, 4)) === year);
    return filtered.length ? filtered : rows.slice(-252);
  }
  return rows.slice(-RANGE_DAYS[range]);
}

function chartBounds(rows: { market: number; cost: number }[]) {
  const values = rows.flatMap((row) => [row.market, row.cost]).filter(Number.isFinite);
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
  return { min, max, interval: axisInterval };
}

function axisMoney(value: number): string {
  const abs = Math.abs(Number(value || 0));
  if (abs >= 1_000_000) return `${(value / 1_000_000).toFixed(abs >= 10_000_000 ? 0 : 1)}M`;
  if (abs >= 1_000) {
    const thousands = value / 1_000;
    const integer = Math.round(thousands);
    return `${Math.abs(thousands - integer) < 0.05 ? integer : thousands.toFixed(1)}K`;
  }
  return Math.round(value).toLocaleString(localeString());
}

function isVisibleYAxisValue(value: number, bounds: { min: number; max: number; interval: number }): boolean {
  const index = Math.round((Number(value) - bounds.min) / bounds.interval);
  const lastIndex = Math.max(0, Math.round((bounds.max - bounds.min) / bounds.interval));
  return index === 0 || index === lastIndex || index % 2 === 0;
}

export function CostValueChart({ rows, range, onRange }: {
  rows: { date: string; market: number; cost: number }[];
  range: string;
  onRange: (range: string) => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<echarts.ECharts | null>(null);
  const hoverLayerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const chart = echarts.init(container);
    chartRef.current = chart;
    const observer = new ResizeObserver(() => chart.resize());
    observer.observe(container);
    return () => {
      observer.disconnect();
      chart.dispose();
      chartRef.current = null;
    };
  }, []);

  useEffect(() => {
    const chart = chartRef.current;
    const container = containerRef.current;
    if (!chart || !container) return;
    syncChartColors(container.closest(".catfolio-view") as HTMLElement);
    const visible = visibleRows(rows, range);
    const hoverLayer = hoverLayerRef.current;
    if (hoverLayer) hoverLayer.innerHTML = "";
    if (!visible.length) {
      chart.clear();
      chart.setOption({
        graphic: [{
          type: "text",
          left: "center",
          top: "middle",
          style: { text: t("noHistory"), fill: cssVar("--muted", "#888"), font: "12px Nunito, system-ui" },
        }],
      });
      return;
    }
    const bounds = chartBounds(visible);
    const series = [
      {
        name: t("market"),
        type: "line",
        z: 5,
        data: visible.map((row) => [row.date, row.market]),
        showSymbol: false,
        smooth: 0.32,
        clip: false,
        lineStyle: { color: CHART_COLORS.market, width: 2, cap: "round" as const },
        itemStyle: { color: CHART_COLORS.market },
        emphasis: { disabled: true },
        markLine: {
          silent: true,
          symbol: ["none", "none"],
          animation: false,
          label: { show: false },
          lineStyle: { color: CHART_COLORS.grid, width: 1, type: "solid" as const, cap: "round" as const },
          data: visibleYAxisValues(bounds).map((value) => ({ yAxis: value })),
        },
      },
      {
        name: t("cost"),
        type: "line",
        z: 5,
        data: visible.map((row) => [row.date, row.cost]),
        showSymbol: false,
        smooth: 0.32,
        clip: false,
        lineStyle: { color: CHART_COLORS.cost, width: 2, cap: "round" as const },
        itemStyle: { color: CHART_COLORS.cost },
        emphasis: { disabled: true },
      },
    ];
    chart.setOption(
      {
        animation: true,
        animationDuration: 420,
        animationDurationUpdate: 220,
        animationEasing: "cubicOut",
        animationEasingUpdate: "cubicOut",
        backgroundColor: "transparent",
        textStyle: { fontFamily: "Nunito Local, Nunito, sans-serif" },
        grid: { left: 0, right: 8, top: 14, bottom: 8, containLabel: true },
        axisPointer: { z: 1, animation: false, animationDurationUpdate: 0 },
        tooltip: { trigger: "axis", showContent: false, confine: true, transitionDuration: 0 },
        xAxis: {
          type: "category",
          position: "top",
          boundaryGap: false,
          data: visible.map((row) => row.date),
          axisLine: { show: false },
          axisTick: { show: false },
          axisLabel: { show: false },
          axisPointer: { show: true, z: 1, label: { show: false } },
        },
        yAxis: {
          type: "value",
          min: bounds.min,
          max: bounds.max,
          interval: bounds.interval,
          axisLine: { show: false },
          axisTick: { show: false },
          axisLabel: {
            color: cssVar("--muted", "#888"),
            fontSize: 12,
            fontWeight: 700,
            margin: 20,
            formatter: (value: number) => (isVisibleYAxisValue(value, bounds) ? axisMoney(value) : ""),
          },
          splitLine: { show: false },
        },
        series,
      },
      true,
    );
  }, [rows, range]);

  return (
    <div className="catfolio-chart-body">
      <div ref={containerRef} className="catfolio-value-chart" role="img" aria-label={t("market")} />
      <div ref={hoverLayerRef} className="catfolio-chart-hover-layer" aria-hidden="true" />
      <div className="catfolio-ranges" role="group" aria-label="图表时间范围">
        {["1d", "1w", "1m", "3m", "ytd", "1y", "max"].map((key) => (
          <button
            key={key}
            type="button"
            className={range === key ? "active" : ""}
            aria-pressed={range === key}
            onClick={() => onRange(key)}
          >
            {key === "1d" ? "1D" : key === "1w" ? "1W" : key === "1m" ? "1M" : key === "3m" ? "3M" : key.toUpperCase()}
          </button>
        ))}
      </div>
    </div>
  );
}

function visibleYAxisValues(bounds: { min: number; max: number; interval: number }): number[] {
  const lastIndex = Math.max(0, Math.round((bounds.max - bounds.min) / bounds.interval));
  const values: number[] = [];
  for (let index = 0; index <= lastIndex; index += 1) {
    if (index === 0 || index === lastIndex || index % 2 === 0) {
      values.push(bounds.min + bounds.interval * index);
    }
  }
  return values;
}

// ── profit calendar ─────────────────────────────────────────────────────────

interface CalendarState { view: "day" | "month" | "year"; year: number; month: number }

export function ProfitCalendar({ data }: { data: Row }) {
  const copy = COPY[currentLang()];
  const rows = useMemo(
    () => (((data.profit_calendar ?? {}) as Row).rows ?? []) as Row[],
    [data],
  );
  const income = useMemo(() => (((data.profit_calendar ?? {}) as Row).income ?? {}) as Row, [data]);
  const [state, setState] = useState<CalendarState>(() => {
    const latest = rows[rows.length - 1]?.date as string | undefined;
    if (latest) {
      const [year, month] = latest.split("-").map(Number);
      return { view: "day", year, month };
    }
    const now = new Date();
    return { view: "day", year: now.getFullYear(), month: now.getMonth() + 1 };
  });

  const renderDay = useCallback(() => {
    const byDate = new Map(rows.map((row) => [String(row.date), row]));
    const daysInMonth = new Date(state.year, state.month, 0).getDate();
    const leadingDays = new Date(state.year, state.month - 1, 1).getDay();
    const cells: { key: string; className: string; style?: string; content?: string; aria?: string }[] = [];
    for (let index = 0; index < leadingDays; index += 1) {
      cells.push({ key: `out-${index}`, className: "catfolio-calendar-day is-outside", content: "" });
    }
    for (let day = 1; day <= daysInMonth; day += 1) {
      const date = `${state.year}-${String(state.month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
      const row = byDate.get(date);
      const value = numeric(row?.pnl_usd);
      const returnPercent = numeric(row?.return) * 100;
      const hasValue = Boolean(row);
      const classes = ["catfolio-calendar-day", hasValue ? "has-value" : "", returnPercent < 0 ? "is-negative" : ""].filter(Boolean).join(" ");
      const style = hasValue ? `--calendar-fill:${calendarFill(returnPercent, 2)}` : undefined;
      const detail = hasValue ? `${copy.dayProfit} ${formatMoney(value)}` : copy.calendarNoData;
      cells.push({
        key: date,
        className: classes,
        style,
        aria: `${date} ${detail}`,
        content: `${day}${hasValue ? `<strong class="catfolio-calendar-day-value">${formatTileMoney(value)}</strong>` : ""}`,
      });
    }
    const totalCells = Math.ceil((leadingDays + daysInMonth) / 7) * 7;
    for (let index = leadingDays + daysInMonth; index < totalCells; index += 1) {
      cells.push({ key: `tail-${index}`, className: "catfolio-calendar-day is-outside", content: "" });
    }
    return cells;
  }, [rows, state, copy]);

  const renderMonths = useCallback(() => {
    const totals = new Map<number, { pnl: number; growth: number }>();
    rows
      .filter((row) => Number(String(row.date).slice(0, 4)) === state.year)
      .forEach((row) => {
        const month = Number(String(row.date).slice(5, 7));
        const total = totals.get(month) || { pnl: 0, growth: 1 };
        total.pnl += numeric(row.pnl_usd);
        total.growth *= 1 + numeric(row.return);
        totals.set(month, total);
      });
    return copy.months.map((label, index) => {
      const month = index + 1;
      const total = totals.get(month) || { pnl: 0, growth: 1 };
      const hasValue = totals.has(month);
      const value = total.pnl;
      const returnPercent = (total.growth - 1) * 100;
      const classes = ["catfolio-calendar-month-tile", hasValue ? "has-value" : "", returnPercent < 0 ? "is-negative" : ""].filter(Boolean).join(" ");
      return {
        key: `month-${month}`,
        className: classes,
        style: hasValue ? `--calendar-fill:${calendarFill(returnPercent, 10)}` : undefined,
        content: `<span>${label}</span>${hasValue ? `<strong>${formatMoney(value)}</strong>` : ""}`,
        aria: hasValue ? `${label} ${formatMoney(value)}` : label,
      };
    });
  }, [rows, state.year, copy]);

  const renderYear = useCallback(() => {
    const yearRows = rows
      .filter((row) => Number(String(row.date).slice(0, 4)) === state.year)
      .sort((left, right) => String(left.date).localeCompare(String(right.date)))
      .slice(0, 272);
    const cells: { key: string; className: string; style: string; aria: string }[] = yearRows.map((row) => {
      const value = numeric(row.pnl_usd);
      const returnPercent = numeric(row.return) * 100;
      const tone = returnPercent < 0 ? "is-negative" : "is-positive";
      const detail = `${copy.dayProfit} ${formatMoney(value)}`;
      return {
        key: String(row.date),
        className: `catfolio-calendar-year-day has-value ${tone}`,
        style: `--calendar-fill:${calendarFill(returnPercent, 2)}`,
        aria: detail,
      };
    });
    while (cells.length < 272) {
      cells.push({ key: `empty-${cells.length}`, className: "catfolio-calendar-year-day is-empty", style: "", aria: "" });
    }
    return cells;
  }, [rows, state.year, copy]);

  const updateIncome = useCallback(() => {
    const monthKey = `${state.year}-${String(state.month).padStart(2, "0")}`;
    const selected = state.view === "day"
      ? (((income.monthly_rows ?? []) as Row[]).find((row) => row.month === monthKey) ?? {})
      : (((income.rows ?? []) as Row[]).find((row) => Number(row.year) === state.year) ?? {});
    return {
      dividends: formatMoney(numeric(selected.dividends_usd)),
      interest: formatMoney(numeric(selected.cash_interest_usd)),
      period: state.view === "day" ? copy.summaryMonth : copy.summaryYear,
    };
  }, [income, state, copy]);

  const incomeSummary = updateIncome();

  const cells = state.view === "year" ? renderYear() : state.view === "month" ? renderMonths() : renderDay();

  const navigate = (direction: 1 | -1) => {
    setState((prev) => {
      if (prev.view !== "day") return { ...prev, year: prev.year + direction };
      if (direction === -1 && prev.month === 1) return { ...prev, month: 12, year: prev.year - 1 };
      if (direction === 1 && prev.month === 12) return { ...prev, month: 1, year: prev.year + 1 };
      return { ...prev, month: prev.month + direction };
    });
  };

  return (
    <article className="catfolio-calendar-card" aria-labelledby="catfolio-calendar-title">
      <header className="catfolio-calendar-head">
        <h2 id="catfolio-calendar-title">{t("dayProfit")} · {t("summaryMonth")}</h2>
        <div className="catfolio-calendar-controls">
          <div className="catfolio-calendar-range" role="group" aria-label="日历范围">
            {(["day", "month", "year"] as const).map((view) => (
              <button
                key={view}
                type="button"
                className={`catfolio-calendar-range-button${state.view === view ? " active" : ""}`}
                aria-pressed={state.view === view}
                onClick={() => setState((prev) => ({ ...prev, view }))}
              >
                {view === "day" ? "D" : view === "month" ? "M" : "Y"}
              </button>
            ))}
          </div>
          <div className="catfolio-calendar-period-nav">
            <button type="button" aria-label="上一个周期" onClick={() => navigate(-1)}>
              <img src={`data:image/svg+xml;utf8,${encodeURIComponent(ICON_ARROW_LEFT)}`} alt="" />
            </button>
            <span className="catfolio-calendar-period" aria-live="polite">
              <span className="catfolio-calendar-period-month">{copy.months[state.month - 1]}</span>
              <span>{state.year}</span>
            </span>
            <button type="button" aria-label="下一个周期" onClick={() => navigate(1)}>
              <img src={`data:image/svg+xml;utf8,${encodeURIComponent(ICON_ARROW_RIGHT)}`} alt="" />
            </button>
          </div>
        </div>
      </header>
      <div className="catfolio-calendar-body">
        {state.view === "day" && (
          <div className="catfolio-calendar-weekdays" aria-hidden="true">
            {copy.weekdays.map((day) => (
              <div key={day} className="catfolio-calendar-weekday">{day}</div>
            ))}
          </div>
        )}
        <div
          className={`catfolio-calendar-grid${state.view === "month" ? " is-months" : ""}${state.view === "year" ? " is-year" : ""}`}
          role="grid"
          aria-label="每日投资组合盈亏"
        >
          {cells.map((cell) => (
            <div
              key={cell.key}
              className={cell.className}
              role="gridcell"
              aria-label={cell.aria}
              title={cell.aria}
              style={cell.style ? { "--calendar-fill": cell.style.split(":")[1] } as React.CSSProperties : undefined}
              dangerouslySetInnerHTML={cell.content ? { __html: cell.content } : undefined}
            />
          ))}
        </div>
      </div>
      <footer className="catfolio-calendar-summary">
        <div className="catfolio-calendar-summary-item">
          <img src={`data:image/svg+xml;utf8,${encodeURIComponent(ICON_DIVIDEND)}`} alt="" />
          <span className="catfolio-calendar-summary-label">{t("dividends")}</span>
          <strong>{incomeSummary.dividends}</strong>
          <span className="catfolio-calendar-summary-period">{incomeSummary.period}</span>
        </div>
        <div className="catfolio-calendar-summary-item">
          <img src={`data:image/svg+xml;utf8,${encodeURIComponent(ICON_CASH_INTEREST)}`} alt="" />
          <span className="catfolio-calendar-summary-label">{t("cashInterest")}</span>
          <strong>{incomeSummary.interest}</strong>
          <span className="catfolio-calendar-summary-period">{incomeSummary.period}</span>
        </div>
      </footer>
    </article>
  );
}

// ── holdings table ──────────────────────────────────────────────────────────

interface HoldingsState {
  mode: "direct" | "lookthrough";
  direct: Row[];
  lookthrough: Row[];
  total: number;
  etfTotal: number;
  sortKey: string;
  sortDirection: "asc" | "desc";
  profitSortMetric: "amount" | "percent";
}

const directHeaders: [string, string][] = [
  ["§", ""],
  [COPY.zh.asset, ""],
  [COPY.zh.currentPrice, ""],
  [COPY.zh.todayShort, "today"],
  [COPY.zh.profit, "profit"],
  [COPY.zh.fxProfit, "fx"],
  [COPY.zh.marketValueColumn, "position"],
  [COPY.zh.weeks, "range"],
];

export function HoldingsTable({ direct, lookthrough, total, etfTotal }: {
  direct: Row[];
  lookthrough: Row[];
  total: number;
  etfTotal: number;
}) {
  const [state, setState] = useState<HoldingsState>({
    mode: "direct",
    direct,
    lookthrough,
    total,
    etfTotal,
    sortKey: "position",
    sortDirection: "desc",
    profitSortMetric: "amount",
  });
  const [profiles, setProfiles] = useState<Map<string, Row>>(new Map());
  const [popover, setPopover] = useState<{ x: number; y: number; ticker: string; row: Row } | null>(null);
  const popoverTimer = useRef<number>(0);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => {
    setState((prev) => ({ ...prev, direct, lookthrough, total, etfTotal }));
  }, [direct, lookthrough, total, etfTotal]);

  useEffect(() => () => {
    window.clearTimeout(popoverTimer.current);
    abortRef.current?.abort();
  }, []);

  const finePointer = window.matchMedia("(hover: hover) and (pointer: fine)");

  const matchingDirectHolding = (row: Row) =>
    direct.find((item) => String(item.ticker || "").toUpperCase() === String(row.ticker || "").toUpperCase());

  const sortValue = (row: Row): number => {
    if (state.mode === "direct") {
      switch (state.sortKey) {
        case "today": return numeric(row.today_change_percent);
        case "profit": return state.profitSortMetric === "amount" ? numeric(row.unrealized_usd) : numeric(row.unrealized_percent);
        case "fx": return numeric(row.broker_fx_ppl_usd);
        case "range": return rangePosition(row) ?? Number.NEGATIVE_INFINITY;
        case "position": return numeric(row.weight);
        default: return 0;
      }
    }
    const directRow = matchingDirectHolding(row);
    const totalUsd = numeric(row.total_usd);
    switch (state.sortKey) {
      case "today": return directRow ? numeric(directRow.today_change_percent) : Number.NEGATIVE_INFINITY;
      case "profit": return directRow ? (state.profitSortMetric === "amount" ? numeric(directRow.unrealized_usd) : numeric(directRow.unrealized_percent)) : Number.NEGATIVE_INFINITY;
      case "fx": return directRow ? numeric(directRow.broker_fx_ppl_usd) : Number.NEGATIVE_INFINITY;
      case "range": return directRow ? (rangePosition(directRow) ?? Number.NEGATIVE_INFINITY) : Number.NEGATIVE_INFINITY;
      case "position": return state.total ? totalUsd / state.total : 0;
      default: return 0;
    }
  };

  const handleSort = (key: string) => {
    setState((prev) => {
      if (key === "profit") {
        if (prev.sortKey !== "profit") return { ...prev, sortKey: "profit", profitSortMetric: "amount", sortDirection: "desc" };
        if (prev.profitSortMetric === "amount" && prev.sortDirection === "desc") return { ...prev, sortDirection: "asc" };
        if (prev.profitSortMetric === "amount") return { ...prev, profitSortMetric: "percent", sortDirection: "desc" };
        if (prev.sortDirection === "desc") return { ...prev, sortDirection: "asc" };
        return { ...prev, profitSortMetric: "amount", sortDirection: "desc" };
      }
      if (prev.sortKey === key) return { ...prev, sortDirection: prev.sortDirection === "desc" ? "asc" : "desc" };
      return { ...prev, sortKey: key, sortDirection: "desc" };
    });
  };

  const sortedRows = [...(state.mode === "direct" ? state.direct : state.lookthrough)].sort((a, b) => {
    const delta = sortValue(a) - sortValue(b);
    return state.sortDirection === "asc" ? delta : -delta;
  });

  const assetCells = (row: Row, shares: unknown = row.shares) => {
    const ticker = String(row.ticker || "—");
    const name = String(row.company_name || row.name || "").trim();
    const displayName = name && name.toUpperCase() !== ticker.toUpperCase() ? name : ticker;
    const shareLabel = shares === null || shares === undefined || shares === "" ? "" : formatNumber(shares, 3, 3);
    const initial = String(row.ticker || "?").slice(0, 1);
    const logoSymbol = String(row.logo_symbol || row.ticker || "").trim();
    return (
      <>
        <td className="catfolio-holding-logo">
          <span
            className="catfolio-holding-badge"
            style={{ "--asset-hue": tickerHue(String(row.ticker)) } as React.CSSProperties}
          >
            <span className="catfolio-holding-initial">{initial}</span>
            {logoSymbol && (
              <img src={`/catfolio/api/asset-logo/${encodeURIComponent(logoSymbol)}`} alt="" loading="lazy" decoding="async" />
            )}
          </span>
        </td>
        <td className="catfolio-holding-asset">
          <span className="catfolio-holding-identity">
            <strong title={displayName}>{displayName}</strong>
            <small>
              {shareLabel ? <span>{shareLabel}</span> : null}
              <span>{ticker}</span>
            </small>
          </span>
        </td>
      </>
    );
  };

  const nativePriceCell = (row: Row) => {
    const price = numeric(row.quote_price);
    const cost = row.avg_cost_native ?? row.avg_cost_usd;
    return (
      <span className="catfolio-holding-stack">
        <b>{nativePrice(row.quote_price, row.quote_currency || row.cost_currency || "USD")}</b>
        <span>{nativePrice(cost, row.cost_currency || "USD")}</span>
      </span>
    );
  };

  const rangeMarkup = (row: Row) => {
    const position = rangePosition(row);
    if (position === null) return <span className="muted">—</span>;
    const percentage = Math.round(position * 100);
    const current = rangePrice(row.quote_price, row.quote_currency);
    const hint = `${t("rangeCurrent")} ${current} · ${t("rangeLocation")} ${percentage}%`;
    return (
      <span className="catfolio-holding-range" role="img" aria-label={hint}>
        <span className="catfolio-holding-range-values">
          <span>{rangePrice(row.high_52w, row.quote_currency)}</span>
          <span>{rangePrice(row.low_52w, row.quote_currency)}</span>
        </span>
        <span className="catfolio-holding-range-track" title={hint}>
          <i style={{ height: `${Math.max(2, position * 100).toFixed(2)}%` }} />
          <span className="catfolio-holding-range-marker" style={{ bottom: `${(position * 100).toFixed(2)}%` }} aria-hidden="true" />
        </span>
      </span>
    );
  };

  /** 未实现盈亏 + 汇率盈亏两列。direct 模式直接传 row；lookthrough 模式传 (lookRow, directRow?)，
   *  directRow 为空时显示占位。 */
  const profitCell = (row: Row, directRow?: Row | null) => {
    const hasSource = Boolean(directRow) || Boolean(row.unrealized_usd !== undefined || row.broker_fx_ppl_usd !== undefined);
    const source = directRow ?? row;
    const profit = numeric(source.unrealized_usd);
    const profitPercent = numeric(source.unrealized_percent);
    const fxProfit = numeric(source.broker_fx_ppl_usd);
    const fxProfitPercent = numeric(source.broker_fx_ppl_percent);
    const tone = profit >= 0 ? "positive" : "negative";
    const fxTone = Math.abs(fxProfit) < 0.005 ? "muted" : fxProfit >= 0 ? "positive" : "negative";
    const fxMoney = Math.abs(fxProfit) < 0.005 ? preciseMoney(0) : signedMoney(fxProfit);
    const fxPercentLabel = Math.abs(fxProfitPercent) < 0.005 ? "0.0%" : signedPercent(fxProfitPercent);
    if (!hasSource) {
      // Look-through rows without a direct holding show placeholders, matching the original.
      return (
        <>
          <td><span className="catfolio-holding-profit"><b className="muted">—</b><span className="muted">—</span></span></td>
          <td><span className="catfolio-holding-fx"><b className="muted">—</b><span className="muted">—</span></span></td>
        </>
      );
    }
    return (
      <>
        <td>
          <span className="catfolio-holding-profit">
            <b className={tone}>{signedMoney(profit)}</b>
            <span className={tone}>{signedPercent(profitPercent)}</span>
          </span>
        </td>
        <td>
          <span className="catfolio-holding-fx">
            <b className={fxTone}>{fxMoney}</b>
            <span className={fxTone}>{fxPercentLabel}</span>
          </span>
        </td>
      </>
    );
  };

  const onRowHover = (row: Row, event: React.MouseEvent) => {
    if (!finePointer.matches) return;
    const ticker = String(row.ticker || "");
    const currency = String(row.quote_currency || row.cost_currency || "USD");
    const costPrice = row.avg_cost_native ?? row.avg_cost_usd;
    const costCurrency = String(row.cost_currency || row.quote_currency || "USD");
    window.clearTimeout(popoverTimer.current);
    popoverTimer.current = window.setTimeout(() => {
      setPopover({ x: event.clientX, y: event.clientY, ticker, row });
    }, 120);
    if (!profiles.has(ticker)) {
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;
      fetch(`/catfolio/api/holdings/${encodeURIComponent(ticker)}/volume-profile`, { signal: controller.signal })
        .then((response) => (response.ok ? response.json() : null))
        .then((profile) => {
          if (profile) setProfiles((prev) => new Map(prev).set(ticker, profile as Row));
        })
        .catch(() => undefined);
    }
  };

  const hidePopover = () => {
    window.clearTimeout(popoverTimer.current);
    setPopover(null);
  };

  const activeProfile = popover ? profiles.get(popover.ticker) : undefined;

  return (
    <section className="catfolio-holdings-card" aria-labelledby="catfolio-holdings-title">
      <header className="catfolio-holdings-head">
        <div className="catfolio-holdings-title">
          <h2 id="catfolio-holdings-title">持仓明细</h2>
          <p aria-live="polite">
            {state.mode === "direct"
              ? `${state.direct.length} ${t("holdings")} · ${t("marketValue")} ${money(state.total)}`
              : `${state.lookthrough.length} ${t("exposures")} · ${t("etfValue")} ${money(state.etfTotal)}`}
          </p>
        </div>
        <div className="catfolio-holdings-mode" role="tablist" aria-label="持仓视图">
          <button
            type="button"
            role="tab"
            aria-selected={state.mode === "direct"}
            className={state.mode === "direct" ? "active" : ""}
            onClick={() => setState((prev) => ({ ...prev, mode: "direct", sortKey: "position", sortDirection: "desc", profitSortMetric: "amount" }))}
          >
            {t("direct")}
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={state.mode === "lookthrough"}
            className={state.mode === "lookthrough" ? "active" : ""}
            onClick={() => setState((prev) => ({ ...prev, mode: "lookthrough", sortKey: "position", sortDirection: "desc", profitSortMetric: "amount" }))}
          >
            {t("lookthrough")}
          </button>
        </div>
      </header>
      <div className="catfolio-holdings-scroll" tabIndex={0} aria-label="持仓明细列表">
        <table className="catfolio-holdings-table">
          <thead>
            <tr>
              {directHeaders.map(([label, key]) => {
                const active = key && state.sortKey === key;
                const ariaSort = active ? (state.sortDirection === "asc" ? "ascending" : "descending") : undefined;
                if (!key) return <th key={label} scope="col">{label === "§" ? "" : label}</th>;
                const profitSortHint = active && key === "profit"
                  ? `${label}: ${state.profitSortMetric === "amount" ? t("amountSort") : t("percentSort")}, ${state.sortDirection === "desc" ? t("highToLow") : t("lowToHigh")}`
                  : label;
                return (
                  <th key={key} scope="col" aria-sort={ariaSort}>
                    <button
                      type="button"
                      className={`catfolio-holdings-sort${active && state.sortDirection === "asc" ? " ascending" : ""}`}
                      data-portfolio-sort={key}
                      aria-label={profitSortHint}
                      title={profitSortHint}
                      onClick={() => handleSort(key)}
                    >
                      {label}
                      {active ? <img src={`data:image/svg+xml;utf8,${encodeURIComponent(ICON_SORT)}`} alt="" /> : null}
                    </button>
                  </th>
                );
              })}
            </tr>
          </thead>
          <tbody>
            {sortedRows.length === 0 && (
              <tr className="catfolio-holdings-message"><td>{t("empty")}</td></tr>
            )}
            {sortedRows.map((row) => {
              if (state.mode === "direct") {
                const profit = numeric(row.unrealized_usd);
                const tone = profit >= 0 ? "positive" : "negative";
                const today = numeric(row.today_change_percent);
                return (
                  <tr
                    key={String(row.ticker)}
                    onPointerEnter={(event) => onRowHover(row, event)}
                    onPointerLeave={hidePopover}
                  >
                    {assetCells(row)}
                    <td>{nativePriceCell(row)}</td>
                    <td className={tone}>{signedPercent(today)}</td>
                    {profitCell(row)}
                    <td>
                      <span className="catfolio-holding-market">
                        <b>{preciseMoney(row.market_value_usd)}</b>
                        <span>{ratioPercent(row.weight)}</span>
                      </span>
                    </td>
                    <td>{rangeMarkup(row)}</td>
                  </tr>
                );
              }
              const directRow = matchingDirectHolding(row);
              const totalUsd = numeric(row.total_usd);
              const position = state.total ? totalUsd / state.total : 0;
              return (
                <tr
                  key={String(row.ticker)}
                  onPointerEnter={(event) => onRowHover(row, event)}
                  onPointerLeave={hidePopover}
                >
                  {assetCells(directRow ? { ...row, company_name: directRow.company_name, logo_symbol: directRow.logo_symbol } : row, directRow?.shares)}
                  <td>{directRow ? nativePriceCell(directRow) : <span className="muted">—</span>}</td>
                  <td className={directRow ? (numeric(directRow.today_change_percent) >= 0 ? "positive" : "negative") : "muted"}>
                    {directRow ? signedPercent(numeric(directRow.today_change_percent)) : "—"}
                  </td>
                  {profitCell(row, directRow)}
                  <td>
                    <span className="catfolio-holding-market">
                      <b>{preciseMoney(totalUsd)}</b>
                      <span>{ratioPercent(position)}</span>
                    </span>
                  </td>
                  <td>{directRow ? rangeMarkup(directRow) : <span className="muted">—</span>}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {popover && (
        <VolumeProfilePopover
          x={popover.x}
          y={popover.y}
          row={popover.row}
          profile={activeProfile}
        />
      )}
    </section>
  );
}

function VolumeProfilePopover({ x, y, row, profile }: { x: number; y: number; row: Row; profile?: Row }) {
  const ref = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState({ left: 0, top: 0 });

  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const gap = 12;
    const edge = 8;
    const rect = node.getBoundingClientRect();
    let left = x + gap;
    let top = y + gap;
    if (left + rect.width > window.innerWidth - edge) left = x - rect.width - gap;
    if (top + rect.height > window.innerHeight - edge) top = y - rect.height - gap;
    setPosition({ left: Math.max(edge, left), top: Math.max(edge, top) });
  }, [x, y, profile]);

  const available = Boolean(profile?.available);
  const currency = String(profile?.currency || row.quote_currency || row.cost_currency || "USD");
  const numericCost = row.avg_cost_native ?? row.avg_cost_usd;
  const entries = [
    { key: "vah", label: t("profileVah"), value: available ? Number(profile?.vah) : null, currency, rank: 0 },
    { key: "poc", label: t("profilePoc"), value: available ? Number(profile?.poc) : null, currency, rank: 1 },
    { key: "cost", label: t("profileCost"), value: Number.isFinite(Number(numericCost)) ? Number(numericCost) : null, currency: String(row.cost_currency || currency), rank: 2 },
    { key: "val", label: t("profileVal"), value: available ? Number(profile?.val) : null, currency, rank: 3 },
  ];
  if (available) {
    entries.sort((a, b) => {
      if (a.value === null) return 1;
      if (b.value === null) return -1;
      return (b.value as number) - (a.value as number) || a.rank - b.rank;
    });
  }
  const vah = Number(profile?.vah);
  const val = Number(profile?.val);
  const costPrice = Number(numericCost);
  const marker = (value: number, tone: string) => {
    if (![vah, val, value].every(Number.isFinite) || vah <= val) return "";
    const positionPct = Math.max(4.5, Math.min(95.5, ((vah - value) / (vah - val)) * 100));
    return <i className={`catfolio-vp-marker is-${tone}`} style={{ "--profile-marker-position": `${positionPct.toFixed(2)}%` } as React.CSSProperties} />;
  };

  return (
    <div ref={ref} className="catfolio-vp-popover" role="tooltip" style={{ left: position.left, top: position.top }} title={available ? "" : t("profileUnavailable")}>
      <strong className="catfolio-vp-title">{t("profileTitle")}</strong>
      <span className="catfolio-vp-body">
        <span className="catfolio-vp-rail" aria-hidden="true">
          {available ? marker(costPrice, "cost") : null}
          {available ? marker(Number(profile?.poc), "poc") : null}
        </span>
        <span className="catfolio-vp-rows">
          {entries.map((entry) => (
            <span key={entry.key} className={`catfolio-vp-row${entry.key === "cost" ? " is-cost" : ""}`}>
              <b>{entry.label}</b>
              <i>{entry.value === null ? "—" : nativePrice(entry.value, entry.currency, 2)}</i>
            </span>
          ))}
        </span>
      </span>
    </div>
  );
}

// ── main view ───────────────────────────────────────────────────────────────

export function PortfolioView() {
  const [overview, setOverview] = useState<Row | null>(null);
  const [chartPayload, setChartPayload] = useState<Row | null>(null);
  const [calendarData, setCalendarData] = useState<Row | null>(null);
  const [holdingsDirect, setHoldingsDirect] = useState<Row[]>([]);
  const [holdingsTotal, setHoldingsTotal] = useState(0);
  const [lookthroughRows, setLookthroughRows] = useState<Row[]>([]);
  const [etfTotal, setEtfTotal] = useState(0);
  const [error, setError] = useState("");
  const [range, setRange] = useState("3m");
  const [source, setSource] = useState<Row | null>(null);
  const [syncing, setSyncing] = useState(false);
  const [syncMessage, setSyncMessage] = useState("");
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    fetch("/catfolio/api/source", { headers: { Accept: "application/json" } })
      .then((response) => (response.ok ? response.json() : null))
      .then((data) => data && setSource(data as Row))
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    let cancelled = false;
    Promise.all([
      fetch("/catfolio/api/portfolio/overview", { headers: { Accept: "application/json" } }),
      fetch("/catfolio/api/portfolio/chart", { cache: "no-store" }),
    ])
      .then(async ([overviewResponse, chartResponse]) => {
        if (!overviewResponse.ok || !chartResponse.ok) throw new Error(`HTTP ${overviewResponse.status}/${chartResponse.status}`);
        const [overviewJson, chartJson] = await Promise.all([overviewResponse.json(), chartResponse.json()]);
        if (cancelled) return;
        setOverview(overviewJson);
        setChartPayload(chartJson);
      })
      .catch((err) => { if (!cancelled) setError(String(err.message)); });
    return () => { cancelled = true; };
  }, [reloadKey]);

  useEffect(() => {
    let cancelled = false;
    fetch("/catfolio/api/profit-calendar", { headers: { Accept: "application/json" } })
      .then((response) => (response.ok ? response.json() : Promise.reject(new Error(`HTTP ${response.status}`))))
      .then((data) => { if (!cancelled) setCalendarData(data); })
      .catch(() => undefined);
    return () => { cancelled = true; };
  }, [reloadKey]);

  useEffect(() => {
    let cancelled = false;
    Promise.all([
      fetch("/catfolio/api/holdings/detail", { headers: { Accept: "application/json" } }),
      fetch("/catfolio/api/etf-lookthrough?basis=market", { headers: { Accept: "application/json" } }),
    ])
      .then(async ([directResponse, lookResponse]) => {
        if (!directResponse.ok || !lookResponse.ok) throw new Error(`HTTP ${directResponse.status}/${lookResponse.status}`);
        const [directJson, lookJson] = await Promise.all([directResponse.json(), lookResponse.json()]);
        if (cancelled) return;
        setHoldingsDirect((directJson.rows ?? []) as Row[]);
        setHoldingsTotal(numeric((directJson.summary as Row)?.market_value_usd));
        setLookthroughRows((lookJson.rows ?? []) as Row[]);
        setEtfTotal(numeric(lookJson.etf_total_usd));
      })
      .catch(() => undefined);
    return () => { cancelled = true; };
  }, [reloadKey]);

  const runSync = async () => {
    setSyncing(true);
    setSyncMessage("正在同步 Trading 212…");
    try {
      const response = await fetch("/catfolio/api/refresh/trading212", { method: "POST" });
      const result = (await response.json()) as Row;
      if (!response.ok || !result.ok) {
        setSyncMessage(String(result.error || result.message || `HTTP ${response.status}`));
        return;
      }
      const reloaded = (result.reloaded ?? {}) as Row;
      setSyncMessage(
        `同步完成：${String(reloaded.source ?? "")} · ${Number(reloaded.holdings ?? 0)} 个持仓`,
      );
      setReloadKey((key) => key + 1);
    } catch (err) {
      setSyncMessage(`同步失败：${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setSyncing(false);
    }
  };

  const metrics = overview ? renderOverview(overview) : null;
  const valueRows = chartPayload ? normalizeValueRows(chartPayload) : [];

  return (
    <main className="catfolio-view">
      <header className="catfolio-page-head">
        <h1>Catfolio</h1>
        <div style={{ display: "flex", alignItems: "center", gap: "12px", minWidth: 0 }}>
          {source && (
            <span className="catfolio-status" title={String(source.live_dir ?? "")}>
              {source.source === "live" ? `真实数据 · ${Number(source.holdings ?? 0)} 持仓` : "演示数据"}
            </span>
          )}
          <button
            className="catfolio-ai-button"
            type="button"
            disabled={syncing}
            onClick={runSync}
            title="从 Trading 212 同步持仓与账户现金"
          >
            <span>{syncing ? "同步中…" : "同步 212"}</span>
          </button>
        </div>
      </header>
      {syncMessage && (
        <div className="catfolio-analytics-status is-visible" aria-live="polite">{syncMessage}</div>
      )}
      <span className="catfolio-status" role="status" aria-live="polite">
        {error ? `${t("failed")}: ${error}` : overview ? t("ready") : t("loading")}
      </span>

      <section className="catfolio-metrics" aria-label="组合核心概览">
        <MetricCard label="总市值" value={metrics?.value ?? "—"} note={metrics?.today ?? "—"} tone={metrics?.todayTone} />
        <MetricCard label="未实现盈亏" value={metrics?.pnl ?? "—"} note={metrics?.pnlRate ?? "—"} tone={metrics?.pnlTone} />
        <MetricCard label="持仓数" value={metrics?.count ?? "—"} note={metrics?.breadth ?? ""} />
        <MetricCard label="前五大仓位" value={metrics?.topFive ?? "—"} note={metrics?.topOne ?? ""} />
      </section>

      <div className="catfolio-insights-row">
        <section className="catfolio-value-card" aria-labelledby="catfolio-cost-value-title">
          <div className="catfolio-chart-head">
            <div>
              <h2 id="catfolio-cost-value-title">{t("market")} vs {t("cost")}</h2>
              <p>当前股票持仓的成本与历史市值（USD，不含账户现金）</p>
            </div>
          </div>
          <CostValueChart rows={valueRows} range={range} onRange={setRange} />
        </section>

        {calendarData ? <ProfitCalendar data={calendarData} /> : (
          <article className="catfolio-calendar-card">
            <div className="catfolio-calendar-body">
              <div className="catfolio-calendar-grid is-loading" role="grid" aria-label="每日投资组合盈亏" />
            </div>
          </article>
        )}
      </div>

      <HoldingsTable
        direct={holdingsDirect}
        lookthrough={lookthroughRows}
        total={holdingsTotal}
        etfTotal={etfTotal}
      />
    </main>
  );
}
