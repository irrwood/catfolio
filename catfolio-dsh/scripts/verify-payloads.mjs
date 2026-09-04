/**
 * Verify the TS engine reproduces the captured Python API payloads exactly.
 * Usage: node scripts/verify-payloads.mjs
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import * as esbuild from "esbuild";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const captured = "/tmp/catfolio-payloads";

// Build the engine to a temp CJS module for direct import.
const outfile = join(root, ".verify-engine.mjs");
await esbuild.build({
  entryPoints: [join(root, "src/core/engine.ts")],
  bundle: true,
  format: "esm",
  platform: "node",
  outfile,
  logLevel: "silent",
});
const engine = await import(outfile);

const snapshot = JSON.parse(readFileSync(join(root, "data/demo_snapshot.json"), "utf8"));
const history = JSON.parse(readFileSync(join(root, "data/demo_lab_history.json"), "utf8"));
const income = JSON.parse(readFileSync(join(root, "data/demo_income.json"), "utf8"));
const sp500 = JSON.parse(readFileSync(join(root, "data/sp500_holdings.json"), "utf8"));

function norm(value) {
  // strip dynamic fields for comparison
  if (Array.isArray(value)) return value.map(norm);
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (k === "generated_at" || k === "loaded_at" || k === "as_of" || k === "as_of_unix" || k === "last_trade_time" || k === "market_time") continue;
      out[k] = norm(v);
    }
    return out;
  }
  return value;
}

function deepEqual(a, b, path = "$") {
  if (typeof a === "number" && typeof b === "number") {
    // exact match preferred; allow tiny float tolerance
    const ok = a === b || Math.abs(a - b) < 1e-9 * Math.max(1, Math.abs(a), Math.abs(b));
    if (!ok) return `float mismatch at ${path}: ${a} vs ${b}`;
    return null;
  }
  if (typeof a !== typeof b) return `type mismatch at ${path}: ${typeof a} vs ${typeof b}`;
  if (Array.isArray(a) !== Array.isArray(b)) return `array mismatch at ${path}`;
  if (a === null || b === null) return a === b ? null : `null mismatch at ${path}`;
  if (typeof a === "object") {
    const keysA = Object.keys(a);
    const keysB = Object.keys(b);
    if (keysA.length !== keysB.length) {
      const onlyA = keysA.filter((k) => !(k in b));
      const onlyB = keysB.filter((k) => !(k in a));
      return `key-count mismatch at ${path}: onlyA=[${onlyA}] onlyB=[${onlyB}]`;
    }
    for (const key of keysA) {
      if (!(key in b)) return `missing key at ${path}.${key}`;
      const err = deepEqual(a[key], b[key], `${path}.${key}`);
      if (err) return err;
    }
    return null;
  }
  return a === b ? null : `value mismatch at ${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`;
}

const checks = [
  ["portfolio/overview", engine.portfolioOverviewPayload(snapshot)],
  ["portfolio/chart", engine.portfolioChartPayload(snapshot, history)],
  ["profit-calendar", { profit_calendar: engine.profitCalendarPayload(snapshot, history, income) }],
  ["holdings/detail", engine.holdingsDetailPayload(snapshot)],
  ["etf-lookthrough?basis=market", engine.etfLookthrough(snapshot, "market", sp500)],
  ["holdings/AAPL/volume-profile", engine.holdingVolumeProfile(snapshot, history, "AAPL")],
  ["comparison", engine.comparisonPayload(snapshot, history, "FIXED")],
  ["analytics", engine.analyticsPayload(snapshot, history)],
  ["holdings/heatmap", engine.holdingsHeatmap(snapshot, history)],
];

let failures = 0;
for (const [name, actual] of checks) {
  const file = captured + "/" + name.replace(/[/?=]/g, "_") + ".json";
  const expected = JSON.parse(readFileSync(file, "utf8"));
  const err = deepEqual(norm(actual), norm(expected), `$${name}`);
  if (err) {
    failures += 1;
    console.error(`✗ ${name}: ${err}`);
  } else {
    console.log(`✓ ${name}`);
  }
}

// extra: spot-check summary values from overview
const overview = engine.portfolioOverviewPayload(snapshot);
console.log("\nspot: market_value_usd =", overview.summary.market_value_usd);
console.log("spot: unrealized_usd  =", overview.summary.unrealized_usd);
console.log("spot: today_pnl_usd   =", overview.today_pnl_usd);
console.log("spot: breadth         =", JSON.stringify(overview.breadth));

if (failures) {
  console.error(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nAll payload checks passed");
