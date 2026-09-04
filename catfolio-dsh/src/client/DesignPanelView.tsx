/**
 * Design panel (设计面板) — port of the Catfolio `/lab/component-demo` page:
 * a four-card carousel showing the product's core components (cost vs market
 * value, profit calendar, drawdown underwater curve, holding details) driven
 * by deterministic fake data. Never calls the live API.
 */
import { useEffect, useRef, useState } from "react";
import * as echarts from "echarts";
import { CostValueChart, ProfitCalendar, HoldingsTable, type Row } from "./PortfolioView.js";
import { ICON_ARROW_LEFT, ICON_ARROW_RIGHT } from "./styles.js";
import { t, currentLang } from "./copy.js";

// ── deterministic fake data (ported from component-demo.js) ─────────────────

const fakeDirectHoldings: Row[] = [
  { ticker: "NVDA", company_name: "NVIDIA", name: "NVIDIA", shares: 84, quote_price: 118.42, avg_cost_native: 91.6, quote_currency: "USD", cost_currency: "USD", today_change_percent: 2.4, unrealized_usd: 2252.88, unrealized_percent: 29.3, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 9957.28, weight: 0.117, low_52w: 75.61, high_52w: 153.13 },
  { ticker: "MSFT", company_name: "Microsoft", name: "Microsoft", shares: 22, quote_price: 418.31, avg_cost_native: 352.24, quote_currency: "USD", cost_currency: "USD", today_change_percent: -0.6, unrealized_usd: 1453.54, unrealized_percent: 18.7, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 9202.82, weight: 0.108, low_52w: 344.77, high_52w: 468.35 },
  { ticker: "AAPL", company_name: "Apple", name: "Apple", shares: 36, quote_price: 211.15, avg_cost_native: 184.5, quote_currency: "USD", cost_currency: "USD", today_change_percent: 1.1, unrealized_usd: 959.4, unrealized_percent: 14.5, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 7601.4, weight: 0.089, low_52w: 164.08, high_52w: 260.1 },
  { ticker: "AMZN", company_name: "Amazon", name: "Amazon", shares: 32, quote_price: 198.77, avg_cost_native: 171.8, quote_currency: "USD", cost_currency: "USD", today_change_percent: 0.8, unrealized_usd: 863.04, unrealized_percent: 15.7, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 6360.64, weight: 0.075, low_52w: 151.61, high_52w: 242.52 },
  { ticker: "VTI", company_name: "Vanguard Total Stock Market ETF", name: "Vanguard Total Stock Market ETF", shares: 28, quote_price: 301.82, avg_cost_native: 267.45, quote_currency: "USD", cost_currency: "USD", today_change_percent: -0.2, unrealized_usd: 962.36, unrealized_percent: 12.9, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 8450.96, weight: 0.099, low_52w: 223.74, high_52w: 302.22 },
  { ticker: "TSLA", company_name: "Tesla", name: "Tesla", shares: 18, quote_price: 286.74, avg_cost_native: 242.15, quote_currency: "USD", cost_currency: "USD", today_change_percent: 3.7, unrealized_usd: 802.62, unrealized_percent: 18.4, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 5161.32, weight: 0.061, low_52w: 182.0, high_52w: 488.54 },
];

const fakeLookthrough: Row[] = [
  { ticker: "NVDA", company_name: "NVIDIA", total_usd: 11830.2 },
  { ticker: "MSFT", company_name: "Microsoft", total_usd: 10480.1 },
  { ticker: "AAPL", company_name: "Apple", total_usd: 9360.4 },
  { ticker: "AMZN", company_name: "Amazon", total_usd: 7520.8 },
  { ticker: "TSLA", company_name: "Tesla", total_usd: 6240.3 },
  { ticker: "META", company_name: "Meta Platforms", total_usd: 4780.6 },
  { ticker: "AVGO", company_name: "Broadcom", total_usd: 4210.7 },
];

const baseDate = new Date(Date.UTC(2026, 3, 30));
const isoDate = (offset: number) => {
  const date = new Date(baseDate);
  date.setUTCDate(date.getUTCDate() + offset);
  return date.toISOString().slice(0, 10);
};

const demoHistory = Array.from({ length: 92 }, (_, index) => {
  const phase = index / 10;
  const cost = 74200 + index * 43 + Math.sin(phase) * 320;
  const market = cost + 3900 + Math.sin(phase * 1.7) * 900 - Math.max(0, Math.sin(phase * 0.72)) * 1050;
  return { date: isoDate(index - 91), market_value_usd: Math.round(market), cost_usd: Math.round(cost) };
});

const demoCalendarRows = Array.from({ length: 30 }, (_, index) => {
  const amount = Math.round(Math.sin(index * 1.47) * 280 + Math.cos(index * 0.38) * 75);
  return { date: `2026-04-${String(index + 1).padStart(2, "0")}`, pnl_usd: amount, return: amount / 18000 };
});

const drawdownRows = Array.from({ length: 92 }, (_, index) => ({
  date: isoDate(index - 91),
  drawdown: -Math.max(0, (Math.sin(index / 8) + 0.33 * Math.sin(index / 2.7) - 0.18) * 0.31),
}));

const fakeCalendarData: Row = {
  profit_calendar: {
    rows: demoCalendarRows,
    income: {
      monthly_rows: [{ month: "2026-04", dividends_usd: 342.5, cash_interest_usd: 46.2 }],
      rows: [{ year: 2026, dividends_usd: 342.5, cash_interest_usd: 46.2 }],
    },
  },
};

// ── drawdown card (same rendering as the analytics page, fake data) ─────────

function DrawdownCard() {
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<echarts.ECharts | null>(null);
  const [range, setRange] = useState("MAX");

  useEffect(() => {
    const node = containerRef.current;
    if (!node) return;
    const chart = echarts.init(node);
    chartRef.current = chart;
    const observer = new ResizeObserver(() => chart.resize());
    observer.observe(node);
    return () => {
      observer.disconnect();
      chart.dispose();
      chartRef.current = null;
    };
  }, []);

  useEffect(() => {
    const chart = chartRef.current;
    const root = containerRef.current?.closest(".catfolio-view") as HTMLElement | null;
    if (!chart || !root) return;
    const style = getComputedStyle(root);
    const colors = {
      muted: style.getPropertyValue("--muted").trim() || "rgba(9,15,5,.6)",
      line: style.getPropertyValue("--line-strong").trim() || "rgba(9,15,5,.2)",
      panel: style.getPropertyValue("--panel").trim() || "#fff",
      ink: style.getPropertyValue("--ink").trim() || "#090f05",
    };
    const endDate = new Date(`${drawdownRows[drawdownRows.length - 1].date}T12:00:00`);
    const dayWindows: Record<string, number> = { "1D": 1, "1W": 7, "1M": 31, "3M": 93, "1Y": 366 };
    let rows = drawdownRows;
    if (range === "YTD") {
      rows = drawdownRows.filter((row) => String(row.date).slice(0, 4) === String(endDate.getFullYear()));
    } else if (dayWindows[range]) {
      const startDate = new Date(endDate);
      startDate.setDate(startDate.getDate() - dayWindows[range]);
      rows = drawdownRows.filter((row) => new Date(`${row.date}T12:00:00`) >= startDate);
    }
    if (rows.length < 2) rows = drawdownRows.slice(-2);
    const values = rows.map((row) => Number(row.drawdown) * 100);
    const minimum = Math.min(...values);
    const axisMinimum = Math.min(-10, Math.floor(minimum / 10) * 10);
    const meta = document.getElementById("catfolio-demo-drawdown-meta");
    if (meta) {
      const maxDd = Math.min(...drawdownRows.map((row) => Number(row.drawdown)));
      meta.textContent = `${"最大回撤"} ${maxDd >= 0 ? "+" : ""}${(maxDd * 100).toFixed(1)}%`;
    }
    chart.setOption(
      {
        animationDuration: 180,
        grid: { left: 54, right: 0, top: 12, bottom: 8 },
        xAxis: {
          type: "category",
          data: rows.map((row) => row.date),
          boundaryGap: false,
          axisLine: { show: false },
          axisTick: { show: false },
          axisLabel: { show: false },
          splitLine: { show: false },
          axisPointer: { show: true, type: "line", lineStyle: { color: "#eaebed", width: 1 }, label: { show: false } },
        },
        yAxis: {
          type: "value",
          min: axisMinimum,
          max: 0,
          interval: 10,
          axisLine: { show: false },
          axisTick: { show: false },
          axisLabel: { color: "rgba(9,15,5,.6)", fontSize: 12, fontWeight: 700, margin: 18, formatter: (value: number) => `${value.toFixed(0)}%` },
          splitLine: { lineStyle: { color: "#eaebed", width: 1, opacity: 1 } },
        },
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
          formatter: (params: { axisValue: string; value: number }[]) => {
            const point = params[0];
            const date = new Date(`${point.axisValue}T12:00:00`);
            const dateLabel = date.toLocaleDateString(currentLang() === "en" ? "en-GB" : "zh-CN", {
              day: "2-digit", month: "short", year: "2-digit",
            }).toUpperCase();
            return `<span style="display:inline-flex;padding:4px 8px;border-radius:10px;color:#fff;background:#000;font-size:10px;font-weight:600">${dateLabel}</span><span style="display:inline-flex;padding:4px 8px;border-radius:10px;color:#fff;background:#e40014;font-size:10px;font-weight:600;margin-top:6px">${Number(point.value).toFixed(1)}%</span>`;
          },
        },
      },
      true,
    );
  }, [range]);

  return (
    <article className="catfolio-analytics-drawdown-card" aria-labelledby="catfolio-demo-drawdown-title">
      <header>
        <div>
          <h2 id="catfolio-demo-drawdown-title">回撤水下曲线</h2>
          <p id="catfolio-demo-drawdown-meta">{"最大回撤"}</p>
        </div>
      </header>
      <div className="catfolio-analytics-drawdown-body">
        <div ref={containerRef} className="catfolio-analytics-chart" role="img" aria-label="回撤水下曲线" />
        <div className="catfolio-analytics-drawdown-ranges" role="group" aria-label="回撤图表时间范围">
          {["1D", "1W", "1M", "3M", "YTD", "1Y", "MAX"].map((key) => (
            <button
              key={key}
              type="button"
              className={range === key ? "active" : ""}
              aria-pressed={range === key}
              onClick={() => setRange(key)}
            >
              {key}
            </button>
          ))}
        </div>
      </div>
    </article>
  );
}

// ── carousel shell ──────────────────────────────────────────────────────────

const SLIDES = [
  { label: "成本与市值对比" },
  { label: "收益日历" },
  { label: "回撤水下曲线" },
  { label: "持仓明细" },
];

export function DesignPanelView() {
  const [current, setCurrent] = useState(0);
  const stageRef = useRef<HTMLElement>(null);

  const showSlide = (next: number, direction: number) => {
    const target = (next + SLIDES.length) % SLIDES.length;
    setCurrent(target);
    requestAnimationFrame(() => window.dispatchEvent(new Event("resize")));
  };

  const go = (next: number, direction = next >= current ? 1 : -1) => showSlide(next, direction);

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.target instanceof Element && event.target.closest("input, textarea, select, [contenteditable='true']")) return;
      if (event.key === "ArrowLeft") { event.preventDefault(); go(current - 1, -1); }
      if (event.key === "ArrowRight") { event.preventDefault(); go(current + 1, 1); }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [current]);

  const isActive = (index: number) => index === current;
  const isBefore = (index: number) => !isActive(index) && index < current;
  const isAfter = (index: number) => !isActive(index) && !isBefore(index);

  return (
    <main className="catfolio-view">
      <div className="catfolio-demo-workspace" id="componentDemo">
        <section
          ref={stageRef}
          className="catfolio-demo-stage"
          aria-roledescription="carousel"
          aria-label="投资组合组件演示"
          tabIndex={0}
        >
          <button className="catfolio-demo-arrow catfolio-demo-arrow-prev" id="componentDemoPrev" type="button" aria-label="上一个组件" onClick={() => go(current - 1, -1)}>
            <img src={`data:image/svg+xml;utf8,${encodeURIComponent(ICON_ARROW_LEFT)}`} alt="" />
          </button>

          <div className="catfolio-demo-viewport" id="componentDemoViewport">
            <div className="catfolio-demo-track">
              <article
                className={`catfolio-demo-slide${isActive(0) ? " is-active" : ""}${isBefore(0) ? " is-before" : ""}${isAfter(0) ? " is-after" : ""}`}
                data-demo-slide="0"
                aria-hidden={!isActive(0)}
                inert={!isActive(0)}
              >
                <CostValueChart rows={demoHistory} range="3m" onRange={() => undefined} />
              </article>

              <article
                className={`catfolio-demo-slide${isActive(1) ? " is-active" : ""}${isBefore(1) ? " is-before" : ""}${isAfter(1) ? " is-after" : ""}`}
                data-demo-slide="1"
                aria-hidden={!isActive(1)}
                inert={!isActive(1)}
              >
                <ProfitCalendar data={fakeCalendarData} />
              </article>

              <article
                className={`catfolio-demo-slide${isActive(2) ? " is-active" : ""}${isBefore(2) ? " is-before" : ""}${isAfter(2) ? " is-after" : ""}`}
                data-demo-slide="2"
                aria-hidden={!isActive(2)}
                inert={!isActive(2)}
              >
                <DrawdownCard />
              </article>

              <article
                className={`catfolio-demo-slide${isActive(3) ? " is-active" : ""}${isBefore(3) ? " is-before" : ""}${isAfter(3) ? " is-after" : ""}`}
                data-demo-slide="3"
                aria-hidden={!isActive(3)}
                inert={!isActive(3)}
              >
                <HoldingsTable
                  direct={fakeDirectHoldings}
                  lookthrough={fakeLookthrough}
                  total={84728.42}
                  etfTotal={44423.1}
                />
              </article>
            </div>
          </div>

          <button className="catfolio-demo-arrow catfolio-demo-arrow-next" id="componentDemoNext" type="button" aria-label="下一个组件" onClick={() => go(current + 1, 1)}>
            <img src={`data:image/svg+xml;utf8,${encodeURIComponent(ICON_ARROW_RIGHT)}`} alt="" />
          </button>
        </section>

        <footer className="catfolio-demo-footer" aria-label="组件切换控制">
          <span className="catfolio-demo-position" id="componentDemoPosition" aria-live="polite">
            {String(current + 1).padStart(2, "0")} / {String(SLIDES.length).padStart(2, "0")}
          </span>
          <div className="catfolio-demo-dots" id="componentDemoDots" role="tablist" aria-label="选择组件">
            {SLIDES.map((slide, index) => (
              <button
                key={slide.label}
                type="button"
                role="tab"
                className={isActive(index) ? "active" : ""}
                data-demo-go={index}
                aria-label={slide.label}
                aria-selected={isActive(index)}
                onClick={() => go(index, index >= current ? 1 : -1)}
              />
            ))}
          </div>
          <span aria-hidden="true"></span>
        </footer>
      </div>
    </main>
  );
}
