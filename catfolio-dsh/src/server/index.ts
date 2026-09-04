/**
 * catfolio-dsh server half — a Cordis plugin that mounts the Catfolio
 * analytics engine as an HTTP API under `/catfolio/api/*` and exposes a
 * `catfolio` service for other host plugins.
 *
 * Enabled via the web profile's cordis.patch.yml:
 *   - insert: [{ id: catfolio, name: "catfolio-dsh" }]
 */
import type { IncomingMessage, ServerResponse } from "node:http";
import { loadLiveData } from "./live-data.js";
import { readSettings, writeSettings, redactSettings, settingsPath, trading212EnvFromSettings, type CatfolioSettings } from "./settings.js";
import {
  analyticsPayload,
  comparisonPayload,
  etfLookthrough,
  holdingsHeatmap,
  holdingVolumeProfile,
  holdingsDetail,
  portfolioChartPayload,
  portfolioOverviewPayload,
  portfolioSummary,
  profitCalendarPayload,
} from "../core/engine.js";
import { returnsExplanationWithLlm, type LlmLike } from "./ai.js";

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

export const name = "catfolio-dsh";
export const inject = ["webServer", "llm"];

function sendJson(res: ServerResponse, status: number, payload: unknown): void {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-cache",
    "access-control-allow-origin": "*",
  });
  res.end(body);
}

function sendText(res: ServerResponse, status: number, body: string, contentType = "text/plain; charset=utf-8"): void {
  res.writeHead(status, { "content-type": contentType, "cache-control": "no-cache" });
  res.end(body);
}

/** Deterministic letter-avatar SVG for a symbol (no network dependency). */
function assetLogoSvg(symbol: string): string {
  const clean = String(symbol || "?").trim().toUpperCase();
  const initial = clean.slice(0, 1) || "?";
  let hue = 0;
  for (const char of clean) hue = (hue + char.charCodeAt(0) * 17) % 360;
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">`,
    `<rect width="32" height="32" rx="8" fill="hsl(${hue}, 42%, 62%)"/>`,
    `<text x="16" y="21.5" text-anchor="middle" font-family="-apple-system, 'PingFang SC', sans-serif" font-size="15" font-weight="700" fill="#ffffff">${initial}</text>`,
    `</svg>`,
  ].join("");
}

/** Host-facing service: plain functions other plugins (or future tools) can call. */
export interface CatfolioService {
  overview(): ReturnType<typeof portfolioOverviewPayload>;
  comparison(): ReturnType<typeof comparisonPayload>;
  analytics(): ReturnType<typeof analyticsPayload>;
  holdingsHeatmap(): ReturnType<typeof holdingsHeatmap>;
  profitCalendar(): ReturnType<typeof profitCalendarPayload>;
  holdingsDetail(): { summary: ReturnType<typeof portfolioSummary>; rows: ReturnType<typeof holdingsDetail>["rows"] };
  etfLookthrough(basis: "cost" | "market"): ReturnType<typeof etfLookthrough>;
  volumeProfile(ticker: string): ReturnType<typeof holdingVolumeProfile>;
  returnsExplanation(): ReturnType<typeof returnsExplanation>;}

interface WebServerLike {
  register(route: { kind: "prefix"; path: string; handler: (req: IncomingMessage, res: ServerResponse) => unknown }): () => void;
}

/** Which provider/model the harness should use for AI calls (settings defaults). */
function llmDefaults(ctx: { llm?: { listProviders?: () => unknown[] } }): { provider: string; model: string } {
  let provider = "deepseek-official";
  let model = "deepseek-v4-flash";
  try {
    const providers = ctx.llm?.listProviders?.() ?? [];
    const first = providers[0] as { provider?: string; models?: { id?: string }[] } | undefined;
    if (first?.provider) provider = first.provider;
    const modelEntry = first?.models?.[0];
    if (modelEntry?.id) model = modelEntry.id;
  } catch {
    // fall through to defaults
  }
  return { provider, model };
}

export function apply(ctx: {
  webServer: WebServerLike;
  llm?: LlmLike & { listProviders?: () => unknown[] };
  provide?: (key: string, value: unknown) => void;
  effect?: (fn: () => unknown, label?: string) => unknown;
}): void {
  let settings = readSettings();
  let data = loadLiveData(settings.dataSource ?? "auto");
  const { provider, model } = llmDefaults(ctx);

  const reloadData = () => {
    data = loadLiveData(settings.dataSource ?? "auto");
  };

  const handleApi = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    try {
      const url = new URL(req.url ?? "/", "http://catfolio.local");
      const path = url.pathname;
      const method = (req.method || "GET").toUpperCase();

      if (path === "/catfolio/api/source" && method === "GET") {
        sendJson(res, 200, {
          source: data.source,
          live_dir: data.liveDir,
          holdings: data.snapshot.portfolio.holdings?.length ?? 0,
          data_source: settings.dataSource ?? "auto",
        });
        return;
      }
      if (path === "/catfolio/api/settings" && method === "GET") {
        sendJson(res, 200, {
          settings: redactSettings(settings),
          source: data.source,
          holdings: data.snapshot.portfolio.holdings?.length ?? 0,
          settings_path: settingsPath(),
        });
        return;
      }
      if (path === "/catfolio/api/settings" && method === "POST") {
        const body = await readBody(req);
        const parsed = JSON.parse(body || "{}") as Partial<CatfolioSettings>;
        const next = writeSettings({
          trading212: parsed.trading212 ?? settings.trading212 ?? {},
          dataSource: parsed.dataSource ?? settings.dataSource ?? "auto",
        });
        settings = next;
        reloadData();
        sendJson(res, 200, {
          settings: redactSettings(settings),
          source: data.source,
          holdings: data.snapshot.portfolio.holdings?.length ?? 0,
          settings_path: settingsPath(),
        });
        return;
      }
      if (path === "/catfolio/api/refresh/trading212" && method === "POST") {
        const { runTrading212Sync } = await import("./sync.js");
        const credentials = trading212EnvFromSettings(settings);
        const result = await runTrading212Sync({ credentials });
        if (result.ok) {
          reloadData();
          result["reloaded"] = { source: data.source, holdings: data.snapshot.portfolio.holdings?.length ?? 0 };
        }
        sendJson(res, result.ok ? 200 : 500, result);
        return;
      }
      if (path === "/catfolio/api/portfolio/overview" && method === "GET") {
        sendJson(res, 200, portfolioOverviewPayload(data.snapshot));
        return;
      }
      if (path === "/catfolio/api/portfolio/chart" && method === "GET") {
        sendJson(res, 200, portfolioChartPayload(data.snapshot, data.history));
        return;
      }
      if (path === "/catfolio/api/profit-calendar" && method === "GET") {
        sendJson(res, 200, { profit_calendar: profitCalendarPayload(data.snapshot, data.history, data.income) });
        return;
      }
      if (path === "/catfolio/api/holdings/detail" && method === "GET") {
        sendJson(res, 200, {
          summary: portfolioSummary(data.snapshot),
          rows: holdingsDetail(data.snapshot).rows,
        });
        return;
      }
      if (path === "/catfolio/api/etf-lookthrough" && method === "GET") {
        const basis = url.searchParams.get("basis") === "market" ? "market" : "cost";
        sendJson(res, 200, etfLookthrough(data.snapshot, basis, data.sp500));
        return;
      }
      const volumeMatch = /^\/catfolio\/api\/holdings\/([^/]+)\/volume-profile$/.exec(path);
      if (volumeMatch && method === "GET") {
        const profile = holdingVolumeProfile(data.snapshot, data.history, decodeURIComponent(volumeMatch[1]));
        if (profile === null) {
          sendJson(res, 404, { detail: "Holding not found" });
        } else {
          sendJson(res, 200, profile);
        }
        return;
      }
      if (path === "/catfolio/api/comparison" && method === "GET") {
        sendJson(res, 200, comparisonPayload(data.snapshot, data.history));
        return;
      }
      if (path === "/catfolio/api/analytics" && method === "GET") {
        sendJson(res, 200, analyticsPayload(data.snapshot, data.history));
        return;
      }
      if (path === "/catfolio/api/holdings/heatmap" && method === "GET") {
        sendJson(res, 200, holdingsHeatmap(data.snapshot, data.history));
        return;
      }
      if (path === "/catfolio/api/ai/returns-explanation" && method === "POST") {
        const result = await returnsExplanationWithLlm(data.snapshot, data.history, ctx.llm, provider, model);
        sendJson(res, 200, result);
        return;
      }
      const logoMatch = /^\/catfolio\/api\/asset-logo\/([^/]+)$/.exec(path);
      if (logoMatch && method === "GET") {
        sendText(res, 200, assetLogoSvg(decodeURIComponent(logoMatch[1])), "image/svg+xml; charset=utf-8");
        return;
      }
      sendJson(res, 404, { detail: "Not found" });
    } catch (error) {
      sendJson(res, 500, { detail: error instanceof Error ? error.message : String(error) });
    }
  };

  const disposer = ctx.webServer.register({
    kind: "prefix",
    path: "/catfolio/api",
    handler: handleApi,
  });
  ctx.effect?.(() => disposer, "catfolio-dsh: api routes");

  const service: CatfolioService = {
    overview: () => portfolioOverviewPayload(data.snapshot),
    comparison: () => comparisonPayload(data.snapshot, data.history),
    analytics: () => analyticsPayload(data.snapshot, data.history),
    holdingsHeatmap: () => holdingsHeatmap(data.snapshot, data.history),
    profitCalendar: () => profitCalendarPayload(data.snapshot, data.history, data.income),
    holdingsDetail: () => ({ summary: portfolioSummary(data.snapshot), rows: holdingsDetail(data.snapshot).rows }),
    etfLookthrough: (basis) => etfLookthrough(data.snapshot, basis, data.sp500),
    volumeProfile: (ticker) => holdingVolumeProfile(data.snapshot, data.history, ticker),
    returnsExplanation: () => returnsExplanationWithLlm(data.snapshot, data.history, ctx.llm, provider, model),
  };
  ctx.provide?.("catfolio", service);

  // Warm the heavy computations once at boot so first page load is instant.
  queueMicrotask(() => {
    comparisonPayload(data.snapshot, data.history);
    profitCalendarPayload(data.snapshot, data.history, data.income);
  });
}
