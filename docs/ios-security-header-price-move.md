# Stock detail header and price-movement analysis

Design: Figma `EtNSXmasS8lz9JzrWUoMd9`, node `282:2003` (2026-09-10).

## UI

- Instrument identity and native close button above a left-aligned price/return block.
- Dark graphite-to-black header background; semantic light counterpart.
- Rounded-rectangle account cards retain linked multi-selection. The third line is the existing portfolio engine's unrealized P&L, converted to the card's quote currency. Unknown disclosure cost is `—`, not zero.
- Two native glass actions: price-movement analysis and the existing explicit quote refresh. Their template vector icons are exported from the specified Figma node.
- The shared grouped time picker, latest quote semantics, cost line, trade markers, chart gestures and morph animation remain in use. The plot is shorter to accommodate the new stacked header.
- A native zoom sheet opens for analysis; it uses the existing evidence/result presentation with an interval-specific heading.

## Scope and privacy

The action title follows the actual displayed chart interval: positive / negative / effectively unchanged. The frozen request contains ticker, company name, quote currency, interval label, dated start/end prices and intraday status. It contains no account IDs, positions, shares, costs, transactions or portfolio totals. Missing or invalid dated prices disable the action.

Only tapping the action (or an explicit retry) starts research. Scrubbing, changing time ranges, loading the header and account switching do not start AI requests. The sheet shows exact dates and explains that this is not necessarily today's move.

Research reuses readable public article bodies, passage validation and a second evidence audit. Undated and out-of-window sources are excluded. Facts and possible interpretations remain separate; correlation is not presented as established causation. If evidence is unavailable, the sheet reports that limitation rather than inventing a cause.

**Coverage limit:** the current shared feed/body pipeline prioritizes recent company news and filings. A long or historical price interval may have only partial or no coverage. The prompt and UI disclose this; they do not claim complete return attribution.

## Cache and lifecycle

`SecurityPriceMoveStore` uses a separate `security-price-moves-v1.json` cache keyed by instrument, currency, interval, exact quote observations and language. Existing generic AI-development and market-data caches are untouched. Successful results persist until explicitly replaced for the same key. Failed refreshes retain the previous result and other intervals.

Concurrent repeated taps join one run. Dismissal permits an in-flight result to finish; the visible Cancel action cancels it and rejects late delivery. Run IDs protect state across cancellation/retry. Date serialization preserves subsecond identity.

## Validation

- iOS 26.5 simulator builds and focused XCTest cases cover interval direction, evidence bounds, privacy fields, deduplication, exact persistent cache identity, failed-refresh retention, cancellation and native light/dark/large-type layout.
- UI fixtures use public/synthetic price histories and injected research dependencies, not live AI requests or user-cache deletion.
- Python contracts cover the Figma header, explicit action, native sheet, shared picker and optional P&L. Existing line-motion, detail-price, picker-performance and research-card contracts are also exercised.
- No physical-device installation is performed by this task.

Latest run: `/tmp/CatfolioSecurityHeaderTests2.xcresult` — 33 passed, 1 intentionally skipped opt-in live AI test; no failures. This also includes the native detail-dismiss/refresh boundary and shared line-motion regression cases. Six focused Python contract modules, including the new header module, passed (26 tests).

Broader checks found unrelated existing mismatches, left unchanged: two assertions in `test_ios_holding_detail_accounts.py` still expect the former `hasSelectedDetailAccounts` visibility expression and inline home-return calculation; current implementations use `showsPosition` and the shared return helper. The global localization audit also reports five missing labels in `AnalystHistoryView.swift`; none belongs to the new header/movement flow. New bilingual keys match and contain no duplicate entries.
