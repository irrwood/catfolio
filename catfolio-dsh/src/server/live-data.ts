/**
 * Live data loader — reads the real Catfolio snapshot from the project's
 * `outputs/portfolio_analysis_v2/` directory (Trading 212 sync output) and
 * shapes it into the same `{snapshot, history, income}` contract the engine
 * consumes. Falls back to the bundled demo data when the live snapshot is
 * missing or unreadable.
 *
 * Detection order:
 *   1. `$CATFOLIO_DATA_DIR` (if set) — custom data directory
 *   2. `<workspace>/outputs/portfolio_analysis_v2` — repo-local real data
 *   3. bundled demo data
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { IncomeSummary, LabHistory, Snapshot, Sp500Dataset } from "../core/engine.js";
import { dshHome } from "./settings.js";

const here = dirname(fileURLToPath(import.meta.url));
const BUNDLED_DATA = join(here, "..", "data");

function loadJson<T>(path: string, fallback: T): T {
  try {
    if (!existsSync(path)) return fallback;
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return fallback;
  }
}

/** Decode the harness session workspace path from $DSH_SESSION_JSONL. */
function workspaceFromSession(): string | null {
  const session = process.env.DSH_SESSION_JSONL;
  if (!session) return null;
  // sessions/--Users-qian-Documents-~80A1~7968~5206~6790--/session-.../...
  const match = /\/sessions\/([^/]+?)--\/session-/.exec(session);
  if (!match) return null;
  try {
    // Workspace token: path segments joined by "--"; non-ASCII characters are
    // encoded as ~XXXX where XXXX is the UTF-16BE code unit in hex.
    const decoded = match[1]
      .split("--")
      .map((segment) => {
        if (!segment.includes("~")) return segment;
        const parts: string[] = [];
        let i = 0;
        while (i < segment.length) {
          if (segment[i] === "~") {
            const hex = segment.slice(i + 1, i + 5);
            if (hex.length === 4) {
              parts.push(String.fromCharCode(parseInt(hex, 16)));
              i += 5;
              continue;
            }
          }
          parts.push(segment[i]);
          i += 1;
        }
        return parts.join("");
      })
      .join("/");
    if (decoded.startsWith("/")) return decoded;
    return null;
  } catch {
    return null;
  }
}

/** Read workspace paths from the harness registry ($DSH_HOME/storages/workspace.json). */
function workspacesFromRegistry(): string[] {
  const registryPath = join(dshHome(), "storages", "workspace.json");
  if (!existsSync(registryPath)) return [];
  try {
    const registry = JSON.parse(readFileSync(registryPath, "utf8")) as {
      tables?: { workspaces?: Record<string, { path?: string }> };
    };
    const rows = registry.tables?.workspaces ?? {};
    return Object.values(rows)
      .map((row) => row.path)
      .filter((path): path is string => Boolean(path));
  } catch {
    return [];
  }
}

function findV2Dir(): string | null {
  // 1. explicit env override
  const env = process.env.CATFOLIO_DATA_DIR;
  if (env) {
    const candidate = join(env, "portfolio_analysis_v2");
    if (existsSync(join(candidate, "portfolio_analysis.json"))) return candidate;
  }
  // 2. CATFOLIO_ROOT/outputs/portfolio_analysis_v2
  if (process.env.CATFOLIO_ROOT) {
    const candidate = join(process.env.CATFOLIO_ROOT, "outputs", "portfolio_analysis_v2");
    if (existsSync(join(candidate, "portfolio_analysis.json"))) return candidate;
  }
  // 3. every harness workspace registered in $DSH_HOME/storages/workspace.json
  for (const workspace of workspacesFromRegistry()) {
    const candidate = join(workspace, "outputs", "portfolio_analysis_v2");
    if (existsSync(join(candidate, "portfolio_analysis.json"))) return candidate;
  }
  // 4. the harness session workspace (decoded from $DSH_SESSION_JSONL)
  const workspace = workspaceFromSession();
  if (workspace) {
    const candidate = join(workspace, "outputs", "portfolio_analysis_v2");
    if (existsSync(join(candidate, "portfolio_analysis.json"))) return candidate;
  }
  // 5. walk up from the plugin package / cwd looking for outputs/portfolio_analysis_v2
  const startDirs = [
    here,
    dirname(here),
    dirname(dirname(here)),
    process.cwd(),
    dirname(process.cwd()),
    dirname(dirname(process.cwd())),
  ];
  for (const start of startDirs) {
    const candidate = join(start, "outputs", "portfolio_analysis_v2");
    if (existsSync(join(candidate, "portfolio_analysis.json"))) return candidate;
  }
  return null;
}

const FX_TO_USD: Record<string, number> = {
  USD: 1.0,
  GBP: 1.346,
  GBX: 0.01346,
  EUR: 1.163,
};

function normalizeCurrency(currency: unknown): string {
  const value = String(currency ?? "");
  if (value === "GBp" || value === "GBX") return "GBX";
  return value || "USD";
}

function usdEquivalent(amount: number, currency: string): number | null {
  const rate = FX_TO_USD[normalizeCurrency(currency)];
  if (rate === undefined) return null;
  return amount * rate;
}

/** Same currency sanity check as the Python app's reconcile_market_currencies. */
function reconcileMarketCurrencies(portfolio: Record<string, unknown>, market: Record<string, unknown>): Record<string, unknown> {
  const holdings: Record<string, Record<string, unknown>> = {};
  for (const row of (portfolio.holdings ?? []) as Record<string, unknown>[]) {
    const ticker = String(row.ticker ?? "").toUpperCase();
    if (ticker) holdings[ticker] = row;
  }
  const rows: Record<string, unknown>[] = [];
  for (const sourceRow of (market.rows ?? []) as Record<string, unknown>[]) {
    const row = { ...sourceRow };
    const holding = holdings[String(row.ticker ?? "").toUpperCase()];
    if (!holding || row.quote_price === null || row.quote_price === undefined) {
      rows.push(row);
      continue;
    }
    const shares = Number(row.shares ?? holding.shares ?? 0);
    const currency = resolveQuoteCurrency(holding, row.quote_currency, Number(row.quote_price), shares);
    if (currency !== row.quote_currency) {
      const nativeValue = shares * Number(row.quote_price);
      const marketValueUsd = usdEquivalent(nativeValue, currency);
      const costUsd = Number(row.cost_usd_standard ?? holding.cost_usd_standard ?? 0);
      row.quote_currency = currency;
      row.market_value_native = nativeValue;
      row.market_value_usd = marketValueUsd;
      row.price_unrealized_usd = marketValueUsd !== null ? marketValueUsd - costUsd : null;
      row.price_unrealized_percent = marketValueUsd !== null && costUsd ? (marketValueUsd / costUsd - 1) * 100 : null;
      row.unrealized_usd = marketValueUsd !== null ? marketValueUsd - costUsd : null;
      row.unrealized_percent = marketValueUsd !== null && costUsd ? (marketValueUsd / costUsd - 1) * 100 : null;
      row.pnl_basis = "price_difference";
    }
    rows.push(row);
  }
  return { ...market, rows };
}

function resolveQuoteCurrency(
  holding: Record<string, unknown>,
  reportedCurrency: unknown,
  price: number,
  shares: number,
): string {
  const reported = normalizeCurrency(reportedCurrency);
  const expected = normalizeCurrency(holding.price_currency ?? holding.cost_currency);
  if (reported === expected) return reported;
  const nativeValue = shares * price;
  const expectedUsd = usdEquivalent(nativeValue, expected);
  const reportedUsd = usdEquivalent(nativeValue, reported);
  if (expectedUsd === null || reportedUsd === null) return reported;
  // Pick the currency whose USD value best agrees with the broker's invested USD.
  const brokerInvested = Number(holding.cost_usd_standard ?? 0);
  const expectedDelta = Math.abs(expectedUsd - brokerInvested);
  const reportedDelta = Math.abs(reportedUsd - brokerInvested);
  return expectedDelta <= reportedDelta ? expected : reported;
}

export interface LiveData {
  snapshot: Snapshot;
  history: LabHistory;
  income: IncomeSummary;
  sp500: Sp500Dataset;
  source: "live" | "live-unavailable" | "demo";
  liveDir: string | null;
  holdings: number;
}

/**
 * Locate the Catfolio repo root (a directory containing the Trading 212
 * pipeline scripts). Shares the same workspace-discovery chain as the data
 * loader: env override → harness workspace registry → session workspace →
 * walk up from cwd/package — so it works from inside the GUI process where
 * the working directory is not the repo.
 */
export function findRepoRoot(): string | null {
  const probe = (root: string): boolean =>
    existsSync(join(root, "scripts", "build_trading212_v2.py")) || existsSync(join(root, "scripts", "enrich_trading212_data.py"));
  if (process.env.CATFOLIO_ROOT && probe(process.env.CATFOLIO_ROOT)) return process.env.CATFOLIO_ROOT;
  for (const workspace of workspacesFromRegistry()) {
    if (probe(workspace)) return workspace;
  }
  const session = workspaceFromSession();
  if (session && probe(session)) return session;
  const startDirs = [
    process.cwd(),
    dirname(process.cwd()),
    dirname(dirname(process.cwd())),
    here,
    dirname(here),
    dirname(dirname(here)),
  ];
  for (const start of startDirs) {
    if (start && probe(start)) return start;
  }
  return null;
}

/** Shape the real snapshot files into the engine contract. */
function buildLiveSnapshot(v2Dir: string): Snapshot {
  const portfolio = loadJson(join(v2Dir, "portfolio_analysis.json"), {
    summary: {},
    holdings: [],
    holdings_by_account: [],
    closed_positions: [],
    import_transactions: [],
  }) as Record<string, unknown>;

  // The real portfolio file is flat: holdings live at top level, not under a
  // nested "portfolio" key. `holdings` is the account-merged view (the engine's
  // canonical source); `holdings_by_account` is the per-account breakdown.
  const holdings = (portfolio.holdings ?? []) as Record<string, unknown>[];
  const holdingsByAccount = (portfolio.holdings_by_account ?? holdings) as Record<string, unknown>[];
  const summary = (portfolio.summary ?? {}) as Record<string, unknown>;
  const portfolioSection = {
    summary,
    holdings: holdings.length ? holdings : holdingsByAccount,
    holdings_by_account: holdingsByAccount,
    closed_positions: (portfolio.closed_positions ?? []) as Record<string, unknown>[],
    import_transactions: (portfolio.import_transactions ?? []) as Record<string, unknown>[],
  };

  // Market: prefer the newer live cache (119 merged rows, matches holdings);
  // fall back to the pipeline market_data.json. Same policy as the Python app's
  // `_latest_market_cache` (newest `as_of_unix` with rows wins).
  const marketData = loadJson(join(v2Dir, "market_data.json"), { rows: [], warnings: [] }) as Record<string, unknown>;
  const liveMarket = loadJson(join(v2Dir, "live_market_data.json"), null) as Record<string, unknown> | null;
  let market = marketData;
  if (liveMarket && (liveMarket.rows as unknown[])?.length) {
    const liveFresh = Number(liveMarket.as_of_unix ?? 0);
    const pipelineFresh = Number(marketData.as_of_unix ?? 0);
    if (liveFresh >= pipelineFresh) market = liveMarket;
  }
  const reconciled = reconcileMarketCurrencies(portfolioSection, market);

  const fundamentals = loadJson(join(v2Dir, "fundamentals_data.json"), { rows: [], warnings: [] }) as Record<string, unknown>;
  const trading212 = loadJson(join(v2Dir, "trading212_data.json"), {
    summary: {},
    account_cash: {},
    positions: [],
    warnings: [],
  }) as Record<string, unknown>;

  return {
    portfolio: portfolioSection,
    market: reconciled,
    fundamentals,
    trading212,
    loaded_at: new Date().toISOString(),
  } as Snapshot;
}

export function loadLiveData(mode: "auto" | "live" | "demo" = "auto"): LiveData {
  if (mode !== "demo") {
    const v2Dir = findV2Dir();
    if (v2Dir) {
      try {
        const snapshot = buildLiveSnapshot(v2Dir);
        const history = loadJson(join(v2Dir, "lab_history_data.json"), { prices: {} }) as LabHistory;
        const income = loadJson(join(BUNDLED_DATA, "demo_income.json"), {
          currency: "USD",
          rows: [],
          monthly_rows: [],
        }) as IncomeSummary;
        const sp500 = loadJson(join(BUNDLED_DATA, "sp500_holdings.json"), { rows: [] }) as Sp500Dataset;
        // A live snapshot without any holdings is not useful — fall back to demo.
        if ((snapshot.portfolio.holdings?.length ?? 0) > 0) {
          return { snapshot, history, income, sp500, source: "live", liveDir: v2Dir };
        }
      } catch {
        // fall through to demo
      }
    }
    if (mode === "live") {
      // Forced live mode with no usable snapshot: return an empty live shape so
      // callers can distinguish "configured but unavailable" from "demo".
      return {
        snapshot: loadJson<Snapshot>(join(BUNDLED_DATA, "demo_snapshot.json"), {} as Snapshot),
        history: loadJson<LabHistory>(join(BUNDLED_DATA, "demo_lab_history.json"), { prices: {} }),
        income: loadJson<IncomeSummary>(join(BUNDLED_DATA, "demo_income.json"), { currency: "USD", rows: [], monthly_rows: [] }),
        sp500: loadJson<Sp500Dataset>(join(BUNDLED_DATA, "sp500_holdings.json"), { rows: [] }),
        source: "live-unavailable",
        liveDir: null,
      };
    }
  }
  return {
    snapshot: loadJson<Snapshot>(join(BUNDLED_DATA, "demo_snapshot.json"), {} as Snapshot),
    history: loadJson<LabHistory>(join(BUNDLED_DATA, "demo_lab_history.json"), { prices: {} }),
    income: loadJson<IncomeSummary>(join(BUNDLED_DATA, "demo_income.json"), { currency: "USD", rows: [], monthly_rows: [] }),
    sp500: loadJson<Sp500Dataset>(join(BUNDLED_DATA, "sp500_holdings.json"), { rows: [] }),
    source: "demo",
    liveDir: null,
  };
}
