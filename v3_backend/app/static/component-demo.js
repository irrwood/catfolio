/*
 * Isolated portfolio component demo.
 *
 * The four cards are the same product markup/scripts used by /lab and
 * /analytics. This file only supplies deterministic front-end data and the
 * carousel shell; it never calls the live API.
 */
(() => {
  window.__CATFOLIO_COMPONENT_DEMO__ = true;

  const fakeDirectHoldings = [
    {
      ticker: "NVDA", company_name: "NVIDIA", shares: 84, quote_price: 118.42, avg_cost_native: 91.6,
      quote_currency: "USD", cost_currency: "USD", today_change_percent: 2.4, unrealized_usd: 2252.88,
      unrealized_percent: 29.3, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 9957.28,
      weight: 0.117, low_52w: 75.61, high_52w: 153.13,
    },
    {
      ticker: "MSFT", company_name: "Microsoft", shares: 22, quote_price: 418.31, avg_cost_native: 352.24,
      quote_currency: "USD", cost_currency: "USD", today_change_percent: -0.6, unrealized_usd: 1453.54,
      unrealized_percent: 18.7, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 9202.82,
      weight: 0.108, low_52w: 344.77, high_52w: 468.35,
    },
    {
      ticker: "AAPL", company_name: "Apple", shares: 36, quote_price: 211.15, avg_cost_native: 184.5,
      quote_currency: "USD", cost_currency: "USD", today_change_percent: 1.1, unrealized_usd: 959.4,
      unrealized_percent: 14.5, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 7601.4,
      weight: 0.089, low_52w: 164.08, high_52w: 260.1,
    },
    {
      ticker: "AMZN", company_name: "Amazon", shares: 32, quote_price: 198.77, avg_cost_native: 171.8,
      quote_currency: "USD", cost_currency: "USD", today_change_percent: 0.8, unrealized_usd: 863.04,
      unrealized_percent: 15.7, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 6360.64,
      weight: 0.075, low_52w: 151.61, high_52w: 242.52,
    },
    {
      ticker: "VTI", company_name: "Vanguard Total Stock Market ETF", shares: 28, quote_price: 301.82, avg_cost_native: 267.45,
      quote_currency: "USD", cost_currency: "USD", today_change_percent: -0.2, unrealized_usd: 962.36,
      unrealized_percent: 12.9, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 8450.96,
      weight: 0.099, low_52w: 223.74, high_52w: 302.22,
    },
    {
      ticker: "TSLA", company_name: "Tesla", shares: 18, quote_price: 286.74, avg_cost_native: 242.15,
      quote_currency: "USD", cost_currency: "USD", today_change_percent: 3.7, unrealized_usd: 802.62,
      unrealized_percent: 18.4, broker_fx_ppl_usd: 0, broker_fx_ppl_percent: 0, market_value_usd: 5161.32,
      weight: 0.061, low_52w: 182.0, high_52w: 488.54,
    },
  ];

  const fakeLookthrough = [
    { ticker: "NVDA", company_name: "NVIDIA", total_usd: 11830.2 },
    { ticker: "MSFT", company_name: "Microsoft", total_usd: 10480.1 },
    { ticker: "AAPL", company_name: "Apple", total_usd: 9360.4 },
    { ticker: "AMZN", company_name: "Amazon", total_usd: 7520.8 },
    { ticker: "TSLA", company_name: "Tesla", total_usd: 6240.3 },
    { ticker: "META", company_name: "Meta Platforms", total_usd: 4780.6 },
    { ticker: "AVGO", company_name: "Broadcom", total_usd: 4210.7 },
  ];

  const baseDate = new Date(Date.UTC(2026, 3, 30));
  const isoDate = offset => {
    const date = new Date(baseDate);
    date.setUTCDate(date.getUTCDate() + offset);
    return date.toISOString().slice(0, 10);
  };

  const history = Array.from({ length: 92 }, (_, index) => {
    const phase = index / 10;
    const cost = 74200 + index * 43 + Math.sin(phase) * 320;
    const market = cost + 3900 + Math.sin(phase * 1.7) * 900 - Math.max(0, Math.sin(phase * 0.72)) * 1050;
    return { date: isoDate(index - 91), market_value_usd: Math.round(market), cost_usd: Math.round(cost) };
  });

  const calendarRows = Array.from({ length: 30 }, (_, index) => {
    const amount = Math.round(Math.sin(index * 1.47) * 280 + Math.cos(index * 0.38) * 75);
    return {
      date: `2026-04-${String(index + 1).padStart(2, "0")}`,
      pnl_usd: amount,
      return: amount / 18000,
    };
  });

  const drawdownRows = Array.from({ length: 92 }, (_, index) => ({
    date: isoDate(index - 91),
    drawdown: -Math.max(0, (Math.sin(index / 8) + 0.33 * Math.sin(index / 2.7) - 0.18) * 0.31),
  }));

  const fakePortfolioOverview = {
    summary: {
      market_value_usd: 84728.42,
      unrealized_usd: 7293.84,
      total_cost_usd_standard: 77434.58,
      open_positions: fakeDirectHoldings.length,
    },
    today_pnl_usd: 416.24,
    breadth: { up: 4, down: 2, flat: 0 },
    top_holdings: fakeDirectHoldings,
  };

  const fakeAnalytics = {
    monthly_returns: { rows: [] },
    drawdown: { max_drawdown: -0.253, rows: drawdownRows },
    profit_calendar: {
      rows: calendarRows,
      income: {
        monthly_rows: [{ month: "2026-04", dividends_usd: 342.5, cash_interest_usd: 46.2 }],
        rows: [{ year: 2026, dividends_usd: 342.5, cash_interest_usd: 46.2 }],
      },
    },
    correlation_matrix: { symbols: [], matrix: [] },
    return_distribution: { bins: [] },
    waterfall: { rows: [] },
  };

  const fakeResponses = {
    "/api/portfolio/overview": fakePortfolioOverview,
    "/api/portfolio/chart": {
      basis: "component-demo",
      position_count: fakeDirectHoldings.length,
      position_history: { rows: history },
      current_point: { date: history.at(-1).date, market_value_usd: 84728.42, cost_usd: 77434.58 },
    },
    "/api/holdings/detail": {
      summary: { market_value_usd: 84728.42 },
      rows: fakeDirectHoldings,
    },
    "/api/etf-lookthrough": { etf_total_usd: 44423.1, rows: fakeLookthrough },
    "/api/analytics": fakeAnalytics,
    "/api/profit-calendar": fakeAnalytics,
    "/api/holdings/heatmap": { rows: [] },
    "/api/refresh/fundamentals": { rows: [] },
  };

  const nativeFetch = window.fetch?.bind(window);
  const responseFor = payload => new Response(JSON.stringify(payload), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });

  window.fetch = (resource, options) => {
    const rawUrl = typeof resource === "string" ? resource : resource?.url;
    const url = new URL(rawUrl || "", window.location.href);
    const key = url.pathname === "/api/etf-lookthrough" ? url.pathname : url.pathname;
    if (url.pathname.endsWith("/volume-profile")) {
      return Promise.resolve(responseFor({ available: false }));
    }
    const payload = fakeResponses[key];
    if (payload !== undefined) return Promise.resolve(responseFor(payload));
    return nativeFetch ? nativeFetch(resource, options) : Promise.reject(new Error("fetch unavailable"));
  };

  const slides = Array.from(document.querySelectorAll("[data-demo-slide]"));
  const dots = Array.from(document.querySelectorAll("[data-demo-go]"));
  const position = document.getElementById("componentDemoPosition");
  const stage = document.querySelector(".component-demo-stage");
  let current = 0;

  function showSlide(next, direction = next >= current ? 1 : -1) {
    if (!slides.length) return;
    const target = (next + slides.length) % slides.length;
    slides.forEach((slide, index) => {
      const active = index === target;
      const before = !active && (direction > 0 ? index < target : index > target);
      slide.classList.toggle("is-active", active);
      slide.classList.toggle("is-before", before);
      slide.classList.toggle("is-after", !active && !before);
      slide.setAttribute("aria-hidden", active ? "false" : "true");
      slide.inert = !active;
    });
    dots.forEach((dot, index) => {
      const active = index === target;
      dot.classList.toggle("active", active);
      dot.setAttribute("aria-selected", active ? "true" : "false");
    });
    if (position) position.textContent = `${String(target + 1).padStart(2, "0")} / ${String(slides.length).padStart(2, "0")}`;
    current = target;
    window.setTimeout(() => window.dispatchEvent(new Event("resize")), 30);
  }

  document.getElementById("componentDemoPrev")?.addEventListener("click", () => showSlide(current - 1, -1));
  document.getElementById("componentDemoNext")?.addEventListener("click", () => showSlide(current + 1, 1));
  dots.forEach(dot => dot.addEventListener("click", () => {
    const target = Number(dot.dataset.demoGo);
    showSlide(target, target >= current ? 1 : -1);
  }));
  stage?.addEventListener("keydown", event => {
    if (event.key === "ArrowLeft") { event.preventDefault(); showSlide(current - 1, -1); }
    if (event.key === "ArrowRight") { event.preventDefault(); showSlide(current + 1, 1); }
  });
  document.addEventListener("keydown", event => {
    if (event.defaultPrevented || event.target.closest("input, textarea, select, [contenteditable='true']")) return;
    if (event.key === "ArrowLeft") showSlide(current - 1, -1);
    if (event.key === "ArrowRight") showSlide(current + 1, 1);
  });

  let touchStartX = null;
  document.getElementById("componentDemoViewport")?.addEventListener("touchstart", event => {
    touchStartX = event.changedTouches[0]?.clientX ?? null;
  }, { passive: true });
  document.getElementById("componentDemoViewport")?.addEventListener("touchend", event => {
    if (touchStartX === null) return;
    const delta = (event.changedTouches[0]?.clientX ?? touchStartX) - touchStartX;
    if (Math.abs(delta) > 42) showSlide(current + (delta < 0 ? 1 : -1), delta < 0 ? 1 : -1);
    touchStartX = null;
  }, { passive: true });

  showSlide(0, 1);
})();
