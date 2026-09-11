# Fund / ETF detail research visibility

Validated 2026-09-10 on the task-owned iPhone 17 Pro simulator, iOS 26.5
(`9BAE01F7-1E92-45BD-A817-395FC654CC16`). No physical-device operations.

## Rules

- Classify by the bundled company reference's explicit instrument type first.
  Verified company metadata wins over a misleading display name. For unclassified
  instruments, recognize explicit ETF / UCITS tokens, specific fund product
  phrases, and exact entries / aliases in the existing ETF directory.
- Never infer fund status from shares, account/source, sector, or arbitrary
  `FUND` / `INDEX` substrings. An ETF look-through constituent such as NVDA
  remains a company security even with zero direct shares.
- Known funds do not mount speculative company-analysis entries. The six
  modules are AI key developments, analyst consensus, analyst history, earnings
  history, financial statements, and related prediction markets. An individual
  module with usable existing content can still appear; other modules stay
  hidden. The existing USD-only consensus restriction remains.
- Analyst history always requires an actual usable offline snapshot. A ticker
  alone is not evidence that a history page exists.
- Unknown type and temporary provider failure do not imply no coverage.
  Company on-demand entries remain available until an actual empty result is
  confirmed. Empty results are not persisted as a permanent visibility flag.
- Valid cached content is retained after failed or empty refreshes. Read-only
  visibility restoration does not delete, reset, refresh, or rewrite user caches,
  invoke AI, or make provider requests. Expired negative market / earnings
  lookups become unknown instead of suppressing new content indefinitely.
- The research section owns its spacing. When all modules are hidden it has
  zero intrinsic height: no heading, empty card, entry, or extra top gap.
- Financial-sheet visibility changes are applied after dismissal, preserving
  the native sheet / zoom transition source while the sheet is open.
- Price, volume profile, 52-week, holdings, ETF expansion, OI, shared charts,
  and account financial calculations are outside this change.

## Verification

`build-for-testing` passed. Native test result:
`/tmp/CatfolioFundVisibilityTests-20260910.xcresult`

- 36 native tests passed; 1 opt-in live earnings-provider test skipped.
- Suites: HoldingResearchVisibilityTests, HoldingResearchCardLayoutTests,
  HoldingDetailInteractionTests, EarningsHistoryTests,
  ETFLookThroughExpansionTests.
- Coverage includes SPY / QQQ / UCITS aliases, closed-end funds, misleading
  company names, unknown symbols, ETF constituents, per-module positive data,
  transient errors vs confirmed absence, expired negative caches, unchanged
  cache bytes, zero EPS as a real value, and native sheet refresh isolation.
- 18 Python contract tests passed across fund visibility, research cards,
  analyst modal, and financial modal. `git diff --check` passed.

The XCTest host uses the existing DEBUG-only research-test isolation switch,
so these tests do not load or refresh the user's portfolio or start AI analysis.

## Visual checks

Export directory: `/tmp/CatfolioFundVisibilityScreenshots`.
Both appearance modes were inspected. These are native production research
views hosted by deterministic UI tests, not screenshots of live fund results.
The earnings-positive fund case intentionally injects a clearly identified
test fixture to verify that valid content is not blanket-hidden.

- Zero-height context: `3FC8D63F-0C3F-4250-B204-32FE59D15AFF.png`.
  The heading / explanatory text are test-only framing, not added app UI.
- Single earnings module, light: `4C05735A-473F-4243-9E38-DF749110135F.png`.
- Single earnings module, dark: `E8F5497F-AE89-4D6F-BB1F-A85DD3E95259.png`.
- NVDA look-through entries, light: `0062A5C0-DD6B-4D2B-812C-2D045004F6EF.png`.
- NVDA look-through entries, dark: `9137B12B-EC40-47DF-ADA7-1187CF8E3E4B.png`.
