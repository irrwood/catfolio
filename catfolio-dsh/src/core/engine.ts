/**
 * Catfolio analytics engine — pure TypeScript port of the Python analytics.
 *
 * This module is the "Rust-ready" seam of the plugin: every payload the plugin
 * serves is produced by pure functions over the embedded demo snapshot and
 * price history. A future Rust core (N-API addon) can replace this module by
 * implementing the same `CatfolioEngine` interface.
 *
 * All functions are deterministic and free of I/O; the server half feeds them
 * the demo data and serializes their output.
 */

export type Json = Record<string, unknown>;

/** Snapshot shape: `portfolio`, `market`, `fundamentals`, `trading212`. */
export interface Snapshot extends Json {
  portfolio: {
    summary: Json;
    holdings: Json[];
    holdings_by_account?: Json[];
  };
  market: { rows: Json[]; as_of_unix?: number };
  fundamentals: { rows: Json[] };
  trading212: {
    positions: Json[];
    account_cash: Record<string, Json>;
    account_info: Record<string, Json>;
    summary: Json;
  };
}

export interface LabHistory {
  prices: Record<string, { date: string; close: number; open?: number; high?: number; low?: number; volume?: number }[]>;
  as_of_unix?: number;
  source?: string;
}

export interface IncomeSummary {
  currency: string;
  rows: { year: string; dividends_usd: number; cash_interest_usd: number }[];
  monthly_rows: { month: string; dividends_usd: number; cash_interest_usd: number }[];
}

export interface Sp500Dataset {
  rows: { ticker: string; name: string; sector?: string; weight_percent: number }[];
  as_of?: string;
  source?: string;
  source_url?: string;
}

// ── constants (ported from analytics.py / lab.py) ───────────────────────────

export const BENCHMARKS: Record<string, string> = {
  SPY: "S&P 500",
  QQQ: "Nasdaq 100",
  VTI: "US Total Market",
  VOO: "Vanguard S&P 500",
  DIA: "Dow Jones 30",
  IWM: "US Small Cap",
  VEU: "World ex-US",
  GLD: "Gold",
};

export const SP500_ETF_TICKERS = new Set(["VUAG", "VUSA"]);

const SECTOR_BY_TICKER: Record<string, string> = {
  AAPL: "Technology", AVGO: "Technology", CHKP: "Technology", GOOG: "Communication Services",
  GOOGL: "Communication Services", META: "Communication Services", MRVL: "Technology",
  MSFT: "Technology", NVDA: "Technology", ORCL: "Technology", PANW: "Technology",
  QCOM: "Technology", SNOW: "Technology", ZS: "Technology", BARC: "Financials",
  BATS: "Consumer Staples", "BRK.B": "Financials", "BRK-B": "Financials", CEG: "Utilities",
  CLS: "Technology", EQGB: "ETF / Multi-Asset", FTNT: "Technology", GAW: "Consumer Discretionary",
  GSK: "Healthcare", LGEN: "Financials", LLOY: "Financials", MNG: "Financials",
  NG: "Utilities", NXT: "Consumer Discretionary", OKTA: "Technology", OSB: "Financials",
  PHNX: "Financials", PHP: "Real Estate", RR: "Industrials", RWE: "Utilities",
  SGLN: "Commodities", SIE: "Industrials", SILG: "Commodities", VUAG: "ETF / S&P 500",
  VUSA: "ETF / S&P 500", VHVG: "ETF / Global Equity", VEUA: "ETF / Europe Equity",
  XUSE: "ETF / S&P 500", NOK: "Communication Equipment", GEV: "Industrials",
  AES: "Utilities", ANAE: "ETF / Clean Energy", ANRJ: "ETF / Clean Energy",
  AV: "Financials", CNA: "Utilities", CNX1: "ETF / Nasdaq 100", CUKX: "ETF / UK Equity",
  ENL1: "Utilities", ENR: "Industrials", FPP: "Consumer Discretionary",
  IBEE: "ETF / Clean Energy", IITU: "ETF / Technology", SOHO: "Real Estate",
  SPGP: "Commodities", SSLN: "Commodities", VIEP: "ETF / Europe Equity",
};

const CN_NAME_BY_TICKER: Record<string, string> = {
  AES: "爱依斯", ANAE: "新能源ETF", ANRJ: "全球氢能ETF", AV: "英杰华", BARC: "巴克莱",
  BATS: "英美烟草", "BRK.B": "伯克希尔哈撒韦B", "BRK-B": "伯克希尔哈撒韦B", CEG: "星座能源",
  CHKP: "Check Point 网络安全", CLS: "天弘科技", CNA: "森特理克", CNX1: "纳斯达克100ETF",
  CUKX: "富时100ETF", ENL1: "德国综合能源", ENR: "西门子能源", EQGB: "纳斯达克100ETF",
  FPP: "波兰服装零售", FTNT: "飞塔", GAW: "战锤母公司", GEV: "GE Vernova 能源",
  GOOG: "谷歌C", GSK: "葛兰素史克", IBEE: "清洁能源ETF", IITU: "标普500科技ETF",
  LGEN: "英杰华法通", LLOY: "劳埃德银行", META: "Meta 平台", MNG: "M&G 资产管理",
  MRVL: "美满电子", MSFT: "微软", NG: "英国国家电网", NOK: "诺基亚", NVDA: "英伟达",
  NXT: "Next 零售", OKTA: "Okta 身份云", ORCL: "甲骨文", OSB: "OSB 银行",
  PANW: "Palo Alto 网络安全", PHNX: "凤凰集团", PHP: "Primary Health 医疗地产",
  QCOM: "高通", RR: "劳斯莱斯", RWE: "莱茵集团", SGLN: "实物黄金ETF", SIE: "西门子",
  SILG: "白银矿业ETF", SNOW: "Snowflake 云数据", SOHO: "社会住房REIT",
  SPGP: "黄金矿商ETF", SSLN: "实物白银ETF", VEUA: "发达欧洲ETF", VHVG: "发达市场ETF",
  VIEP: "欧洲股息ETF", VUAG: "标普500累积型", VUSA: "标普500派息型",
  XUSE: "全球除美国ETF", ZS: "Zscaler 零信任安全",
};

export const ASSET_ALIASES: Record<string, string> = {
  "VUAG.L": "S&P 500 Fund",
  "VUSA.L": "S&P 500 Fund",
};

const REPORT_FX_TO_USD: Record<string, number> = {
  USD: 1.0,
  GBP: 1.346,
  GBX: 0.01346,
  EUR: 1.163,
};

// ── numeric helpers ─────────────────────────────────────────────────────────

export function num(value: unknown): number {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function optionalNum(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function mean(values: number[]): number {
  if (!values.length) return 0;
  return values.reduce((a, b) => a + b, 0) / values.length;
}

function stdev(values: number[]): number {
  if (values.length < 2) return 0;
  const avg = mean(values);
  const variance = values.reduce((a, b) => a + (b - avg) ** 2, 0) / (values.length - 1);
  return Math.sqrt(variance);
}

/** Python-style round (round-half-even at the requested decimal place). */
export function pyRound(value: number, ndigits = 0): number {
  const factor = 10 ** ndigits;
  const scaled = value * factor;
  const floored = Math.floor(scaled);
  const diff = scaled - floored;
  let result: number;
  if (diff < 0.5) result = floored;
  else if (diff > 0.5) result = floored + 1;
  else result = floored % 2 === 0 ? floored : floored + 1;
  return result / factor;
}

function baseTicker(ticker: string): string {
  return (ticker || "").replace(".L", "").replace("_EQ", "");
}

function displayName(ticker: string, name: string): string {
  const cn = CN_NAME_BY_TICKER[baseTicker(ticker)];
  if (cn && name) return `${cn} / ${name}`;
  if (cn) return cn;
  return name || ticker;
}

// ── market / holdings index helpers ─────────────────────────────────────────

function marketByTicker(snapshot: Snapshot): Record<string, Json> {
  const rows: Record<string, Json> = {};
  for (const row of snapshot.market.rows) {
    if (row.ticker) rows[String(row.ticker)] = row;
  }
  return rows;
}

function holdingsByTicker(snapshot: Snapshot): Record<string, Json> {
  const rows: Record<string, Json> = {};
  for (const row of snapshot.portfolio.holdings) {
    if (row.ticker) rows[String(row.ticker)] = row;
  }
  return rows;
}

function exposureValueUsd(ticker: string, snapshot: Snapshot, basis: "market" | "cost" = "market"): number {
  const holdings = holdingsByTicker(snapshot);
  const market = marketByTicker(snapshot);
  if (basis === "market") {
    const row = market[ticker] ?? {};
    if (row.market_value_usd !== undefined && row.market_value_usd !== null) return num(row.market_value_usd);
    const holding = holdings[ticker] ?? {};
    if (holding.api_market_value_usd !== undefined && holding.api_market_value_usd !== null) {
      return num(holding.api_market_value_usd);
    }
  }
  return num((holdings[ticker] ?? {}).cost_usd_standard);
}

function brokerPnlByTicker(snapshot: Snapshot): Record<string, Json> {
  const rows: Record<string, Json> = {};
  const trading212 = snapshot.trading212;
  const accountCash = trading212.account_cash ?? {};
  const accountInfo = trading212.account_info ?? {};
  for (const position of trading212.positions) {
    const ticker = String(position.normalized_ticker || position.ticker || "").toUpperCase();
    if (!ticker) continue;
    const ppl = optionalNum(position.ppl);
    if (ppl === null) continue;
    const account = String(position.account || "Trading212 API");
    const cash = accountCash[account] ?? {};
    const info = accountInfo[account] ?? {};
    const currency = String(
      cash.currencyCode ?? info.currencyCode ?? "GBP"
    ).toUpperCase();
    const rate = REPORT_FX_TO_USD[currency];
    if (rate === undefined) continue;
    const fxPpl = optionalNum(position.fx_ppl);
    const target = rows[ticker] ?? {
      broker_unrealized_usd: 0,
      broker_fx_ppl_usd: 0,
      broker_pnl_currencies: new Set<string>(),
      broker_ppl_includes_fx: true,
    };
    target.broker_unrealized_usd += ppl * rate;
    if (fxPpl !== null) target.broker_fx_ppl_usd += fxPpl * rate;
    target.broker_pnl_currencies.add(currency);
  }
  for (const [ticker, target] of Object.entries(rows)) {
    const currencies = [...target.broker_pnl_currencies].sort();
    delete target.broker_pnl_currencies;
    target.broker_pnl_currency = currencies.length === 1 ? currencies[0] : "MIXED";
  }
  // Portable fallback: persisted broker fields on holdings win over machine-local data.
  for (const holding of snapshot.portfolio.holdings) {
    const ticker = String(holding.ticker || "").toUpperCase();
    if (!ticker || rows[ticker]) continue;
    const brokerUsd = optionalNum(holding.broker_unrealized_usd);
    if (brokerUsd === null) continue;
    rows[ticker] = {
      broker_unrealized_usd: brokerUsd,
      broker_fx_ppl_usd: num(holding.broker_fx_ppl_usd),
      broker_pnl_currency: holding.broker_unrealized_currency ?? "USD",
      broker_ppl_includes_fx: holding.broker_ppl_includes_fx !== false,
    };
  }
  return rows;
}

// ── portfolio summary ───────────────────────────────────────────────────────

export function portfolioSummary(snapshot: Snapshot): Json {
  const summary = { ...snapshot.portfolio.summary };
  const market = marketByTicker(snapshot);
  const holdings = holdingsByTicker(snapshot);
  const brokerPnl = brokerPnlByTicker(snapshot);

  let marketTotal = 0;
  for (const [ticker, holding] of Object.entries(holdings)) {
    marketTotal +=
      holding.api_market_value_usd !== undefined && holding.api_market_value_usd !== null
        ? num(holding.api_market_value_usd)
        : num(market[ticker]?.market_value_usd);
  }
  if (!Object.keys(holdings).length) {
    marketTotal = Object.values(market).reduce((sum, row) => sum + num(row.market_value_usd), 0);
  }
  const costTotal = num(summary.total_cost_usd_standard);
  const priceUnrealizedTotal = marketTotal - costTotal;
  let unrealizedTotal = 0;
  let brokerPositions = 0;
  for (const [ticker, holding] of Object.entries(holdings)) {
    const brokerRow = brokerPnl[ticker];
    if (brokerRow) {
      unrealizedTotal += num(brokerRow.broker_unrealized_usd);
      brokerPositions += 1;
      continue;
    }
    const marketValue = num(market[ticker]?.market_value_usd);
    unrealizedTotal += marketValue - num(holding.cost_usd_standard);
  }

  const holdingCount = Object.keys(holdings).length;
  summary.market_value_usd = marketTotal;
  summary.unrealized_usd = unrealizedTotal;
  summary.broker_unrealized_usd = Object.values(brokerPnl).reduce(
    (sum, row) => sum + num(row.broker_unrealized_usd), 0,
  );
  summary.broker_fx_ppl_usd = Object.values(brokerPnl).reduce(
    (sum, row) => sum + num(row.broker_fx_ppl_usd), 0,
  );
  summary.price_unrealized_usd = priceUnrealizedTotal;
  summary.unrealized_includes_fx = brokerPositions > 0;
  summary.unrealized_source =
    brokerPositions === holdingCount && holdingCount > 0
      ? "trading212_ppl"
      : brokerPositions > 0
        ? "mixed"
        : "price_difference";
  summary.trading212_positions = snapshot.trading212.summary?.positions;
  summary.broker_positions = snapshot.trading212.positions.length;
  summary.cash = snapshot.trading212.account_cash ?? {};
  return summary;
}

// ── holdings detail ─────────────────────────────────────────────────────────

export function holdingsDetail(snapshot: Snapshot): { rows: Json[] } {
  const holdings = holdingsByTicker(snapshot);
  const market = marketByTicker(snapshot);
  let total = 0;
  for (const row of Object.values(market)) total += num(row.market_value_usd);
  const brokerPnl = brokerPnlByTicker(snapshot);
  const rows: Json[] = [];
  for (const [ticker, holding] of Object.entries(holdings)) {
    const marketRow = market[ticker] ?? {};
    const marketValue = num(marketRow.market_value_usd) || num(holding.api_market_value_usd);
    const cost = num(holding.cost_usd_standard);
    const companyName =
      marketRow.company_name || marketRow.name || holding.company_name || holding.name || ticker;
    const priceUnrealized = marketValue - cost;
    const brokerRow = brokerPnl[ticker];
    const unrealized = brokerRow ? num(brokerRow.broker_unrealized_usd) : priceUnrealized;
    rows.push({
      ticker,
      logo_symbol: holding.yahoo_symbol || ticker,
      name: holding.name || ticker,
      company_name: String(companyName),
      display_name: displayName(ticker, String(holding.name || ticker)),
      sector: SECTOR_BY_TICKER[baseTicker(ticker)] ?? "Other / Unclassified",
      shares: num(holding.shares),
      cost_usd: cost,
      avg_cost_usd: num(holding.avg_cost_usd_standard),
      avg_cost_native: num(holding.avg_cost_native),
      cost_currency: holding.cost_currency || holding.price_currency,
      cost_native: num(holding.cost_native),
      accounts: holding.accounts || holding.account || "",
      last_trade_time: holding.last_trade_time,
      quote_price: marketRow.quote_price,
      quote_currency: marketRow.quote_currency || holding.price_currency,
      today_change_percent: marketRow.change_percent,
      market_value_usd: marketValue,
      weight: total ? marketValue / total : 0,
      unrealized_usd: unrealized,
      unrealized_percent: cost ? (unrealized / cost) * 100 : null,
      broker_unrealized_usd: brokerRow ? num(brokerRow.broker_unrealized_usd) : null,
      broker_fx_ppl_usd: brokerRow ? num(brokerRow.broker_fx_ppl_usd) : null,
      broker_fx_ppl_percent: brokerRow && cost ? (num(brokerRow.broker_fx_ppl_usd) / cost) * 100 : null,
      broker_ppl_includes_fx: Boolean(brokerRow),
      broker_pnl_currency: brokerRow?.broker_pnl_currency ?? null,
      price_unrealized_usd: priceUnrealized,
      price_unrealized_percent: cost ? (priceUnrealized / cost) * 100 : null,
      volume: marketRow.volume,
      avg_volume_3m: marketRow.avg_volume_3m,
      market_cap: marketRow.market_cap,
      high_52w: marketRow.high_52w,
      low_52w: marketRow.low_52w,
    });
  }
  rows.sort((a, b) => num(b.market_value_usd) - num(a.market_value_usd));
  return { rows };
}

// ── holdings detail payload (matches GET /api/holdings/detail) ─────────────

export function holdingsDetailPayload(snapshot: Snapshot): Json {
  return {
    summary: portfolioSummary(snapshot),
    rows: holdingsDetail(snapshot).rows,
  };
}

// ── sector concentration ────────────────────────────────────────────────────

export function sectorConcentration(snapshot: Snapshot): Json {
  const market = marketByTicker(snapshot);
  let total = 0;
  for (const row of Object.values(market)) total += num(row.market_value_usd);
  const sectors: Record<string, number> = {};
  for (const [ticker, row] of Object.entries(market)) {
    const sector = SECTOR_BY_TICKER[baseTicker(ticker)] ?? "Other / Unclassified";
    sectors[sector] = (sectors[sector] ?? 0) + num(row.market_value_usd);
  }
  const rows = Object.entries(sectors)
    .map(([sector, value]) => ({ sector, market_value_usd: value, weight: total ? value / total : 0 }))
    .sort((a, b) => b.market_value_usd - a.market_value_usd);
  return { rows, coverage_note: "Sector map is local and approximate for MVP." };
}

// ── ETF look-through ────────────────────────────────────────────────────────

export function etfLookthrough(snapshot: Snapshot, basis: "cost" | "market" = "cost", dataset: Sp500Dataset): Json {
  const holdings = holdingsByTicker(snapshot);
  let etfTotal = 0;
  for (const ticker of SP500_ETF_TICKERS) etfTotal += exposureValueUsd(ticker, snapshot, basis);
  const direct: Record<string, number> = {};
  for (const ticker of Object.keys(holdings)) {
    if (!SP500_ETF_TICKERS.has(ticker)) direct[ticker] = exposureValueUsd(ticker, snapshot, basis);
  }
  const constituentRows = dataset.rows?.length
    ? dataset.rows
    : [];
  const rows: Json[] = [];
  let usedWeight = 0;
  for (const constituent of constituentRows) {
    const ticker = String(constituent.ticker || "").toUpperCase();
    if (!ticker) continue;
    const name = constituent.name || ticker;
    const weight = num(constituent.weight_percent);
    usedWeight += weight;
    const fromEtf = (etfTotal * weight) / 100;
    const directValue = direct[ticker] ?? 0;
    const holding = holdings[ticker] ?? {};
    rows.push({
      ticker,
      name: holding.name || name,
      direct_usd: directValue,
      from_etf_usd: fromEtf,
      total_usd: directValue + fromEtf,
      etf_weight_percent: weight,
      sector: constituent.sector,
    });
  }
  const otherWeight = Math.max(0, 100 - usedWeight);
  if (otherWeight > 0.001) {
    rows.push({
      ticker: "ETF 其他",
      name: "基金现金及衍生品",
      direct_usd: 0,
      from_etf_usd: (etfTotal * otherWeight) / 100,
      total_usd: (etfTotal * otherWeight) / 100,
      etf_weight_percent: otherWeight,
      sector: "ETF / Other",
    });
  }
  const rowTickers = new Set(rows.map((row) => String(row.ticker)));
  for (const [ticker, value] of Object.entries(direct)) {
    if (rowTickers.has(ticker)) continue;
    const holding = holdings[ticker] ?? {};
    rows.push({
      ticker,
      logo_symbol: holding.yahoo_symbol || ticker,
      name: holding.name || ticker,
      direct_usd: value,
      from_etf_usd: 0,
      total_usd: value,
      etf_weight_percent: 0,
    });
  }
  rows.sort((a, b) => num(b.total_usd) - num(a.total_usd));
  return {
    basis,
    etf_tickers: [...SP500_ETF_TICKERS].sort(),
    etf_total_usd: etfTotal,
    covered_weight_percent: usedWeight,
    other_weight_percent: otherWeight,
    constituent_count: constituentRows.length,
    holdings_as_of: dataset.as_of,
    holdings_source: dataset.source,
    holdings_source_url: dataset.source_url,
    rows,
  };
}

// ── open positions history (backcast) ───────────────────────────────────────

export function currentOpenPositionsHistory(snapshot: Snapshot, history: LabHistory): Json {
  const prices = history.prices ?? {};
  const holdingsByAccount = snapshot.portfolio.holdings_by_account ?? snapshot.portfolio.holdings;
  const rawPositions = snapshot.trading212.positions ?? [];
  const initialFillByKey: Record<string, string> = {};
  for (const row of rawPositions) {
    if (!row.ticker || !row.initial_fill_date) continue;
    initialFillByKey[`${String(row.account || "")}|${String(row.ticker || "")}`] = String(
      row.initial_fill_date,
    ).slice(0, 10);
  }
  const fxToUsd = { ...REPORT_FX_TO_USD };
  const positions: { start_date: string; symbol: string; shares: number; cost_usd: number; fx: number }[] = [];
  for (const holding of holdingsByAccount) {
    const account = String(holding.account || holding.accounts || "");
    const apiTicker = String(holding.api_ticker || "");
    const startDate = initialFillByKey[`${account}|${apiTicker}`];
    const symbol = holding.yahoo_symbol || holding.ticker;
    if (!startDate || !symbol) continue;
    positions.push({
      start_date: startDate,
      symbol: String(symbol),
      shares: num(holding.shares),
      cost_usd: num(holding.cost_usd_standard),
      fx: fxToUsd[String(holding.cost_currency || "USD")] ?? 1,
    });
  }
  if (!positions.length) return { available: false, rows: [], basis: "current_open_positions_excluding_cash" };

  const priceBySymbol: Record<string, Record<string, number>> = {};
  for (const [symbol, rows] of Object.entries(prices)) {
    const byDate: Record<string, number> = {};
    for (const row of rows) {
      if (row.date && row.close !== undefined && row.close !== null) byDate[String(row.date)] = Number(row.close);
    }
    priceBySymbol[symbol] = byDate;
  }
  const allDates = new Set<string>();
  for (const byDate of Object.values(priceBySymbol)) for (const date of Object.keys(byDate)) allDates.add(date);
  const dates = [...allDates].sort();
  const earliestStart = Math.min(...positions.map((p) => p.start_date));
  const rows: Json[] = [];
  const lastClose: Record<string, number> = {};
  for (const date of dates) {
    if (date < earliestStart) continue;
    let marketValue = 0;
    let positionCost = 0;
    let activePositions = 0;
    for (const position of positions) {
      if (date < position.start_date) continue;
      activePositions += 1;
      positionCost += position.cost_usd;
      let close = priceBySymbol[position.symbol]?.[date];
      if (close !== undefined && close !== null) {
        lastClose[position.symbol] = close;
      } else {
        close = lastClose[position.symbol];
      }
      marketValue += close !== undefined ? position.shares * close * position.fx : position.cost_usd;
    }
    if (activePositions) {
      rows.push({ date, market_value_usd: marketValue, cost_usd: positionCost });
    }
  }
  return {
    available: rows.length > 0,
    rows,
    basis: "current_open_positions_backcast_from_initial_fill_excluding_cash",
    position_count: positions.length,
  };
}

// ── returns / benchmark machinery ───────────────────────────────────────────

export function returnsFromPrices(priceRows: { date: string; close: number }[]): Record<string, number> {
  const returns: Record<string, number> = {};
  let previous: number | null = null;
  for (const row of priceRows) {
    const close = Number(row.close);
    if (previous !== null && close) returns[row.date] = close / previous - 1;
    if (close) previous = close;
  }
  return returns;
}

function labSymbols(snapshot: Snapshot, maxSymbols = 35, excludeBenchmarks = false): string[] {
  const ranked = [...snapshot.portfolio.holdings].sort(
    (a, b) => exposureValueUsd(String(b.ticker), snapshot, "market") - exposureValueUsd(String(a.ticker), snapshot, "market"),
  );
  const symbols: string[] = [];
  for (const row of ranked) {
    const symbol = row.yahoo_symbol || row.ticker;
    if (symbol && !symbols.includes(String(symbol))) symbols.push(String(symbol));
    if (symbols.length >= maxSymbols) break;
  }
  if (!excludeBenchmarks) {
    for (const benchmark of Object.keys(BENCHMARKS)) {
      if (!symbols.includes(benchmark)) symbols.push(benchmark);
    }
  }
  return symbols;
}

function holdingValuesBySymbol(snapshot: Snapshot, symbols: string[]): Record<string, number> {
  const market = marketByTicker(snapshot);
  const holdings = holdingsByTicker(snapshot);
  const wanted = new Set(symbols);
  const values: Record<string, number> = {};
  for (const [ticker, holding] of Object.entries(holdings)) {
    const symbol = String(holding.yahoo_symbol || ticker);
    if (!wanted.has(symbol)) continue;
    const value =
      num(market[ticker]?.market_value_usd) ||
      num(holding.api_market_value_usd) ||
      num(holding.cost_usd_standard);
    if (value <= 0) continue;
    values[symbol] = (values[symbol] ?? 0) + value;
  }
  return values;
}

export function groupedUniverse(
  snapshot: Snapshot,
  history: LabHistory,
  options: { maxSymbols?: number; excludeBenchmarks?: boolean } = {},
): {
  symbols: string[];
  weights: Record<string, number>;
  dates: string[];
  matrix: Record<string, number[]>;
  groups: Record<string, { members: Record<string, number>; weight: number }>;
} {
  const prices = history.prices ?? {};
  let rawSymbols = labSymbols(
    snapshot,
    options.maxSymbols ?? 35,
    options.excludeBenchmarks ?? false,
  ).filter((symbol) => prices[symbol]);
  if (options.excludeBenchmarks) {
    rawSymbols = rawSymbols.filter((symbol) => !(symbol in BENCHMARKS));
  }
  const rawValues = holdingValuesBySymbol(snapshot, rawSymbols);
  const groups: Record<string, { value: number; members: Record<string, number> }> = {};
  for (const symbol of rawSymbols) {
    const value = rawValues[symbol] ?? 0;
    if (value <= 0) continue;
    const canonical = ASSET_ALIASES[symbol] ?? symbol;
    const group = groups[canonical] ?? { value: 0, members: {} };
    group.value += value;
    group.members[symbol] = (group.members[symbol] ?? 0) + value;
    groups[canonical] = group;
  }
  const total = Object.values(groups).reduce((sum, group) => sum + group.value, 0);
  const weights: Record<string, number> = {};
  for (const [symbol, group] of Object.entries(groups)) {
    if (total) weights[symbol] = group.value / total;
  }
  const returnsBySymbol: Record<string, Record<string, number>> = {};
  for (const [symbol, group] of Object.entries(groups)) {
    const memberReturns: Record<string, Record<string, number>> = {};
    for (const member of Object.keys(group.members)) {
      memberReturns[member] = returnsFromPrices(prices[member] ?? []);
    }
    const memberDateSets = Object.values(memberReturns)
      .filter((rows) => Object.keys(rows).length)
      .map((rows) => new Set(Object.keys(rows)));
    const commonMemberDates = memberDateSets.length
      ? [...memberDateSets.reduce((acc, set) => new Set([...acc].filter((d) => set.has(d))))].sort()
      : [];
    const memberTotal = Object.values(group.members).reduce((a, b) => a + b, 0) || 1;
    const merged: Record<string, number> = {};
    for (const date of commonMemberDates) {
      let sum = 0;
      for (const [member, value] of Object.entries(group.members)) {
        const ret = memberReturns[member][date];
        if (ret !== undefined) sum += ret * (value / memberTotal);
      }
      merged[date] = sum;
    }
    returnsBySymbol[symbol] = merged;
  }
  let commonDates: Set<string> | null = null;
  for (const rows of Object.values(returnsBySymbol)) {
    const dates = new Set(Object.keys(rows));
    commonDates = commonDates === null ? dates : new Set([...commonDates].filter((d) => dates.has(d)));
  }
  const dates = [...(commonDates ?? [])].sort();
  const matrix: Record<string, number[]> = {};
  for (const symbol of Object.keys(weights)) {
    matrix[symbol] = dates.map((date) => returnsBySymbol[symbol][date]);
  }
  return {
    symbols: Object.keys(weights),
    weights,
    dates,
    matrix,
    groups: Object.fromEntries(
      Object.entries(groups).map(([symbol, group]) => [
        symbol,
        { members: group.members, weight: weights[symbol] ?? 0 },
      ]),
    ),
  };
}

export function portfolioReturns(matrix: Record<string, number[]>, weights: Record<string, number>): number[] {
  const symbols = Object.keys(weights).filter((symbol) => matrix[symbol]);
  if (!symbols.length) return [];
  const length = Math.min(...symbols.map((symbol) => matrix[symbol].length));
  const rows: number[] = [];
  for (let i = 0; i < length; i += 1) {
    let sum = 0;
    for (const symbol of symbols) sum += matrix[symbol][i] * weights[symbol];
    rows.push(sum);
  }
  return rows;
}

export function annualizedStats(returns: number[], riskFree = 0): Json {
  if (!returns.length) {
    return { annual_return: 0, annual_volatility: 0, sharpe: 0, max_drawdown: 0 };
  }
  const avg = mean(returns);
  const vol = returns.length > 1 ? stdev(returns) : 0;
  const annualReturn = (1 + avg) ** 252 - 1;
  const annualVol = vol * Math.sqrt(252);
  const sharpe = annualVol ? (annualReturn - riskFree) / annualVol : 0;
  let nav = 1;
  let peak = 1;
  let maxDd = 0;
  for (const ret of returns) {
    nav *= 1 + ret;
    peak = Math.max(peak, nav);
    maxDd = Math.min(maxDd, nav / peak - 1);
  }
  return { annual_return: annualReturn, annual_volatility: annualVol, sharpe, max_drawdown: maxDd };
}

export function navSeries(dates: string[], returns: number[]): { date: string; nav: number; return: number }[] {
  let nav = 1;
  const rows: { date: string; nav: number; return: number }[] = [];
  const slicedDates = dates.slice(-returns.length);
  for (let i = 0; i < returns.length; i += 1) {
    nav *= 1 + returns[i];
    rows.push({ date: slicedDates[i], nav, return: returns[i] });
  }
  return rows;
}

export function labHistorySummary(snapshot: Snapshot, history: LabHistory): Json {
  const universe = groupedUniverse(snapshot, history);
  const returns = portfolioReturns(universe.matrix, universe.weights);
  const stats = annualizedStats(returns);
  return {
    history_as_of_unix: history.as_of_unix,
    source: history.source,
    symbols: Object.keys(universe.weights),
    weights: universe.weights,
    groups: universe.groups,
    stats,
    nav: navSeries(universe.dates, returns),
    warnings: [],
  };
}

export function backtest(snapshot: Snapshot, history: LabHistory): Json {
  const summary = labHistorySummary(snapshot, history);
  const portfolioNav = summary.nav as { date: string; nav: number; return: number }[];
  const portfolioDates = portfolioNav.map((row) => row.date);
  const benchmarkRows: Json[] = [];
  for (const [symbol, label] of Object.entries(BENCHMARKS)) {
    const prices = history.prices?.[symbol];
    if (!prices) continue;
    const returnsByDate = returnsFromPrices(prices);
    const dates = portfolioDates.filter((date) => returnsByDate[date] !== undefined);
    const returns = dates.map((date) => returnsByDate[date]);
    benchmarkRows.push({
      symbol,
      label,
      stats: annualizedStats(returns),
      nav: navSeries(dates, returns),
    });
  }
  return { portfolio: { stats: summary.stats, nav: portfolioNav }, benchmarks: benchmarkRows };
}

export function cumulativeVsBenchmark(snapshot: Snapshot, history: LabHistory, symbol = "SPY"): Json {
  const bt = backtest(snapshot, history);
  const portfolio = (bt.portfolio as Json).nav as { date: string; nav: number }[];
  const benchmark = (bt.benchmarks as Json[]).find((row) => row.symbol === symbol);
  const benchmarkByDate: Record<string, number> = {};
  for (const row of (benchmark?.nav as { date: string; nav: number }[]) ?? []) {
    benchmarkByDate[row.date] = row.nav;
  }
  const rawRows: { date: string; portfolio: number; benchmark: number }[] = [];
  for (const row of portfolio) {
    const benchNav = benchmarkByDate[row.date];
    if (benchNav === undefined) continue;
    rawRows.push({ date: row.date, portfolio: row.nav, benchmark: benchNav });
  }
  if (!rawRows.length) return { benchmark: symbol, basis: "current-weight model portfolio", rows: [] };
  const portfolioBase = rawRows[0].portfolio || 1;
  const benchmarkBase = rawRows[0].benchmark || 1;
  const rows = rawRows.map((row) => {
    const portfolioNav = row.portfolio / portfolioBase;
    const benchmarkNav = row.benchmark / benchmarkBase;
    return {
      date: row.date,
      portfolio: portfolioNav,
      benchmark: benchmarkNav,
      excess: benchmarkNav ? portfolioNav / benchmarkNav - 1 : 0,
    };
  });
  return {
    benchmark: symbol,
    basis: "current-weight model portfolio, rebased to first common date",
    label: "TWR 策略收益",
    note: "剔除现金流影响，用于衡量策略本身表现。",
    date_range: { start: rows[0].date, end: rows[rows.length - 1].date },
    rows,
  };
}

export function cashFlowMirrorVsBenchmark(snapshot: Snapshot, history: LabHistory, symbol = "SPY"): Json {
  const model = cumulativeVsBenchmark(snapshot, history, symbol);
  const modelRows = (model.rows ?? []) as { date: string; portfolio: number; benchmark: number }[];
  if (!modelRows.length) {
    return { benchmark: symbol, available: false, status: "demo_no_rows", rows: [] };
  }
  const eventIndexes: Record<number, number> = {
    0: 12000,
    [Math.floor(modelRows.length / 5)]: 4000,
    [Math.floor((modelRows.length * 2) / 5)]: 3500,
    [Math.floor((modelRows.length * 3) / 5)]: -1800,
    [Math.floor((modelRows.length * 4) / 5)]: 2500,
  };
  let portfolioUnits = 0;
  let benchmarkUnits = 0;
  let buyTotal = 0;
  let sellTotal = 0;
  let cumulativeSellTotal = 0;
  let netCashFlow = 0;
  const rows: Json[] = [];
  for (let index = 0; index < modelRows.length; index += 1) {
    const row = modelRows[index];
    const portfolioNav = Number(row.portfolio) || 1;
    const benchmarkNav = Number(row.benchmark) || 1;
    const amount = eventIndexes[index] ?? 0;
    if (amount > 0) {
      portfolioUnits += amount / portfolioNav;
      benchmarkUnits += amount / benchmarkNav;
      buyTotal += amount;
      netCashFlow += amount;
    } else if (amount < 0) {
      const withdrawal = Math.min(Math.abs(amount), portfolioUnits * portfolioNav * 0.35);
      portfolioUnits -= withdrawal / portfolioNav;
      benchmarkUnits -= withdrawal / benchmarkNav;
      sellTotal += withdrawal;
      cumulativeSellTotal += withdrawal;
      netCashFlow -= withdrawal;
    }
    const portfolioValue = portfolioUnits * portfolioNav;
    const benchmarkValue = benchmarkUnits * benchmarkNav;
    rows.push({
      date: row.date,
      portfolio_value: portfolioValue,
      benchmark_value: benchmarkValue,
      adjusted_portfolio_value: portfolioValue + cumulativeSellTotal,
      adjusted_benchmark_value: benchmarkValue + cumulativeSellTotal,
      portfolio_return: buyTotal ? (portfolioValue + cumulativeSellTotal) / buyTotal - 1 : 0,
      benchmark_return: buyTotal ? (benchmarkValue + cumulativeSellTotal) / buyTotal - 1 : 0,
      net_cash_flow: netCashFlow,
      buy_total: buyTotal,
      cumulative_sell_total: cumulativeSellTotal,
      priced_symbols: 13,
    });
  }
  const last = rows[rows.length - 1];
  return {
    benchmark: symbol,
    available: true,
    status: "demo_synthetic",
    basis: "synthetic demo contributions mirrored into the benchmark",
    label: "现金流镜像",
    note: "Demo 模式使用固定假现金流，仅用于展示产品交互。",
    message: "All cash flows and values on this view are synthetic demo data.",
    date_range: { start: rows[0].date, end: rows[rows.length - 1].date },
    rows,
    stats: {
      trade_count: Object.keys(eventIndexes).length,
      buy_total_usd: buyTotal,
      sell_total_usd: sellTotal,
      net_cash_flow_usd: netCashFlow,
      final_portfolio_value_usd: last.portfolio_value,
      final_benchmark_value_usd: last.benchmark_value,
      final_adjusted_portfolio_value_usd: last.adjusted_portfolio_value,
      final_adjusted_benchmark_value_usd: last.adjusted_benchmark_value,
      final_gap_usd: Number(last.portfolio_value) - Number(last.benchmark_value),
      covered_symbols: 13,
      missing_symbols: [],
    },
    warnings: ["Demo 假数据：现金流时点与金额不代表任何真实账户。"],
  };
}

// ── comparison payload (matches GET /api/comparison) ────────────────────────

export function comparisonPayload(snapshot: Snapshot, history: LabHistory, generatedAt = new Date().toISOString()): Json {
  const results: Record<string, Json> = {};
  for (const symbol of Object.keys(BENCHMARKS)) {
    results[symbol] = cashFlowMirrorVsBenchmark(snapshot, history, symbol);
  }
  const spy = results.SPY ?? cashFlowMirrorVsBenchmark(snapshot, history, "SPY");
  const spyRows = (spy.rows ?? []) as { date: string; adjusted_portfolio_value: number; portfolio_return: number }[];
  const dates = spyRows.map((row) => row.date).filter(Boolean);
  const portfolioByDate: Record<string, number> = {};
  for (const row of spyRows) {
    if (row.date) portfolioByDate[row.date] = row.adjusted_portfolio_value;
  }
  const benchmarkSeries: Record<string, (number | null)[]> = {};
  const benchmarkReturns: Record<string, number | null> = {};
  for (const [symbol, result] of Object.entries(results)) {
    const rows = (result.rows ?? []) as { date: string; adjusted_benchmark_value: number; benchmark_return: number }[];
    const values: Record<string, number> = {};
    for (const row of rows) {
      if (row.date) values[row.date] = row.adjusted_benchmark_value;
    }
    benchmarkSeries[symbol] = dates.map((date) => values[date] ?? null);
    benchmarkReturns[symbol] = rows.length ? rows[rows.length - 1].benchmark_return : null;
  }
  return {
    available: dates.length > 0,
    dates,
    portfolio: dates.map((date) => portfolioByDate[date] ?? null),
    benchmarks: benchmarkSeries,
    summary: {
      portfolio_return: spyRows.length ? spyRows[spyRows.length - 1].portfolio_return : null,
      benchmark_return: benchmarkReturns.SPY,
      benchmark_returns: benchmarkReturns,
    },
    generated_at: generatedAt,
  };
}

// ── profit calendar payload ─────────────────────────────────────────────────

export function profitCalendarPayload(
  snapshot: Snapshot,
  history: LabHistory,
  income: IncomeSummary,
): Json {
  const summary = portfolioSummary(snapshot);
  const marketValueUsd = Number(summary.market_value_usd || 0);
  const labSummary = labHistorySummary(snapshot, history);
  const nav = (labSummary.nav ?? []) as { date: string; return: number }[];
  return {
    basis: "current-weight model daily return multiplied by current portfolio market value",
    currency: "USD",
    market_value_usd: marketValueUsd,
    rows: nav.map((row) => ({
      date: row.date,
      return: row.return,
      pnl_usd: marketValueUsd * Number(row.return || 0),
    })),
    income,
  };
}

// ── volume profile ──────────────────────────────────────────────────────────

export function calculateVolumeProfile(
  rows: { date?: string; low?: number; high?: number; volume?: number }[],
  opts: { bins?: number; valueArea?: number; lookback?: number; minimumBars?: number } = {},
): Json {
  const bins = opts.bins ?? 36;
  const valueArea = opts.valueArea ?? 0.7;
  const lookback = opts.lookback ?? 120;
  const minimumBars = opts.minimumBars ?? 20;
  const valid: { date: string; low: number; high: number; volume: number }[] = [];
  for (const row of rows ?? []) {
    const low = Number(row.low);
    const high = Number(row.high);
    const volume = Number(row.volume);
    if (![low, high, volume].every(Number.isFinite) || volume <= 0) continue;
    valid.push({ date: String(row.date || ""), low: Math.min(low, high), high: Math.max(low, high), volume });
  }
  valid.splice(0, Math.max(0, valid.length - Math.max(1, Math.floor(lookback))));
  if (valid.length < Math.max(1, Math.floor(minimumBars))) {
    return { available: false, reason: "insufficient_ohlcv_history", sessions: valid.length };
  }
  const priceLow = Math.min(...valid.map((row) => row.low));
  const priceHigh = Math.max(...valid.map((row) => row.high));
  if (!Number.isFinite(priceLow) || !Number.isFinite(priceHigh) || priceHigh <= priceLow) {
    return { available: false, reason: "invalid_price_range", sessions: valid.length };
  }
  const binCount = Math.max(8, Math.min(120, Math.floor(bins)));
  const step = (priceHigh - priceLow) / binCount;
  const volumeByBin = new Array<number>(binCount).fill(0);
  for (const row of valid) {
    const first = Math.max(0, Math.min(binCount - 1, Math.floor((row.low - priceLow) / step)));
    const last = Math.max(0, Math.min(binCount - 1, Math.floor((row.high - priceLow) / step)));
    const touched = last - first + 1;
    const allocated = row.volume / touched;
    for (let index = first; index <= last; index += 1) volumeByBin[index] += allocated;
  }
  const totalVolume = volumeByBin.reduce((a, b) => a + b, 0);
  if (totalVolume <= 0) {
    return { available: false, reason: "invalid_volume", sessions: valid.length };
  }
  let pocIndex = 0;
  for (let index = 1; index < binCount; index += 1) {
    if (volumeByBin[index] > volumeByBin[pocIndex]) pocIndex = index;
  }
  let selectedLow = pocIndex;
  let selectedHigh = pocIndex;
  let selectedVolume = volumeByBin[pocIndex];
  const targetVolume = totalVolume * Math.max(0.5, Math.min(0.95, Number(valueArea)));
  while (selectedVolume < targetVolume && (selectedLow > 0 || selectedHigh < binCount - 1)) {
    const leftVolume = selectedLow > 0 ? volumeByBin[selectedLow - 1] : -1;
    const rightVolume = selectedHigh < binCount - 1 ? volumeByBin[selectedHigh + 1] : -1;
    if (rightVolume > leftVolume) {
      selectedHigh += 1;
      selectedVolume += volumeByBin[selectedHigh];
    } else {
      selectedLow -= 1;
      selectedVolume += volumeByBin[selectedLow];
    }
  }
  return {
    available: true,
    vah: pyRound(priceLow + (selectedHigh + 1) * step, 4),
    poc: pyRound(priceLow + (pocIndex + 0.5) * step, 4),
    val: pyRound(priceLow + selectedLow * step, 4),
    sessions: valid.length,
    value_area_percent: Math.round(Number(valueArea) * 100),
    as_of: valid[valid.length - 1].date || null,
    method: "daily_ohlcv_uniform_price_bins",
  };
}

export function holdingVolumeProfile(snapshot: Snapshot, history: LabHistory, tickerInput: string): Json | null {
  const normalized = String(tickerInput || "").trim().toUpperCase();
  const holdings = snapshot.portfolio.holdings;
  const holding = holdings.find(
    (row) =>
      normalized === String(row.ticker || "").trim().toUpperCase() ||
      normalized === String(row.yahoo_symbol || "").trim().toUpperCase(),
  );
  if (!holding) return null;
  const tickerLabel = String(holding.ticker || normalized).trim().toUpperCase();
  const symbol = String(holding.yahoo_symbol || holding.ticker || normalized).trim().toUpperCase();
  const cachedRows = history.prices?.[symbol] ?? [];
  const profile = calculateVolumeProfile(cachedRows);
  const marketRows = snapshot.market.rows;
  const marketRow =
    marketRows.find(
      (row) =>
        normalized === String(row.ticker || "").trim().toUpperCase() ||
        normalized === String(row.yahoo_symbol || "").trim().toUpperCase(),
    ) ?? {};
  const currency =
    marketRow.quote_currency || marketRow.currency || holding.price_currency || holding.cost_currency || "USD";
  return {
    ticker: tickerLabel,
    symbol,
    currency: String(currency).toUpperCase(),
    ...profile,
  };
}

// ── portfolio overview + chart payloads (matches /api/portfolio/*) ─────────

export function portfolioOverviewPayload(snapshot: Snapshot): Json {
  const detail = holdingsDetail(snapshot).rows;
  const summary = portfolioSummary(snapshot);
  let todayPnl = 0;
  for (const row of detail) {
    const change = Number(row.today_change_percent);
    const value = Number(row.market_value_usd);
    if (change === null || change === undefined || Number.isNaN(change) || value === null || value === undefined) {
      continue;
    }
    const rate = change / 100;
    if (rate !== -1) todayPnl += value - value / (1 + rate);
  }
  return {
    summary,
    today_pnl_usd: todayPnl,
    breadth: {
      up: detail.filter((row) => Number(row.today_change_percent || 0) > 0).length,
      down: detail.filter((row) => Number(row.today_change_percent || 0) < 0).length,
      flat: detail.filter((row) => Number(row.today_change_percent || 0) === 0).length,
    },
    top_holdings: detail.slice(0, 10),
    sectors: (sectorConcentration(snapshot).rows as Json[]) ?? [],
  };
}

export function portfolioChartPayload(snapshot: Snapshot, history: LabHistory): Json {
  const summary = portfolioSummary(snapshot);
  const holdings = snapshot.portfolio.holdings;
  const asOf = String(summary.as_of || "");
  const dateMatch = /^(\d{4}-\d{2}-\d{2})/.exec(asOf);
  const currentDate = dateMatch ? dateMatch[1] : new Date().toISOString().slice(0, 10);
  const marketValue = Number(summary.market_value_usd || 0);
  const summaryCost = summary.total_cost_usd_standard;
  const positionCost =
    summaryCost !== undefined && summaryCost !== null
      ? Number(summaryCost)
      : holdings.reduce((sum, row) => sum + Number(row.cost_usd_standard || 0), 0);
  return {
    basis: "current_trading212_open_positions_excluding_cash",
    position_count: holdings.length,
    position_history: currentOpenPositionsHistory(snapshot, history),
    current_point: {
      date: currentDate,
      as_of: asOf || null,
      market_value_usd: marketValue,
      cost_usd: positionCost,
    },
  };
}

// ── returns explanation (deterministic demo text) ───────────────────────────

export function returnsExplanation(snapshot: Snapshot, history: LabHistory): { explanation: string; period: string } {
  const twr = cumulativeVsBenchmark(snapshot, history, "SPY");
  const range = twr.date_range as { start?: string; end?: string } | undefined;
  const explanation =
    "当前处于假数据模式：这是一段固定示例分析，没有读取本机 AI Key，也没有调用外部 AI Provider。" +
    "关闭假数据模式并在设置里配置 AI Key 后，Catfolio 才会根据真实组合生成 AI 分析。";
  return { explanation, period: `${range?.start ?? "—"} ~ ${range?.end ?? "—"}` };
}

// ── analytics charts (matches GET /api/analytics) ───────────────────────────

export function monthlyReturnHeatmap(snapshot: Snapshot, history: LabHistory, years: number[] = [2025, 2026]): Json {
  const summary = labHistorySummary(snapshot, history);
  const nav = (summary.nav ?? []) as { date: string; return: number }[];
  const monthReturns: Record<string, number> = {};
  for (const row of nav) {
    const year = Number(String(row.date).slice(0, 4));
    if (!years.includes(year)) continue;
    const key = String(row.date).slice(0, 7);
    monthReturns[key] = (monthReturns[key] ?? 1) * (1 + row.return);
  }
  const rows = Object.keys(monthReturns)
    .sort()
    .map((month) => ({ month, return: monthReturns[month] - 1 }));
  return {
    basis: "current-weight model portfolio, not cash-flow adjusted account return",
    date_range: {
      start: nav.length ? nav[0].date : null,
      end: nav.length ? nav[nav.length - 1].date : null,
    },
    rows,
  };
}

export function drawdownCurve(snapshot: Snapshot, history: LabHistory): Json {
  const summary = labHistorySummary(snapshot, history);
  const nav = (summary.nav ?? []) as { date: string; nav: number }[];
  let peak = 1;
  const rows: Json[] = [];
  let maxDrawdown = 0;
  for (const row of nav) {
    peak = Math.max(peak, row.nav);
    const drawdown = peak ? row.nav / peak - 1 : 0;
    maxDrawdown = Math.min(maxDrawdown, drawdown);
    rows.push({ date: row.date, drawdown });
  }
  return { max_drawdown: maxDrawdown, rows };
}

export function returnDistribution(snapshot: Snapshot, history: LabHistory): Json {
  const summary = labHistorySummary(snapshot, history);
  const returns = ((summary.nav ?? []) as { return: number }[]).map((row) => row.return);
  if (!returns.length) return { bins: [], stats: {} };
  const low = Math.min(...returns);
  const high = Math.max(...returns);
  const bucketCount = 20;
  const width = high > low ? (high - low) / bucketCount : 0.01;
  const bins: Json[] = [];
  for (let index = 0; index < bucketCount; index += 1) {
    const start = low + index * width;
    const end = start + width;
    const count = returns.filter(
      (value) => (start <= value && value < end) || (index === bucketCount - 1 && value >= start),
    ).length;
    bins.push({ start, end, mid: (start + end) / 2, count });
  }
  const avg = mean(returns);
  const downside = returns.filter((value) => value < 0);
  return {
    bins,
    stats: {
      mean: avg,
      worst: low,
      best: high,
      negative_days: downside.length,
      sample_days: returns.length,
    },
  };
}

export function correlationMatrix(snapshot: Snapshot, history: LabHistory, limit = 14): Json {
  const universe = groupedUniverse(snapshot, history, { maxSymbols: limit, excludeBenchmarks: true });
  const symbols = universe.symbols;
  const matrix = universe.matrix;
  const rows: number[][] = [];
  for (const left of symbols) {
    const row: number[] = [];
    const leftValues = matrix[left] ?? [];
    for (const right of symbols) {
      const rightValues = matrix[right] ?? [];
      const length = Math.min(leftValues.length, rightValues.length);
      if (length < 3) {
        row.push(0);
        continue;
      }
      const lvals = leftValues.slice(-length);
      const rvals = rightValues.slice(-length);
      const avgL = mean(lvals);
      const avgR = mean(rvals);
      let cov = 0;
      for (let i = 0; i < length; i += 1) cov += (lvals[i] - avgL) * (rvals[i] - avgR);
      cov /= length;
      let varL = 0;
      for (let i = 0; i < length; i += 1) varL += (lvals[i] - avgL) ** 2;
      varL /= length;
      let varR = 0;
      for (let i = 0; i < length; i += 1) varR += (rvals[i] - avgR) ** 2;
      varR /= length;
      row.push(varL && varR ? cov / Math.sqrt(varL * varR) : 0);
    }
    rows.push(row);
  }
  return { symbols, matrix: rows };
}

export function monthlyContributionWaterfall(snapshot: Snapshot, history: LabHistory): Json {
  const universe = groupedUniverse(snapshot, history, { maxSymbols: 18, excludeBenchmarks: true });
  if (!universe.dates.length) return { month: null, rows: [] };
  const month = universe.dates[universe.dates.length - 1].slice(0, 7);
  const indexes = universe.dates
    .map((date, idx) => ({ date, idx }))
    .filter(({ date }) => date.startsWith(month))
    .map(({ idx }) => idx);
  const rows: Json[] = [];
  for (const [symbol, returns] of Object.entries(universe.matrix)) {
    let compounded = 1;
    for (const idx of indexes) compounded *= 1 + returns[idx];
    const contribution = (universe.weights[symbol] ?? 0) * (compounded - 1);
    rows.push({ symbol, contribution });
  }
  rows.sort((a, b) => Math.abs(num(b.contribution)) - Math.abs(num(a.contribution)));
  return { month, basis: "current-weight model contribution", rows: rows.slice(0, 16) };
}

// ── analytics payload (matches GET /api/analytics) ──────────────────────────

export function analyticsPayload(snapshot: Snapshot, history: LabHistory): Json {
  return {
    monthly_returns: monthlyReturnHeatmap(snapshot, history),
    drawdown: drawdownCurve(snapshot, history),
    correlation_matrix: correlationMatrix(snapshot, history),
    return_distribution: returnDistribution(snapshot, history),
    waterfall: monthlyContributionWaterfall(snapshot, history),
  };
}

// ── holdings heatmap (matches GET /api/holdings/heatmap) ────────────────────

function calcReturn(prices: { date: string; close: number }[], offset: number): number | null {
  if (!prices.length || prices.length <= offset) return null;
  const latest = Number(prices[prices.length - 1].close);
  const past = Number(prices[prices.length - 1 - offset].close);
  return past ? (latest / past - 1) * 100 : null;
}

function calcYtdReturn(prices: { date: string; close: number }[]): number | null {
  if (!prices.length) return null;
  const latestDate = String(prices[prices.length - 1].date);
  const latestYear = Number(latestDate.slice(0, 4));
  let pastRow: { date: string; close: number } | null = null;
  for (let i = prices.length - 1; i >= 0; i -= 1) {
    if (Number(String(prices[i].date).slice(0, 4)) < latestYear) {
      pastRow = prices[i];
      break;
    }
  }
  if (!pastRow) pastRow = prices[0];
  const latest = Number(prices[prices.length - 1].close);
  const past = Number(pastRow.close);
  return past ? (latest / past - 1) * 100 : null;
}

export function holdingsHeatmap(snapshot: Snapshot, history: LabHistory): Json {
  const detail = holdingsDetail(snapshot).rows;
  const holdings = holdingsByTicker(snapshot);
  const fundamentals = snapshot.fundamentals;
  const valuation: Record<string, Json> = {};
  for (const row of fundamentals.rows) {
    if (row.ticker) valuation[String(row.ticker)] = row;
  }
  const valuationAsOfUnix = fundamentals.as_of_unix;
  const pricesMap = history.prices ?? {};
  const rows: Json[] = [];
  for (const row of detail) {
    const holding = holdings[String(row.ticker)] ?? {};
    const yahooSymbol = holding.yahoo_symbol || row.ticker;
    const prices = pricesMap[String(yahooSymbol)] ?? [];
    const val = valuation[String(row.ticker)] ?? {};
    rows.push({
      ticker: row.ticker,
      logo_symbol: row.logo_symbol ?? yahooSymbol,
      name: row.name,
      display_name: row.display_name ?? displayName(String(row.ticker), String(row.name)),
      sector: row.sector,
      weight: row.weight,
      shares: row.shares,
      cost_usd: row.cost_usd,
      avg_cost_usd: row.avg_cost_usd,
      quote_price: row.quote_price,
      quote_currency: row.quote_currency,
      market_value_usd: row.market_value_usd,
      today_change_percent: row.today_change_percent,
      unrealized_usd: row.unrealized_usd,
      unrealized_percent: row.unrealized_percent,
      broker_unrealized_usd: row.broker_unrealized_usd,
      broker_fx_ppl_usd: row.broker_fx_ppl_usd,
      broker_fx_ppl_percent: row.broker_fx_ppl_percent,
      broker_ppl_includes_fx: row.broker_ppl_includes_fx,
      price_unrealized_usd: row.price_unrealized_usd,
      price_unrealized_percent: row.price_unrealized_percent,
      trailing_pe: val.trailing_pe ?? row.trailing_pe ?? null,
      forward_pe: val.forward_pe ?? row.forward_pe ?? null,
      price_to_sales: val.price_to_sales ?? null,
      price_to_book: val.price_to_book ?? null,
      eps_growth_yoy: val.eps_growth_yoy ?? null,
      revenue_growth_yoy: val.revenue_growth_yoy ?? null,
      volume: row.volume,
      avg_volume_3m: row.avg_volume_3m,
      market_cap: row.market_cap,
      high_52w: row.high_52w,
      low_52w: row.low_52w,
      valuation_as_of_unix: valuationAsOfUnix,
      return_1w: calcReturn(prices, 5),
      return_1m: calcReturn(prices, 21),
      return_3m: calcReturn(prices, 63),
      return_6m: calcReturn(prices, 126),
      return_ytd: calcYtdReturn(prices),
      return_1y: calcReturn(prices, 252),
    });
  }
  return { rows };
}
