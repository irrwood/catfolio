/**
 * Analytics view — port of the Catfolio `/analytics` page: monthly return
 * heatmap, drawdown curve, correlation matrix, return distribution, model
 * attribution waterfall, and the valuation matrix + detail table.
 */
import { useEffect, useRef, useState } from "react";
import * as echarts from "echarts";
import { t, numeric, escapeHtml, currentLang, localeString } from "./copy.js";

type Row = Record<string, unknown>;

const COPY = {
  zh: {
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
    valuationLoading: "正在加载估值数据…",
    valuationLoadError: "估值数据加载失败。",
    valuationEmpty: "暂无可用估值数据，请先刷新 fundamentals。",
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
  },
  en: {
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
    valuationLoading: "Loading valuation data…",
    valuationLoadError: "Could not load valuation data.",
    valuationEmpty: "No valuation data is available. Refresh fundamentals first.",
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
  },
} as const;

const copy = () => (currentLang() === "en" ? COPY.en : COPY.zh);

function palette(root: HTMLElement | null) {
  const style = root ? getComputedStyle(root) : null;
  const v = (name: string, fallback: string) => style?.getPropertyValue(name).trim() || fallback;
  return {
    ink: v("--ink", "#090f05"),
    muted: v("--muted", "rgba(9,15,5,.6)"),
    line: v("--line-strong", "rgba(9,15,5,.2)"),
    panel: v("--panel", "#ffffff"),
    soft: v("--soft", "#f0f1f3"),
    hover: v("--panel-hover", "#f4f5f7"),
    primary: v("--primary-strong", "#257a33"),
    positive: v("--positive", "#2f8a3e"),
    negative: v("--negative", "#e40014"),
    indigo: "#6068e8",
  };
}

function formatPct(value: unknown, digits = 1): string {
  const number = Number(value || 0) * 100;
  return `${number >= 0 ? "+" : ""}${number.toFixed(digits)}%`;
}

function finiteNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function formatMultiple(value: unknown): string {
  const number = finiteNumber(value);
  return number !== null && number > 0 ? `${number.toFixed(1)}×` : "—";
}

function growthPercent(value: unknown): number | null {
  const number = finiteNumber(value);
  if (number === null) return null;
  return Math.abs(number) <= 2 ? number * 100 : number;
}

function formatGrowth(value: unknown): string {
  const number = growthPercent(value);
  return number === null ? "—" : `${number >= 0 ? "+" : ""}${number.toFixed(1)}%`;
}

function median(values: number[]): number | null {
  const numbers = values.map(Number).filter(Number.isFinite).sort((a, b) => a - b);
  if (!numbers.length) return null;
  const middle = Math.floor(numbers.length / 2);
  return numbers.length % 2 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2;
}

function prepareValuationRows(payload: Row): Row[] {
  const c = copy();
  const raw = ((payload.rows ?? []) as Row[]).map((row) => {
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
      growthSource: epsGrowth !== null ? c.epsGrowth : c.revenueGrowth,
      weight: Number(row.weight || 0),
    };
  }).filter((row) => row.pe || row.priceToSales || row.priceToBook || row.growth !== null);

  const peRows = raw.filter((row) => row.pe);
  const portfolioMedian = median(peRows.map((row) => Number(row.pe)));
  const bySector = new Map<string, number[]>();
  peRows.forEach((row) => {
    const sector = String(row.sector || "Other");
    if (!bySector.has(sector)) bySector.set(sector, []);
    bySector.get(sector)!.push(Number(row.pe));
  });
  return raw
    .map((row) => {
      if (!row.pe || !portfolioMedian) return { ...row, benchmark: null, premium: null };
      const sectorRows = bySector.get(String(row.sector || "Other")) || [];
      const benchmark = sectorRows.length >= 3 ? median(sectorRows) : portfolioMedian;
      return { ...row, benchmark, premium: benchmark ? Number(row.pe) / Number(benchmark) - 1 : null };
    })
    .sort((a, b) => Number(b.weight) - Number(a.weight));
}

function useChart(id: string, heightClass?: string) {
  const ref = useRef<HTMLDivElement>(null);
  const chartRef = useRef<echarts.ECharts | null>(null);

  useEffect(() => {
    const node = ref.current;
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

  return { ref, chartRef };
}

function baseOption(root: HTMLElement | null) {
  const colors = palette(root);
  return {
    animationDuration: 260,
    animationEasing: "cubicOut" as const,
    textStyle: { color: colors.ink },
    tooltip: {
      confine: true,
      backgroundColor: colors.panel,
      borderColor: colors.line,
      borderWidth: 1,
      textStyle: { color: colors.ink, fontSize: 12 },
      extraCssText: "border-radius:12px;box-shadow:0 6px 18px rgba(15,23,42,.06);",
    },
  };
}

function categoryAxis(colors: ReturnType<typeof palette>, extra: Record<string, unknown> = {}) {
  return {
    type: "category",
    axisLine: { lineStyle: { color: colors.line } },
    axisTick: { show: false },
    axisLabel: { color: colors.muted, fontSize: 11 },
    ...extra,
  };
}

function valueAxis(colors: ReturnType<typeof palette>, extra: Record<string, unknown> = {}) {
  return {
    type: "value",
    axisLine: { show: false },
    axisTick: { show: false },
    axisLabel: { color: colors.muted, fontSize: 11 },
    splitLine: { lineStyle: { color: colors.line, opacity: 0.55 } },
    ...extra,
  };
}

export function AnalyticsView() {
  const rootRef = useRef<HTMLElement>(null);
  const [data, setData] = useState<Row | null>(null);
  const [valuation, setValuation] = useState<Row | null>(null);
  const [status, setStatus] = useState("");
  const [drawdownRange, setDrawdownRange] = useState("MAX");
  const [tableExpanded, setTableExpanded] = useState(false);
  const monthly = useChart("monthly");
  const drawdown = useChart("drawdown");
  const correlation = useChart("corr");
  const distribution = useChart("dist");
  const waterfall = useChart("waterfall");
  const valuationChart = useChart("val");

  const load = async () => {
    const c = copy();
    setStatus(c.loading);
    try {
      const [analyticsResult, valuationResult] = await Promise.allSettled([
        fetch("/catfolio/api/analytics", { headers: { Accept: "application/json" } }).then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`)))),
        fetch("/catfolio/api/holdings/heatmap", { headers: { Accept: "application/json" } }).then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`)))),
      ]);
      if (analyticsResult.status === "rejected") throw analyticsResult.reason;
      setData(analyticsResult.value as Row);
      if (valuationResult.status === "fulfilled") {
        setValuation(valuationResult.value as Row);
        setStatus("");
      } else {
        setValuation({ rows: [] });
        setStatus(`${c.valuationLoadError} ${String((valuationResult.reason as Error)?.message || "")}`);
      }
    } catch (error) {
      setStatus(`${c.loadError} ${error instanceof Error ? error.message : String(error)}`);
    }
  };

  useEffect(() => {
    load();
  }, []);

  // ── monthly return heatmap ──
  useEffect(() => {
    const chart = monthly.chartRef.current;
    const root = rootRef.current;
    if (!chart || !root || !data) return;
    const rows = ((data.monthly_returns as Row)?.rows ?? []) as Row[];
    if (!rows.length) return;
    const colors = palette(root);
    const c = copy();
    const years = [...new Set(rows.map((row) => String(row.month).slice(0, 4)))].sort();
    const values = rows.map((row) => [
      Number(String(row.month).slice(5, 7)) - 1,
      years.indexOf(String(row.month).slice(0, 4)),
      Number(row.return || 0) * 100,
    ]);
    const maxAbs = Math.max(1, ...values.map((row) => Math.abs(row[2])));
    chart.setOption(
      {
        ...baseOption(root),
        grid: { left: 54, right: 22, top: 18, bottom: 68 },
        xAxis: categoryAxis(colors, { data: c.months, splitArea: { show: true, areaStyle: { color: ["transparent"] } } }),
        yAxis: categoryAxis(colors, { data: years, splitArea: { show: true, areaStyle: { color: ["transparent"] } } }),
        visualMap: {
          min: -maxAbs,
          max: maxAbs,
          orient: "horizontal",
          left: "center",
          bottom: 8,
          calculable: false,
          textStyle: { color: colors.muted, fontSize: 10 },
          formatter: (value: number) => `${value >= 0 ? "+" : ""}${Number(value).toFixed(1)}%`,
          inRange: { color: [colors.negative, colors.soft, colors.primary] },
        },
        series: [{
          type: "heatmap",
          data: values,
          itemStyle: { borderColor: colors.panel, borderWidth: 4, borderRadius: 7 },
          label: { show: true, color: colors.ink, fontSize: 10, formatter: (params: { value: number[] }) => `${params.value[2] >= 0 ? "+" : ""}${params.value[2].toFixed(1)}%` },
          emphasis: { itemStyle: { borderColor: colors.ink, borderWidth: 1 } },
        }],
        tooltip: {
          ...baseOption(root).tooltip,
          formatter: (params: { value: number[] }) =>
            `${years[params.value[1]]} ${c.months[params.value[0]]}<br><b>${params.value[2] >= 0 ? "+" : ""}${params.value[2].toFixed(2)}%</b>`,
        },
      },
      true,
    );
  }, [data, monthly.chartRef]);

  // ── drawdown curve ──
  useEffect(() => {
    const chart = drawdown.chartRef.current;
    const root = rootRef.current;
    if (!chart || !root || !data) return;
    const allRows = ((data.drawdown as Row)?.rows ?? []) as Row[];
    if (!allRows.length) return;
    const colors = palette(root);
    const endDate = new Date(`${String(allRows[allRows.length - 1].date)}T12:00:00`);
    const dayWindows: Record<string, number> = { "1D": 1, "1W": 7, "1M": 31, "3M": 93, "1Y": 366 };
    let rows = allRows;
    if (drawdownRange === "YTD") {
      rows = allRows.filter((row) => String(row.date).slice(0, 4) === String(endDate.getFullYear()));
    } else if (dayWindows[drawdownRange]) {
      const startDate = new Date(endDate);
      startDate.setDate(startDate.getDate() - dayWindows[drawdownRange]);
      rows = allRows.filter((row) => new Date(`${String(row.date)}T12:00:00`) >= startDate);
    }
    if (rows.length < 2) rows = allRows.slice(-2);
    const values = rows.map((row) => Number(row.drawdown || 0) * 100);
    const minimum = Math.min(...values);
    const axisMinimum = Math.min(-10, Math.floor(minimum / 10) * 10);
    const maxDrawdown = Number((data.drawdown as Row)?.max_drawdown);
    const meta = document.getElementById("catfolio-drawdown-meta");
    if (meta) meta.textContent = `${copy().maxDrawdown} ${formatPct(maxDrawdown)}`;
    chart.setOption(
      {
        ...baseOption(root),
        animationDuration: 180,
        grid: { left: 54, right: 0, top: 12, bottom: 8 },
        xAxis: categoryAxis(colors, {
          data: rows.map((row) => row.date),
          boundaryGap: false,
          axisLine: { show: false },
          axisLabel: { show: false },
          splitLine: { show: false },
          axisPointer: { show: true, type: "line", lineStyle: { color: "#eaebed", width: 1 }, label: { show: false } },
        }),
        yAxis: valueAxis(colors, {
          min: axisMinimum,
          max: 0,
          interval: 10,
          axisLabel: { color: "rgba(9,15,5,.6)", fontSize: 12, fontWeight: 700, margin: 18, formatter: (value: number) => `${value.toFixed(0)}%` },
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
          formatter: (params: { axisValue: string; value: number }[]) => {
            const point = params[0];
            const date = new Date(`${point.axisValue}T12:00:00`);
            const dateLabel = date.toLocaleDateString(currentLang() === "en" ? "en-GB" : "zh-CN", {
              day: "2-digit", month: "short", year: "2-digit",
            }).toUpperCase();
            return `<span style="display:inline-flex;padding:4px 8px;border-radius:10px;color:#fff;background:#000;font-size:10px;font-weight:600">${escapeHtml(dateLabel)}</span><span style="display:inline-flex;padding:4px 8px;border-radius:10px;color:#fff;background:#e40014;font-size:10px;font-weight:600;margin-top:6px">${Number(point.value).toFixed(1)}%</span>`;
          },
        },
      },
      true,
    );
  }, [data, drawdownRange, drawdown.chartRef]);

  // ── correlation matrix ──
  useEffect(() => {
    const chart = correlation.chartRef.current;
    const root = rootRef.current;
    if (!chart || !root || !data) return;
    const corr = (data.correlation_matrix ?? {}) as Row;
    const symbols = (corr.symbols ?? []) as string[];
    const matrix = (corr.matrix ?? []) as number[][];
    if (!symbols.length || !matrix.length) return;
    const colors = palette(root);
    const values = matrix.flatMap((row, y) => row.map((value, x) => [x, y, Number(value)]));
    const shortened = (value: string) => (value.length > 11 ? `${value.slice(0, 10)}…` : value);
    chart.setOption(
      {
        ...baseOption(root),
        grid: { left: 106, right: 30, top: 24, bottom: 104 },
        xAxis: categoryAxis(colors, { data: symbols, axisLabel: { color: colors.muted, rotate: 38, fontSize: 10, formatter: shortened } }),
        yAxis: categoryAxis(colors, { data: symbols, axisLabel: { color: colors.muted, fontSize: 10, formatter: shortened } }),
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
          label: { show: symbols.length <= 10, color: colors.ink, fontSize: 9, formatter: (params: { value: number[] }) => params.value[2].toFixed(2) },
          emphasis: { itemStyle: { borderColor: colors.ink, borderWidth: 1 } },
        }],
        tooltip: {
          ...baseOption(root).tooltip,
          formatter: (params: { value: number[] }) => `${symbols[params.value[1]]}<br>${symbols[params.value[0]]}<br>${copy().correlation} <b>${params.value[2].toFixed(2)}</b>`,
        },
      },
      true,
    );
  }, [data, correlation.chartRef]);

  // ── return distribution ──
  useEffect(() => {
    const chart = distribution.chartRef.current;
    const root = rootRef.current;
    if (!chart || !root || !data) return;
    const distributionData = (data.return_distribution ?? {}) as Row;
    const bins = (distributionData.bins ?? []) as Row[];
    if (!bins.length) return;
    const colors = palette(root);
    const stats = (distributionData.stats ?? {}) as Row;
    const meta = document.getElementById("catfolio-distribution-meta");
    if (meta) {
      meta.textContent = `${Number(stats.sample_days || 0)} ${copy().days} · ${Number(stats.negative_days || 0)} ${copy().downDays} · ${copy().dailyAverage} ${formatPct(stats.mean, 2)}`;
    }
    chart.setOption(
      {
        ...baseOption(root),
        grid: { left: 48, right: 18, top: 18, bottom: 50 },
        xAxis: categoryAxis(colors, { data: bins.map((row) => `${(Number(row.mid) * 100).toFixed(1)}%`), axisLabel: { color: colors.muted, hideOverlap: true, rotate: 35, fontSize: 9 } }),
        yAxis: valueAxis(colors, { minInterval: 1 }),
        series: [{
          type: "bar",
          barMaxWidth: 28,
          data: bins.map((row) => ({ value: row.count, itemStyle: { color: Number(row.mid) >= 0 ? colors.positive : colors.negative, opacity: 0.82, borderRadius: [5, 5, 2, 2] } })),
        }],
        tooltip: { ...baseOption(root).tooltip, trigger: "axis", formatter: (params: { name: string; value: number }[]) => `${params[0].name}<br><b>${params[0].value}</b> ${copy().days}` },
      },
      true,
    );
  }, [data, distribution.chartRef]);

  // ── waterfall ──
  useEffect(() => {
    const chart = waterfall.chartRef.current;
    const root = rootRef.current;
    if (!chart || !root || !data) return;
    const waterfallData = (data.waterfall ?? {}) as Row;
    const rows = ((waterfallData.rows ?? []) as Row[]).filter((row) => Number.isFinite(Number(row.contribution)));
    if (!rows.length) return;
    const colors = palette(root);
    let running = 0;
    const helper: number[] = [];
    const changes: { value: number; raw: number; itemStyle: { color: string; borderRadius: number } }[] = [];
    const cumulative = [0];
    rows.forEach((row) => {
      const contribution = Number(row.contribution);
      const next = running + contribution;
      helper.push(Math.min(running, next) * 100);
      changes.push({ value: Math.abs(contribution * 100), raw: contribution, itemStyle: { color: contribution >= 0 ? colors.positive : colors.negative, borderRadius: 4 } });
      running = next;
      cumulative.push(running * 100);
    });
    const yMin = Math.min(0, ...cumulative);
    const yMax = Math.max(0, ...cumulative);
    const meta = document.getElementById("catfolio-waterfall-meta");
    if (meta) meta.textContent = `${copy().monthContribution} · ${String(waterfallData.month || "")} · ${formatPct(running)}`;
    chart.setOption(
      {
        ...baseOption(root),
        grid: { left: 54, right: 18, top: 18, bottom: 64 },
        xAxis: categoryAxis(colors, { data: rows.map((row) => row.symbol), axisLabel: { color: colors.muted, rotate: 34, fontSize: 9 } }),
        yAxis: valueAxis(colors, {
          min: Math.floor(yMin * 10) / 10,
          max: Math.ceil((yMax || 1) * 11) / 10,
          axisLabel: { color: colors.muted, formatter: (value: number) => `${value.toFixed(1)}%` },
        }),
        series: [
          { type: "bar", stack: "waterfall", silent: true, data: helper, itemStyle: { color: "transparent" }, emphasis: { disabled: true } },
          { type: "bar", stack: "waterfall", barMaxWidth: 24, data: changes },
        ],
        tooltip: {
          ...baseOption(root).tooltip,
          trigger: "axis",
          formatter: (params: { name: string; seriesIndex: number; data: { raw: number } }[]) => {
            const point = params.find((item) => item.seriesIndex === 1);
            return point ? `${point.name}<br><b>${formatPct(point.data.raw, 2)}</b>` : "";
          },
        },
      },
      true,
    );
  }, [data, waterfall.chartRef]);

  // ── valuation matrix + table ──
  const valuationRows = valuation ? prepareValuationRows(valuation) : [];
  useEffect(() => {
    const chart = valuationChart.chartRef.current;
    const root = rootRef.current;
    if (!chart || !root) return;
    const colors = palette(root);
    chart.clear();
    const chartRows = valuationRows.filter((row) => row.pe && row.growth !== null);
    if (!chartRows.length) {
      chart.setOption({
        ...baseOption(root),
        title: { text: copy().valuationEmpty, left: "center", top: "middle", textStyle: { color: colors.muted, fontSize: 13, fontWeight: 500 } },
      });
      return;
    }
    const sectorPalette = ["#89d663", "#f36d0d", "#708cff", "#2f8a3e", "#d49b27", "#7d68d8", "#1a9aa8"];
    const sectorColor = new Map<string, string>();
    chartRows.forEach((row) => {
      const sector = String(row.sector || "Other");
      if (!sectorColor.has(sector)) sectorColor.set(sector, sectorPalette[sectorColor.size % sectorPalette.length]);
    });
    const peValues = chartRows.map((row) => Number(row.pe));
    const growthValues = chartRows.map((row) => Number(row.growth));
    const xMinimum = Math.min(-10, Math.floor(Math.min(...peValues) / 10) * 10);
    const xMaximum = Math.max(50, Math.ceil(Math.max(...peValues) / 10) * 10);
    const growthSpan = Math.max(20, Math.max(...growthValues) - Math.min(...growthValues));
    const growthPadding = Math.max(10, growthSpan * 0.25);
    const yMinimum = Math.min(-60, Math.floor((Math.min(...growthValues) - growthPadding) / 10) * 10);
    const yMaximum = Math.max(0, Math.ceil((Math.max(...growthValues) + growthPadding) / 10) * 10);
    const xInterval = Math.max(10, Math.ceil(((xMaximum - xMinimum) / 6) / 10) * 10);
    const yInterval = Math.max(10, Math.ceil(((yMaximum - yMinimum) / 6) / 10) * 10);
    const maximumWeight = Math.max(...chartRows.map((row) => Number(row.weight)), 0.0001);
    chart.setOption(
      {
        ...baseOption(root),
        animationDuration: 220,
        grid: { left: 54, right: 18, top: 12, bottom: 39 },
        xAxis: valueAxis(colors, {
          min: xMinimum,
          max: xMaximum,
          interval: xInterval,
          axisLabel: { color: "rgba(9,15,5,.6)", fontSize: 12, fontWeight: 700, margin: 18, formatter: (value: number) => `${Number(value).toFixed(0)}×${Number(value) === xMaximum ? " P/E" : ""}` },
          splitLine: { lineStyle: { color: "#eaebed", width: 1, opacity: 1 } },
        }),
        yAxis: valueAxis(colors, {
          min: yMinimum,
          max: yMaximum,
          interval: yInterval,
          axisLabel: { color: "rgba(9,15,5,.6)", fontSize: 12, fontWeight: 700, margin: 18, formatter: (value: number) => `${Number(value).toFixed(0)}%` },
          splitLine: { lineStyle: { color: "#eaebed", width: 1, opacity: 1 } },
        }),
        series: [{
          type: "scatter",
          clip: false,
          data: chartRows.map((row) => {
            const pointColor = sectorColor.get(String(row.sector || "Other"))!;
            return {
              value: [Number(row.pe), Number(row.growth), Number(row.weight)],
              raw: row,
              itemStyle: { color: pointColor, opacity: 1 },
              label: { color: pointColor },
            };
          }),
          symbolSize: (value: number[]) => Math.max(20, Math.min(118, Math.sqrt(Number(value[2] || 0) / maximumWeight) * 118)),
          label: { show: true, formatter: (params: { data: { raw: Row } }) => String(params.data.raw.ticker), position: "top", distance: 4, fontSize: 11, fontWeight: 700 },
          emphasis: { scale: 1.04 },
        }],
        tooltip: {
          confine: true,
          backgroundColor: "#fff",
          borderColor: "#f1f1f1",
          borderWidth: 1,
          padding: 8,
          textStyle: { color: "#000", fontSize: 10 },
          extraCssText: "border-radius:8px;box-shadow:0 10px 9px rgba(0,0,0,.08);",
          formatter: (params: { data: { raw: Row } }) => {
            const row = params.data.raw;
            return `<div style="display:grid;min-width:108px;gap:4px;color:#000;font:600 10px/14px sans-serif">
              <div style="display:flex;align-items:center;justify-content:space-between;gap:16px;margin-bottom:1px;font-size:12px;line-height:16px;font-weight:800"><span>${escapeHtml(row.ticker)}</span><span>${Number(row.pe).toFixed(1)}×</span></div>
              <div style="display:flex;align-items:center;justify-content:space-between;gap:16px"><span>${escapeHtml(row.growthSource)}</span><span>${Number(row.growth) >= 0 ? "+" : ""}${Number(row.growth).toFixed(1)}%</span></div>
              <div style="display:flex;align-items:center;justify-content:space-between;gap:16px"><span>${escapeHtml(copy().weight)}</span><span>${(Number(row.weight) * 100).toFixed(1)}%</span></div>
            </div>`;
          },
        },
      },
      true,
    );
  }, [valuationRows, valuationChart.chartRef]);

  const c = copy();
  const range = ((data?.monthly_returns as Row)?.date_range ?? {}) as Row;
  const valuationPeCount = valuationRows.filter((row) => row.pe).length;
  const peMedian = median(valuationRows.filter((row) => row.pe).map((row) => Number(row.pe)));

  return (
    <main className="catfolio-view" ref={rootRef}>
      <div className="catfolio-analytics">
        <header className="catfolio-analytics-head">
          <div>
            <h1>分析图表</h1>
            <p id="catfolio-analytics-range">
              {range.start && range.end ? `${c.period}: ${String(range.start)} – ${String(range.end)}` : c.period}
            </p>
          </div>
          <button className="catfolio-ai-button catfolio-analytics-refresh" type="button" onClick={load}>
            <span>{c.refresh}</span>
          </button>
        </header>

        <div className={`catfolio-analytics-status${status ? " is-visible" : ""}${status.startsWith(c.loadError) || status.startsWith(c.valuationLoadError) ? " is-error" : ""}`} aria-live="polite">
          {status}
        </div>

        <section className="catfolio-analytics-grid" aria-label="分析图表">
          <div className="catfolio-analytics-figma">
            <article className="catfolio-analytics-drawdown-card">
              <header>
                <div><h2>回撤水下曲线</h2><p id="catfolio-drawdown-meta">{c.maxDrawdown}</p></div>
              </header>
              <div className="catfolio-analytics-drawdown-body">
                <div ref={drawdown.ref} className="catfolio-analytics-chart" role="img" aria-label="回撤水下曲线" />
                <div className="catfolio-analytics-drawdown-ranges" role="group" aria-label="回撤图表时间范围">
                  {["1D", "1W", "1M", "3M", "YTD", "1Y", "MAX"].map((key) => (
                    <button
                      key={key}
                      type="button"
                      className={drawdownRange === key ? "active" : ""}
                      aria-pressed={drawdownRange === key}
                      onClick={() => setDrawdownRange(key)}
                    >
                      {key}
                    </button>
                  ))}
                </div>
              </div>
            </article>

            <article className={`catfolio-analytics-valuation-card${tableExpanded ? " is-table-expanded" : ""}`}>
              <header>
                <div><h2>估值矩阵 (P/E vs 成长)</h2><p>气泡大小 = 仓位权重</p></div>
                <div className="catfolio-analytics-valuation-actions">
                  <button
                    className="catfolio-ai-button catfolio-analytics-valuation-details"
                    id="catfolio-valuation-toggle"
                    type="button"
                    aria-expanded={tableExpanded}
                    aria-controls="catfolio-valuation-panel"
                    onClick={() => setTableExpanded((prev) => !prev)}
                  >
                    {tableExpanded ? c.hideDetails : c.showDetails} ({valuationRows.length})
                  </button>
                </div>
              </header>
              <div className="catfolio-analytics-valuation-chart-wrap">
                <div ref={valuationChart.ref} className="catfolio-analytics-chart valuation-matrix-chart" role="img" aria-label="估值矩阵 (P/E vs 成长)" />
              </div>
              <div className="catfolio-valuation-table-wrap" id="catfolio-valuation-panel" tabIndex={0} aria-label="持仓估值明细" hidden={!tableExpanded}>
                <table className="catfolio-valuation-table">
                  <thead>
                    <tr>
                      <th scope="col">{c.asset}</th>
                      <th scope="col" className="numeric">P/E</th>
                      <th scope="col" className="numeric">P/S</th>
                      <th scope="col" className="numeric">P/B</th>
                      <th scope="col" className="numeric">{c.epsGrowth}</th>
                      <th scope="col" className="numeric">{c.revenueGrowth}</th>
                      <th scope="col" className="numeric">{c.weight}</th>
                      <th scope="col" className="numeric">{c.relativeLevel}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {!valuationRows.length ? (
                      <tr><td className="catfolio-valuation-table-empty" colSpan={8}>{c.valuationEmpty}</td></tr>
                    ) : (
                      valuationRows.map((row) => {
                        const premium = row.premium as number | null;
                        const tone = premium === null ? "" : premium >= 0 ? "expensive" : "cheap";
                        const level = premium === null ? "—" : `${premium >= 0 ? "+" : ""}${(premium * 100).toFixed(1)}%`;
                        return (
                          <tr key={String(row.ticker)}>
                            <td>
                              <span className="catfolio-valuation-asset">
                                <strong>{escapeHtml(row.ticker || "—")}</strong>
                                <small>{escapeHtml(row.display_name || row.name || row.sector || "")}</small>
                              </span>
                            </td>
                            <td className="numeric">{formatMultiple(row.pe)}</td>
                            <td className="numeric">{formatMultiple(row.priceToSales)}</td>
                            <td className="numeric">{formatMultiple(row.priceToBook)}</td>
                            <td className={`numeric${row.epsGrowth !== null && Number(row.epsGrowth) < 0 ? " negative" : ""}`}>{formatGrowth(row.eps_growth_yoy)}</td>
                            <td className={`numeric${row.revenueGrowth !== null && Number(row.revenueGrowth) < 0 ? " negative" : ""}`}>{formatGrowth(row.revenue_growth_yoy)}</td>
                            <td className="numeric">{(Number(row.weight) * 100).toFixed(1)}%</td>
                            <td className={`numeric catfolio-valuation-level ${tone}`}>{level}</td>
                          </tr>
                        );
                      })
                    )}
                  </tbody>
                </table>
              </div>
            </article>
          </div>

          <article className="catfolio-analytics-card">
            <header>
              <div><h2>月度收益热图</h2><p>年 × 月盈亏%</p></div>
            </header>
            <div ref={monthly.ref} className="catfolio-analytics-chart" role="img" aria-label="月度收益热图" />
          </article>

          <article className="catfolio-analytics-card">
            <header>
              <div><h2>收益率分布</h2><p id="catfolio-distribution-meta">模型日收益</p></div>
            </header>
            <div ref={distribution.ref} className="catfolio-analytics-chart" role="img" aria-label="收益率分布" />
          </article>

          <article className="catfolio-analytics-card catfolio-analytics-wide" style={{ gridColumn: "1 / -1" }}>
            <header>
              <div><h2>持仓相关性矩阵</h2><p>颜色越深，越容易同涨同跌</p></div>
            </header>
            <div ref={correlation.ref} className="catfolio-analytics-chart catfolio-analytics-correlation" role="img" aria-label="持仓相关性矩阵" />
          </article>

          <article className="catfolio-analytics-card catfolio-analytics-wide" style={{ gridColumn: "1 / -1" }}>
            <header>
              <div><h2>模型归因 Waterfall</h2><p id="catfolio-waterfall-meta">模型口径 · 当月权重收益%（非真实盈亏）</p></div>
            </header>
            <div ref={waterfall.ref} className="catfolio-analytics-chart" role="img" aria-label="模型归因 Waterfall" />
          </article>
        </section>
      </div>
    </main>
  );
}
