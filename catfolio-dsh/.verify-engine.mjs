// src/core/engine.ts
var BENCHMARKS = {
  SPY: "S&P 500",
  QQQ: "Nasdaq 100",
  VTI: "US Total Market",
  VOO: "Vanguard S&P 500",
  DIA: "Dow Jones 30",
  IWM: "US Small Cap",
  VEU: "World ex-US",
  GLD: "Gold"
};
var SP500_ETF_TICKERS = /* @__PURE__ */ new Set(["VUAG", "VUSA"]);
var SECTOR_BY_TICKER = {
  AAPL: "Technology",
  AVGO: "Technology",
  CHKP: "Technology",
  GOOG: "Communication Services",
  GOOGL: "Communication Services",
  META: "Communication Services",
  MRVL: "Technology",
  MSFT: "Technology",
  NVDA: "Technology",
  ORCL: "Technology",
  PANW: "Technology",
  QCOM: "Technology",
  SNOW: "Technology",
  ZS: "Technology",
  BARC: "Financials",
  BATS: "Consumer Staples",
  "BRK.B": "Financials",
  "BRK-B": "Financials",
  CEG: "Utilities",
  CLS: "Technology",
  EQGB: "ETF / Multi-Asset",
  FTNT: "Technology",
  GAW: "Consumer Discretionary",
  GSK: "Healthcare",
  LGEN: "Financials",
  LLOY: "Financials",
  MNG: "Financials",
  NG: "Utilities",
  NXT: "Consumer Discretionary",
  OKTA: "Technology",
  OSB: "Financials",
  PHNX: "Financials",
  PHP: "Real Estate",
  RR: "Industrials",
  RWE: "Utilities",
  SGLN: "Commodities",
  SIE: "Industrials",
  SILG: "Commodities",
  VUAG: "ETF / S&P 500",
  VUSA: "ETF / S&P 500",
  VHVG: "ETF / Global Equity",
  VEUA: "ETF / Europe Equity",
  XUSE: "ETF / S&P 500",
  NOK: "Communication Equipment",
  GEV: "Industrials",
  AES: "Utilities",
  ANAE: "ETF / Clean Energy",
  ANRJ: "ETF / Clean Energy",
  AV: "Financials",
  CNA: "Utilities",
  CNX1: "ETF / Nasdaq 100",
  CUKX: "ETF / UK Equity",
  ENL1: "Utilities",
  ENR: "Industrials",
  FPP: "Consumer Discretionary",
  IBEE: "ETF / Clean Energy",
  IITU: "ETF / Technology",
  SOHO: "Real Estate",
  SPGP: "Commodities",
  SSLN: "Commodities",
  VIEP: "ETF / Europe Equity"
};
var CN_NAME_BY_TICKER = {
  AES: "\u7231\u4F9D\u65AF",
  ANAE: "\u65B0\u80FD\u6E90ETF",
  ANRJ: "\u5168\u7403\u6C22\u80FDETF",
  AV: "\u82F1\u6770\u534E",
  BARC: "\u5DF4\u514B\u83B1",
  BATS: "\u82F1\u7F8E\u70DF\u8349",
  "BRK.B": "\u4F2F\u514B\u5E0C\u5C14\u54C8\u6492\u97E6B",
  "BRK-B": "\u4F2F\u514B\u5E0C\u5C14\u54C8\u6492\u97E6B",
  CEG: "\u661F\u5EA7\u80FD\u6E90",
  CHKP: "Check Point \u7F51\u7EDC\u5B89\u5168",
  CLS: "\u5929\u5F18\u79D1\u6280",
  CNA: "\u68EE\u7279\u7406\u514B",
  CNX1: "\u7EB3\u65AF\u8FBE\u514B100ETF",
  CUKX: "\u5BCC\u65F6100ETF",
  ENL1: "\u5FB7\u56FD\u7EFC\u5408\u80FD\u6E90",
  ENR: "\u897F\u95E8\u5B50\u80FD\u6E90",
  EQGB: "\u7EB3\u65AF\u8FBE\u514B100ETF",
  FPP: "\u6CE2\u5170\u670D\u88C5\u96F6\u552E",
  FTNT: "\u98DE\u5854",
  GAW: "\u6218\u9524\u6BCD\u516C\u53F8",
  GEV: "GE Vernova \u80FD\u6E90",
  GOOG: "\u8C37\u6B4CC",
  GSK: "\u845B\u5170\u7D20\u53F2\u514B",
  IBEE: "\u6E05\u6D01\u80FD\u6E90ETF",
  IITU: "\u6807\u666E500\u79D1\u6280ETF",
  LGEN: "\u82F1\u6770\u534E\u6CD5\u901A",
  LLOY: "\u52B3\u57C3\u5FB7\u94F6\u884C",
  META: "Meta \u5E73\u53F0",
  MNG: "M&G \u8D44\u4EA7\u7BA1\u7406",
  MRVL: "\u7F8E\u6EE1\u7535\u5B50",
  MSFT: "\u5FAE\u8F6F",
  NG: "\u82F1\u56FD\u56FD\u5BB6\u7535\u7F51",
  NOK: "\u8BFA\u57FA\u4E9A",
  NVDA: "\u82F1\u4F1F\u8FBE",
  NXT: "Next \u96F6\u552E",
  OKTA: "Okta \u8EAB\u4EFD\u4E91",
  ORCL: "\u7532\u9AA8\u6587",
  OSB: "OSB \u94F6\u884C",
  PANW: "Palo Alto \u7F51\u7EDC\u5B89\u5168",
  PHNX: "\u51E4\u51F0\u96C6\u56E2",
  PHP: "Primary Health \u533B\u7597\u5730\u4EA7",
  QCOM: "\u9AD8\u901A",
  RR: "\u52B3\u65AF\u83B1\u65AF",
  RWE: "\u83B1\u8335\u96C6\u56E2",
  SGLN: "\u5B9E\u7269\u9EC4\u91D1ETF",
  SIE: "\u897F\u95E8\u5B50",
  SILG: "\u767D\u94F6\u77FF\u4E1AETF",
  SNOW: "Snowflake \u4E91\u6570\u636E",
  SOHO: "\u793E\u4F1A\u4F4F\u623FREIT",
  SPGP: "\u9EC4\u91D1\u77FF\u5546ETF",
  SSLN: "\u5B9E\u7269\u767D\u94F6ETF",
  VEUA: "\u53D1\u8FBE\u6B27\u6D32ETF",
  VHVG: "\u53D1\u8FBE\u5E02\u573AETF",
  VIEP: "\u6B27\u6D32\u80A1\u606FETF",
  VUAG: "\u6807\u666E500\u7D2F\u79EF\u578B",
  VUSA: "\u6807\u666E500\u6D3E\u606F\u578B",
  XUSE: "\u5168\u7403\u9664\u7F8E\u56FDETF",
  ZS: "Zscaler \u96F6\u4FE1\u4EFB\u5B89\u5168"
};
var ASSET_ALIASES = {
  "VUAG.L": "S&P 500 Fund",
  "VUSA.L": "S&P 500 Fund"
};
var REPORT_FX_TO_USD = {
  USD: 1,
  GBP: 1.346,
  GBX: 0.01346,
  EUR: 1.163
};
function num(value) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}
function optionalNum(value) {
  if (value === null || value === void 0 || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}
function mean(values) {
  if (!values.length) return 0;
  return values.reduce((a, b) => a + b, 0) / values.length;
}
function stdev(values) {
  if (values.length < 2) return 0;
  const avg = mean(values);
  const variance = values.reduce((a, b) => a + (b - avg) ** 2, 0) / (values.length - 1);
  return Math.sqrt(variance);
}
function pyRound(value, ndigits = 0) {
  const factor = 10 ** ndigits;
  const scaled = value * factor;
  const floored = Math.floor(scaled);
  const diff = scaled - floored;
  let result;
  if (diff < 0.5) result = floored;
  else if (diff > 0.5) result = floored + 1;
  else result = floored % 2 === 0 ? floored : floored + 1;
  return result / factor;
}
function baseTicker(ticker) {
  return (ticker || "").replace(".L", "").replace("_EQ", "");
}
function displayName(ticker, name) {
  const cn = CN_NAME_BY_TICKER[baseTicker(ticker)];
  if (cn && name) return `${cn} / ${name}`;
  if (cn) return cn;
  return name || ticker;
}
function marketByTicker(snapshot) {
  const rows = {};
  for (const row of snapshot.market.rows) {
    if (row.ticker) rows[String(row.ticker)] = row;
  }
  return rows;
}
function holdingsByTicker(snapshot) {
  const rows = {};
  for (const row of snapshot.portfolio.holdings) {
    if (row.ticker) rows[String(row.ticker)] = row;
  }
  return rows;
}
function exposureValueUsd(ticker, snapshot, basis = "market") {
  const holdings = holdingsByTicker(snapshot);
  const market = marketByTicker(snapshot);
  if (basis === "market") {
    const row = market[ticker] ?? {};
    if (row.market_value_usd !== void 0 && row.market_value_usd !== null) return num(row.market_value_usd);
    const holding = holdings[ticker] ?? {};
    if (holding.api_market_value_usd !== void 0 && holding.api_market_value_usd !== null) {
      return num(holding.api_market_value_usd);
    }
  }
  return num((holdings[ticker] ?? {}).cost_usd_standard);
}
function brokerPnlByTicker(snapshot) {
  const rows = {};
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
    if (rate === void 0) continue;
    const fxPpl = optionalNum(position.fx_ppl);
    const target = rows[ticker] ?? {
      broker_unrealized_usd: 0,
      broker_fx_ppl_usd: 0,
      broker_pnl_currencies: /* @__PURE__ */ new Set(),
      broker_ppl_includes_fx: true
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
  for (const holding of snapshot.portfolio.holdings) {
    const ticker = String(holding.ticker || "").toUpperCase();
    if (!ticker || rows[ticker]) continue;
    const brokerUsd = optionalNum(holding.broker_unrealized_usd);
    if (brokerUsd === null) continue;
    rows[ticker] = {
      broker_unrealized_usd: brokerUsd,
      broker_fx_ppl_usd: num(holding.broker_fx_ppl_usd),
      broker_pnl_currency: holding.broker_unrealized_currency ?? "USD",
      broker_ppl_includes_fx: holding.broker_ppl_includes_fx !== false
    };
  }
  return rows;
}
function portfolioSummary(snapshot) {
  const summary = { ...snapshot.portfolio.summary };
  const market = marketByTicker(snapshot);
  const holdings = holdingsByTicker(snapshot);
  const brokerPnl = brokerPnlByTicker(snapshot);
  let marketTotal = 0;
  for (const [ticker, holding] of Object.entries(holdings)) {
    marketTotal += holding.api_market_value_usd !== void 0 && holding.api_market_value_usd !== null ? num(holding.api_market_value_usd) : num(market[ticker]?.market_value_usd);
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
    (sum, row) => sum + num(row.broker_unrealized_usd),
    0
  );
  summary.broker_fx_ppl_usd = Object.values(brokerPnl).reduce(
    (sum, row) => sum + num(row.broker_fx_ppl_usd),
    0
  );
  summary.price_unrealized_usd = priceUnrealizedTotal;
  summary.unrealized_includes_fx = brokerPositions > 0;
  summary.unrealized_source = brokerPositions === holdingCount && holdingCount > 0 ? "trading212_ppl" : brokerPositions > 0 ? "mixed" : "price_difference";
  summary.trading212_positions = snapshot.trading212.summary?.positions;
  summary.broker_positions = snapshot.trading212.positions.length;
  summary.cash = snapshot.trading212.account_cash ?? {};
  return summary;
}
function holdingsDetail(snapshot) {
  const holdings = holdingsByTicker(snapshot);
  const market = marketByTicker(snapshot);
  let total = 0;
  for (const row of Object.values(market)) total += num(row.market_value_usd);
  const brokerPnl = brokerPnlByTicker(snapshot);
  const rows = [];
  for (const [ticker, holding] of Object.entries(holdings)) {
    const marketRow = market[ticker] ?? {};
    const marketValue = num(marketRow.market_value_usd) || num(holding.api_market_value_usd);
    const cost = num(holding.cost_usd_standard);
    const companyName = marketRow.company_name || marketRow.name || holding.company_name || holding.name || ticker;
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
      unrealized_percent: cost ? unrealized / cost * 100 : null,
      broker_unrealized_usd: brokerRow ? num(brokerRow.broker_unrealized_usd) : null,
      broker_fx_ppl_usd: brokerRow ? num(brokerRow.broker_fx_ppl_usd) : null,
      broker_fx_ppl_percent: brokerRow && cost ? num(brokerRow.broker_fx_ppl_usd) / cost * 100 : null,
      broker_ppl_includes_fx: Boolean(brokerRow),
      broker_pnl_currency: brokerRow?.broker_pnl_currency ?? null,
      price_unrealized_usd: priceUnrealized,
      price_unrealized_percent: cost ? priceUnrealized / cost * 100 : null,
      volume: marketRow.volume,
      avg_volume_3m: marketRow.avg_volume_3m,
      market_cap: marketRow.market_cap,
      high_52w: marketRow.high_52w,
      low_52w: marketRow.low_52w
    });
  }
  rows.sort((a, b) => num(b.market_value_usd) - num(a.market_value_usd));
  return { rows };
}
function holdingsDetailPayload(snapshot) {
  return {
    summary: portfolioSummary(snapshot),
    rows: holdingsDetail(snapshot).rows
  };
}
function sectorConcentration(snapshot) {
  const market = marketByTicker(snapshot);
  let total = 0;
  for (const row of Object.values(market)) total += num(row.market_value_usd);
  const sectors = {};
  for (const [ticker, row] of Object.entries(market)) {
    const sector = SECTOR_BY_TICKER[baseTicker(ticker)] ?? "Other / Unclassified";
    sectors[sector] = (sectors[sector] ?? 0) + num(row.market_value_usd);
  }
  const rows = Object.entries(sectors).map(([sector, value]) => ({ sector, market_value_usd: value, weight: total ? value / total : 0 })).sort((a, b) => b.market_value_usd - a.market_value_usd);
  return { rows, coverage_note: "Sector map is local and approximate for MVP." };
}
function etfLookthrough(snapshot, basis = "cost", dataset) {
  const holdings = holdingsByTicker(snapshot);
  let etfTotal = 0;
  for (const ticker of SP500_ETF_TICKERS) etfTotal += exposureValueUsd(ticker, snapshot, basis);
  const direct = {};
  for (const ticker of Object.keys(holdings)) {
    if (!SP500_ETF_TICKERS.has(ticker)) direct[ticker] = exposureValueUsd(ticker, snapshot, basis);
  }
  const constituentRows = dataset.rows?.length ? dataset.rows : [];
  const rows = [];
  let usedWeight = 0;
  for (const constituent of constituentRows) {
    const ticker = String(constituent.ticker || "").toUpperCase();
    if (!ticker) continue;
    const name = constituent.name || ticker;
    const weight = num(constituent.weight_percent);
    usedWeight += weight;
    const fromEtf = etfTotal * weight / 100;
    const directValue = direct[ticker] ?? 0;
    const holding = holdings[ticker] ?? {};
    rows.push({
      ticker,
      name: holding.name || name,
      direct_usd: directValue,
      from_etf_usd: fromEtf,
      total_usd: directValue + fromEtf,
      etf_weight_percent: weight,
      sector: constituent.sector
    });
  }
  const otherWeight = Math.max(0, 100 - usedWeight);
  if (otherWeight > 1e-3) {
    rows.push({
      ticker: "ETF \u5176\u4ED6",
      name: "\u57FA\u91D1\u73B0\u91D1\u53CA\u884D\u751F\u54C1",
      direct_usd: 0,
      from_etf_usd: etfTotal * otherWeight / 100,
      total_usd: etfTotal * otherWeight / 100,
      etf_weight_percent: otherWeight,
      sector: "ETF / Other"
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
      etf_weight_percent: 0
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
    rows
  };
}
function currentOpenPositionsHistory(snapshot, history) {
  const prices = history.prices ?? {};
  const holdingsByAccount = snapshot.portfolio.holdings_by_account ?? snapshot.portfolio.holdings;
  const rawPositions = snapshot.trading212.positions ?? [];
  const initialFillByKey = {};
  for (const row of rawPositions) {
    if (!row.ticker || !row.initial_fill_date) continue;
    initialFillByKey[`${String(row.account || "")}|${String(row.ticker || "")}`] = String(
      row.initial_fill_date
    ).slice(0, 10);
  }
  const fxToUsd = { ...REPORT_FX_TO_USD };
  const positions = [];
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
      fx: fxToUsd[String(holding.cost_currency || "USD")] ?? 1
    });
  }
  if (!positions.length) return { available: false, rows: [], basis: "current_open_positions_excluding_cash" };
  const priceBySymbol = {};
  for (const [symbol, rows2] of Object.entries(prices)) {
    const byDate = {};
    for (const row of rows2) {
      if (row.date && row.close !== void 0 && row.close !== null) byDate[String(row.date)] = Number(row.close);
    }
    priceBySymbol[symbol] = byDate;
  }
  const allDates = /* @__PURE__ */ new Set();
  for (const byDate of Object.values(priceBySymbol)) for (const date of Object.keys(byDate)) allDates.add(date);
  const dates = [...allDates].sort();
  const earliestStart = Math.min(...positions.map((p) => p.start_date));
  const rows = [];
  const lastClose = {};
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
      if (close !== void 0 && close !== null) {
        lastClose[position.symbol] = close;
      } else {
        close = lastClose[position.symbol];
      }
      marketValue += close !== void 0 ? position.shares * close * position.fx : position.cost_usd;
    }
    if (activePositions) {
      rows.push({ date, market_value_usd: marketValue, cost_usd: positionCost });
    }
  }
  return {
    available: rows.length > 0,
    rows,
    basis: "current_open_positions_backcast_from_initial_fill_excluding_cash",
    position_count: positions.length
  };
}
function returnsFromPrices(priceRows) {
  const returns = {};
  let previous = null;
  for (const row of priceRows) {
    const close = Number(row.close);
    if (previous !== null && close) returns[row.date] = close / previous - 1;
    if (close) previous = close;
  }
  return returns;
}
function labSymbols(snapshot, maxSymbols = 35, excludeBenchmarks = false) {
  const ranked = [...snapshot.portfolio.holdings].sort(
    (a, b) => exposureValueUsd(String(b.ticker), snapshot, "market") - exposureValueUsd(String(a.ticker), snapshot, "market")
  );
  const symbols = [];
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
function holdingValuesBySymbol(snapshot, symbols) {
  const market = marketByTicker(snapshot);
  const holdings = holdingsByTicker(snapshot);
  const wanted = new Set(symbols);
  const values = {};
  for (const [ticker, holding] of Object.entries(holdings)) {
    const symbol = String(holding.yahoo_symbol || ticker);
    if (!wanted.has(symbol)) continue;
    const value = num(market[ticker]?.market_value_usd) || num(holding.api_market_value_usd) || num(holding.cost_usd_standard);
    if (value <= 0) continue;
    values[symbol] = (values[symbol] ?? 0) + value;
  }
  return values;
}
function groupedUniverse(snapshot, history, options = {}) {
  const prices = history.prices ?? {};
  let rawSymbols = labSymbols(
    snapshot,
    options.maxSymbols ?? 35,
    options.excludeBenchmarks ?? false
  ).filter((symbol) => prices[symbol]);
  if (options.excludeBenchmarks) {
    rawSymbols = rawSymbols.filter((symbol) => !(symbol in BENCHMARKS));
  }
  const rawValues = holdingValuesBySymbol(snapshot, rawSymbols);
  const groups = {};
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
  const weights = {};
  for (const [symbol, group] of Object.entries(groups)) {
    if (total) weights[symbol] = group.value / total;
  }
  const returnsBySymbol = {};
  for (const [symbol, group] of Object.entries(groups)) {
    const memberReturns = {};
    for (const member of Object.keys(group.members)) {
      memberReturns[member] = returnsFromPrices(prices[member] ?? []);
    }
    const memberDateSets = Object.values(memberReturns).filter((rows) => Object.keys(rows).length).map((rows) => new Set(Object.keys(rows)));
    const commonMemberDates = memberDateSets.length ? [...memberDateSets.reduce((acc, set) => new Set([...acc].filter((d) => set.has(d))))].sort() : [];
    const memberTotal = Object.values(group.members).reduce((a, b) => a + b, 0) || 1;
    const merged = {};
    for (const date of commonMemberDates) {
      let sum = 0;
      for (const [member, value] of Object.entries(group.members)) {
        const ret = memberReturns[member][date];
        if (ret !== void 0) sum += ret * (value / memberTotal);
      }
      merged[date] = sum;
    }
    returnsBySymbol[symbol] = merged;
  }
  let commonDates = null;
  for (const rows of Object.values(returnsBySymbol)) {
    const dates2 = new Set(Object.keys(rows));
    commonDates = commonDates === null ? dates2 : new Set([...commonDates].filter((d) => dates2.has(d)));
  }
  const dates = [...commonDates ?? []].sort();
  const matrix = {};
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
        { members: group.members, weight: weights[symbol] ?? 0 }
      ])
    )
  };
}
function portfolioReturns(matrix, weights) {
  const symbols = Object.keys(weights).filter((symbol) => matrix[symbol]);
  if (!symbols.length) return [];
  const length = Math.min(...symbols.map((symbol) => matrix[symbol].length));
  const rows = [];
  for (let i = 0; i < length; i += 1) {
    let sum = 0;
    for (const symbol of symbols) sum += matrix[symbol][i] * weights[symbol];
    rows.push(sum);
  }
  return rows;
}
function annualizedStats(returns, riskFree = 0) {
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
function navSeries(dates, returns) {
  let nav = 1;
  const rows = [];
  const slicedDates = dates.slice(-returns.length);
  for (let i = 0; i < returns.length; i += 1) {
    nav *= 1 + returns[i];
    rows.push({ date: slicedDates[i], nav, return: returns[i] });
  }
  return rows;
}
function labHistorySummary(snapshot, history) {
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
    warnings: []
  };
}
function backtest(snapshot, history) {
  const summary = labHistorySummary(snapshot, history);
  const portfolioNav = summary.nav;
  const portfolioDates = portfolioNav.map((row) => row.date);
  const benchmarkRows = [];
  for (const [symbol, label] of Object.entries(BENCHMARKS)) {
    const prices = history.prices?.[symbol];
    if (!prices) continue;
    const returnsByDate = returnsFromPrices(prices);
    const dates = portfolioDates.filter((date) => returnsByDate[date] !== void 0);
    const returns = dates.map((date) => returnsByDate[date]);
    benchmarkRows.push({
      symbol,
      label,
      stats: annualizedStats(returns),
      nav: navSeries(dates, returns)
    });
  }
  return { portfolio: { stats: summary.stats, nav: portfolioNav }, benchmarks: benchmarkRows };
}
function cumulativeVsBenchmark(snapshot, history, symbol = "SPY") {
  const bt = backtest(snapshot, history);
  const portfolio = bt.portfolio.nav;
  const benchmark = bt.benchmarks.find((row) => row.symbol === symbol);
  const benchmarkByDate = {};
  for (const row of benchmark?.nav ?? []) {
    benchmarkByDate[row.date] = row.nav;
  }
  const rawRows = [];
  for (const row of portfolio) {
    const benchNav = benchmarkByDate[row.date];
    if (benchNav === void 0) continue;
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
      excess: benchmarkNav ? portfolioNav / benchmarkNav - 1 : 0
    };
  });
  return {
    benchmark: symbol,
    basis: "current-weight model portfolio, rebased to first common date",
    label: "TWR \u7B56\u7565\u6536\u76CA",
    note: "\u5254\u9664\u73B0\u91D1\u6D41\u5F71\u54CD\uFF0C\u7528\u4E8E\u8861\u91CF\u7B56\u7565\u672C\u8EAB\u8868\u73B0\u3002",
    date_range: { start: rows[0].date, end: rows[rows.length - 1].date },
    rows
  };
}
function cashFlowMirrorVsBenchmark(snapshot, history, symbol = "SPY") {
  const model = cumulativeVsBenchmark(snapshot, history, symbol);
  const modelRows = model.rows ?? [];
  if (!modelRows.length) {
    return { benchmark: symbol, available: false, status: "demo_no_rows", rows: [] };
  }
  const eventIndexes = {
    0: 12e3,
    [Math.floor(modelRows.length / 5)]: 4e3,
    [Math.floor(modelRows.length * 2 / 5)]: 3500,
    [Math.floor(modelRows.length * 3 / 5)]: -1800,
    [Math.floor(modelRows.length * 4 / 5)]: 2500
  };
  let portfolioUnits = 0;
  let benchmarkUnits = 0;
  let buyTotal = 0;
  let sellTotal = 0;
  let cumulativeSellTotal = 0;
  let netCashFlow = 0;
  const rows = [];
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
      priced_symbols: 13
    });
  }
  const last = rows[rows.length - 1];
  return {
    benchmark: symbol,
    available: true,
    status: "demo_synthetic",
    basis: "synthetic demo contributions mirrored into the benchmark",
    label: "\u73B0\u91D1\u6D41\u955C\u50CF",
    note: "Demo \u6A21\u5F0F\u4F7F\u7528\u56FA\u5B9A\u5047\u73B0\u91D1\u6D41\uFF0C\u4EC5\u7528\u4E8E\u5C55\u793A\u4EA7\u54C1\u4EA4\u4E92\u3002",
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
      missing_symbols: []
    },
    warnings: ["Demo \u5047\u6570\u636E\uFF1A\u73B0\u91D1\u6D41\u65F6\u70B9\u4E0E\u91D1\u989D\u4E0D\u4EE3\u8868\u4EFB\u4F55\u771F\u5B9E\u8D26\u6237\u3002"]
  };
}
function comparisonPayload(snapshot, history, generatedAt = (/* @__PURE__ */ new Date()).toISOString()) {
  const results = {};
  for (const symbol of Object.keys(BENCHMARKS)) {
    results[symbol] = cashFlowMirrorVsBenchmark(snapshot, history, symbol);
  }
  const spy = results.SPY ?? cashFlowMirrorVsBenchmark(snapshot, history, "SPY");
  const spyRows = spy.rows ?? [];
  const dates = spyRows.map((row) => row.date).filter(Boolean);
  const portfolioByDate = {};
  for (const row of spyRows) {
    if (row.date) portfolioByDate[row.date] = row.adjusted_portfolio_value;
  }
  const benchmarkSeries = {};
  const benchmarkReturns = {};
  for (const [symbol, result] of Object.entries(results)) {
    const rows = result.rows ?? [];
    const values = {};
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
      benchmark_returns: benchmarkReturns
    },
    generated_at: generatedAt
  };
}
function profitCalendarPayload(snapshot, history, income) {
  const summary = portfolioSummary(snapshot);
  const marketValueUsd = Number(summary.market_value_usd || 0);
  const labSummary = labHistorySummary(snapshot, history);
  const nav = labSummary.nav ?? [];
  return {
    basis: "current-weight model daily return multiplied by current portfolio market value",
    currency: "USD",
    market_value_usd: marketValueUsd,
    rows: nav.map((row) => ({
      date: row.date,
      return: row.return,
      pnl_usd: marketValueUsd * Number(row.return || 0)
    })),
    income
  };
}
function calculateVolumeProfile(rows, opts = {}) {
  const bins = opts.bins ?? 36;
  const valueArea = opts.valueArea ?? 0.7;
  const lookback = opts.lookback ?? 120;
  const minimumBars = opts.minimumBars ?? 20;
  const valid = [];
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
  const volumeByBin = new Array(binCount).fill(0);
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
    method: "daily_ohlcv_uniform_price_bins"
  };
}
function holdingVolumeProfile(snapshot, history, tickerInput) {
  const normalized = String(tickerInput || "").trim().toUpperCase();
  const holdings = snapshot.portfolio.holdings;
  const holding = holdings.find(
    (row) => normalized === String(row.ticker || "").trim().toUpperCase() || normalized === String(row.yahoo_symbol || "").trim().toUpperCase()
  );
  if (!holding) return null;
  const tickerLabel = String(holding.ticker || normalized).trim().toUpperCase();
  const symbol = String(holding.yahoo_symbol || holding.ticker || normalized).trim().toUpperCase();
  const cachedRows = history.prices?.[symbol] ?? [];
  const profile = calculateVolumeProfile(cachedRows);
  const marketRows = snapshot.market.rows;
  const marketRow = marketRows.find(
    (row) => normalized === String(row.ticker || "").trim().toUpperCase() || normalized === String(row.yahoo_symbol || "").trim().toUpperCase()
  ) ?? {};
  const currency = marketRow.quote_currency || marketRow.currency || holding.price_currency || holding.cost_currency || "USD";
  return {
    ticker: tickerLabel,
    symbol,
    currency: String(currency).toUpperCase(),
    ...profile
  };
}
function portfolioOverviewPayload(snapshot) {
  const detail = holdingsDetail(snapshot).rows;
  const summary = portfolioSummary(snapshot);
  let todayPnl = 0;
  for (const row of detail) {
    const change = Number(row.today_change_percent);
    const value = Number(row.market_value_usd);
    if (change === null || change === void 0 || Number.isNaN(change) || value === null || value === void 0) {
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
      flat: detail.filter((row) => Number(row.today_change_percent || 0) === 0).length
    },
    top_holdings: detail.slice(0, 10),
    sectors: sectorConcentration(snapshot).rows ?? []
  };
}
function portfolioChartPayload(snapshot, history) {
  const summary = portfolioSummary(snapshot);
  const holdings = snapshot.portfolio.holdings;
  const asOf = String(summary.as_of || "");
  const dateMatch = /^(\d{4}-\d{2}-\d{2})/.exec(asOf);
  const currentDate = dateMatch ? dateMatch[1] : (/* @__PURE__ */ new Date()).toISOString().slice(0, 10);
  const marketValue = Number(summary.market_value_usd || 0);
  const summaryCost = summary.total_cost_usd_standard;
  const positionCost = summaryCost !== void 0 && summaryCost !== null ? Number(summaryCost) : holdings.reduce((sum, row) => sum + Number(row.cost_usd_standard || 0), 0);
  return {
    basis: "current_trading212_open_positions_excluding_cash",
    position_count: holdings.length,
    position_history: currentOpenPositionsHistory(snapshot, history),
    current_point: {
      date: currentDate,
      as_of: asOf || null,
      market_value_usd: marketValue,
      cost_usd: positionCost
    }
  };
}
function returnsExplanation(snapshot, history) {
  const twr = cumulativeVsBenchmark(snapshot, history, "SPY");
  const range = twr.date_range;
  const explanation = "\u5F53\u524D\u5904\u4E8E\u5047\u6570\u636E\u6A21\u5F0F\uFF1A\u8FD9\u662F\u4E00\u6BB5\u56FA\u5B9A\u793A\u4F8B\u5206\u6790\uFF0C\u6CA1\u6709\u8BFB\u53D6\u672C\u673A AI Key\uFF0C\u4E5F\u6CA1\u6709\u8C03\u7528\u5916\u90E8 AI Provider\u3002\u5173\u95ED\u5047\u6570\u636E\u6A21\u5F0F\u5E76\u5728\u8BBE\u7F6E\u91CC\u914D\u7F6E AI Key \u540E\uFF0CCatfolio \u624D\u4F1A\u6839\u636E\u771F\u5B9E\u7EC4\u5408\u751F\u6210 AI \u5206\u6790\u3002";
  return { explanation, period: `${range?.start ?? "\u2014"} ~ ${range?.end ?? "\u2014"}` };
}
function monthlyReturnHeatmap(snapshot, history, years = [2025, 2026]) {
  const summary = labHistorySummary(snapshot, history);
  const nav = summary.nav ?? [];
  const monthReturns = {};
  for (const row of nav) {
    const year = Number(String(row.date).slice(0, 4));
    if (!years.includes(year)) continue;
    const key = String(row.date).slice(0, 7);
    monthReturns[key] = (monthReturns[key] ?? 1) * (1 + row.return);
  }
  const rows = Object.keys(monthReturns).sort().map((month) => ({ month, return: monthReturns[month] - 1 }));
  return {
    basis: "current-weight model portfolio, not cash-flow adjusted account return",
    date_range: {
      start: nav.length ? nav[0].date : null,
      end: nav.length ? nav[nav.length - 1].date : null
    },
    rows
  };
}
function drawdownCurve(snapshot, history) {
  const summary = labHistorySummary(snapshot, history);
  const nav = summary.nav ?? [];
  let peak = 1;
  const rows = [];
  let maxDrawdown = 0;
  for (const row of nav) {
    peak = Math.max(peak, row.nav);
    const drawdown = peak ? row.nav / peak - 1 : 0;
    maxDrawdown = Math.min(maxDrawdown, drawdown);
    rows.push({ date: row.date, drawdown });
  }
  return { max_drawdown: maxDrawdown, rows };
}
function returnDistribution(snapshot, history) {
  const summary = labHistorySummary(snapshot, history);
  const returns = (summary.nav ?? []).map((row) => row.return);
  if (!returns.length) return { bins: [], stats: {} };
  const low = Math.min(...returns);
  const high = Math.max(...returns);
  const bucketCount = 20;
  const width = high > low ? (high - low) / bucketCount : 0.01;
  const bins = [];
  for (let index = 0; index < bucketCount; index += 1) {
    const start = low + index * width;
    const end = start + width;
    const count = returns.filter(
      (value) => start <= value && value < end || index === bucketCount - 1 && value >= start
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
      sample_days: returns.length
    }
  };
}
function correlationMatrix(snapshot, history, limit = 14) {
  const universe = groupedUniverse(snapshot, history, { maxSymbols: limit, excludeBenchmarks: true });
  const symbols = universe.symbols;
  const matrix = universe.matrix;
  const rows = [];
  for (const left of symbols) {
    const row = [];
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
function monthlyContributionWaterfall(snapshot, history) {
  const universe = groupedUniverse(snapshot, history, { maxSymbols: 18, excludeBenchmarks: true });
  if (!universe.dates.length) return { month: null, rows: [] };
  const month = universe.dates[universe.dates.length - 1].slice(0, 7);
  const indexes = universe.dates.map((date, idx) => ({ date, idx })).filter(({ date }) => date.startsWith(month)).map(({ idx }) => idx);
  const rows = [];
  for (const [symbol, returns] of Object.entries(universe.matrix)) {
    let compounded = 1;
    for (const idx of indexes) compounded *= 1 + returns[idx];
    const contribution = (universe.weights[symbol] ?? 0) * (compounded - 1);
    rows.push({ symbol, contribution });
  }
  rows.sort((a, b) => Math.abs(num(b.contribution)) - Math.abs(num(a.contribution)));
  return { month, basis: "current-weight model contribution", rows: rows.slice(0, 16) };
}
function analyticsPayload(snapshot, history) {
  return {
    monthly_returns: monthlyReturnHeatmap(snapshot, history),
    drawdown: drawdownCurve(snapshot, history),
    correlation_matrix: correlationMatrix(snapshot, history),
    return_distribution: returnDistribution(snapshot, history),
    waterfall: monthlyContributionWaterfall(snapshot, history)
  };
}
function calcReturn(prices, offset) {
  if (!prices.length || prices.length <= offset) return null;
  const latest = Number(prices[prices.length - 1].close);
  const past = Number(prices[prices.length - 1 - offset].close);
  return past ? (latest / past - 1) * 100 : null;
}
function calcYtdReturn(prices) {
  if (!prices.length) return null;
  const latestDate = String(prices[prices.length - 1].date);
  const latestYear = Number(latestDate.slice(0, 4));
  let pastRow = null;
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
function holdingsHeatmap(snapshot, history) {
  const detail = holdingsDetail(snapshot).rows;
  const holdings = holdingsByTicker(snapshot);
  const fundamentals = snapshot.fundamentals;
  const valuation = {};
  for (const row of fundamentals.rows) {
    if (row.ticker) valuation[String(row.ticker)] = row;
  }
  const valuationAsOfUnix = fundamentals.as_of_unix;
  const pricesMap = history.prices ?? {};
  const rows = [];
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
      return_1y: calcReturn(prices, 252)
    });
  }
  return { rows };
}
export {
  ASSET_ALIASES,
  BENCHMARKS,
  SP500_ETF_TICKERS,
  analyticsPayload,
  annualizedStats,
  backtest,
  calculateVolumeProfile,
  cashFlowMirrorVsBenchmark,
  comparisonPayload,
  correlationMatrix,
  cumulativeVsBenchmark,
  currentOpenPositionsHistory,
  drawdownCurve,
  etfLookthrough,
  groupedUniverse,
  holdingVolumeProfile,
  holdingsDetail,
  holdingsDetailPayload,
  holdingsHeatmap,
  labHistorySummary,
  monthlyContributionWaterfall,
  monthlyReturnHeatmap,
  navSeries,
  num,
  portfolioChartPayload,
  portfolioOverviewPayload,
  portfolioReturns,
  portfolioSummary,
  profitCalendarPayload,
  pyRound,
  returnDistribution,
  returnsExplanation,
  returnsFromPrices,
  sectorConcentration
};
