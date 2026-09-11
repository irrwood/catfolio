# Evidence-backed security developments

The security detail and AI inbox now show material developments instead of mandatory bull/bear arguments. Internal `SecurityDebate` names remain for call-site stability.

## Generation

1. Discover English and selected-language news plus issuer-matched SEC filings. Yahoo searches use only the ticker, verify related tickers when supplied, and require a company headline to exclude incidental ticker tags. Feed titles are leads, not generation evidence.
2. Select dated news within 45 days and filings within 120 days; reject future/undated leads. Prefer direct publisher URLs over duplicate Google News wrappers. Fetch up to 16 documents, with bounded request/resource timeouts. Follow normal redirects or explicitly declared publisher metadata; Google wrapper pages themselves never qualify as evidence. Read JSON-LD articleBody, article elements, or SEC document text and decode numeric HTML entities; unavailable bodies do not qualify. Non-filing bodies must mention the company.
3. Supply body excerpts, publication dates, publishers and URLs. Limit the combined input to 64,000 characters, with 12,000 characters per document.
4. Request zero to three material company developments: attributed factual change, conditional business impact, concrete observation and uncertainty. Exclude remote price targets and generic macro opinions.
5. Reject an entire item when any citation is unknown, too short, or not found in the supplied excerpt. Reject a fiscal-year contradiction between the headline and factual change (for example, FY27 versus 2026 财年); publication calendar years are not fiscal years. Count only sources cited by surviving items.
6. Make a separate model review call checking factual support, attribution, relevance and duplicate events. Only accepted items reach the UI. Invalid review output is an error, never a pass.

The source chip exposes the retained verbatim passages with publisher/date/link. Analysis and observation fields are labeled separately from facts. An unreadable collection, malformed model output, failed quote validation or rejected factual review is a retryable failure. A model returning zero qualifying items after reading relevant documents is a separate empty state with the number of documents checked. Neither state is a successful result.

## Persistence

New valid results use `security-developments-v2.json`. The old debate cache is left intact but is no longer loaded or displayed. Languages remain separate within the new cache. Empty results are not saved and cannot replace valid results. Empty records from older builds remain on disk but restore as retryable, not completed. The last valid result remains visible during regeneration and after a failed/empty attempt, including in the AI inbox. Starting research is explicit; appearing/restoring never triggers generation. Repeated taps, including retry, join an in-flight request rather than duplicating fetch/model calls.

## Limits

This is a conservative on-device retrieval pipeline, not comprehensive news coverage. Paywalls, redirects and unsupported markup may make bodies unavailable. Long documents are truncated, and relevant facts outside the excerpts will be missed. Publication dates do not independently establish the date of every event; the generation and review passes must preserve periods from the evidence. Quote matching proves textual provenance, not truth or entailment; model review is an additional fallible check, not a guarantee. No financial calculations change.

## Verification

Focused XCTest fixtures cover symbol-only Yahoo queries, unrelated/incidental ticker filtering, direct-link deduplication, publisher metadata, company matching, HTML entities, body extraction, date filtering and citation/audit checks. Injected-pipeline tests distinguish collection/validation failure from legitimate empty results, verify request deduplication, preserve valid results after failed refresh, and restore legacy empty records without deleting files. Bilingual persistence fixtures use valid cited results.

The September 10 NVDA retrieval recheck read nine relevant bodies, including four issuer-matched SEC documents, from sixteen selected leads. Counts fluctuate with live feeds. An earlier retrieval-only smoke test counted readable but unrelated Yahoo articles and therefore did not demonstrate working generation. `testLiveNVDAWithConfiguredProvider` is an explicit opt-in (`CATFOLIO_LIVE_SECURITY_DEVELOPMENTS=1`) end-to-end check using only public NVDA documents and the device's configured AI provider. It attaches the accepted result to XCTest output without saving the app's research cache. Ordinary tests do not make model calls. Set `CATFOLIO_RESEARCH_TEST_HOST=1` in the Debug XCTest environment to avoid starting portfolio refresh or account/cloud preference tasks on a physical device; normal launches and Release builds are unchanged.

The initial isolated iPhone 17 Pro / iOS 27 run passed all 30 pipeline/retrieval tests, including live generation, and produced three cited items. Human inspection then caught a fiscal-year contradiction, motivating the additional deterministic gate and explicit fiscal-period instructions. The iOS 26.5 simulator suite passed 49 tests with the opt-in network/model test skipped; five holding-card structural tests also passed. Source retrieval and citation checks do not establish that every generated assertion is correct.

The final iOS 27 rerun passed all 31 tests, including the new fiscal-year regression and live NVDA generation. One development survived the stricter review, citing the actual SEC results/outlook passages with consistent FY27 periods. The final live result is an XCTest attachment in `/tmp/CatfolioAINVDA-Final-20260910.xcresult`; the app research cache was not populated by the test. The updated app was installed in place and relaunched normally.
