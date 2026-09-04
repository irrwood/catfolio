/**
 * Returns comparison view — port of the Catfolio `/returns` page:
 * cash-flow-mirror portfolio vs SPY (plus all benchmarks) with ranges,
 * end-of-line labels, crosshair value labels, and the AI explanation panel.
 */
import { useEffect, useRef, useState } from "react";
import { createChart, CrosshairMode, LineType, LineSeries, type IChartApi, type ISeriesApi, type UTCTimestamp } from "lightweight-charts";
import { t, numeric, currentLang } from "./copy.js";

type Row = Record<string, unknown>;

const COLORS = {
  portfolio: "#22c55e",
  SPY: "#f97316",
  QQQ: "#708cff",
  grid: "#eaebed",
  text: "rgba(9,15,5,0.60)",
};

const BENCHMARK_COLORS: Record<string, string> = {
  SPY: "#f97316",
  QQQ: "#708cff",
  VTI: "#8b5cf6",
  VOO: "#06b6d4",
  DIA: "#eab308",
  IWM: "#ec4899",
  VEU: "#a855f7",
  GLD: "#d89b22",
};

const RANGES = ["1d", "1w", "1m", "3m", "ytd", "1y", "max"] as const;
type RangeKey = (typeof RANGES)[number];

function themeColor(name: string, fallback: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;
}

function currentChartTheme() {
  return {
    background: "rgba(0, 0, 0, 0)",
    text: themeColor("--muted", COLORS.text),
    grid: themeColor("--line-strong", COLORS.grid),
    crosshairLabel: themeColor("--ink", "#000000"),
  };
}

const finiteNumber = (value: unknown): number | null => {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
};

const compactValue = (value: number): string => {
  const number = Number(value) || 0;
  const absolute = Math.abs(number);
  if (absolute >= 1_000_000) return `${(number / 1_000_000).toFixed(1)}M`;
  if (absolute >= 1_000) return `${Math.round(number / 1_000)}K`;
  return Math.round(number).toLocaleString(currentLang() === "zh" ? "zh-CN" : "en-US");
};

function formatReturn(value: unknown): { text: string; className: string } {
  const number = finiteNumber(value);
  if (number === null) return { text: "—", className: "" };
  const percent = number * 100;
  return {
    text: `${percent >= 0 ? "+" : ""}${percent.toFixed(1)}%`,
    className: percent >= 0 ? "positive" : "negative",
  };
}

interface SeriesMeta {
  title: string;
  color: string;
  data: { time: string; value: number }[];
  series: ISeriesApi<"Line">;
  label: HTMLDivElement | null;
  labelValue: HTMLSpanElement | null;
  primary: boolean;
}

function timeKey(time: unknown): string {
  if (typeof time === "string") return time;
  if (!time || typeof time !== "object") return "";
  const obj = time as { year?: number; month?: number; day?: number };
  return `${obj.year}-${String(obj.month).padStart(2, "0")}-${String(obj.day).padStart(2, "0")}`;
}

function adaptiveAutoscale(baseImplementation: () => unknown) {
  const scale = baseImplementation() as { priceRange?: { minValue: number; maxValue: number } } | null;
  const range = scale?.priceRange;
  if (!range) return scale;
  const min = finiteNumber(range.minValue);
  const max = finiteNumber(range.maxValue);
  if (min === null || max === null) return scale;
  const magnitude = Math.max(Math.abs(min), Math.abs(max), 1);
  const span = Math.max(max - min, magnitude * 0.015);
  const padding = span * 0.08;
  return { ...scale, priceRange: { minValue: min - padding, maxValue: max + padding } };
}

export function ReturnsView() {
  const containerRef = useRef<HTMLDivElement>(null);
  const endLabelsRef = useRef<HTMLDivElement>(null);
  const crosshairDateRef = useRef<HTMLDivElement>(null);
  const crosshairValueRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const seriesMetaRef = useRef<SeriesMeta[]>([]);
  const portfolioSeriesRef = useRef<ISeriesApi<"Line"> | null>(null);
  const allDatesRef = useRef<string[]>([]);
  const [range, setRangeState] = useState<RangeKey>("3m");
  const rangeRef = useRef<RangeKey>("3m");
  const [payload, setPayload] = useState<Row | null>(null);
  const [loadError, setLoadError] = useState("");
  const [aiStatus, setAiStatus] = useState("");
  const [aiResult, setAiResult] = useState<{ period?: string; explanation?: string } | null>(null);
  const [aiBusy, setAiBusy] = useState(false);

  useEffect(() => {
    let cancelled = false;
    fetch("/catfolio/api/comparison", { headers: { Accept: "application/json" } })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
      })
      .then((data) => { if (!cancelled) setPayload(data as Row); })
      .catch((error) => { if (!cancelled) setLoadError(error.message); });
    return () => { cancelled = true; };
  }, []);

  const setComparisonData = (payload: Row) => {
    const dates = Array.isArray(payload.dates) ? (payload.dates as string[]) : [];
    const compactRows = (values: unknown) => dates
      .map((date, index) => ({ time: date, value: finiteNumber((values as unknown[])?.[index]) }))
      .filter((row) => row.time && row.value !== null) as { time: string; value: number }[];
    const portfolioRows = compactRows(payload.portfolio);
    const benchmarkRows: Record<string, { time: string; value: number }[]> = {};
    const benchmarks = (payload.benchmarks ?? {}) as Record<string, unknown>;
    for (const [symbol, values] of Object.entries(benchmarks)) {
      benchmarkRows[symbol] = compactRows(values);
    }
    allDatesRef.current = portfolioRows.map((row) => row.time);
    return { portfolioRows, benchmarkRows, summary: (payload.summary ?? {}) as Row };
  };

  const updateEndLabels = () => {
    const chart = chartRef.current;
    const endLabels = endLabelsRef.current;
    const container = containerRef.current;
    if (!chart || !endLabels || !container) return;
    const visibleTo = timeKey(chart.timeScale().getVisibleRange()?.to);
    const maxY = Math.max(20, container.clientHeight - 14);
    const positions: { meta: SeriesMeta; target: number; y: number; x: number }[] = [];

    seriesMetaRef.current.forEach((meta) => {
      let label = meta.label;
      if (!label) {
        label = document.createElement("div");
        label.className = `catfolio-end-label${meta.primary ? "" : " secondary"}`;
        label.style.background = meta.color;
        const name = document.createElement("span");
        name.textContent = meta.title;
        const value = document.createElement("span");
        value.className = "catfolio-end-label-value";
        label.append(name, value);
        endLabels.appendChild(label);
        meta.label = label;
        meta.labelValue = value;
      }
      const row = meta.data.length
        ? (!visibleTo ? meta.data[meta.data.length - 1] : null) ?? [...meta.data].reverse().find((item) => item.time <= visibleTo) ?? null
        : null;
      const coordinate = row ? meta.series.priceToCoordinate(row.value) : null;
      const timeCoordinate = row ? chart.timeScale().timeToCoordinate(row.time as UTCTimestamp) : null;
      if (coordinate === null || timeCoordinate === null || coordinate < -20 || coordinate > container.clientHeight + 20) {
        label.hidden = true;
        return;
      }
      if (meta.labelValue) meta.labelValue.textContent = compactValue(row.value);
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
  };

  const crosshairDateLabel = (time: unknown): string => {
    const raw = typeof time === "string"
      ? time
      : time && typeof time === "object"
        ? `${(time as { year?: number }).year}-${String((time as { month?: number }).month).padStart(2, "0")}-${String((time as { day?: number }).day).padStart(2, "0")}`
        : "";
    if (!raw) return "";
    const date = new Date(`${raw}T00:00:00Z`);
    if (Number.isNaN(date.getTime())) return "";
    return date.toLocaleDateString(currentLang() === "zh" ? "zh-CN" : "en-GB", {
      day: "2-digit",
      month: "short",
      year: "2-digit",
      timeZone: "UTC",
    }).toUpperCase();
  };

  const hideCrosshairLabels = () => {
    if (crosshairDateRef.current) crosshairDateRef.current.hidden = true;
    if (crosshairValueRef.current) crosshairValueRef.current.hidden = true;
  };

  const positionCrosshairLabels = (param: Parameters<Parameters<IChartApi["subscribeCrosshairMove"]>[0]>[0]) => {
    const container = containerRef.current;
    if (!param?.point || !param.time || !portfolioSeriesRef.current) {
      hideCrosshairLabels();
      return;
    }
    const dateX = Math.max(38, Math.min(container!.clientWidth - 80, param.point.x));
    if (crosshairDateRef.current) {
      crosshairDateRef.current.textContent = crosshairDateLabel(param.time);
      crosshairDateRef.current.style.left = `${dateX}px`;
      crosshairDateRef.current.hidden = false;
    }
    let closest: { meta: SeriesMeta; value: number; coordinate: number; distance: number } | null = null;
    seriesMetaRef.current.forEach((meta) => {
      const point = param.seriesData?.get(meta.series);
      const value = finiteNumber(point?.value ?? point?.close);
      if (value === null) return;
      const coordinate = meta.series.priceToCoordinate(value);
      if (coordinate === null) return;
      const distance = Math.abs(coordinate - param.point!.y);
      if (!closest || distance < closest.distance) closest = { meta, value, coordinate, distance };
    });
    if (!closest || closest.distance > 18) {
      if (crosshairValueRef.current) crosshairValueRef.current.hidden = true;
      return;
    }
    if (crosshairValueRef.current) {
      crosshairValueRef.current.textContent = compactValue(closest.value);
      crosshairValueRef.current.style.background = closest.meta.color;
      crosshairValueRef.current.dataset.series = closest.meta.title;
      crosshairValueRef.current.hidden = false;
      const halfWidth = Math.max(20, crosshairValueRef.current.offsetWidth / 2);
      const valueX = Math.max(halfWidth + 4, Math.min(container!.clientWidth - halfWidth - 4, param.point!.x));
      const placeBelow = closest.coordinate < 42;
      crosshairValueRef.current.classList.toggle("is-below", placeBelow);
      crosshairValueRef.current.style.left = `${valueX}px`;
      crosshairValueRef.current.style.top = `${closest.coordinate + (placeBelow ? 8 : -8)}px`;
    }
  };

  const visibleRangeFor = (key: RangeKey): { from: string; to: string } | null => {
    const allDates = allDatesRef.current;
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
  };

  const applyRange = (key: RangeKey) => {
    rangeRef.current = key;
    setRangeState(key);
    const chart = chartRef.current;
    if (!chart) return;
    const range = visibleRangeFor(key);
    if (range) {
      chart.timeScale().setVisibleRange(range as never);
      requestAnimationFrame(updateEndLabels);
    }
  };

  useEffect(() => {
    if (!payload || !containerRef.current) return;
    const container = containerRef.current;
    const empty = container.querySelector(".catfolio-chart-empty") as HTMLElement | null;
    const { portfolioRows, benchmarkRows } = setComparisonData(payload);
    if (!portfolioRows.length) {
      if (empty) empty.hidden = false;
      return;
    }
    if (empty) empty.hidden = true;
    const theme = currentChartTheme();
    const chart = createChart(container, {
      width: container.clientWidth,
      height: Math.max(398, Math.round(container.getBoundingClientRect().height || 398)),
      layout: {
        background: { type: "solid", color: theme.background },
        textColor: theme.text,
        fontFamily: '"Nunito Local", "Nunito", sans-serif',
        fontSize: 12,
        attributionLogo: false,
      },
      localization: { priceFormatter: compactValue },
      grid: {
        vertLines: { visible: false },
        horzLines: { visible: true, color: theme.grid, style: 0 },
      },
      crosshair: {
        mode: CrosshairMode.Normal,
        vertLine: { visible: false, labelVisible: false },
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
      handleScroll: { mouseWheel: true, pressedMouseMove: true, horzTouchDrag: true, vertTouchDrag: false },
      handleScale: { axisPressedMouseMove: false, mouseWheel: false, pinch: true },
      kineticScroll: { mouse: true, touch: true },
    });
    chartRef.current = chart;
    seriesMetaRef.current = [];
    portfolioSeriesRef.current = null;

    const createSeries = (title: string, color: string, data: { time: string; value: number }[], width = 2) => {
      const series = chart.addSeries(LineSeries, {
        title: "",
        color,
        lineWidth: width,
        lineType: LineType.Curved,
        crosshairMarkerVisible: true,
        crosshairMarkerRadius: title === "Portfolio" ? 4 : 3,
        crosshairMarkerBorderColor: color,
        crosshairMarkerBackgroundColor: color,
        lastValueVisible: false,
        priceLineVisible: false,
        priceFormat: { type: "custom", formatter: (value: number) => compactValue(value) },
        autoscaleInfoProvider: adaptiveAutoscale,
      });
      series.setData(data.map((row) => ({ time: row.time as UTCTimestamp, value: row.value })));
      const meta: SeriesMeta = {
        title,
        color,
        data,
        series,
        label: null,
        labelValue: null,
        primary: title === "Portfolio" || title === "SPY" || title === "QQQ",
      };
      seriesMetaRef.current.push(meta);
      return series;
    };

    portfolioSeriesRef.current = createSeries(t("portfolioSeries"), COLORS.portfolio, portfolioRows, 2);
    const fallbackColors = ["#8b5cf6", "#06b6d4", "#eab308", "#ec4899", "#a855f7", "#ef4444"];
    Object.entries(benchmarkRows).forEach(([symbol, rows], index) => {
      if (!rows.length) return;
      createSeries(symbol, BENCHMARK_COLORS[symbol] || fallbackColors[index % fallbackColors.length], rows, symbol === "SPY" ? 2 : 1);
    });

    chart.subscribeCrosshairMove(positionCrosshairLabels);
    chart.timeScale().subscribeVisibleTimeRangeChange(() => requestAnimationFrame(updateEndLabels));

    const observer = new ResizeObserver(([entry]) => {
      if (!chart || !entry) return;
      chart.resize(Math.floor(entry.contentRect.width), Math.max(398, Math.round(entry.contentRect.height || 398)));
      requestAnimationFrame(updateEndLabels);
    });
    observer.observe(container);

    applyRange("3m");
    requestAnimationFrame(updateEndLabels);

    const onPointerDown = () => container.classList.add("is-dragging");
    const onPointerUp = () => container.classList.remove("is-dragging");
    container.addEventListener("pointerdown", onPointerDown);
    window.addEventListener("pointerup", onPointerUp);
    container.addEventListener("pointercancel", onPointerUp);

    return () => {
      observer.disconnect();
      container.removeEventListener("pointerdown", onPointerDown);
      window.removeEventListener("pointerup", onPointerUp);
      container.removeEventListener("pointercancel", onPointerUp);
      if (endLabelsRef.current) endLabelsRef.current.innerHTML = "";
      chart.remove();
      chartRef.current = null;
      seriesMetaRef.current = [];
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [payload]);

  const summary = (payload?.summary ?? {}) as Row;
  const portfolioReturn = formatReturn(summary.portfolio_return);
  const benchmarkReturn = formatReturn(summary.benchmark_return);

  const loadReturnsAI = async () => {
    setAiBusy(true);
    setAiStatus("");
    try {
      const response = await fetch("/catfolio/api/ai/returns-explanation", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ lang: document.documentElement.lang || "en" }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = (await response.json()) as { explanation?: string; period?: string };
      setAiResult({ period: data.period, explanation: data.explanation });
    } catch (error) {
      setAiStatus(`${t("aiError")}: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setAiBusy(false);
    }
  };

  return (
    <main className="catfolio-view">
      <div className="catfolio-returns">
        <header className="catfolio-page-head">
          <h1>收益对比</h1>
          <button className="catfolio-ai-button" type="button" disabled={aiBusy} onClick={loadReturnsAI}>
            <span>{t("aiButton")}</span>
          </button>
        </header>

        {aiStatus && <div className="catfolio-ai-status" aria-live="polite">{aiStatus}</div>}
        {aiResult && (
          <section className="catfolio-ai-result">
            <button className="catfolio-ai-close" type="button" aria-label={t("aiClosing")} onClick={() => setAiResult(null)}>
              ×
            </button>
            {aiResult.period && <div className="catfolio-ai-period">{aiResult.period}</div>}
            <p>{aiResult.explanation}</p>
          </section>
        )}

        <section className="catfolio-metrics-2" aria-label="现金流匹配收益摘要">
          <article className="catfolio-metric-card">
            <span className="catfolio-metric-label">组合净值</span>
            <strong className={portfolioReturn.className}>{portfolioReturn.text}</strong>
            <span className="catfolio-metric-note positive">基准：SPY</span>
          </article>
          <article className="catfolio-metric-card">
            <span className="catfolio-metric-label">基准净值</span>
            <strong className={benchmarkReturn.className}>{benchmarkReturn.text}</strong>
            <span className="catfolio-metric-note">SPY</span>
          </article>
        </section>

        <section className="catfolio-chart-card">
          <header className="catfolio-chart-head">
            <div>
              <h2>{t("cashFlowTitle")}</h2>
              <p>{t("cashFlowDesc")}</p>
            </div>
          </header>
          <div className="catfolio-chart-stage">
            <div ref={containerRef} className="catfolio-returns-chart" role="img" aria-label="现金流匹配的组合与基准对比图"></div>
            <div ref={endLabelsRef} className="catfolio-end-labels" aria-hidden="true"></div>
            <div ref={crosshairDateRef} className="catfolio-crosshair-date" hidden></div>
            <div ref={crosshairValueRef} className="catfolio-crosshair-value" hidden></div>
            <div className="catfolio-chart-empty" hidden>{loadError ? `对比数据加载失败（${loadError}）。` : t("chartEmpty")}</div>
          </div>
          <nav className="catfolio-ranges" aria-label="图表时间范围">
            {RANGES.map((key) => (
              <button key={key} type="button" className={range === key ? "active" : ""} aria-pressed={range === key} onClick={() => applyRange(key)}>
                {key === "1d" ? "1天" : key === "1w" ? "1周" : key === "1m" ? "1个月" : key === "3m" ? "3个月" : key === "ytd" ? "年初至今" : key === "1y" ? "1年" : "全部"}
              </button>
            ))}
          </nav>
        </section>
      </div>
    </main>
  );
}
