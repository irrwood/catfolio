/**
 * Catfolio demo data loader — embedded JSON assets shipped with the plugin.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import type { IncomeSummary, LabHistory, Snapshot, Sp500Dataset } from "../core/engine.js";

const here = dirname(fileURLToPath(import.meta.url));
// lib/ is the build output directory; data/ sits next to it in the package.
const dataDir = join(here, "..", "data");

function load<T>(name: string): T {
  const raw = readFileSync(join(dataDir, name), "utf8");
  return JSON.parse(raw) as T;
}

export interface DemoData {
  snapshot: Snapshot;
  history: LabHistory;
  income: IncomeSummary;
  sp500: Sp500Dataset;
}

export function loadDemoData(): DemoData {
  return {
    snapshot: load<Snapshot>("demo_snapshot.json"),
    history: load<LabHistory>("demo_lab_history.json"),
    income: load<IncomeSummary>("demo_income.json"),
    sp500: load<Sp500Dataset>("sp500_holdings.json"),
  };
}
