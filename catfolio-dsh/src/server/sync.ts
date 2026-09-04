/**
 * Trading 212 live sync — bridges the user's Keychain credentials
 * (`com.catfolio.portfolio` service, the same slots the original Catfolio
 * Settings page writes) into the environment the repo's Python pipeline
 * reads, then runs the sync steps that refresh the on-disk snapshot.
 *
 * The pipeline is intentionally the original one: it knows the Trading 212
 * API shape, currency reconciliation, Yahoo history, and FMP fundamentals.
 * The plugin only orchestrates it and reloads the snapshot afterwards.
 */
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { findRepoRoot } from "./live-data.js";

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));

export interface SyncOptions {
  /** Absolute path of the repo root containing scripts/ (default: probed). */
  repoRoot?: string;
  /** Python interpreter to run the pipeline with (default: v3_backend/.venv/bin/python). */
  python?: string;
  /** Pre-set credential env (preferred over the Keychain fallback). */
  credentials?: Record<string, string>;
}

function keychainGet(service: string, account: string): string | null {
  try {
    const out = execFileSync(
      "security",
      ["find-generic-password", "-s", service, "-a", account, "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    );
    const value = String(out ?? "").trim();
    return value || null;
  } catch {
    return null;
  }
}

function defaultPython(repoRoot: string): string {
  const candidates = [
    join(repoRoot, "v3_backend", ".venv", "bin", "python"),
    join(repoRoot, ".venv", "bin", "python"),
    "python3",
  ];
  for (const candidate of candidates) {
    try {
      execFileSync(candidate, ["--version"], { stdio: "ignore" });
      return candidate;
    } catch {
      // try next
    }
  }
  return "python3";
}

/**
 * Read the Trading 212 credentials from the `com.catfolio.portfolio` Keychain
 * service and return them as an env map for the pipeline. Slot 1 = default
 * account, slot 2 = optional second account.
 */
export function trading212EnvFromKeychain(): Record<string, string> {
  const service = "com.catfolio.portfolio";
  const env: Record<string, string> = {};
  const slots: [string, string, string][] = [
    ["TRADING212_API_KEY", "TRADING212_API_SECRET", "default"],
    ["TRADING212_API_KEY_2", "TRADING212_API_SECRET_2", "2"],
  ];
  for (const [keyName, secretName, account] of slots) {
    const key = keychainGet(service, keyName);
    if (key) {
      env[keyName] = key;
      const secret = keychainGet(service, secretName);
      if (secret) env[secretName] = secret;
    }
  }
  // Account list: if a second account is configured, both are synced.
  if (env.TRADING212_API_KEY_2) env.TRADING212_ACCOUNTS = "default,2";
  return env;
}

export interface SyncResult {
  ok: boolean;
  steps: { name: string; ok: boolean; output: string }[];
  error?: string;
}

// The v2 pipeline is a single script: it refreshes Trading 212 positions,
// account cash, and the normalized market rows in one pass (writing
// portfolio_analysis.json / market_data.json / trading212_data.json under
// outputs/portfolio_analysis_v2). Price history lives in lab_history_data.json
// and is refreshed by the original app's history pipeline; it is not part of a
// quick holdings sync.
const SYNC_STEPS = [
  { name: "trading212-v2", script: "build_trading212_v2.py", call: "build_and_write" },
];

export async function runTrading212Sync(options: SyncOptions = {}): Promise<SyncResult> {
  const repoRoot = options.repoRoot ?? findRepoRoot();
  if (!repoRoot) {
    return { ok: false, steps: [], error: "Catfolio repo root not found (probe scripts/enrich_trading212_data.py)" };
  }
  const python = options.python ?? defaultPython(repoRoot);
  // Prefer the plugin settings file; fall back to the original Keychain slots.
  let credentials = options.credentials ?? {};
  if (!credentials.TRADING212_API_KEY) {
    credentials = { ...trading212EnvFromKeychain(), ...credentials };
  }
  if (!credentials.TRADING212_API_KEY) {
    return {
      ok: false,
      steps: [],
      error: "Trading 212 API key 未配置。请在「设置」面板填写 API Key（和 Secret），或使用 Keychain（service com.catfolio.portfolio）。",
    };
  }
  const steps: SyncResult["steps"] = [];
  for (const step of SYNC_STEPS) {
    try {
      let command: string[];
      if ("call" in step && step.call) {
        // v2 builder: import the module and call its write function in-process,
        // mirroring how the FastAPI app refreshes. Runs with the bridged env.
        command = [
          python,
          "-c",
          `import sys, json; sys.path.insert(0, ${JSON.stringify(join(repoRoot, "scripts"))}); import build_trading212_v2; print(json.dumps(build_trading212_v2.build_and_write(), ensure_ascii=False, default=str))`,
        ];
      } else {
        command = [python, join(repoRoot, "scripts", step.script)];
      }
      const { stdout, stderr } = await execFileAsync(command[0], command.slice(1), {
        cwd: repoRoot,
        env: { ...process.env, ...credentials },
        maxBuffer: 16 * 1024 * 1024,
        timeout: 5 * 60 * 1000,
      });
      steps.push({ name: step.name, ok: true, output: (stdout + stderr).slice(-2000) });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      steps.push({ name: step.name, ok: false, output: message.slice(-2000) });
      return { ok: false, steps, error: `${step.name} 同步失败: ${message}` };
    }
  }
  return { ok: true, steps };
}
