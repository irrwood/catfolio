import json
import os
from pathlib import Path

# Load .env from project root before anything else
_env_path = Path(__file__).resolve().parent.parent.parent / ".env"
if _env_path.exists():
    with open(_env_path) as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith("#") and "=" in _line:
                _key, _, _val = _line.partition("=")
                os.environ.setdefault(_key.strip(), _val.strip())
del _env_path

import ssl
import math
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from .cache import cached
from .settings import FUNDAMENTALS_CACHE, LIVE_MARKET_CACHE, MARKET_REFRESH_TTL_SECONDS, ROOT, V2_DIR

_DEMO_FLAG = V2_DIR / "demo_mode.flag"

# Fan-out limits for the per-symbol refresh loops. Each loop used to pay one
# whole network round trip at a time, so a refresh cost
# len(symbols) x (latency + throttle) even though the requests are independent.
#
# The MIN_INTERVAL values are the same throttles the serial loops spent in
# time.sleep() between calls, now applied to the *aggregate* rate instead of
# between consecutive calls on one thread. Nothing here asks a third party for
# data faster than the serial version did; the win is that latency overlaps
# instead of accumulating. Raise these only if your API plan allows it.
QUOTE_FETCH_WORKERS = int(os.environ.get("CATFOLIO_QUOTE_WORKERS", "8"))
QUOTE_FETCH_MIN_INTERVAL = float(os.environ.get("CATFOLIO_QUOTE_MIN_INTERVAL", "0.04"))
AFTER_HOURS_WORKERS = int(os.environ.get("CATFOLIO_AFTER_HOURS_WORKERS", "4"))
AFTER_HOURS_MIN_INTERVAL = float(os.environ.get("CATFOLIO_AFTER_HOURS_MIN_INTERVAL", "0.35"))
FMP_FETCH_WORKERS = int(os.environ.get("CATFOLIO_FMP_WORKERS", "4"))


def _rate_limiter(min_interval: float):
    """Return a wait() that admits at most one caller per `min_interval`.

    Threads reserve their slot under the lock and sleep outside it, so the
    dispenser itself never becomes the bottleneck.
    """
    lock = threading.Lock()
    next_slot = [0.0]

    def wait():
        if min_interval <= 0:
            return
        with lock:
            start = max(time.monotonic(), next_slot[0])
            next_slot[0] = start + min_interval
        delay = start - time.monotonic()
        if delay > 0:
            time.sleep(delay)

    return wait


def _parallel_map(items, worker, *, max_workers, min_interval=0.0):
    """Map `worker` over `items` concurrently, returning results in input order.

    Input order is preserved regardless of completion order so warnings and
    cache rows stay reproducible. `worker` is expected to handle its own
    failures and return them; an exception escaping it aborts the whole map.
    """
    items = list(items)
    if not items:
        return []
    wait = _rate_limiter(min_interval)

    def run(item):
        wait()
        return worker(item)

    if len(items) == 1 or max_workers <= 1:
        return [run(item) for item in items]
    with ThreadPoolExecutor(max_workers=min(max_workers, len(items))) as pool:
        return list(pool.map(run, items))


def public_demo_mode() -> bool:
    """Whether this process is a permanently read-only public showcase."""
    return (os.environ.get("CATFOLIO_PUBLIC_DEMO") or "").lower() in ("1", "true", "yes", "on")


def demo_mode() -> bool:
    """Demo (sample-data) mode.

    CATFOLIO_DEMO/HELM_DEMO provides the startup default, while the Settings
    toggle writes an explicit runtime override so demo mode can be turned off
    even when the app was launched with CATFOLIO_DEMO=1.
    """
    if public_demo_mode():
        return True
    try:
        if _DEMO_FLAG.exists():
            flag = _DEMO_FLAG.read_text(encoding="utf-8").strip().lower()
            return flag in ("1", "true", "yes", "on")
    except Exception:
        pass
    demo_flag = os.environ.get("CATFOLIO_DEMO") or os.environ.get("HELM_DEMO") or ""
    if demo_flag.lower() in ("1", "true", "yes"):
        return True
    return False


def set_demo_mode(on: bool) -> bool:
    """Persist the demo-mode toggle and clear caches so it takes effect now."""
    if public_demo_mode():
        return bool(on)
    try:
        _DEMO_FLAG.parent.mkdir(parents=True, exist_ok=True)
        _DEMO_FLAG.write_text("1" if on else "0", encoding="utf-8")
        from .cache import clear_all
        clear_all()
        return True
    except Exception:
        return False

FX_TO_USD = {
    "USD": 1.0,
    "GBP": 1.3460,
    "GBX": 0.013460,
    "EUR": 1.1630,
    "AUD": float(os.environ.get("CATFOLIO_AUD_TO_USD", "0.655")),
    "CAD": float(os.environ.get("CATFOLIO_CAD_TO_USD", "0.726")),
    "CNH": float(os.environ.get("CATFOLIO_CNH_TO_USD", "0.139")),
    "CNY": float(os.environ.get("CATFOLIO_CNY_TO_USD", "0.139")),
    "HKD": float(os.environ.get("CATFOLIO_HKD_TO_USD", "0.1275")),
    "JPY": float(os.environ.get("CATFOLIO_JPY_TO_USD", "0.0068")),
    "SGD": float(os.environ.get("CATFOLIO_SGD_TO_USD", "0.777")),
}


def load_json(path: Path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return fallback


def _cache_freshness(data, path: Path) -> float:
    """Return a comparable timestamp for a JSON cache without trusting its name."""
    if isinstance(data, dict):
        for value in (data.get("as_of_unix"), data.get("market_time")):
            try:
                if value is not None:
                    return float(value)
            except (TypeError, ValueError):
                pass
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def _latest_market_cache():
    """Pick the newest market snapshot instead of blindly preferring live cache.

    A Trading 212 sync writes market_data.json. Previously an older
    live_market_data.json always won, so the refreshed positions/cost basis were
    combined with stale prices until somebody separately refreshed quotes.
    """
    pipeline_path = V2_DIR / "market_data.json"
    pipeline = load_json(pipeline_path, None)
    live = load_json(LIVE_MARKET_CACHE, None)
    candidates = [
        (live, LIVE_MARKET_CACHE),
        (pipeline, pipeline_path),
    ]
    valid = [(data, path) for data, path in candidates if isinstance(data, dict) and data.get("rows")]
    if not valid:
        return {"rows": [], "warnings": []}
    return max(valid, key=lambda item: _cache_freshness(item[0], item[1]))[0]


@cached(ttl=10)
def current_snapshot():
    # Cached briefly to dedupe the burst of concurrent /api/* calls a single page
    # load fires — without this, every widget re-reads the same 4 JSON files from
    # disk. Every data-refresh path calls cache.clear_all(), so this never serves
    # stale data; callers must treat the returned dict as read-only (it is shared).
    if demo_mode():
        from .demo_data import DEMO_SNAPSHOT
        return DEMO_SNAPSHOT
    portfolio = load_json(V2_DIR / "portfolio_analysis.json", {"summary": {}, "holdings": [], "holdings_by_account": []})
    market = _latest_market_cache()
    market = reconcile_market_currencies(portfolio, market)
    fundamentals = load_json(FUNDAMENTALS_CACHE, {"rows": [], "warnings": ["Fundamentals cache not available."]})
    trading212 = load_json(V2_DIR / "trading212_data.json", {"summary": {}, "account_cash": {}, "positions": [], "warnings": []})
    broker_cache = load_json(V2_DIR / "broker_data.json", {})
    provider = str(portfolio.get("summary", {}).get("broker_provider") or "trading212")
    broker = broker_cache if provider in {"moomoo", "ibkr"} and broker_cache.get("provider") == provider else trading212
    from .brokers.accounts import apply_accounts
    return apply_accounts({
        "portfolio": portfolio,
        "market": market,
        "fundamentals": fundamentals,
        "broker": broker,
        "trading212": trading212,
        "loaded_at": datetime.now(timezone.utc).isoformat(),
    })


def normalize_currency(currency):
    if currency in {"GBp", "GBX"}:
        return "GBX"
    return currency


def usd_equivalent(amount, currency):
    if amount is None:
        return None
    rate = FX_TO_USD.get(normalize_currency(currency))
    if rate is None:
        return None
    return float(amount) * rate


def resolve_quote_currency(holding, reported_currency, price, shares):
    """Choose the currency that best agrees with the broker's market value.

    Yahoo occasionally labels a London GBX quote as USD. The broker snapshot is
    used only as a sanity anchor, so legitimate USD-listed London instruments
    keep Yahoo's currency when it is the closer interpretation.
    """
    reported = normalize_currency(reported_currency)
    expected = normalize_currency(holding.get("price_currency") or holding.get("cost_currency"))
    if not reported:
        return expected
    if not expected or expected == reported:
        return reported
    try:
        broker_value = float(holding.get("api_market_value_usd") or 0)
        native_value = float(shares or 0) * float(price)
    except (TypeError, ValueError):
        return reported
    if broker_value <= 0 or native_value <= 0:
        return reported

    candidates = [currency for currency in (reported, expected) if currency in FX_TO_USD]
    if len(candidates) < 2:
        return reported

    def distance(currency):
        candidate_value = usd_equivalent(native_value, currency)
        return abs(math.log(candidate_value / broker_value)) if candidate_value and candidate_value > 0 else float("inf")

    return min(candidates, key=distance)


def reconcile_market_currencies(portfolio, market):
    """Repair stale market-cache rows using the same currency sanity check."""
    holdings = {str(row.get("ticker") or "").upper(): row for row in portfolio.get("holdings", [])}
    rows = []
    for source_row in market.get("rows", []):
        row = dict(source_row)
        holding = holdings.get(str(row.get("ticker") or "").upper())
        if not holding or row.get("quote_price") is None:
            rows.append(row)
            continue
        shares = float(row.get("shares") or holding.get("shares") or 0)
        currency = resolve_quote_currency(holding, row.get("quote_currency"), row.get("quote_price"), shares)
        if currency != row.get("quote_currency"):
            native_value = shares * float(row["quote_price"])
            market_value_usd = usd_equivalent(native_value, currency)
            cost_usd = float(row.get("cost_usd_standard") or holding.get("cost_usd_standard") or 0)
            row.update(
                {
                    "quote_currency": currency,
                    "market_value_native": native_value,
                    "market_value_usd": market_value_usd,
                    "price_unrealized_usd": market_value_usd - cost_usd if market_value_usd is not None else None,
                    "price_unrealized_percent": (market_value_usd / cost_usd - 1) * 100 if market_value_usd is not None and cost_usd else None,
                    "unrealized_usd": market_value_usd - cost_usd if market_value_usd is not None else None,
                    "unrealized_percent": (market_value_usd / cost_usd - 1) * 100 if market_value_usd is not None and cost_usd else None,
                    "pnl_basis": "price_difference",
                }
            )
        rows.append(row)
    return {**market, "rows": rows}


def open_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        if "CERTIFICATE_VERIFY_FAILED" not in str(exc):
            raise
        with urllib.request.urlopen(req, timeout=15, context=ssl._create_unverified_context()) as response:
            return json.loads(response.read().decode("utf-8"))


_secret_cache: dict = {}
_secret_lock = threading.Lock()


def secret_value(name):
    """Read a secret, memoized in-process.

    The underlying read forks a `security` subprocess on macOS (~33 ms each),
    so without this cache a single page render that checks several keys (e.g.
    Settings reads ~10, the home-page alert check reads 2 even when Telegram is
    unconfigured) pays that cost repeatedly. Both found values and misses (None)
    are cached; save_secret() updates the cache so newly-saved keys are seen.
    """
    with _secret_lock:
        if name in _secret_cache:
            return _secret_cache[name]
    value = _read_secret(name)
    with _secret_lock:
        _secret_cache[name] = value
    return value


def _read_secret(name):
    """Read a secret from environment, system keychain, or keyring library.

    On macOS the security CLI is used directly — it was already granted Keychain
    access and never triggers a prompt. The keyring library is only used on
    Linux / Windows where the security CLI is unavailable.
    """
    import platform
    value = os.environ.get(name)
    if value:
        return value
    if platform.system() == "Darwin":
        # macOS: security CLI — no UI prompts for already-trusted items
        for service in ("com.catfolio.portfolio", "com.helm.portfolio", "portfolio-analysis-v3"):
            value = _keychain_get(name, service)
            if value:
                if service != "com.catfolio.portfolio":
                    _keychain_save(name, value, "com.catfolio.portfolio")
                return value
    else:
        # Linux / Windows: use keyring library (Credential Manager / libsecret / etc.)
        try:
            import keyring as _kr
            value = _kr.get_password("com.catfolio.portfolio", name)
            if value:
                return value
            value = _kr.get_password("com.helm.portfolio", name)
            if value:
                _kr.set_password("com.catfolio.portfolio", name, value)
                return value
        except Exception:
            pass
    return None


def save_secret(name: str, value: str) -> bool:
    """Persist a secret to the system keychain (macOS) or keyring library (Linux/Windows)."""
    import platform
    ok = False
    if platform.system() == "Darwin":
        ok = _keychain_save(name, value, "com.catfolio.portfolio")
    else:
        try:
            import keyring as _kr
            _kr.set_password("com.catfolio.portfolio", name, value)
            ok = True
        except Exception:
            ok = False
    if ok:
        with _secret_lock:
            _secret_cache[name] = value
    return ok


def delete_secret(name: str) -> bool:
    """Delete a Catfolio-owned secret from the OS credential store."""
    import platform

    ok = False
    if platform.system() == "Darwin":
        ok = _keychain_delete(name, "com.catfolio.portfolio")
    else:
        try:
            import keyring as _kr
            _kr.delete_password("com.catfolio.portfolio", name)
            ok = True
        except Exception:
            ok = False
    with _secret_lock:
        _secret_cache.pop(name, None)
    return ok


def _keychain_get(account, service):
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-a", account, "-s", service, "-w"],
            capture_output=True, text=True, timeout=5,
        )
    except Exception:
        return None
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    return None


def _keychain_save(account, password, service):
    try:
        result = subprocess.run(
            ["security", "add-generic-password", "-a", account, "-s", service, "-w", password, "-U"],
            capture_output=True, text=True, timeout=5,
        )
        return result.returncode == 0
    except Exception:
        return False


def _keychain_delete(account, service):
    try:
        result = subprocess.run(
            ["security", "delete-generic-password", "-a", account, "-s", service],
            capture_output=True, text=True, timeout=5,
        )
        # security returns 44 when the item does not exist; deletion is still
        # effectively complete from Catfolio's perspective.
        return result.returncode in {0, 44}
    except Exception:
        return False


def fetch_yahoo_chart(symbol):
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range=1d&interval=1m"
    payload = open_json(url)
    result = payload.get("chart", {}).get("result") or []
    if not result:
        return {}
    meta = result[0].get("meta", {})
    previous_close = meta.get("previousClose")
    price = meta.get("regularMarketPrice")
    change_percent = None
    if previous_close and price:
        change_percent = (float(price) / float(previous_close) - 1) * 100
    return {
        "symbol": meta.get("symbol") or symbol,
        "regularMarketPrice": price,
        "regularMarketCurrency": meta.get("currency"),
        "regularMarketChangePercent": change_percent,
        "regularMarketTime": meta.get("regularMarketTime"),
        "shortName": meta.get("shortName") or meta.get("longName"),
        "trailingPE": meta.get("trailingPE"),
        "forwardPE": meta.get("forwardPE"),
        "regularMarketVolume": meta.get("regularMarketVolume"),
        "averageDailyVolume3Month": meta.get("averageDailyVolume3Month"),
        "marketCap": meta.get("marketCap"),
        "fiftyTwoWeekHigh": meta.get("fiftyTwoWeekHigh"),
        "fiftyTwoWeekLow": meta.get("fiftyTwoWeekLow"),
        "regularMarketOpen": meta.get("regularMarketOpen"),
    }


def live_cache_age_seconds():
    data = load_json(LIVE_MARKET_CACHE, None)
    if not data or not data.get("as_of_unix"):
        return None
    return max(0, int(time.time()) - int(data["as_of_unix"]))


def refresh_market_quotes(force=False):
    portfolio = current_snapshot()["portfolio"]
    holdings = portfolio.get("holdings", [])
    symbols = sorted({row.get("yahoo_symbol") or row.get("ticker") for row in holdings if row.get("ticker")})
    cached_market = load_json(LIVE_MARKET_CACHE, {"rows": [], "warnings": []}) or {"rows": []}
    cached_as_of = int(cached_market.get("as_of_unix") or 0)
    cached_by_symbol = {
        row.get("yahoo_symbol") or row.get("ticker"): row
        for row in cached_market.get("rows", [])
        if row.get("ticker")
    }
    now = int(time.time())
    fetch_symbols = []
    for symbol in symbols:
        cached_row = cached_by_symbol.get(symbol)
        row_as_of = int((cached_row or {}).get("quote_as_of_unix") or cached_as_of or 0)
        if force or not cached_row or now - row_as_of >= MARKET_REFRESH_TTL_SECONDS:
            fetch_symbols.append(symbol)

    structure_changed = set(symbols) != set(cached_by_symbol)
    age = live_cache_age_seconds()
    if not fetch_symbols and not structure_changed:
        return {"ok": True, "cached": True, "age_seconds": age or 0, "market": cached_market}

    warnings = []
    quotes = {
        symbol: {
            "symbol": symbol,
            "regularMarketPrice": row.get("quote_price"),
            "regularMarketCurrency": row.get("quote_currency"),
            "regularMarketChangePercent": row.get("change_percent"),
            "regularMarketTime": row.get("market_time"),
            "shortName": row.get("company_name") or row.get("name"),
            "trailingPE": row.get("trailing_pe"),
            "forwardPE": row.get("forward_pe"),
            "regularMarketVolume": row.get("volume"),
            "averageDailyVolume3Month": row.get("avg_volume_3m"),
            "marketCap": row.get("market_cap"),
            "fiftyTwoWeekHigh": row.get("high_52w"),
            "fiftyTwoWeekLow": row.get("low_52w"),
            "regularMarketOpen": row.get("open_price"),
            "quote_as_of_unix": row.get("quote_as_of_unix") or cached_as_of,
        }
        for symbol, row in cached_by_symbol.items()
        if symbol in symbols
    }
    started = time.time()

    def _fetch_quote(symbol):
        try:
            quote = fetch_yahoo_chart(symbol)
        except Exception as exc:
            return symbol, None, f"Yahoo chart failed {symbol}: {type(exc).__name__} {str(exc)[:100]}"
        if not quote:
            return symbol, None, f"Yahoo chart empty: {symbol}"
        quote["quote_as_of_unix"] = now
        return symbol, quote, None

    for symbol, quote, warning in _parallel_map(
        fetch_symbols,
        _fetch_quote,
        max_workers=QUOTE_FETCH_WORKERS,
        min_interval=QUOTE_FETCH_MIN_INTERVAL,
    ):
        if quote is not None:
            quotes[symbol] = quote
        if warning:
            warnings.append(warning)

    rows = []
    for row in holdings:
        symbol = row.get("yahoo_symbol") or row.get("ticker")
        quote = quotes.get(symbol, {})
        company_name = quote.get("shortName") or row.get("name") or row["ticker"]
        price = quote.get("regularMarketPrice")
        source = "Yahoo Finance chart endpoint live cache"
        if price is None:
            price = row.get("last_trade_price")
            source = "Trading 212 portfolio API fallback"
        shares = float(row.get("shares") or 0)
        quote_currency = resolve_quote_currency(
            row,
            quote.get("regularMarketCurrency") or row.get("price_currency") or row.get("cost_currency"),
            price,
            shares,
        )
        market_value_native = shares * float(price) if price is not None else None
        market_value_usd = usd_equivalent(market_value_native, quote_currency)
        cost_usd = float(row.get("cost_usd_standard") or 0)
        rows.append(
            {
                "ticker": row["ticker"],
                "name": company_name,
                "company_name": company_name,
                "yahoo_symbol": symbol,
                "shares": shares,
                "cost_currency": row.get("cost_currency", ""),
                "avg_cost_native": row.get("avg_cost_native"),
                "cost_usd_standard": cost_usd,
                "quote_price": price,
                "quote_currency": quote_currency,
                "market_value_native": market_value_native,
                "market_value_usd": market_value_usd,
                "price_unrealized_usd": market_value_usd - cost_usd if market_value_usd is not None else None,
                "price_unrealized_percent": (market_value_usd / cost_usd - 1) * 100 if market_value_usd is not None and cost_usd else None,
                "unrealized_usd": market_value_usd - cost_usd if market_value_usd is not None else None,
                "unrealized_percent": (market_value_usd / cost_usd - 1) * 100 if market_value_usd is not None and cost_usd else None,
                "pnl_basis": "price_difference",
                "change_percent": quote.get("regularMarketChangePercent"),
                "today_change_percent": quote.get("regularMarketChangePercent"),
                "trailing_pe": quote.get("trailingPE"),
                "forward_pe": quote.get("forwardPE"),
                "volume": quote.get("regularMarketVolume"),
                "avg_volume_3m": quote.get("averageDailyVolume3Month"),
                "market_cap": quote.get("marketCap"),
                "high_52w": quote.get("fiftyTwoWeekHigh"),
                "low_52w": quote.get("fiftyTwoWeekLow"),
                "open_price": quote.get("regularMarketOpen"),
                "market_time": quote.get("regularMarketTime"),
                "quote_as_of_unix": quote.get("quote_as_of_unix") or cached_as_of or now,
                "source": source,
            }
        )

    market = {
        "as_of_unix": int(time.time()),
        "duration_seconds": round(time.time() - started, 2),
        "rows": rows,
        "warnings": warnings,
        "source": "live_market_cache",
        "ttl_seconds": MARKET_REFRESH_TTL_SECONDS,
        "incremental": not force,
        "refresh_stats": {
            "requested": len(fetch_symbols),
            "reused": max(0, len(symbols) - len(fetch_symbols)),
            "removed": len(set(cached_by_symbol) - set(symbols)),
        },
    }
    LIVE_MARKET_CACHE.write_text(json.dumps(market, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "cached": False, "age_seconds": 0, "market": market}


def _raw_value(value):
    if isinstance(value, dict):
        return value.get("raw")
    return value


def _metric_number(metric, *keys):
    for key in keys:
        value = _raw_value(metric.get(key))
        if value not in (None, "", "NaN"):
            try:
                return float(value)
            except (TypeError, ValueError):
                continue
    return None


def _finnhub_metric(symbol, token):
    query = urllib.parse.urlencode({"symbol": symbol, "metric": "all", "token": token})
    return open_json(f"https://finnhub.io/api/v1/stock/metric?{query}")


def _fmp_json(path, apikey, params=None):
    query = urllib.parse.urlencode({**(params or {}), "apikey": apikey})
    return open_json(f"https://financialmodelingprep.com/api/{path}?{query}")


def _fmp_stable_json(endpoint, symbol, apikey, params=None):
    query = urllib.parse.urlencode({**(params or {}), "symbol": symbol, "apikey": apikey})
    return open_json(f"https://financialmodelingprep.com/stable/{endpoint}?{query}")


def _fmp_symbol_candidates(holding):
    ticker = holding.get("ticker")
    yahoo = holding.get("yahoo_symbol")
    candidates = []
    for symbol in [ticker, yahoo]:
        if not symbol:
            continue
        variants = [symbol]
        if symbol == "BRK.B":
            variants.append("BRK-B")
        if symbol.endswith(".L"):
            variants.append(symbol[:-2])
        for variant in variants:
            if variant and variant not in candidates:
                candidates.append(variant)
    return candidates


_FMP_TTM_ENDPOINTS = (
    ("ratios-ttm", None),
    ("key-metrics-ttm", None),
    ("income-statement-growth", {"limit": 1}),
    ("profile", None),
)


def _fmp_snapshot(symbol, token):
    """Fetch the four independent FMP endpoints for one symbol concurrently.

    They used to run back to back, so every candidate symbol cost four serial
    round trips before the next holding was even started. Failure semantics are
    unchanged: the first error aborts the candidate, and the caller moves on.
    """
    def call(spec):
        endpoint, params = spec
        try:
            return _fmp_stable_json(endpoint, symbol, token, params), None
        except Exception as exc:
            return None, exc

    results = _parallel_map(_FMP_TTM_ENDPOINTS, call, max_workers=FMP_FETCH_WORKERS)
    for _, exc in results:
        if exc is not None:
            raise exc
    return tuple(payload for payload, _ in results)


def _first_number(payload, *keys):
    if isinstance(payload, list):
        payload = payload[0] if payload else {}
    if not isinstance(payload, dict):
        return None
    return _metric_number(payload, *keys)


def _refresh_fundamentals_fmp(holdings, token):
    rows = []
    warnings = []
    for holding in holdings:
        ticker = holding.get("ticker")
        if not ticker or holding.get("cost_currency") != "USD":
            continue
        row = None
        last_error = None
        for symbol in _fmp_symbol_candidates(holding):
            try:
                ratios, metrics, growth, profile = _fmp_snapshot(symbol, token)
                trailing_pe = _first_number(ratios, "priceToEarningsRatioTTM", "priceEarningsRatioTTM") or _first_number(metrics, "peRatioTTM") or _first_number(profile, "pe")
                price_to_sales = _first_number(ratios, "priceToSalesRatioTTM") or _first_number(metrics, "priceToSalesRatioTTM", "evToSalesTTM")
                price_to_book = _first_number(ratios, "priceToBookRatioTTM") or _first_number(metrics, "pbRatioTTM", "priceToBookRatioTTM")
                eps_growth = _first_number(growth, "growthEPSDiluted", "growthEPS")
                revenue_growth = _first_number(growth, "growthRevenue")
                if any(value is not None for value in [trailing_pe, price_to_sales, price_to_book, eps_growth, revenue_growth]):
                    row = {
                        "ticker": ticker,
                        "provider_symbol": symbol,
                        "trailing_pe": trailing_pe,
                        "forward_pe": None,
                        "price_to_sales": price_to_sales,
                        "price_to_book": price_to_book,
                        "eps_ttm": _first_number(ratios, "netIncomePerShareTTM") or _first_number(metrics, "netIncomePerShareTTM"),
                        "eps_growth_yoy": eps_growth,
                        "revenue_growth_yoy": revenue_growth,
                        "source": "FMP stable ratios/key-metrics/growth endpoints",
                    }
                    break
            except Exception as exc:
                last_error = exc
            time.sleep(0.08)
        if row:
            rows.append(row)
        elif last_error:
            warnings.append(f"{ticker} FMP failed: {type(last_error).__name__} {str(last_error)[:120]}")
    return rows, warnings


def fundamentals_cache_age_seconds():
    data = load_json(FUNDAMENTALS_CACHE, None)
    if not data or not data.get("as_of_unix"):
        return None
    return max(0, int(time.time()) - int(data["as_of_unix"]))


def refresh_fundamentals(force=False):
    FUNDAMENTALS_TTL_SECONDS = 60 * 60 * 12
    fmp_token = secret_value("FMP_API_KEY")
    finnhub_token = secret_value("FINNHUB_API_KEY")
    portfolio = current_snapshot()["portfolio"]
    holdings = portfolio.get("holdings", [])
    eligible_holdings = [
        holding for holding in holdings
        if holding.get("ticker") and holding.get("cost_currency") == "USD"
    ]
    eligible_tickers = {holding["ticker"] for holding in eligible_holdings}
    cached = load_json(FUNDAMENTALS_CACHE, {"rows": [], "warnings": []}) or {"rows": []}
    cached_by_ticker = {
        row.get("ticker"): row
        for row in cached.get("rows", [])
        if row.get("ticker") in eligible_tickers
    }
    attempted_at = dict(cached.get("attempted_at") or {})
    cached_as_of = int(cached.get("as_of_unix") or 0)
    now = int(time.time())
    needed_tickers = set()
    for holding in eligible_holdings:
        ticker = holding["ticker"]
        row = cached_by_ticker.get(ticker, {})
        last_attempt = int(attempted_at.get(ticker) or row.get("fetched_at_unix") or cached_as_of or 0)
        if force or last_attempt == 0 or now - last_attempt >= FUNDAMENTALS_TTL_SECONDS:
            needed_tickers.add(ticker)

    if not needed_tickers:
        return {
            "ok": True,
            "cached": True,
            "age_seconds": fundamentals_cache_age_seconds() or 0,
            "fundamentals": cached,
        }

    needed_holdings = [holding for holding in eligible_holdings if holding["ticker"] in needed_tickers]
    all_rows = []
    all_warnings = []
    providers_used = []

    # ── Step 1: FMP first ──
    if fmp_token:
        fmp_rows, fmp_warnings = _refresh_fundamentals_fmp(needed_holdings, fmp_token)
        all_rows.extend(fmp_rows)
        all_warnings.extend(fmp_warnings)
        if fmp_rows:
            providers_used.append("FMP")
    else:
        all_warnings.append("未设置 FMP_API_KEY。")

    # ── Step 2: Finnhub for missed tickers ──
    if finnhub_token:
        fmp_tickers = {r["ticker"] for r in all_rows}
        needed = []
        for h in sorted(needed_holdings, key=lambda h: float(h.get("cost_usd_standard") or 0), reverse=True):
            t = h.get("ticker")
            if not t or "." in t or h.get("cost_currency") != "USD":
                continue
            if t not in fmp_tickers:
                needed.append(t)
        if needed:
            providers_used.append("Finnhub")
            for ticker in dict.fromkeys(needed):
                for attempt in range(3):
                    try:
                        payload = _finnhub_metric(ticker, finnhub_token)
                        metric = payload.get("metric") or {}
                        all_rows.append({
                            "ticker": ticker,
                            "trailing_pe": _metric_number(metric, "peBasicExclExtraTTM", "peTTM", "peNormalizedAnnual"),
                            "forward_pe": _metric_number(metric, "forwardPE", "peExclExtraAnnual"),
                            "price_to_sales": _metric_number(metric, "psTTM", "psAnnual"),
                            "price_to_book": _metric_number(metric, "pbAnnual", "pbQuarterly"),
                            "eps_ttm": _metric_number(metric, "epsBasicExclExtraItemsTTM", "epsInclExtraItemsTTM"),
                            "eps_growth_yoy": _metric_number(metric, "epsGrowthTTMYoy", "epsGrowthQuarterlyYoy", "epsGrowth5Y"),
                            "revenue_growth_yoy": _metric_number(metric, "revenueGrowthTTMYoy", "revenueGrowthQuarterlyYoy"),
                            "source": "Finnhub stock metric endpoint",
                        })
                        break
                    except Exception as exc:
                        err = str(exc)
                        if "429" in err and attempt < 2:
                            time.sleep(3 + attempt * 3)
                            continue
                        if attempt == 2 or "429" not in err:
                            all_warnings.append(f"{ticker} Finnhub failed: {type(exc).__name__} {str(exc)[:80]}")
                time.sleep(1.1)  # ~1 call/sec for Finnhub free tier
    elif not fmp_token:
        all_warnings.append("未设置 FINNHUB_API_KEY。")

    for ticker in needed_tickers:
        attempted_at[ticker] = now
    for row in all_rows:
        row["fetched_at_unix"] = now

    merged_by_ticker = dict(cached_by_ticker)
    merged_by_ticker.update({row["ticker"]: row for row in all_rows if row.get("ticker")})
    merged_rows = [merged_by_ticker[ticker] for ticker in sorted(merged_by_ticker) if ticker in eligible_tickers]
    failed_count = len(needed_tickers - {row.get("ticker") for row in all_rows})

    fundamentals = {
        "as_of_unix": now,
        "rows": merged_rows,
        "warnings": all_warnings,
        "source": "+".join(providers_used) if providers_used else cached.get("source", "none"),
        "attempted_at": {ticker: attempted_at[ticker] for ticker in eligible_tickers if ticker in attempted_at},
        "incremental": not force,
        "refresh_stats": {
            "requested": len(needed_tickers),
            "updated": len({row.get("ticker") for row in all_rows}),
            "reused": max(0, len(eligible_tickers) - len({row.get("ticker") for row in all_rows})),
            "failed": failed_count,
            "removed": len(set(row.get("ticker") for row in cached.get("rows", [])) - eligible_tickers),
        },
    }
    FUNDAMENTALS_CACHE.write_text(json.dumps(fundamentals, ensure_ascii=False, indent=2), encoding="utf-8")
    if not merged_rows and not all_rows:
        return {
            "ok": False,
            "cached": False,
            "fundamentals": fundamentals,
            "warning": "FMP 和 Finnhub 均未返回数据。",
        }
    return {"ok": True, "cached": False, "fundamentals": fundamentals}


def refresh_trading212():
    """Refresh normalized Trading 212 holdings by calling the pipeline in-process.

    Previously this spawned `python3 scripts/build_trading212_v2.py`. That breaks
    inside a PyInstaller-bundled desktop app (no python3 interpreter, scripts not on
    disk), so the pipeline now runs as imported functions in the current process.
    The return shape is preserved for existing route callers (`ok`, `stdout`, etc.).
    """
    import sys
    import traceback

    started_at = datetime.now(timezone.utc).isoformat()
    scripts_dir = str((ROOT / "scripts").resolve())
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)

    # Bridge UI-saved secrets into the environment the standalone fetch script
    # reads. Slot 2 maps to the script's named account "2". When configured, it
    # is appended to any explicit account list so both accounts are fetched and
    # merged into the normalized portfolio output.
    for _name in (
        "TRADING212_API_KEY",
        "TRADING212_API_SECRET",
        "TRADING212_API_KEY_2",
        "TRADING212_API_SECRET_2",
    ):
        _val = secret_value(_name)
        if _val:
            os.environ[_name] = _val

    _accounts_value = secret_value("TRADING212_ACCOUNTS") or os.environ.get("TRADING212_ACCOUNTS") or "default"
    _accounts = [item.strip() for item in _accounts_value.split(",") if item.strip()]
    if not _accounts:
        _accounts = ["default"]
    if os.environ.get("TRADING212_API_KEY_2") and "2" not in _accounts:
        _accounts.append("2")
    os.environ["TRADING212_ACCOUNTS"] = ",".join(_accounts)

    try:
        import build_trading212_v2
        summary = build_trading212_v2.build_and_write()
        return {
            "ok": bool(summary.get("ok", True)),
            "started_at": started_at,
            "finished_at": datetime.now(timezone.utc).isoformat(),
            "summary": summary,
            "stdout": json.dumps(summary, ensure_ascii=False)[-2000:],
            "stderr": "",
            "returncode": 0,
        }
    except Exception as exc:
        return {
            "ok": False,
            "started_at": started_at,
            "finished_at": datetime.now(timezone.utc).isoformat(),
            "stdout": "",
            "stderr": f"{type(exc).__name__}: {exc}\n{traceback.format_exc()[-1800:]}",
            "returncode": 1,
        }


# ── After-Hours Unusual Activity ───────────────────────────────────

AFTER_HOURS_CACHE = V2_DIR / "after_hours_data.json"
AFTER_HOURS_CACHE_TTL = 60 * 15  # cache for 15 minutes


def after_hours_cache_age_seconds():
    data = load_json(AFTER_HOURS_CACHE, None)
    if not data or not data.get("as_of_unix"):
        return None
    return max(0, int(time.time()) - int(data["as_of_unix"]))


def _fetch_open_close(api_key, ticker, date_str):
    """Call Massive /v1/open-close/{ticker}/{date} for a single ticker.
    Retries on rate limits, falls back to previous trading day if today's data unavailable."""
    query = urllib.parse.urlencode({"apiKey": api_key})
    dates_to_try = [date_str]
    # If today's date fails, also try previous 2 trading days
    from datetime import timedelta
    yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
    day_before = (datetime.now() - timedelta(days=2)).strftime("%Y-%m-%d")
    if yesterday != date_str:
        dates_to_try.append(yesterday)
    if day_before not in dates_to_try:
        dates_to_try.append(day_before)

    last_error = None
    for attempt_date in dates_to_try:
        url = f"https://api.massive.com/v1/open-close/{ticker}/{attempt_date}?{query}"
        for retry in range(3):
            try:
                data = open_json(url)
                if data.get("status") == "OK":
                    data["_date_used"] = attempt_date
                    return data
                # If API returned error status, try next date
                last_error = RuntimeError(f"API status={data.get('status')}: {data.get('error', '')[:80]}")
                break  # Don't retry same date if API says error
            except Exception as exc:
                last_error = exc
                err_str = str(exc)
                if "429" in err_str or "exceeded" in err_str.lower():
                    time.sleep(2 + retry * 2)
                    continue
                if "403" in err_str or "404" in err_str:
                    break  # Try next date
                raise
    raise last_error or RuntimeError("All dates failed")


def refresh_after_hours(force=False):
    """Fetch after-hours price changes for portfolio holdings via Massive API.

    Compares afterHours vs close to detect unusual extended-hours moves.
    Caches results for AFTER_HOURS_CACHE_TTL seconds.
    """
    # Check cache
    if not force:
        cached = load_json(AFTER_HOURS_CACHE, None)
        if cached and cached.get("as_of_unix"):
            age = max(0, int(time.time()) - int(cached["as_of_unix"]))
            if age < AFTER_HOURS_CACHE_TTL:
                return {"ok": True, "cached": True, "age_seconds": age, "data": cached}

    api_key = secret_value("MASSIVE_API_KEY")
    if not api_key:
        return {"ok": False, "cached": False, "warning": "未设置 MASSIVE_API_KEY，盘后数据不可用。"}

    portfolio = current_snapshot()["portfolio"]
    holdings = portfolio.get("holdings", [])

    # Only US-listed tickers (no "." suffix)
    tickers = [
        h["ticker"]
        for h in holdings
        if "." not in h.get("ticker", "") and h.get("cost_currency") == "USD"
    ]

    today_str = datetime.now().strftime("%Y-%m-%d")
    rows = []
    warnings = []

    def _fetch_after_hours(ticker):
        try:
            data = _fetch_open_close(api_key, ticker, today_str)
        except Exception as exc:
            return None, f"{ticker} after-hours fetch failed: {type(exc).__name__} {str(exc)[:100]}"
        if data.get("status") != "OK":
            return None, f"{ticker}: API status={data.get('status')}"

        close = data.get("close")
        after = data.get("afterHours")
        pre = data.get("preMarket")

        if close and after and close != 0:
            change_pct = (after - close) / close * 100
            if abs(change_pct) >= 1.0:  # Filter: only show moves >= 1%
                return {
                    "ticker": ticker,
                    "symbol": data.get("symbol", ticker),
                    "close": close,
                    "after_hours": after,
                    "pre_market": pre,
                    "change_pct": round(change_pct, 2),
                    "volume": data.get("volume"),
                }, None
        return None, None

    for row, warning in _parallel_map(
        tickers,
        _fetch_after_hours,
        max_workers=AFTER_HOURS_WORKERS,
        min_interval=AFTER_HOURS_MIN_INTERVAL,  # Rate limit: ~3 calls/sec
    ):
        if row is not None:
            rows.append(row)
        if warning:
            warnings.append(warning)

    # Sort by absolute change descending
    rows.sort(key=lambda r: abs(r["change_pct"]), reverse=True)

    data = {
        "as_of_unix": int(time.time()),
        "date": today_str,
        "rows": rows,
        "warnings": warnings,
        "total_checked": len(tickers),
    }
    AFTER_HOURS_CACHE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "cached": False, "age_seconds": 0, "data": data}
