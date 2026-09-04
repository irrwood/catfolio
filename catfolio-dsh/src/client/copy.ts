/** Shared i18n copy and helpers for the catfolio views. */

export type Lang = "zh" | "en";

export function currentLang(): Lang {
  return (document.documentElement.lang || "zh").toLowerCase().startsWith("en") ? "en" : "zh";
}

export const COPY = {
  zh: {
    loading: "正在读取组合数据",
    ready: "组合数据已更新",
    failed: "组合数据暂时不可用",
    today: "今日",
    totalReturn: "总收益率",
    up: "上涨",
    down: "下跌",
    largest: "最大单一仓位",
    noHistory: "暂无可用的成本与市值历史数据",
    market: "持仓市值",
    cost: "持仓成本",
    asOf: "截至",
    holdings: "个持仓",
    exposures: "个底层暴露",
    marketValue: "市值",
    etfValue: "ETF 市值",
    asset: "资产",
    currentPrice: "现价",
    todayShort: "今日",
    profit: "未实现盈亏",
    fxProfit: "汇率盈亏",
    marketValueColumn: "市值",
    weeks: "52 周",
    rangeCurrent: "当前价格",
    rangeLocation: "位于 52 周区间",
    directValue: "直接持有",
    etfExposure: "ETF 间接暴露",
    totalExposure: "总暴露",
    source: "来源",
    etfWeight: "ETF 权重",
    direct: "原始持仓",
    lookthrough: "ETF 穿透",
    loadingHoldings: "正在读取持仓…",
    empty: "暂无可用持仓。",
    holdingsFailed: "持仓加载失败",
    amountSort: "金额",
    percentSort: "比例",
    highToLow: "从高到低",
    lowToHigh: "从低到高",
    profileUnavailable: "暂无成交量分布数据",
    profileTitle: "成交量分布",
    profileVah: "VAH 上沿",
    profilePoc: "POC 峰值",
    profileCost: "持仓成本",
    profileVal: "VAL 下沿",
    calendarLoadError: "收益日历加载失败。",
    calendarNoData: "暂无可用数据",
    months: ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"],
    weekdays: ["日", "一", "二", "三", "四", "五", "六"],
    dayProfit: "当日盈亏",
    summaryMonth: "本月",
    summaryYear: "全年",
    dividends: "股息",
    cashInterest: "现金利息",
    portfolioReturn: "组合净值",
    benchmarkReturn: "基准净值",
    benchmarkNote: "基准：SPY",
    aiButton: "AI 解读",
    aiClosing: "关闭 AI 解读",
    aiStatusEmpty: "",
    aiError: "AI 解读失败",
    aiLoading: "正在生成解读…",
    cashFlowTitle: "现金流匹配对比",
    cashFlowDesc: "按实际交易重放现金流，将组合总价值与同金额投入基准的结果进行比较。",
    chartEmpty: "需要交易流水才能绘制对比。",
    portfolioSeries: "组合",
  },
  en: {
    loading: "Reading portfolio data",
    ready: "Portfolio is up to date",
    failed: "Portfolio data unavailable",
    today: "today",
    totalReturn: "total return",
    up: "Up",
    down: "Down",
    largest: "Largest position",
    noHistory: "Cost and market-value history is not available yet",
    market: "Holdings Market Value",
    cost: "Holdings Cost",
    asOf: "As of",
    holdings: "holdings",
    exposures: "exposures",
    marketValue: "market value",
    etfValue: "ETF value",
    asset: "Asset",
    currentPrice: "Current Price",
    todayShort: "Today",
    profit: "Unreal. P&L",
    fxProfit: "FX P&L",
    marketValueColumn: "Market Value",
    weeks: "52 Weeks",
    rangeCurrent: "Current price",
    rangeLocation: "of the 52-week range",
    directValue: "Direct Value",
    etfExposure: "ETF Exposure",
    totalExposure: "Total Exposure",
    source: "Source",
    etfWeight: "ETF Weight",
    direct: "Direct",
    lookthrough: "Look-through",
    loadingHoldings: "Loading holdings…",
    empty: "No holdings are available.",
    holdingsFailed: "Holdings failed to load",
    amountSort: "amount",
    percentSort: "percentage",
    highToLow: "high to low",
    lowToHigh: "low to high",
    profileUnavailable: "Volume profile unavailable",
    profileTitle: "Volume Profile",
    profileVah: "VAH",
    profilePoc: "POC",
    profileCost: "Cost Price",
    profileVal: "VAL",
    calendarLoadError: "Could not load the profit calendar.",
    calendarNoData: "No data available",
    months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
    weekdays: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
    dayProfit: "Daily P/L",
    summaryMonth: "Month",
    summaryYear: "Year",
    dividends: "Dividends",
    cashInterest: "Cash interest",
    portfolioReturn: "Portfolio NAV",
    benchmarkReturn: "Benchmark NAV",
    benchmarkNote: "Benchmark: SPY",
    aiButton: "AI Explain",
    aiClosing: "Close AI explanation",
    aiStatusEmpty: "",
    aiError: "AI explanation failed",
    aiLoading: "Generating explanation…",
    cashFlowTitle: "Cash-flow matched comparison",
    cashFlowDesc: "Replays cash flows from actual trades to compare total portfolio value against the same amount invested in the benchmark.",
    chartEmpty: "Trade history is required to draw the comparison.",
    portfolioSeries: "Portfolio",
  },
} as const;

export function t(key: keyof (typeof COPY)["zh"]): string {
  const lang = currentLang();
  return (COPY[lang] as Record<string, string>)[key] ?? (COPY.zh as Record<string, string>)[key] ?? key;
}

/** Escape HTML for table cell content. */
export function escapeHtml(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[character] as string);
}

export function numeric(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

export function localeString(): string {
  return currentLang() === "en" ? "en-GB" : "zh-CN";
}

export function money(value: unknown): string {
  const amount = numeric(value);
  return `${amount < 0 ? "-" : ""}$${Math.abs(amount).toLocaleString(localeString(), { maximumFractionDigits: 0 })}`;
}

export function preciseMoney(value: unknown): string {
  const amount = numeric(value);
  return `${amount < 0 ? "-" : ""}$${Math.abs(amount).toLocaleString(localeString(), { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function signedMoney(value: unknown): string {
  const amount = numeric(value);
  return `${amount >= 0 ? "+" : "-"}$${Math.abs(amount).toLocaleString(localeString(), { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function signedPercent(value: unknown): string {
  const amount = numeric(value);
  return `${amount >= 0 ? "+" : ""}${amount.toFixed(1)}%`;
}

export function ratioPercent(value: unknown): string {
  return `${(numeric(value) * 100).toFixed(1)}%`;
}

export function formatNumber(value: unknown, maximumFractionDigits = 2, minimumFractionDigits = 0): string {
  return numeric(value).toLocaleString(localeString(), { maximumFractionDigits, minimumFractionDigits });
}

/** Deterministic hue for a ticker's letter badge. */
export function tickerHue(ticker: string): number {
  return Array.from(String(ticker || "?")).reduce((total, character) => total + character.charCodeAt(0) * 17, 0) % 360;
}

/** Native price display handling GBX pence. */
export function nativePrice(value: unknown, currency: unknown, minDigits = 2): string {
  if (value === null || value === undefined || value === "") return "—";
  const code = String(currency || "USD").toUpperCase();
  const amount = code === "GBX" ? numeric(value) / 100 : numeric(value);
  const displayCurrency = code === "GBX" ? "GBP" : code;
  const symbols: Record<string, string> = { USD: "$", GBP: "£", EUR: "€", JPY: "¥", CNY: "¥" };
  const formatted = formatNumber(amount, 2, minDigits);
  return symbols[displayCurrency] ? `${symbols[displayCurrency]}${formatted}` : `${formatted} ${displayCurrency}`;
}

export function rangePrice(value: unknown, currency: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  const amount = formatNumber(value, 2, 2);
  if (currency === "USD") return `$${amount}`;
  if (currency === "GBP") return `£${amount}`;
  if (currency === "EUR") return `€${amount}`;
  if (currency === "GBX") return `£${formatNumber(numeric(value) / 100, 2, 2)}`;
  return amount;
}

export interface RangePosition {
  position: number | null;
  percentage: number;
}

export function rangePosition(row: Record<string, unknown>): number | null {
  const low = Number(row.low_52w);
  const high = Number(row.high_52w);
  const price = Number(row.quote_price);
  if (![low, high, price].every(Number.isFinite) || high <= low) return null;
  return Math.max(0, Math.min(1, (price - low) / (high - low)));
}
