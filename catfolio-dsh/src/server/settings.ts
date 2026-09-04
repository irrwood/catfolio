/**
 * Catfolio plugin settings — a small owner-only JSON document under the
 * harness home (`$DSH_HOME/catfolio.json`, mode 0600). Holds the Trading 212
 * credentials and the data-source mode so the plugin works without touching
 * the original Catfolio Keychain entries.
 *
 * The settings file is read at boot by live-data; saving re-reads the
 * snapshot so changes apply immediately.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/**
 * Resolve the DeepSeek Harness home (`$DSH_HOME`, default `~/.dsh`).
 * Prefer the environment variable; fall back to the user home so the plugin
 * keeps working when the GUI is started without `DSH_HOME` exported (e.g.
 * `npm exec @deepseek-ai/dsh web` from a plain terminal).
 */
export function dshHome(): string {
  return process.env.DSH_HOME ?? join(homedir(), ".dsh");
}

export interface CatfolioSettings {
  /** Trading 212 credentials (kept in this file, mode 0600). */
  trading212?: {
    apiKey?: string;
    apiSecret?: string;
    apiKey2?: string;
    apiSecret2?: string;
    accounts?: string;
  };
  /** Data source: "auto" (live snapshot when present, demo fallback) | "live" | "demo". */
  dataSource?: "auto" | "live" | "demo";
}

const DEFAULT_SETTINGS: CatfolioSettings = {
  trading212: {},
  dataSource: "auto",
};

export function settingsPath(): string {
  return join(dshHome(), "catfolio.json");
}

export function readSettings(): CatfolioSettings {
  const path = settingsPath();
  try {
    if (!existsSync(path)) return { ...DEFAULT_SETTINGS };
    const raw = JSON.parse(readFileSync(path, "utf8")) as Partial<CatfolioSettings>;
    return {
      trading212: { ...(raw.trading212 ?? {}) },
      dataSource: raw.dataSource ?? "auto",
    };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

export function writeSettings(next: CatfolioSettings): CatfolioSettings {
  const path = settingsPath();
  const normalized: CatfolioSettings = {
    trading212: {
      apiKey: next.trading212?.apiKey?.trim() || undefined,
      apiSecret: next.trading212?.apiSecret?.trim() || undefined,
      apiKey2: next.trading212?.apiKey2?.trim() || undefined,
      apiSecret2: next.trading212?.apiSecret2?.trim() || undefined,
      accounts: next.trading212?.accounts?.trim() || undefined,
    },
    dataSource: next.dataSource ?? "auto",
  };
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(normalized, null, 2) + "\n", { mode: 0o600 });
  return normalized;
}

/**
 * Build the environment map the sync pipeline needs, preferring the plugin
 * settings file over the original Keychain. Returns an empty object when
 * neither source has a key.
 */
export function trading212EnvFromSettings(settings: CatfolioSettings): Record<string, string> {
  const env: Record<string, string> = {};
  const t = settings.trading212 ?? {};
  if (t.apiKey) env.TRADING212_API_KEY = t.apiKey;
  if (t.apiSecret) env.TRADING212_API_SECRET = t.apiSecret;
  if (t.apiKey2) env.TRADING212_API_KEY_2 = t.apiKey2;
  if (t.apiSecret2) env.TRADING212_API_SECRET_2 = t.apiSecret2;
  if (t.accounts) env.TRADING212_ACCOUNTS = t.accounts;
  else if (t.apiKey2) env.TRADING212_ACCOUNTS = "default,2";
  return env;
}

/** Redact secrets for any payload that may reach the browser. */
export function redactSettings(settings: CatfolioSettings): CatfolioSettings {
  const mask = (value?: string) => (value ? "••••••••" : undefined);
  return {
    trading212: {
      apiKey: mask(settings.trading212?.apiKey),
      apiSecret: mask(settings.trading212?.apiSecret),
      apiKey2: mask(settings.trading212?.apiKey2),
      apiSecret2: mask(settings.trading212?.apiSecret2),
      accounts: settings.trading212?.accounts,
    },
    dataSource: settings.dataSource ?? "auto",
  };
}
