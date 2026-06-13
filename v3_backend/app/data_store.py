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
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from .cache import cached
from .settings import FUNDAMENTALS_CACHE, LIVE_MARKET_CACHE, MARKET_REFRESH_TTL_SECONDS, ROOT, V2_DIR

_DEMO_MODE = os.environ.get("HELM_DEMO", "").lower() in ("1", "true", "yes")

FX_TO_USD = {
    "USD": 1.0,
    "GBP": 1.3460,
    "GBX": 0.013460,
    "EUR": 1.1630,
}


def load_json(path: Path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return fallback


@cached(ttl=10)
def current_snapshot():
    # Cached briefly to dedupe the burst of concurrent /api/* calls a single page
    # load fires — without this, every widget re-reads the same 4 JSON files from
    # disk. Every data-refresh path calls cache.clear_all(), so this never serves
    # stale data; callers must treat the returned dict as read-only (it is shared).
    if _DEMO_MODE:
        from .demo_data import DEMO_SNAPSHOT
        return DEMO_SNAPSHOT
    portfolio = load_json(V2_DIR / "portfolio_analysis.json", {"summary": {}, "holdings": [], "holdings_by_account": []})
    market = load_json(LIVE_MARKET_CACHE, None) or load_json(V2_DIR / "market_data.json", {"rows": [], "warnings": []})
    fundamentals = load_json(FUNDAMENTALS_CACHE, {"rows": [], "warnings": ["Fundamentals cache not available."]})
    trading212 = load_json(V2_DIR / "trading212_data.json", {"summary": {}, "account_cash": {}, "positions": [], "warnings": []})
    return {
        "portfolio": portfolio,
        "market": market,
        "fundamentals": fundamentals,
        "trading212": trading212,
        "loaded_at": datetime.now(timezone.utc).isoformat(),
    }


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
        value = _keychain_get(name, "com.helm.portfolio")
        if value:
            return value
        # Legacy service name migration
        value = _keychain_get(name, "portfolio-analysis-v3")
        if value:
            _keychain_save(name, value, "com.helm.portfolio")
            return value
    else:
        # Linux / Windows: use keyring library (Credential Manager / libsecret / etc.)
        try:
            import keyring as _kr
            value = _kr.get_password("com.helm.portfolio", name)
            if value:
                return value
        except Exception:
            pass
    return None


def save_secret(name: str, value: str) -> bool:
    """Persist a secret to the system keychain (macOS) or keyring library (Linux/Windows)."""
    import platform
    ok = False
    if platform.system() == "Darwin":
        _keychain_save(name, value, "com.helm.portfolio")
        ok = True
    else:
        try:
            import keyring as _kr
            _kr.set_password("com.helm.portfolio", name, value)
            ok = True
        except Exception:
            ok = False
    if ok:
        with _secret_lock:
            _secret_cache[name] = value
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
        subprocess.run(
            ["security", "add-generic-password", "-a", account, "-s", service, "-w", password, "-U"],
            capture_output=True, text=True, timeout=5,
        )
    except Exception:
        pass


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
    age = live_cache_age_seconds()
    if not force and age is not None and age < MARKET_REFRESH_TTL_SECONDS:
        data = load_json(LIVE_MARKET_CACHE, {"rows": [], "warnings": []})
        return {"ok": True, "cached": True, "age_seconds": age, "market": data}

    portfolio = load_json(V2_DIR / "portfolio_analysis.json", {"holdings": []})
    holdings = portfolio.get("holdings", [])
    symbols = sorted({row.get("yahoo_symbol") or row.get("ticker") for row in holdings if row.get("ticker")})
    warnings = []
    quotes = {}
    started = time.time()

    for symbol in symbols:
        try:
            quote = fetch_yahoo_chart(symbol)
            if quote:
                quotes[symbol] = quote
            else:
                warnings.append(f"Yahoo chart empty: {symbol}")
        except Exception as exc:
            warnings.append(f"Yahoo chart failed {symbol}: {type(exc).__name__} {str(exc)[:100]}")
        time.sleep(0.04)

    rows = []
    for row in holdings:
        symbol = row.get("yahoo_symbol") or row.get("ticker")
        quote = quotes.get(symbol, {})
        price = quote.get("regularMarketPrice")
        source = "Yahoo Finance chart endpoint live cache"
        if price is None:
            price = row.get("last_trade_price")
            source = "Trading 212 portfolio API fallback"
        quote_currency = normalize_currency(quote.get("regularMarketCurrency") or row.get("price_currency") or row.get("cost_currency"))
        shares = float(row.get("shares") or 0)
        market_value_native = shares * float(price) if price is not None else None
        market_value_usd = usd_equivalent(market_value_native, quote_currency)
        cost_usd = float(row.get("cost_usd_standard") or 0)
        rows.append(
            {
                "ticker": row["ticker"],
                "name": row.get("name", ""),
                "yahoo_symbol": symbol,
                "shares": shares,
                "cost_currency": row.get("cost_currency", ""),
                "avg_cost_native": row.get("avg_cost_native"),
                "cost_usd_standard": cost_usd,
                "quote_price": price,
                "quote_currency": quote_currency,
                "market_value_native": market_value_native,
                "market_value_usd": market_value_usd,
                "unrealized_usd": market_value_usd - cost_usd if market_value_usd is not None else None,
                "unrealized_percent": (market_value_usd / cost_usd - 1) * 100 if market_value_usd is not None and cost_usd else None,
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
                ratios = _fmp_stable_json("ratios-ttm", symbol, token)
                metrics = _fmp_stable_json("key-metrics-ttm", symbol, token)
                growth = _fmp_stable_json("income-statement-growth", symbol, token, {"limit": 1})
                profile = _fmp_stable_json("profile", symbol, token)
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
    age = fundamentals_cache_age_seconds()
    # Cache fundamentals for 12 hours
    FUNDAMENTALS_TTL_SECONDS = 60 * 60 * 12
    if not force and age is not None and age < FUNDAMENTALS_TTL_SECONDS:
        data = load_json(FUNDAMENTALS_CACHE, {"rows": [], "warnings": []})
        if data.get("rows"):
            return {"ok": True, "cached": True, "age_seconds": age, "fundamentals": data}

    fmp_token = secret_value("FMP_API_KEY")
    finnhub_token = secret_value("FINNHUB_API_KEY")
    portfolio = load_json(V2_DIR / "portfolio_analysis.json", {"holdings": []})
    holdings = portfolio.get("holdings", [])
    all_rows = []
    all_warnings = []
    providers_used = []

    # ── Step 1: FMP first ──
    if fmp_token:
        fmp_rows, fmp_warnings = _refresh_fundamentals_fmp(holdings, fmp_token)
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
        for h in sorted(holdings, key=lambda h: float(h.get("cost_usd_standard") or 0), reverse=True):
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

    if not all_rows:
        cached = load_json(FUNDAMENTALS_CACHE, {"rows": [], "warnings": []})
        return {"ok": False, "cached": True, "fundamentals": cached, "warning": "FMP 和 Finnhub 均未返回数据，返回缓存。"}

    fundamentals = {
        "as_of_unix": int(time.time()),
        "rows": all_rows,
        "warnings": all_warnings,
        "source": "+".join(providers_used) if providers_used else "none",
    }
    FUNDAMENTALS_CACHE.write_text(json.dumps(fundamentals, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "cached": False, "fundamentals": fundamentals}


def refresh_trading212():
    """Refresh Trading 212 data + audit report by calling the pipeline in-process.

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

    portfolio = load_json(V2_DIR / "portfolio_analysis.json", {"holdings": []})
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

    for ticker in tickers:
        try:
            data = _fetch_open_close(api_key, ticker, today_str)
            if data.get("status") != "OK":
                warnings.append(f"{ticker}: API status={data.get('status')}")
                continue

            close = data.get("close")
            after = data.get("afterHours")
            pre = data.get("preMarket")

            if close and after and close != 0:
                change_pct = (after - close) / close * 100
                if abs(change_pct) >= 1.0:  # Filter: only show moves >= 1%
                    rows.append({
                        "ticker": ticker,
                        "symbol": data.get("symbol", ticker),
                        "close": close,
                        "after_hours": after,
                        "pre_market": pre,
                        "change_pct": round(change_pct, 2),
                        "volume": data.get("volume"),
                    })
        except Exception as exc:
            warnings.append(f"{ticker} after-hours fetch failed: {type(exc).__name__} {str(exc)[:100]}")
        time.sleep(0.35)  # Rate limit: ~3 calls/sec

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
