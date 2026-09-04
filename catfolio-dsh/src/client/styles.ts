/**
 * Catfolio view styles — ported from the project's portfolio.css / returns.css,
 * scoped under `.catfolio-view` and adapted to the harness light/dark theme
 * (`body[data-ds-dark-theme]`).
 */
export const CATFOLIO_CSS = `
.catfolio-view {
  --positive: #2f8a3e;
  --negative: #e40014;
  --accent: #708cff;
  --bg: #f7f8fa;
  --panel: #ffffff;
  --panel-hover: #f4f5f7;
  --soft: #f0f1f3;
  --line: #f1f1f1;
  --line-strong: rgba(9,15,5,0.20);
  --ink: #090f05;
  --ink-secondary: #333833;
  --muted: rgba(9,15,5,0.60);
  --surface: #ffffff;
  --primary: #2f8a3e;
  --primary-strong: #257a33;
  --primary-soft: #e7f4e9;
  --on-primary: #ffffff;
  --font-sans: "Nunito Local", "Nunito", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  --portfolio-card-radius: 20px;
  box-sizing: border-box;
  width: 100%;
  min-height: 100%;
  padding: 20px 10px;
  color: var(--ink);
  background: var(--bg);
  font-family: var(--font-sans);
  font-size: 14px;
  line-height: 1.4;
}
.catfolio-view *,
.catfolio-view *::before,
.catfolio-view *::after { box-sizing: border-box; }
body[data-ds-dark-theme] .catfolio-view {
  --bg: #0f1115;
  --panel: #171a20;
  --panel-hover: #1d2129;
  --soft: #1d2129;
  --line: #242933;
  --line-strong: rgba(255,255,255,0.16);
  --ink: #ededef;
  --ink-secondary: #d4d6da;
  --muted: #707580;
  --surface: #171a20;
  --primary: #2f8a3e;
  --primary-strong: #3aa24b;
  --primary-soft: rgba(47,138,62,0.18);
  --on-primary: #ffffff;
}
.catfolio-view h1, .catfolio-view h2, .catfolio-view p { margin: 0; }
.catfolio-view button { font-family: inherit; }
.catfolio-view .positive { color: var(--positive); }
.catfolio-view .negative { color: var(--negative); }
.catfolio-view .muted { color: var(--muted); }

/* ── page head ── */
.catfolio-page-head {
  min-height: 41px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
}
.catfolio-page-head h1 { font-size: 30px; font-weight: 800; line-height: 41px; }
.catfolio-visually-hidden {
  position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
  overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0;
}
.catfolio-status { min-height: 16px; color: var(--muted); font-size: 12px; font-weight: 600; }

/* ── metric cards ── */
.catfolio-metrics {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 10px;
  margin-top: 10px;
}
.catfolio-metric-card {
  min-width: 0; height: 132px; padding: 20px;
  display: flex; flex-direction: column; align-items: flex-start; justify-content: space-between;
  border: 1px solid var(--line); border-radius: var(--portfolio-card-radius); background: var(--panel);
}
.catfolio-metric-card > span, .catfolio-metric-card > small {
  overflow: hidden; max-width: 100%; color: var(--muted);
  font-size: 12px; font-weight: 600; line-height: 16px;
  text-overflow: ellipsis; white-space: nowrap;
}
.catfolio-metric-card > strong {
  color: var(--ink); font-size: 30px; font-weight: 750; line-height: 41px;
  font-variant-numeric: tabular-nums;
}
.catfolio-metric-card .positive { color: var(--positive); }
.catfolio-metric-card .negative { color: var(--negative); }

/* ── insights row: chart + calendar ── */
.catfolio-insights-row {
  width: 100%; display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 10px; margin-top: 10px;
}
.catfolio-insights-row > * { min-width: 0; }
.catfolio-insights-row .catfolio-ranges { padding-inline: 0; grid-template-columns: repeat(7, minmax(0,1fr)); gap: 2px; }
.catfolio-insights-row .catfolio-ranges button { width: 100%; }

.catfolio-value-card {
  height: 545px; min-height: 545px; padding: 20px;
  display: flex; flex-direction: column; gap: 24px; overflow: hidden;
  border: 1px solid var(--line); border-radius: var(--portfolio-card-radius); background: var(--panel);
}
.catfolio-chart-head { min-height: 44px; display: flex; align-items: flex-start; }
.catfolio-chart-head h2 { color: var(--ink); font-size: 18px; font-weight: 750; line-height: 25px; letter-spacing: -0.01em; white-space: nowrap; }
.catfolio-chart-head p { margin-top: 2px; color: var(--muted); font-size: 14px; font-weight: 600; line-height: 19px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.catfolio-chart-body { width: 100%; min-height: 0; display: flex; flex: 1; flex-direction: column; gap: 10px; }
.catfolio-value-chart { position: relative; width: 100%; min-height: 0; flex: 1; cursor: crosshair; }
.catfolio-chart-hover-layer { position: absolute; inset: 0; z-index: 12; overflow: visible; pointer-events: none; contain: layout style; }
.catfolio-chart-hover-dot, .catfolio-chart-hover-bubble, .catfolio-chart-hover-date {
  position: absolute; display: block; pointer-events: none;
  animation: none !important; transition: none !important; will-change: left, top;
}
.catfolio-chart-hover-dot { width: 8px; height: 8px; transform: translate3d(-50%,-50%,0); border-radius: 50%; }
.catfolio-chart-hover-dot.market, .catfolio-chart-hover-bubble.market { background: var(--positive); }
.catfolio-chart-hover-dot.cost, .catfolio-chart-hover-bubble.cost { background: #708cff; }
.catfolio-chart-hover-bubble {
  min-width: 48px; padding: 4px 8px; transform: translate3d(-50%, calc(-100% - 8px), 0);
  border-radius: 10px; color: #fff; font-size: 14px; font-weight: 600; line-height: 19px;
  text-align: center; white-space: nowrap; font-variant-numeric: tabular-nums;
}
.catfolio-chart-hover-bubble.is-below { transform: translate3d(-50%, 8px, 0); }
.catfolio-chart-hover-date {
  min-width: max-content; padding: 4px 8px; transform: translate3d(-50%,-50%,0);
  border-radius: 10px; background: var(--ink); color: var(--panel);
  font-size: 10px; font-weight: 600; line-height: 14px; white-space: nowrap; font-variant-numeric: tabular-nums;
}
.catfolio-ranges {
  width: 100%; height: 32px; padding: 0 17.401392%;
  display: grid; grid-template-columns: repeat(7, 50px);
  align-items: center; justify-content: space-between;
}
.catfolio-ranges button {
  width: 50px; height: 32px; padding: 0; border: 1px solid transparent; border-radius: 8px;
  color: var(--muted); background: transparent; font: inherit; font-size: 12px; font-weight: 700; cursor: pointer;
}
.catfolio-ranges button:hover { color: var(--ink); }
.catfolio-ranges button.active { color: var(--ink); background: var(--soft); font-weight: 800; }
.catfolio-ranges button:focus-visible { outline: 2px solid #708cff; outline-offset: 1px; }

/* ── profit calendar ── */
.catfolio-calendar-card {
  height: 545px; min-height: 545px; padding: 20px;
  display: flex; flex-direction: column; gap: 16px; overflow: hidden;
  border: 1px solid var(--line); border-radius: 17px; background: var(--panel);
}
.catfolio-calendar-head, .catfolio-calendar-controls, .catfolio-calendar-range, .catfolio-calendar-period-nav { display: flex; align-items: center; }
.catfolio-calendar-head { min-height: 36px; justify-content: space-between; gap: 10px; }
.catfolio-calendar-head h2 { color: var(--ink); font-size: 20px; font-weight: 750; line-height: 25px; white-space: nowrap; }
.catfolio-calendar-controls { min-width: 0; height: 40px; padding: 3px; gap: 0; border: 1px solid var(--line-strong); border-radius: 12px; background: var(--soft); }
.catfolio-calendar-range, .catfolio-calendar-period-nav { height: 32px; padding: 0; border: 0; background: transparent; }
.catfolio-calendar-range { border-radius: 9px; }
.catfolio-calendar-period-nav { margin-left: 0; gap: 3px; border-radius: 9px; }
.catfolio-calendar-range-button, .catfolio-calendar-period-nav button {
  appearance: none; border: 0; color: var(--muted); background: transparent; font: inherit; cursor: pointer;
}
.catfolio-calendar-range-button { width: 50px; height: 32px; padding: 0; border-radius: 8px; font-size: 13px; font-weight: 600; }
.catfolio-calendar-range-button.active { border: 1px solid var(--line-strong); color: var(--ink); background: var(--panel); font-weight: 800; }
.catfolio-calendar-range-button:focus-visible, .catfolio-calendar-period-nav button:focus-visible { outline: 2px solid #708cff; outline-offset: 1px; }
.catfolio-calendar-period-nav button { display: grid; width: 20px; height: 32px; padding: 0; place-items: center; border-radius: 7px; }
.catfolio-calendar-period-nav button:hover { background: var(--panel-hover); }
.catfolio-calendar-period-nav img { width: 14px; height: 14px; }
.catfolio-calendar-period { min-width: 72px; display: flex; align-items: center; justify-content: center; gap: 5px; color: color-mix(in srgb, var(--ink) 60%, transparent); font-size: 13px; font-weight: 600; white-space: nowrap; }
.catfolio-calendar-period-month { text-transform: uppercase; }
.catfolio-calendar-body { min-height: 0; display: flex; flex: 1; flex-direction: column; gap: 6px; overflow: hidden; }
.catfolio-calendar-weekdays, .catfolio-calendar-grid { display: grid; grid-template-columns: repeat(7, minmax(0,1fr)); gap: 6px; }
.catfolio-calendar-weekdays { min-height: 20px; }
.catfolio-calendar-weekdays[hidden] { display: none; }
.catfolio-calendar-weekday { color: color-mix(in srgb, var(--ink) 80%, transparent); font-size: 13px; font-weight: 700; line-height: 16px; text-align: center; }
.catfolio-calendar-grid { min-height: 0; flex: 1; grid-auto-rows: minmax(0,1fr); }
.catfolio-calendar-day, .catfolio-calendar-month-tile { min-width: 0; overflow: hidden; border-radius: 10px; background: var(--soft); transition: filter 140ms ease; }
.catfolio-calendar-day { padding: 8px 10px; }
.catfolio-calendar-day.is-outside { background: transparent; pointer-events: none; }
.catfolio-calendar-day.has-value, .catfolio-calendar-month-tile.has-value { background: var(--calendar-fill); }
.catfolio-calendar-day:not(.is-outside):hover, .catfolio-calendar-month-tile:hover { filter: brightness(1.025); }
.catfolio-calendar-day-number { display: block; color: color-mix(in srgb, var(--ink) 80%, transparent); font-size: 13px; font-weight: 600; line-height: 15px; }
.catfolio-calendar-day-value { display: block; overflow: hidden; color: var(--calendar-positive-text); font-size: 13px; font-weight: 700; line-height: 16px; text-overflow: ellipsis; white-space: nowrap; }
.catfolio-calendar-day.is-negative .catfolio-calendar-day-value, .catfolio-calendar-month-tile.is-negative strong { color: var(--calendar-negative-text); }
.catfolio-calendar-grid.is-months { grid-template-columns: repeat(4, minmax(0,1fr)); grid-template-rows: repeat(3, minmax(0,1fr)); }
.catfolio-calendar-month-tile { padding: 10px; display: flex; flex-direction: column; justify-content: space-between; }
.catfolio-calendar-month-tile span { color: color-mix(in srgb, var(--ink) 80%, transparent); font-size: 13px; font-weight: 700; line-height: 15px; }
.catfolio-calendar-month-tile strong { overflow: hidden; color: var(--calendar-positive-text); font-size: 14px; font-weight: 800; line-height: 16px; text-overflow: ellipsis; white-space: nowrap; }
.catfolio-calendar-grid.is-year {
  width: 100%; min-width: 0; min-height: 0; padding: 0;
  display: grid; grid-template-columns: repeat(17, minmax(0,1fr)); grid-template-rows: repeat(16, minmax(0,1fr));
  grid-auto-flow: row; align-content: stretch; justify-content: stretch; gap: 4px; flex: 1;
  border-radius: 0; background: transparent; overflow: hidden;
  animation: catfolio-calendar-year-enter 180ms ease-out both;
}
.catfolio-calendar-year-day { width: auto; height: auto; min-width: 0; min-height: 0; border-radius: 4px; background: var(--calendar-year-empty-fill); transition: filter 120ms ease, transform 120ms ease; }
.catfolio-calendar-year-day.has-value { background: var(--calendar-fill); }
.catfolio-calendar-month-tile:not(.has-value) strong { display: none; }
.catfolio-calendar-year-day:hover { z-index: 1; filter: brightness(0.94); transform: scale(1.2); }
@keyframes catfolio-calendar-year-enter { from { opacity: 0; transform: translateY(3px); } to { opacity: 1; transform: translateY(0); } }
.catfolio-calendar-summary { display: grid; grid-template-columns: repeat(2, minmax(0,1fr)); gap: 8px; }
.catfolio-calendar-summary-item { height: 46px; min-width: 0; padding: 0 12px; display: flex; align-items: center; gap: 6px; border-radius: 10px; background: var(--soft); }
.catfolio-calendar-summary-item img { width: 18px; height: 18px; flex: 0 0 auto; }
.catfolio-calendar-summary-label, .catfolio-calendar-summary-period { color: var(--ink); font-size: 14px; font-weight: 800; line-height: 14px; white-space: nowrap; }
.catfolio-calendar-summary-item strong { margin-left: auto; color: var(--positive); font-size: 14px; font-weight: 800; line-height: 15px; white-space: nowrap; }
.catfolio-calendar-summary-period { color: var(--muted); font-size: 12px; }
body[data-ds-dark-theme] .catfolio-calendar-card {
  --calendar-positive-text: #70d57d;
  --calendar-negative-text: #ff8191;
  --calendar-year-empty-fill: color-mix(in srgb, var(--ink) 10%, var(--panel));
}
.catfolio-view .catfolio-calendar-card {
  --calendar-positive-text: #269739;
  --calendar-negative-text: #bd263d;
  --calendar-year-empty-fill: #f8f9f7;
}

/* ── holdings table ── */
.catfolio-holdings-card {
  width: 100%; margin-top: 10px; padding: 20px 0;
  display: flex; flex-direction: column; gap: 10px; overflow: hidden;
  border: 1px solid var(--line); border-radius: var(--portfolio-card-radius); background: var(--panel);
}
.catfolio-holdings-head { width: 100%; min-height: 44px; padding: 0 20px; display: flex; align-items: flex-start; justify-content: space-between; gap: 20px; }
.catfolio-holdings-title { min-width: 0; display: flex; flex-direction: column; align-items: flex-start; white-space: nowrap; }
.catfolio-holdings-title h2 { color: var(--ink); font-size: 18px; font-weight: 700; line-height: 25px; }
.catfolio-holdings-title p { max-width: 100%; margin: 0; overflow: hidden; color: var(--muted); font-size: 14px; font-weight: 600; line-height: 19px; text-overflow: ellipsis; }
.catfolio-holdings-mode { width: 252px; height: 40px; padding: 4px; display: flex; flex: 0 0 auto; align-items: center; border: 1px solid var(--line-strong); border-radius: 16px; background: var(--panel); }
.catfolio-holdings-mode button:first-child { width: 110px; }
.catfolio-holdings-mode button:last-child { width: 134px; }
.catfolio-holdings-mode button { height: 32px; padding: 0 16px; border: 1px solid transparent; border-radius: 12px; color: var(--muted); background: transparent; font: inherit; font-size: 12px; font-weight: 600; line-height: 16px; white-space: nowrap; cursor: pointer; }
.catfolio-holdings-mode button:hover { color: var(--ink-secondary); }
.catfolio-holdings-mode button.active { border-color: var(--line-strong); color: var(--ink-secondary); background: var(--soft); font-weight: 800; }
.catfolio-holdings-mode button:focus-visible, .catfolio-holdings-sort:focus-visible, .catfolio-holdings-scroll:focus-visible { outline: 2px solid #708cff; outline-offset: 1px; }
.catfolio-holdings-scroll { width: 100%; overflow-x: auto; overflow-y: hidden; scrollbar-width: thin; scrollbar-color: var(--line-strong) transparent; }
.catfolio-holdings-table { width: 100%; min-width: 1044px; border: 0; border-collapse: separate; border-spacing: 0; color: var(--ink); font-variant-numeric: tabular-nums; }
.catfolio-holdings-table thead, .catfolio-holdings-table tbody { display: block; }
.catfolio-holdings-table thead tr {
  width: calc(100% - 40px); height: 36px; margin: 0 20px; padding: 10px 16px 10px 8px;
  display: grid; grid-template-columns: 24px minmax(160px,1fr) 100px 100px 118px 100px 118px 100px;
  column-gap: 20px; align-items: center; border-radius: 8px; background: var(--soft);
}
.catfolio-holdings-table th { min-width: 0; padding: 0; border: 0; color: var(--muted); font-size: 12px; font-weight: 700; line-height: 16px; text-align: center; white-space: nowrap; }
.catfolio-holdings-table th:nth-child(2) { text-align: left; }
.catfolio-holdings-table th:nth-child(3), .catfolio-holdings-table th:nth-child(5), .catfolio-holdings-table th:nth-child(6), .catfolio-holdings-table th:nth-child(7), .catfolio-holdings-table th:nth-child(8) { text-align: right; }
.catfolio-holdings-sort { width: 100%; height: 16px; padding: 0; display: flex; align-items: center; justify-content: center; gap: 2px; border: 0; color: inherit; background: transparent; font: inherit; cursor: pointer; }
.catfolio-holdings-table th:nth-child(5) .catfolio-holdings-sort, .catfolio-holdings-table th:nth-child(6) .catfolio-holdings-sort, .catfolio-holdings-table th:nth-child(7) .catfolio-holdings-sort, .catfolio-holdings-table th:nth-child(8) .catfolio-holdings-sort { justify-content: flex-end; }
.catfolio-holdings-sort img { width: 8px; height: 8px; flex: 0 0 8px; }
.catfolio-holdings-sort.ascending img { transform: rotate(180deg); }
.catfolio-holdings-table tbody { padding-top: 10px; display: flex; flex-direction: column; gap: 8px; }
.catfolio-holdings-table tbody tr:not(.catfolio-holdings-message) {
  width: calc(100% - 40px); height: 44px; margin-inline: 20px; padding: 4px 16px 4px 8px;
  display: grid; grid-template-columns: 24px minmax(160px,1fr) 100px 100px 118px 100px 118px 100px;
  column-gap: 20px; align-items: center; border-radius: 8px; box-sizing: border-box;
  transition: background-color 180ms ease;
}
@media (hover: hover) { .catfolio-holdings-table tbody tr:not(.catfolio-holdings-message):hover { background: var(--panel-hover); } }
.catfolio-holdings-table td { min-width: 0; padding: 0; border: 0; overflow: hidden; color: var(--ink); font-size: 14px; font-weight: 600; line-height: 19px; text-align: center; text-overflow: ellipsis; white-space: nowrap; }
.catfolio-holdings-table td:nth-child(3), .catfolio-holdings-table td:nth-child(5), .catfolio-holdings-table td:nth-child(6), .catfolio-holdings-table td:nth-child(7) { text-align: right; }
.catfolio-holdings-table .positive { color: var(--positive); }
.catfolio-holdings-table .negative { color: var(--negative); }
.catfolio-holdings-table .muted { color: var(--muted); }
.catfolio-holding-asset { text-align: left; }
.catfolio-holding-logo { display: flex; align-items: center; justify-content: center; }
.catfolio-holding-badge {
  position: relative; width: 24px; height: 24px; display: inline-flex; flex: 0 0 24px;
  align-items: center; justify-content: center; border-radius: 50%; overflow: hidden;
  color: #fff; background: hsl(var(--asset-hue) 72% 48%); font-size: 10px; font-weight: 800; line-height: 1;
}
.catfolio-holding-badge img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: contain; }
.catfolio-holding-identity { width: 100%; height: 36px; min-width: 0; display: flex; flex-direction: column; justify-content: center; align-items: flex-start; }
.catfolio-holding-identity strong { display: block; width: 100%; overflow: hidden; text-align: left; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; font-weight: 700; line-height: 19px; }
.catfolio-holding-identity small { height: 16px; display: flex; align-items: center; gap: 4px; color: var(--muted); font-size: 12px; font-weight: 600; line-height: 16px; white-space: nowrap; }
.catfolio-holding-stack, .catfolio-holding-market, .catfolio-holding-profit, .catfolio-holding-fx { height: 36px; display: flex; flex-direction: column; justify-content: space-between; line-height: normal; align-items: flex-end; }
.catfolio-holding-stack b, .catfolio-holding-market b, .catfolio-holding-profit b, .catfolio-holding-fx b { font-size: 14px; font-weight: 600; line-height: 19px; }
.catfolio-holding-stack span, .catfolio-holding-market span, .catfolio-holding-profit span, .catfolio-holding-fx span { color: var(--muted); font-size: 12px; font-weight: 600; line-height: 16px; }
.catfolio-holding-range { height: 36px; display: flex; align-items: center; justify-content: flex-end; gap: 6px; }
.catfolio-holding-range-track { position: relative; width: 8px; height: 30px; flex: 0 0 8px; border-radius: 34px; background: var(--line); }
.catfolio-holding-range-track i { position: absolute; right: 0; bottom: 0; left: 0; min-height: 2px; border-radius: 20px; background: var(--line-strong); }
.catfolio-holding-range-marker { position: absolute; left: 50%; z-index: 1; width: 8px; height: 8px; border: 2px solid var(--panel); border-radius: 50%; background: var(--ink); box-sizing: border-box; transform: translate(-50%, 50%); }
.catfolio-holding-range-values { display: flex; flex-direction: column; align-items: flex-start; color: var(--muted); font-size: 12px; font-weight: 600; line-height: 16px; text-align: right; }
.catfolio-holdings-message td { width: 100%; padding: 14px 20px 0; color: var(--muted); text-align: left; }

/* volume profile popover */
.catfolio-vp-popover {
  position: fixed; z-index: 240; width: clamp(156px, 14vw, 184px); padding: clamp(9px, 0.8vw, 12px);
  display: flex; flex-direction: column; gap: 6px;
  border: 1px solid var(--line); border-radius: 8px; background: var(--panel);
  box-shadow: 0 10px 8.45px rgb(0 0 0 / 8%);
  color: var(--ink); font-family: var(--font-sans); font-size: clamp(11px, 1vw, 12px);
  line-height: normal; letter-spacing: 0.25px; white-space: nowrap; pointer-events: none;
}
.catfolio-vp-title { opacity: 0.5; font-size: clamp(11px, 1vw, 12px); font-weight: 700; }
.catfolio-vp-body { display: flex; width: 100%; min-height: clamp(82px, 7vw, 92px); align-items: flex-start; gap: 5px; }
.catfolio-vp-rail { position: relative; width: 12px; height: clamp(82px, 7vw, 92px); flex: 0 0 12px; overflow: hidden; border-radius: 5px; background: #e8e8e8; }
.catfolio-vp-marker { position: absolute; left: 2.5px; top: var(--profile-marker-position); width: 7px; height: 7px; border-radius: 50%; transform: translateY(-50%); }
.catfolio-vp-marker.is-poc { background: #000; }
.catfolio-vp-marker.is-cost { background: #708cff; }
.catfolio-vp-rows { display: flex; min-width: 0; flex: 1 1 auto; flex-direction: column; gap: clamp(5px, 0.5vw, 7px); }
.catfolio-vp-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.catfolio-vp-row b, .catfolio-vp-row i { color: inherit; font-style: normal; font-weight: 600; }
.catfolio-vp-row.is-cost { color: #405fdd; }
@media (hover: none), (pointer: coarse) { .catfolio-vp-popover { display: none; } }

/* ── returns comparison page ── */
.catfolio-returns { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.catfolio-ai-button {
  height: 36px; padding: 1px 11px; display: inline-flex; align-items: center; justify-content: center; gap: 2px;
  border: 1px solid var(--primary-strong); border-radius: 14px; background: var(--primary); color: var(--on-primary);
  cursor: pointer; font: 800 12px/1 var(--font-sans);
  transition: background-color 160ms ease, border-color 160ms ease, transform 160ms ease;
}
.catfolio-ai-button:hover { border-color: var(--accent); background: var(--primary-soft); }
.catfolio-ai-button:active { transform: translateY(1px); }
.catfolio-ai-button:disabled { cursor: wait; opacity: 0.7; }
.catfolio-ai-button:focus-visible, .catfolio-ranges button:focus-visible { outline: 2px solid #708cff; outline-offset: 2px; }
.catfolio-ai-status { min-height: 16px; color: var(--negative); font-size: 12px; font-weight: 700; }
.catfolio-ai-result {
  position: relative; padding: 18px 44px 18px 20px;
  border: 1px solid var(--accent); border-radius: 16px; background: var(--primary-soft); color: var(--ink-secondary);
  font-size: 13px; line-height: 1.6;
}
.catfolio-ai-result p { margin: 4px 0 0; }
.catfolio-ai-period { color: var(--accent); font-size: 11px; font-weight: 800; }
.catfolio-ai-close { position: absolute; top: 10px; right: 12px; padding: 4px; border: 0; background: transparent; color: var(--accent); cursor: pointer; font-size: 20px; }
.catfolio-metrics-2 { display: grid; grid-template-columns: repeat(2, minmax(0,1fr)); gap: 10px; }
.catfolio-metric-note { color: var(--muted); font-size: 12px; font-weight: 700; line-height: 16px; }
.catfolio-metric-note.positive { color: var(--positive); }
.catfolio-chart-card {
  min-width: 0; height: 555px; min-height: 555px; padding: 17px 32px 16px 20px;
  display: flex; flex-direction: column; gap: 0; overflow: hidden;
  border: 1px solid var(--line); border-radius: 20px; background: var(--panel);
}
.catfolio-chart-card .catfolio-chart-head { flex: 0 0 44px; margin-bottom: 24px; }
.catfolio-chart-stage { position: relative; height: 406px; min-height: 406px; flex: 0 0 406px; overflow: hidden; }
.catfolio-returns-chart { width: 100%; height: 100%; min-height: 398px; cursor: grab; touch-action: pan-y; user-select: none; }
.catfolio-returns-chart.is-dragging { cursor: grabbing; }
.catfolio-end-labels { position: absolute; inset: 0; z-index: 3; overflow: hidden; pointer-events: none; }
.catfolio-end-label {
  position: absolute; left: 0; min-height: 24px; padding: 4px 8px;
  display: inline-flex; align-items: center; justify-content: center; gap: 8px; transform: translateY(-50%);
  border-radius: 48px; color: #fff; font-size: 12px; font-weight: 600; line-height: 16px;
  white-space: nowrap; font-variant-numeric: tabular-nums; transition: top 120ms ease;
}
.catfolio-end-label.secondary { min-height: 20px; padding-block: 2px; font-size: 11px; line-height: 16px; }
.catfolio-crosshair-date, .catfolio-crosshair-value {
  position: absolute; z-index: 4; transform: translateX(-50%); pointer-events: none;
  white-space: nowrap; font-variant-numeric: tabular-nums;
}
.catfolio-crosshair-date { top: 0; padding: 4px 8px; border-radius: 10px; background: var(--ink); color: var(--panel); font-size: 10px; font-weight: 600; line-height: 14px; }
.catfolio-crosshair-value { transform: translate(-50%,-100%); padding: 4px 8px; border-radius: 10px; background: #22c55e; color: #fff; font-size: 14px; font-weight: 600; line-height: 19px; }
.catfolio-crosshair-value.is-below { transform: translate(-50%, 0); }
.catfolio-chart-empty { position: absolute; inset: 0; display: grid; place-items: center; color: var(--muted); font-size: 13px; font-weight: 700; text-align: center; }
.catfolio-chart-empty[hidden] { display: none; }
.catfolio-crosshair-date[hidden], .catfolio-crosshair-value[hidden] { display: none; }
.catfolio-returns .catfolio-ranges {
  height: 36px; margin-top: 10px; padding: 0 clamp(0px, 18%, 150px);
  grid-template-columns: repeat(7, minmax(50px, 1fr)); gap: 4px;
}
.catfolio-returns .catfolio-ranges button { width: 50px; height: 36px; justify-self: center; }

@media (max-width: 960px) {
  .catfolio-insights-row { grid-template-columns: minmax(0,1fr); }
  .catfolio-value-card, .catfolio-calendar-card { height: 460px; min-height: 460px; }
}
@media (max-width: 720px) {
  .catfolio-metrics, .catfolio-metrics-2 { grid-template-columns: 1fr; }
  .catfolio-chart-card { height: auto; min-height: 520px; padding: 16px 12px; }
  .catfolio-chart-stage, .catfolio-returns-chart { height: 340px; min-height: 340px; }
  .catfolio-chart-stage { flex-basis: 340px; }
  .catfolio-returns .catfolio-ranges { padding: 0; overflow-x: auto; grid-template-columns: repeat(7, 50px); }
}
@media (max-width: 640px) {
  .catfolio-metrics { grid-template-columns: repeat(2, minmax(0,1fr)); }
  .catfolio-value-card { height: auto; min-height: 440px; }
  .catfolio-calendar-card { height: auto; min-height: 545px; }
  .catfolio-value-chart { min-height: 292px; }
}
@media (prefers-reduced-motion: reduce) {
  .catfolio-view * { transition: none !important; animation: none !important; }
}

/* ── Settings (设置) ─────────────────────────────────────────────── */
.catfolio-settings { width: min(100%, 860px); margin: 0 auto; padding: 10px 0 44px; display: grid; gap: 14px; }
.catfolio-page-head { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; }
.catfolio-settings-card { border: 1px solid var(--line); border-radius: 20px; background: var(--panel); padding: 20px 22px; display: grid; gap: 12px; }
.catfolio-settings-card h2 { margin: 0; font-size: 17px; font-weight: 800; }
.catfolio-settings-note { margin: 0; color: var(--muted); font-size: 12.5px; font-weight: 600; word-break: break-all; }
.catfolio-settings-field { display: grid; gap: 6px; }
.catfolio-settings-field label { font-size: 12.5px; font-weight: 800; color: var(--ink); }
.catfolio-settings-field input { appearance: none; width: 100%; box-sizing: border-box; padding: 10px 12px; border: 1px solid var(--line-strong); border-radius: 10px; background: var(--soft); color: var(--ink); font: inherit; font-size: 13.5px; font-weight: 600; }
.catfolio-settings-field input::placeholder { color: var(--muted); opacity: .75; }
.catfolio-settings-field input:focus { outline: 2px solid #708cff; outline-offset: 1px; border-color: transparent; }
.catfolio-settings-modes { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }
.catfolio-settings-modes button { appearance: none; display: grid; gap: 4px; text-align: left; padding: 12px 14px; border: 1px solid var(--line-strong); border-radius: 12px; background: var(--soft); color: var(--ink); cursor: pointer; transition: border-color 150ms ease, background-color 150ms ease, transform 150ms ease; }
.catfolio-settings-modes button strong { font-size: 13px; font-weight: 800; }
.catfolio-settings-modes button span { font-size: 11px; font-weight: 600; color: var(--muted); line-height: 1.4; }
.catfolio-settings-modes button:hover { border-color: var(--accent); transform: translateY(-1px); }
.catfolio-settings-modes button.active { border-color: var(--accent); background: var(--primary-soft); }
.catfolio-settings-modes button:focus-visible { outline: 2px solid #708cff; outline-offset: 2px; }
.catfolio-settings-actions { display: flex; gap: 10px; flex-wrap: wrap; }
.catfolio-settings-actions .catfolio-ai-button { padding: 10px 18px; }
@media (max-width: 640px) {
  .catfolio-settings-modes { grid-template-columns: 1fr; }
}
`;

export const ICON_ARROW_LEFT =
  '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M10 12L6 8L10 4" stroke="#686C67" stroke-opacity=".5" stroke-width="1.33333" stroke-miterlimit="3.8637" stroke-linecap="round" stroke-linejoin="round"/></svg>';
export const ICON_ARROW_RIGHT =
  '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M6 12L10 8L6 4" stroke="#686C67" stroke-opacity=".5" stroke-width="1.33333" stroke-miterlimit="3.8637" stroke-linecap="round" stroke-linejoin="round"/></svg>';
export const ICON_DIVIDEND =
  '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M6 10.5C8.48528 10.5 10.5 8.48528 10.5 6C10.5 3.51472 8.48528 1.5 6 1.5C3.51472 1.5 1.5 3.51472 1.5 6C1.5 8.48528 3.51472 10.5 6 10.5Z" stroke="#2F8A3E" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><path d="M13.5675 7.7775C14.2765 8.04182 14.9074 8.48065 15.4018 9.05321L16.5 10.5V12H13.5V15H10.5V13.5H7.5V15H4.5V12.375C5.62659 11.4533 7.19937 10.4955 8.50992 9.5256" stroke="#2F8A3E" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
export const ICON_CASH_INTEREST =
  '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M14.25 3.75C13.125 3.75 12.15 4.8 12 5.25C9.375 4.125 3.75 5.025 3.75 9C3.75 10.35 3.75 11.25 5.25 12.375V15H8.25V13.5H10.5V15H13.5V12C14.25 11.625 14.775 11.25 15 10.5H16.5V7.5H15C15 6.75 14.625 6.375 14.25 6V3.75Z" stroke="#2F8A3E" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
export const ICON_SORT =
  '<svg preserveAspectRatio="none" width="100%" height="100%" overflow="visible" style="display:block" viewBox="0 0 8 8" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M5.63431 4.36569L5.13137 4.86863C4.73535 5.26465 4.53734 5.46265 4.30902 5.53684C4.10817 5.6021 3.89183 5.6021 3.69098 5.53684C3.46266 5.46265 3.26465 5.26465 2.86863 4.86863L2.36569 4.36569C2.22294 4.22294 2.22294 3.99011 2.36569 3.84736C2.38051 3.83254 2.3964 3.81877 2.41325 3.80617C2.60315 3.66 2.88984 3.66 3.07974 3.80617C3.09659 3.81877 3.11248 3.83254 3.1273 3.84736L3.4 4.12006V1.6C3.4 1.26863 3.66863 1 4 1C4.33137 1 4.6 1.26863 4.6 1.6V4.12006L4.8727 3.84736C4.88752 3.83254 4.90341 3.81877 4.92026 3.80617C5.11016 3.66 5.39685 3.66 5.58675 3.80617C5.6036 3.81877 5.61949 3.83254 5.63431 3.84736C5.77706 3.99011 5.77706 4.22294 5.63431 4.36569Z" fill="#A7A7A7"/></svg>';

// ── analytics page ──────────────────────────────────────────────────────────
export const ANALYTICS_CSS = `
.catfolio-analytics { display: flex; flex-direction: column; gap: 18px; min-width: 0; }
.catfolio-analytics-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
.catfolio-analytics-head h1 { margin: 0; font-size: 24px; line-height: 1.2; font-weight: 700; }
.catfolio-analytics-head p { margin: 5px 0 0; color: var(--muted); font-size: 13px; }
.catfolio-analytics-refresh { flex: 0 0 auto; min-width: 92px; justify-content: center; }
.catfolio-analytics-status { display: none; padding: 12px 14px; border: 1px solid var(--line); border-radius: 12px; background: var(--soft); color: var(--muted); font-size: 13px; }
.catfolio-analytics-status.is-visible { display: block; }
.catfolio-analytics-status.is-error { color: var(--negative); background: var(--primary-soft); }
.catfolio-analytics-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 18px; min-width: 0; }
.catfolio-analytics-figma { display: grid; grid-column: 1 / -1; grid-template-columns: minmax(0, 586fr) minmax(0, 889fr); gap: 25px; align-items: start; min-width: 0; }
.catfolio-analytics-card { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-radius: 20px; background: var(--panel); }
.catfolio-analytics-card.analytics-wide { grid-column: 1 / -1; }
.catfolio-analytics-card > header { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; padding: 18px 20px 4px; }
.catfolio-analytics-card h2 { margin: 0; font-size: 15px; line-height: 1.35; font-weight: 650; }
.catfolio-analytics-card header p { margin: 4px 0 0; color: var(--muted); font-size: 12px; line-height: 1.45; }
.catfolio-analytics-chart { position: relative; width: 100%; height: 340px; min-width: 0; }
.catfolio-analytics-correlation { height: 520px; }
.catfolio-analytics-drawdown-card, .catfolio-analytics-valuation-card { position: relative; display: flex; height: 545px; min-width: 0; flex-direction: column; gap: 24px; padding: 21px; border-color: var(--line); border-radius: 20px; background: var(--panel); }
.catfolio-analytics-drawdown-card > header, .catfolio-analytics-valuation-card > header { min-height: 46px; align-items: flex-start; padding: 0; }
.catfolio-analytics-drawdown-card h2, .catfolio-analytics-valuation-card h2 { font-size: 18px; line-height: 25px; font-weight: 700; letter-spacing: 0; }
.catfolio-analytics-drawdown-card header p, .catfolio-analytics-valuation-card header p { margin-top: 0; color: #a7a7a7; font-size: 14px; line-height: 19px; font-weight: 600; }
.catfolio-analytics-drawdown-body { display: flex; min-height: 0; flex: 1 1 auto; flex-direction: column; gap: 10px; }
.catfolio-analytics-drawdown-body > .catfolio-analytics-chart { min-height: 0; flex: 1 1 auto; height: auto; }
.catfolio-analytics-drawdown-ranges { display: grid; height: 32px; flex: 0 0 32px; grid-template-columns: repeat(7, 50px); justify-content: center; gap: 7px; }
.catfolio-analytics-drawdown-ranges button { appearance: none; display: grid; width: 50px; min-width: 0; height: 32px; padding: 8px; place-items: center; border: 0; border-radius: 8px; background: transparent; color: color-mix(in srgb, var(--ink) 60%, transparent); font: 700 12px/16px var(--font-sans); cursor: pointer; }
.catfolio-analytics-drawdown-ranges button:hover { background: var(--panel-hover); }
.catfolio-analytics-drawdown-ranges button.active { background: var(--soft); color: var(--ink); font-weight: 800; }
.catfolio-analytics-drawdown-ranges button:focus-visible { outline: 2px solid #708cff; outline-offset: 2px; }
.catfolio-analytics-valuation-card.is-table-expanded { height: auto; }
.catfolio-analytics-valuation-card.is-table-expanded .catfolio-analytics-valuation-chart-wrap { height: 433px; flex: 0 0 433px; }
.catfolio-analytics-valuation-chart-wrap { min-height: 0; flex: 1 1 auto; padding: 0; }
.catfolio-analytics-chart.valuation-matrix-chart { height: 100%; }
.catfolio-analytics-valuation-actions { position: absolute; z-index: 3; top: 16px; right: 52px; display: flex; align-items: center; gap: 8px; opacity: 0; pointer-events: none; transition: opacity 140ms ease; }
.catfolio-analytics-valuation-card:hover .catfolio-analytics-valuation-actions, .catfolio-analytics-valuation-card:focus-within .catfolio-analytics-valuation-actions, .catfolio-analytics-valuation-card.is-table-expanded .catfolio-analytics-valuation-actions { opacity: 1; pointer-events: auto; }
.catfolio-analytics-valuation-details { min-width: 92px; justify-content: center; }
.catfolio-valuation-table-wrap { overflow-x: auto; border-top: 1px solid var(--line); }
.catfolio-valuation-table-wrap[hidden] { display: none; }
.catfolio-valuation-table-wrap:focus-visible { outline: 2px solid #708cff; outline-offset: -2px; }
.catfolio-valuation-table { width: 100%; min-width: 880px; border-collapse: collapse; color: var(--ink); }
.catfolio-valuation-table th, .catfolio-valuation-table td { padding: 13px 20px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: middle; }
.catfolio-valuation-table th { color: var(--muted); background: var(--panel); font-size: 11px; line-height: 16px; font-weight: 700; white-space: nowrap; }
.catfolio-valuation-table td { font-size: 12px; line-height: 17px; font-variant-numeric: tabular-nums; }
.catfolio-valuation-table tbody tr:last-child td { border-bottom: 0; }
.catfolio-valuation-table tbody tr:hover td { background: var(--panel-hover); }
.catfolio-valuation-table th.numeric, .catfolio-valuation-table td.numeric { text-align: right; }
.catfolio-valuation-asset { display: grid; min-width: 150px; }
.catfolio-valuation-asset strong { font-size: 12px; font-weight: 750; }
.catfolio-valuation-asset small { overflow: hidden; margin-top: 2px; color: var(--muted); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.catfolio-valuation-table td.negative, .catfolio-valuation-level.expensive { color: var(--negative); }
.catfolio-valuation-level.cheap { color: var(--positive); }
.catfolio-valuation-level { font-weight: 750; }
.catfolio-valuation-table-empty { height: 100px; color: var(--muted); text-align: center !important; }
@media (max-width: 960px) { .catfolio-analytics-figma { grid-template-columns: minmax(0, 1fr); } .catfolio-analytics-grid { grid-template-columns: minmax(0, 1fr); } }
`;

// ── component demo (设计面板) ───────────────────────────────────────────────
export const DEMO_CSS = `
.catfolio-demo-workspace { min-height: calc(100dvh - 48px); display: flex; flex-direction: column; gap: 10px; color: var(--ink); }
.catfolio-demo-stage { position: relative; width: min(100%, 1220px); height: 610px; margin: 0 auto; display: grid; grid-template-columns: 54px minmax(0, 1fr) 54px; align-items: center; outline: none; }
.catfolio-demo-stage:focus-visible .catfolio-demo-viewport { outline: 2px solid #708cff; outline-offset: 2px; }
.catfolio-demo-viewport { position: relative; width: 100%; height: 590px; min-width: 0; overflow: hidden; border-radius: 20px; touch-action: pan-y; }
.catfolio-demo-track, .catfolio-demo-slide { position: absolute; inset: 0; }
.catfolio-demo-slide { padding: 20px 34px; display: grid; place-items: center; opacity: 0; visibility: hidden; transform: translateX(34px); transition: opacity 220ms ease, transform 260ms cubic-bezier(.22,.68,.22,1), visibility 0s linear 260ms; pointer-events: none; }
.catfolio-demo-slide.is-before { transform: translateX(-34px); }
.catfolio-demo-slide.is-after { transform: translateX(34px); }
.catfolio-demo-slide.is-active { z-index: 2; opacity: 1; visibility: visible; transform: translateX(0); transition-delay: 0s; pointer-events: auto; }
.catfolio-demo-slide > .catfolio-value-card, .catfolio-demo-slide > .catfolio-calendar-card { width: min(100%, 586px); }
.catfolio-demo-slide > .catfolio-analytics-drawdown-card { width: min(100%, 745px); }
.catfolio-demo-slide > .catfolio-holdings-card { width: min(100%, 904px); }
.catfolio-demo-arrow { appearance: none; width: 44px; height: 44px; padding: 0; display: grid; place-items: center; justify-self: center; border: 1px solid var(--line-strong); border-radius: 12px; background: var(--panel); color: var(--ink); cursor: pointer; transition: background-color 150ms ease, border-color 150ms ease, transform 150ms ease; }
.catfolio-demo-arrow:hover { background: var(--soft); transform: translateY(-1px); }
.catfolio-demo-arrow:active { transform: translateY(0); }
.catfolio-demo-arrow img { width: 18px; height: 18px; }
.catfolio-demo-arrow:focus-visible, .catfolio-demo-workspace button:focus-visible { outline: 2px solid #708cff; outline-offset: 2px; }
.catfolio-demo-footer { width: min(100%, 1112px); min-height: 32px; margin: 0 auto; display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; gap: 16px; color: var(--muted); font-size: 12px; font-weight: 700; }
.catfolio-demo-position { justify-self: start; font-variant-numeric: tabular-nums; }
.catfolio-demo-dots { display: flex; align-items: center; gap: 8px; }
.catfolio-demo-dots button { appearance: none; width: 7px; height: 7px; padding: 0; border: 0; border-radius: 999px; background: color-mix(in srgb, var(--ink) 18%, transparent); cursor: pointer; transition: width 180ms ease, background-color 180ms ease; }
.catfolio-demo-dots button.active { width: 24px; background: var(--ink); }
@media (max-width: 760px) {
  .catfolio-demo-stage { height: 650px; display: block; }
  .catfolio-demo-viewport { height: 630px; }
  .catfolio-demo-arrow { position: absolute; z-index: 8; top: 50%; width: 40px; height: 40px; transform: translateY(-50%); }
  .catfolio-demo-arrow:hover { transform: translateY(calc(-50% - 1px)); }
  .catfolio-demo-arrow-prev { left: 8px; }
  .catfolio-demo-arrow-next { right: 8px; }
  .catfolio-demo-slide { padding: 20px 16px; }
}
@media (prefers-reduced-motion: reduce) {
  .catfolio-demo-slide, .catfolio-demo-arrow, .catfolio-demo-dots button { transition: none !important; }
}
`;
