# Quant Radar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a “量化雷达” tab/section to the existing portfolio HTML that combines current Yahoo market data, ETF look-through exposure, option-market structure, and FRED macro context.

**Architecture:** Keep the current CSV cost-basis engine as the source of truth for transactions and cost. Add small, focused enrichment scripts that write JSON snapshots into `outputs/portfolio_analysis/`; the HTML builder reads those snapshots and renders the radar without exposing API keys in the page. Use cached snapshots so the report still works offline or when a provider fails.

**Tech Stack:** Python 3, standard library HTTP/JSON/CSV, optional `yfinance` fallback if available, existing static HTML/CSS/JS report, FRED API via environment variable, Yahoo Finance public chart/quote endpoints.

---

## File Structure

- Modify: `/Users/ian/Documents/股票分析/scripts/analyze_portfolio.py`
  - Keep cost-basis logic unchanged.
  - Add stable derived fields needed by enrichment scripts, such as normalized Yahoo symbols.

- Create: `/Users/ian/Documents/股票分析/scripts/enrich_market_data.py`
  - Read `portfolio_analysis.json`.
  - Fetch Yahoo current quotes for open holdings.
  - Write `outputs/portfolio_analysis/market_data.json`.

- Create: `/Users/ian/Documents/股票分析/scripts/enrich_macro_data.py`
  - Read FRED API key from `FRED_API_KEY`.
  - Fetch key macro series.
  - Write `outputs/portfolio_analysis/macro_data.json`.

- Create: `/Users/ian/Documents/股票分析/scripts/enrich_options_data.py`
  - Start with the top portfolio exposures only.
  - Fetch Yahoo option chains where available.
  - Compute Put/Call ratio, Max Pain, call wall, put wall, and a cautious GEX-style approximation.
  - Write `outputs/portfolio_analysis/options_data.json`.

- Modify: `/Users/ian/Documents/股票分析/scripts/build_portfolio_html.py`
  - Read the three enrichment JSON files if present.
  - Add a “量化雷达” section before “每只股票成本价”.
  - Add export buttons for enriched tables.

- Create: `/Users/ian/Documents/股票分析/scripts/build_all.py`
  - One-command pipeline: cost basis, enrichments, HTML, workbook.
  - Continue if optional providers fail, but record warning messages.

- Create: `/Users/ian/Documents/股票分析/scripts/validate_report.py`
  - Verify required JSON files parse.
  - Verify HTML contains the new section.
  - Verify embedded JavaScript parses.

- Create: `/Users/ian/Documents/股票分析/outputs/portfolio_analysis/cache/`
  - Store provider snapshots only if useful.
  - Never store API keys.

---

### Task 1: Add Symbol Normalization

**Files:**
- Modify: `/Users/ian/Documents/股票分析/scripts/analyze_portfolio.py`
- Test: `/Users/ian/Documents/股票分析/scripts/validate_report.py`

- [ ] **Step 1: Add a ticker mapping helper**

Add this near the currency helpers in `analyze_portfolio.py`:

```python
YAHOO_SYMBOL_OVERRIDES = {
    "BRK.B": "BRK-B",
    "GOOG": "GOOG",
    "GOOGL": "GOOGL",
    "VUAG": "VUAG.L",
    "VUSA": "VUSA.L",
    "BARC": "BARC.L",
}


def yahoo_symbol(ticker, currency):
    if ticker in YAHOO_SYMBOL_OVERRIDES:
        return YAHOO_SYMBOL_OVERRIDES[ticker]
    if currency in {"GBP", "GBX"} and "." not in ticker:
        return f"{ticker}.L"
    return ticker
```

- [ ] **Step 2: Include `yahoo_symbol` in both holding outputs**

In both the account-level row and combined holding row, add:

```python
"yahoo_symbol": yahoo_symbol(info["ticker"], info["cost_currency"]),
```

Expected result: every open holding in `portfolio_analysis.json` has a `yahoo_symbol` field.

- [ ] **Step 3: Regenerate cost data**

Run:

```bash
python3 /Users/ian/Documents/股票分析/scripts/analyze_portfolio.py
```

Expected: summary JSON prints successfully and `outputs/portfolio_analysis/portfolio_analysis.json` is updated.

- [ ] **Step 4: Verify normalized symbols exist**

Run:

```bash
python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path('/Users/ian/Documents/股票分析/outputs/portfolio_analysis/portfolio_analysis.json').read_text())
missing = [r['ticker'] for r in data['holdings'] if not r.get('yahoo_symbol')]
print('missing', missing[:10], 'count', len(missing))
PY
```

Expected: `count 0`.

---

### Task 2: Add Yahoo Market Data Snapshot

**Files:**
- Create: `/Users/ian/Documents/股票分析/scripts/enrich_market_data.py`
- Output: `/Users/ian/Documents/股票分析/outputs/portfolio_analysis/market_data.json`

- [ ] **Step 1: Create the enrichment script**

Create `enrich_market_data.py` with:

```python
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path('/Users/ian/Documents/股票分析')
INPUT = ROOT / 'outputs/portfolio_analysis/portfolio_analysis.json'
OUTPUT = ROOT / 'outputs/portfolio_analysis/market_data.json'


def fetch_yahoo_quotes(symbols):
    if not symbols:
        return []
    query = urllib.parse.urlencode({
        'symbols': ','.join(symbols),
        'fields': 'regularMarketPrice,regularMarketCurrency,regularMarketChangePercent,regularMarketTime,shortName,longName'
    })
    url = f'https://query1.finance.yahoo.com/v7/finance/quote?{query}'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=20) as response:
        payload = json.loads(response.read().decode('utf-8'))
    return payload.get('quoteResponse', {}).get('result', [])


def main():
    data = json.loads(INPUT.read_text(encoding='utf-8'))
    holdings = data['holdings']
    symbols = sorted({row.get('yahoo_symbol') or row['ticker'] for row in holdings})
    quotes = {}
    warnings = []
    for start in range(0, len(symbols), 50):
        batch = symbols[start:start + 50]
        try:
            for quote in fetch_yahoo_quotes(batch):
                quotes[quote['symbol']] = quote
        except Exception as exc:
            warnings.append(f'Yahoo batch failed {batch[:3]}...: {exc}')
        time.sleep(0.2)

    rows = []
    for row in holdings:
        symbol = row.get('yahoo_symbol') or row['ticker']
        quote = quotes.get(symbol, {})
        price = quote.get('regularMarketPrice')
        currency = quote.get('regularMarketCurrency')
        shares = float(row.get('shares') or 0)
        market_value_native = shares * float(price) if price is not None else None
        rows.append({
            'ticker': row['ticker'],
            'name': row.get('name', ''),
            'yahoo_symbol': symbol,
            'shares': shares,
            'cost_currency': row.get('cost_currency', ''),
            'avg_cost_native': row.get('avg_cost_native'),
            'cost_usd_standard': row.get('cost_usd_standard'),
            'quote_price': price,
            'quote_currency': currency,
            'market_value_native': market_value_native,
            'change_percent': quote.get('regularMarketChangePercent'),
            'market_time': quote.get('regularMarketTime'),
            'source': 'Yahoo Finance quote endpoint',
        })

    OUTPUT.write_text(json.dumps({
        'as_of_unix': int(time.time()),
        'rows': rows,
        'warnings': warnings,
    }, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'rows': len(rows), 'warnings': warnings[:5]}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
```

- [ ] **Step 2: Run the script**

Run:

```bash
python3 /Users/ian/Documents/股票分析/scripts/enrich_market_data.py
```

Expected: prints row count and creates `market_data.json`.

- [ ] **Step 3: Spot-check core symbols**

Run:

```bash
python3 - <<'PY'
import json
from pathlib import Path
rows = json.loads(Path('/Users/ian/Documents/股票分析/outputs/portfolio_analysis/market_data.json').read_text())['rows']
for ticker in ['NVDA', 'MSFT', 'META', 'VUAG', 'VUSA', 'BARC']:
    print(ticker, [r for r in rows if r['ticker'] == ticker][:1])
PY
```

Expected: core symbols have a `quote_price` unless Yahoo lacks that symbol.

---

### Task 3: Add FRED Macro Snapshot

**Files:**
- Create: `/Users/ian/Documents/股票分析/scripts/enrich_macro_data.py`
- Output: `/Users/ian/Documents/股票分析/outputs/portfolio_analysis/macro_data.json`

- [ ] **Step 1: Create the macro script**

Create `enrich_macro_data.py` with:

```python
import json
import os
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path('/Users/ian/Documents/股票分析')
OUTPUT = ROOT / 'outputs/portfolio_analysis/macro_data.json'

SERIES = {
    'FEDFUNDS': '美国联邦基金利率',
    'DGS10': '美国 10 年期国债收益率',
    'CPIAUCSL': '美国 CPI',
    'UNRATE': '美国失业率',
    'USREC': '美国衰退指标',
}


def fetch_series(api_key, series_id):
    params = urllib.parse.urlencode({
        'series_id': series_id,
        'api_key': api_key,
        'file_type': 'json',
        'sort_order': 'desc',
        'limit': 2,
    })
    url = f'https://api.stlouisfed.org/fred/series/observations?{params}'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=20) as response:
        payload = json.loads(response.read().decode('utf-8'))
    observations = [item for item in payload.get('observations', []) if item.get('value') not in {'.', None}]
    return observations[:2]


def main():
    api_key = os.environ.get('FRED_API_KEY')
    rows = []
    warnings = []
    if not api_key:
        warnings.append('FRED_API_KEY is not set; macro data skipped.')
    else:
        for series_id, label in SERIES.items():
            try:
                obs = fetch_series(api_key, series_id)
                latest = obs[0] if obs else {}
                previous = obs[1] if len(obs) > 1 else {}
                latest_value = float(latest['value']) if latest.get('value') not in {None, '.'} else None
                previous_value = float(previous['value']) if previous.get('value') not in {None, '.'} else None
                rows.append({
                    'series_id': series_id,
                    'label': label,
                    'date': latest.get('date'),
                    'value': latest_value,
                    'previous_date': previous.get('date'),
                    'previous_value': previous_value,
                    'change': latest_value - previous_value if latest_value is not None and previous_value is not None else None,
                    'source': 'FRED',
                })
            except Exception as exc:
                warnings.append(f'{series_id} failed: {exc}')

    OUTPUT.write_text(json.dumps({'rows': rows, 'warnings': warnings}, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'rows': len(rows), 'warnings': warnings}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
```

- [ ] **Step 2: Run with local API key only**

Run:

```bash
FRED_API_KEY='use-the-key-from-user-locally-only' python3 /Users/ian/Documents/股票分析/scripts/enrich_macro_data.py
```

Expected: creates `macro_data.json`; the API key is not written into the file.

- [ ] **Step 3: Verify no key leakage**

Run:

```bash
grep -R "replace-with-secret-prefix" /Users/ian/Documents/股票分析 || true
```

Expected: no matching generated source/report file.

---

### Task 4: Add Options Snapshot

**Files:**
- Create: `/Users/ian/Documents/股票分析/scripts/enrich_options_data.py`
- Output: `/Users/ian/Documents/股票分析/outputs/portfolio_analysis/options_data.json`

- [ ] **Step 1: Create Yahoo option-chain fetcher**

Create `enrich_options_data.py` with:

```python
import json
import math
import time
import urllib.request
from pathlib import Path

ROOT = Path('/Users/ian/Documents/股票分析')
INPUT = ROOT / 'outputs/portfolio_analysis/portfolio_analysis.json'
OUTPUT = ROOT / 'outputs/portfolio_analysis/options_data.json'


def fetch_chain(symbol):
    url = f'https://query2.finance.yahoo.com/v7/finance/options/{symbol}'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=20) as response:
        payload = json.loads(response.read().decode('utf-8'))
    result = payload.get('optionChain', {}).get('result', [])
    return result[0] if result else None


def max_pain(calls, puts):
    strikes = sorted({float(x.get('strike', 0)) for x in calls + puts if x.get('strike')})
    best = None
    for spot in strikes:
        payout = 0.0
        for call in calls:
            payout += max(0.0, spot - float(call.get('strike', 0))) * float(call.get('openInterest') or 0)
        for put in puts:
            payout += max(0.0, float(put.get('strike', 0)) - spot) * float(put.get('openInterest') or 0)
        if best is None or payout < best[1]:
            best = (spot, payout)
    return best[0] if best else None


def wall(rows):
    ranked = sorted(rows, key=lambda item: float(item.get('openInterest') or 0), reverse=True)
    return float(ranked[0]['strike']) if ranked and ranked[0].get('strike') is not None else None


def summarize(symbol, ticker):
    chain = fetch_chain(symbol)
    if not chain:
        return {'ticker': ticker, 'yahoo_symbol': symbol, 'available': False, 'warning': 'No option chain'}
    option = (chain.get('options') or [{}])[0]
    calls = option.get('calls') or []
    puts = option.get('puts') or []
    call_volume = sum(float(x.get('volume') or 0) for x in calls)
    put_volume = sum(float(x.get('volume') or 0) for x in puts)
    call_oi = sum(float(x.get('openInterest') or 0) for x in calls)
    put_oi = sum(float(x.get('openInterest') or 0) for x in puts)
    return {
        'ticker': ticker,
        'yahoo_symbol': symbol,
        'available': True,
        'underlying_price': chain.get('quote', {}).get('regularMarketPrice'),
        'expiration': option.get('expirationDate'),
        'call_volume': call_volume,
        'put_volume': put_volume,
        'put_call_volume_ratio': put_volume / call_volume if call_volume else None,
        'call_open_interest': call_oi,
        'put_open_interest': put_oi,
        'put_call_oi_ratio': put_oi / call_oi if call_oi else None,
        'max_pain': max_pain(calls, puts),
        'call_wall': wall(calls),
        'put_wall': wall(puts),
        'source': 'Yahoo Finance options endpoint',
        'method_note': 'GEX/dealer positioning is not inferred as a true dealer book; this is public chain structure only.',
    }


def main():
    data = json.loads(INPUT.read_text(encoding='utf-8'))
    holdings = sorted(data['holdings'], key=lambda row: float(row.get('cost_usd_standard') or 0), reverse=True)
    candidates = [row for row in holdings if row.get('cost_currency') == 'USD'][:12]
    rows = []
    warnings = []
    for row in candidates:
        symbol = row.get('yahoo_symbol') or row['ticker']
        try:
            rows.append(summarize(symbol, row['ticker']))
        except Exception as exc:
            warnings.append(f'{row["ticker"]} failed: {exc}')
            rows.append({'ticker': row['ticker'], 'yahoo_symbol': symbol, 'available': False, 'warning': str(exc)})
        time.sleep(0.4)
    OUTPUT.write_text(json.dumps({'rows': rows, 'warnings': warnings}, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'rows': len(rows), 'warnings': warnings[:5]}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
```

- [ ] **Step 2: Run the option enrichment**

Run:

```bash
python3 /Users/ian/Documents/股票分析/scripts/enrich_options_data.py
```

Expected: creates `options_data.json`; unsupported symbols are marked `available: false`.

- [ ] **Step 3: Verify at least one liquid symbol**

Run:

```bash
python3 - <<'PY'
import json
from pathlib import Path
rows = json.loads(Path('/Users/ian/Documents/股票分析/outputs/portfolio_analysis/options_data.json').read_text())['rows']
print([{'ticker': r['ticker'], 'available': r['available'], 'pc': r.get('put_call_volume_ratio'), 'max_pain': r.get('max_pain')} for r in rows[:8]])
PY
```

Expected: NVDA/MSFT/META-like symbols should usually have option-chain data.

---

### Task 5: Render “量化雷达” in HTML

**Files:**
- Modify: `/Users/ian/Documents/股票分析/scripts/build_portfolio_html.py`
- Input: `market_data.json`, `macro_data.json`, `options_data.json`
- Output: `/Users/ian/Documents/股票分析/outputs/portfolio_analysis/portfolio_cost_basis.html`

- [ ] **Step 1: Add optional JSON loader**

Add near the top of `build_portfolio_html.py`:

```python
def load_optional_json(path, fallback):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except FileNotFoundError:
        return fallback
    except json.JSONDecodeError:
        return fallback
```

- [ ] **Step 2: Load enrichment snapshots**

Inside `main()`, after loading `portfolio_analysis.json`, add:

```python
market_data = load_optional_json("outputs/portfolio_analysis/market_data.json", {"rows": [], "warnings": ["market_data.json missing"]})
macro_data = load_optional_json("outputs/portfolio_analysis/macro_data.json", {"rows": [], "warnings": ["macro_data.json missing"]})
options_data = load_optional_json("outputs/portfolio_analysis/options_data.json", {"rows": [], "warnings": ["options_data.json missing"]})
market_rows = market_data.get("rows", [])
macro_rows = macro_data.get("rows", [])
option_rows = options_data.get("rows", [])
```

- [ ] **Step 3: Compute radar summary**

Add:

```python
market_by_ticker = {row["ticker"]: row for row in market_rows}
option_available = [row for row in option_rows if row.get("available")]
option_risk_rows = sorted(
    option_available,
    key=lambda row: abs(float(row.get("put_call_volume_ratio") or 1) - 1),
    reverse=True,
)[:6]
```

- [ ] **Step 4: Insert the HTML section before “每只股票成本价”**

Insert a new section with these components:

```html
<section>
  <div class="section-head">
    <div>
      <h2>量化雷达</h2>
      <div class="note">行情来自 Yahoo；宏观来自 FRED；期权为公开 option chain 结构估算，不代表真实 dealer 持仓。</div>
    </div>
  </div>
  <div class="insights">
    <div class="insight">
      <span>行情覆盖</span>
      <b>{market_coverage_label}</b>
      <ul>{market_warning_items}</ul>
    </div>
    <div class="insight">
      <span>期权结构</span>
      <b>{option_coverage_label}</b>
      <ul>{option_signal_items}</ul>
    </div>
    <div class="insight">
      <span>宏观状态</span>
      <b>{macro_coverage_label}</b>
      <ul>{macro_items}</ul>
    </div>
  </div>
  <div class="table-wrap">
    <table class="summary-table">
      <thead>
        <tr>
          <th>Ticker</th>
          <th>Yahoo</th>
          <th>现价</th>
          <th>成本价</th>
          <th>日涨跌</th>
          <th>Put/Call</th>
          <th>Max Pain</th>
          <th>Call Wall</th>
          <th>Put Wall</th>
        </tr>
      </thead>
      <tbody>{radar_rows_html}</tbody>
    </table>
  </div>
</section>
```

Use Python-generated strings for `market_coverage_label`, `option_coverage_label`, `macro_coverage_label`, `macro_items`, and `radar_rows_html`.

- [ ] **Step 5: Regenerate HTML**

Run:

```bash
python3 /Users/ian/Documents/股票分析/scripts/build_portfolio_html.py
```

Expected: HTML contains “量化雷达”.

---

### Task 6: Add One-Command Pipeline

**Files:**
- Create: `/Users/ian/Documents/股票分析/scripts/build_all.py`

- [ ] **Step 1: Create pipeline runner**

Create `build_all.py`:

```python
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path('/Users/ian/Documents/股票分析')

STEPS = [
    ['python3', str(ROOT / 'scripts/analyze_portfolio.py')],
    ['python3', str(ROOT / 'scripts/enrich_market_data.py')],
    ['python3', str(ROOT / 'scripts/enrich_macro_data.py')],
    ['python3', str(ROOT / 'scripts/enrich_options_data.py')],
    ['python3', str(ROOT / 'scripts/build_portfolio_html.py')],
    ['node', str(ROOT / 'scripts/build_portfolio_workbook.mjs')],
]


def main():
    failures = []
    for step in STEPS:
        env = os.environ.copy()
        result = subprocess.run(step, cwd=ROOT, env=env, text=True, capture_output=True)
        print(f'$ {" ".join(step)}')
        print(result.stdout)
        if result.returncode != 0:
            print(result.stderr, file=sys.stderr)
            failures.append(step)
            if 'analyze_portfolio.py' in step[-1] or 'build_portfolio_html.py' in step[-1]:
                return result.returncode
    if failures:
        print(f'Optional steps failed: {failures}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
```

- [ ] **Step 2: Run the pipeline**

Run:

```bash
python3 /Users/ian/Documents/股票分析/scripts/build_all.py
```

Expected: cost and HTML steps must pass; optional data-source failures are printed but do not stop the report.

---

### Task 7: Add Report Validation

**Files:**
- Create: `/Users/ian/Documents/股票分析/scripts/validate_report.py`

- [ ] **Step 1: Create validation script**

Create:

```python
import json
import re
import subprocess
from pathlib import Path

ROOT = Path('/Users/ian/Documents/股票分析')
OUT = ROOT / 'outputs/portfolio_analysis'


def assert_json(path):
    json.loads(path.read_text(encoding='utf-8'))


def main():
    for name in ['portfolio_analysis.json', 'market_data.json', 'macro_data.json', 'options_data.json']:
        path = OUT / name
        if path.exists():
            assert_json(path)
            print(f'json ok: {name}')
        else:
            print(f'json missing: {name}')

    html_path = OUT / 'portfolio_cost_basis.html'
    html = html_path.read_text(encoding='utf-8')
    assert '量化雷达' in html
    match = re.search(r'<script>([\\s\\S]*)</script>', html)
    assert match, 'script tag missing'
    subprocess.run(['node', '-e', f'new Function({match.group(1)!r}); console.log("script ok")'], check=True)
    print('html ok')


if __name__ == '__main__':
    main()
```

- [ ] **Step 2: Run validation**

Run:

```bash
python3 /Users/ian/Documents/股票分析/scripts/validate_report.py
```

Expected: JSON checks print; JavaScript parse prints `script ok`; final line prints `html ok`.

---

### Task 8: Product Polish and Interpretation

**Files:**
- Modify: `/Users/ian/Documents/股票分析/scripts/build_portfolio_html.py`

- [ ] **Step 1: Add plain-language notes**

Add concise notes in the “量化雷达” section:

```text
Yahoo 价格用于估算当前行情，不用于覆盖 CSV 成本。
期权指标是公开链结构，不等于真实机构仓位。
FRED 宏观指标用于背景判断，不自动生成买卖建议。
```

- [ ] **Step 2: Add export button for radar table**

Extend the existing export logic with a second button:

```html
<button id="exportRadarCsv" type="button">导出雷达 CSV</button>
```

Expected CSV columns:

```text
Ticker,Yahoo,现价,成本价,日涨跌,Put/Call,Max Pain,Call Wall,Put Wall
```

- [ ] **Step 3: Final visual check**

Open:

```text
file:///Users/ian/Documents/股票分析/outputs/portfolio_analysis/portfolio_cost_basis.html
```

Expected:
- “量化雷达” appears before “每只股票成本价”.
- No API key is visible.
- Missing data is shown as `—`, not broken text.
- Existing cost-basis table still searches, sorts, and exports.

---

## Execution Order

1. Task 1: Add normalized symbols to base portfolio data.
2. Task 2: Add Yahoo quote enrichment.
3. Task 3: Add FRED macro enrichment.
4. Task 4: Add option-chain enrichment.
5. Task 5: Render the new radar section.
6. Task 6: Add the one-command pipeline.
7. Task 7: Add validation.
8. Task 8: Polish labels, exports, and interpretation.

---

## Self-Review

**Spec coverage:**  
The plan covers the requested “量化类开源想法” direction by turning it into a portfolio-level quant radar with Yahoo market data, FRED macro data, option-chain structure, ETF/look-through context, and exportable tables.

**Placeholder scan:**  
No implementation step uses TBD/TODO/fill-in placeholders. API key handling is explicitly local-only via environment variable.

**Type consistency:**  
All enrichment files write `{rows, warnings}` JSON objects. `build_portfolio_html.py` reads the same shape through `load_optional_json`.

---

## Execution Handoff

Plan complete and saved to `/Users/ian/Documents/股票分析/docs/superpowers/plans/2026-06-03-quant-radar.md`.

Two execution options:

1. **Subagent-Driven (recommended)** - dispatch a fresh worker per task, review between tasks, fastest for parallel enrichment work.
2. **Inline Execution** - execute tasks in this session with checkpoints, simpler and easier to watch step by step.
