import json
import http.cookiejar
import os
import ssl
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import os; ROOT = Path(os.environ.get("HELM_ROOT", str(Path(__file__).resolve().parent.parent)))
INPUT = ROOT / "outputs/portfolio_analysis/portfolio_analysis.json"
OUTPUT = ROOT / "outputs/portfolio_analysis/options_data.json"
MIN_RELIABLE_OPEN_INTEREST = 1000
CTX = ssl._create_unverified_context()
COOKIE_JAR = http.cookiejar.CookieJar()
OPENER = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(COOKIE_JAR),
    urllib.request.HTTPSHandler(context=CTX),
)
CRUMB = None


def open_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        if "CERTIFICATE_VERIFY_FAILED" not in str(exc):
            raise
        with urllib.request.urlopen(req, timeout=20, context=ssl._create_unverified_context()) as response:
            return json.loads(response.read().decode("utf-8"))


def fetch_massive_chain(api_key, ticker, expiration_date):
    query = urllib.parse.urlencode(
        {
            "expiration_date": expiration_date,
            "limit": 250,
            "apiKey": api_key,
        }
    )
    url = f"https://api.massive.com/v3/snapshot/options/{ticker}?{query}"
    results = []
    while url:
        payload = open_json(url)
        results.extend(payload.get("results") or [])
        next_url = payload.get("next_url")
        if next_url and "apiKey=" not in next_url:
            separator = "&" if "?" in next_url else "?"
            url = f"{next_url}{separator}{urllib.parse.urlencode({'apiKey': api_key})}"
        else:
            url = next_url
        if len(results) >= 1000:
            break
    return results


def normalize_massive_contracts(results):
    calls = []
    puts = []
    underlying_price = None
    for item in results:
        details = item.get("details") or {}
        session = item.get("session") or {}
        underlying = item.get("underlying_asset") or {}
        if underlying_price is None:
            underlying_price = underlying.get("price") or underlying.get("value")
        row = {
            "strike": details.get("strike_price"),
            "volume": session.get("volume") or 0,
            "openInterest": item.get("open_interest") or 0,
            "impliedVolatility": item.get("implied_volatility"),
            "delta": (item.get("greeks") or {}).get("delta"),
            "gamma": (item.get("greeks") or {}).get("gamma"),
        }
        if details.get("contract_type") == "call":
            calls.append(row)
        elif details.get("contract_type") == "put":
            puts.append(row)
    return calls, puts, underlying_price


def summarize_massive(api_key, ticker, expiration_date):
    results = fetch_massive_chain(api_key, ticker, expiration_date)
    if not results:
        raise RuntimeError("Massive returned no option chain rows")
    calls, puts, underlying_price = normalize_massive_contracts(results)
    call_volume = sum(float(item.get("volume") or 0) for item in calls)
    put_volume = sum(float(item.get("volume") or 0) for item in puts)
    call_oi = sum(float(item.get("openInterest") or 0) for item in calls)
    put_oi = sum(float(item.get("openInterest") or 0) for item in puts)
    total_oi = call_oi + put_oi
    has_open_interest = total_oi >= MIN_RELIABLE_OPEN_INTEREST
    return {
        "ticker": ticker,
        "yahoo_symbol": ticker,
        "available": True,
        "underlying_price": underlying_price,
        "expiration": None,
        "expiration_date": expiration_date,
        "call_volume": call_volume,
        "put_volume": put_volume,
        "put_call_volume_ratio": put_volume / call_volume if call_volume else None,
        "call_open_interest": call_oi,
        "put_open_interest": put_oi,
        "open_interest_reliable": has_open_interest,
        "open_interest_minimum": MIN_RELIABLE_OPEN_INTEREST,
        "put_call_oi_ratio": put_oi / call_oi if call_oi else None,
        "max_pain": max_pain(calls, puts) if has_open_interest else None,
        "call_wall": wall(calls, "openInterest") if has_open_interest else None,
        "put_wall": wall(puts, "openInterest") if has_open_interest else None,
        "volume_call_wall": wall(calls, "volume"),
        "volume_put_wall": wall(puts, "volume"),
        "dominant_strikes": exposure_by_strike(calls, puts, "openInterest" if has_open_interest else "volume"),
        "basis": "open_interest" if has_open_interest else "volume_only",
        "source": "Massive options chain snapshot endpoint",
        "method_note": "Massive option chain snapshot. Max Pain is shown only when open interest meets the reliability threshold.",
    }


def yahoo_open(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    return OPENER.open(req, timeout=20).read().decode("utf-8")


def yahoo_crumb():
    global CRUMB
    if CRUMB:
        return CRUMB
    try:
        yahoo_open("https://fc.yahoo.com")
    except Exception:
        pass
    CRUMB = yahoo_open("https://query2.finance.yahoo.com/v1/test/getcrumb").strip()
    return CRUMB


def fetch_chain(symbol, expiration=None):
    crumb = urllib.parse.quote(yahoo_crumb())
    date_part = f"date={expiration}&" if expiration else ""
    url = f"https://query2.finance.yahoo.com/v7/finance/options/{symbol}?{date_part}crumb={crumb}"
    payload = json.loads(yahoo_open(url))
    result = payload.get("optionChain", {}).get("result", [])
    return result[0] if result else None


def select_expiration(expiration_dates, as_of):
    if not expiration_dates:
        return None
    base = datetime.strptime(as_of, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp()
    future = [ts for ts in expiration_dates if ts >= base + 7 * 86400]
    if not future:
        future = [ts for ts in expiration_dates if ts >= base]
    if not future:
        return expiration_dates[0]
    return min(future, key=lambda ts: abs(((ts - base) / 86400) - 45))


def max_pain(calls, puts):
    strikes = sorted({float(item.get("strike", 0)) for item in calls + puts if item.get("strike")})
    best = None
    for spot in strikes:
        payout = 0.0
        for call in calls:
            payout += max(0.0, spot - float(call.get("strike", 0))) * float(call.get("openInterest") or 0)
        for put in puts:
            payout += max(0.0, float(put.get("strike", 0)) - spot) * float(put.get("openInterest") or 0)
        if best is None or payout < best[1]:
            best = (spot, payout)
    return best[0] if best else None


def wall(rows, field):
    ranked = sorted(rows, key=lambda item: float(item.get(field) or 0), reverse=True)
    return float(ranked[0]["strike"]) if ranked and ranked[0].get("strike") is not None else None


def exposure_by_strike(calls, puts, field):
    exposures = {}
    for call in calls:
        strike = call.get("strike")
        if strike is None:
            continue
        exposures[float(strike)] = exposures.get(float(strike), 0.0) + float(call.get(field) or 0)
    for put in puts:
        strike = put.get("strike")
        if strike is None:
            continue
        exposures[float(strike)] = exposures.get(float(strike), 0.0) - float(put.get(field) or 0)
    return [
        {"strike": strike, "net_open_interest": value}
        for strike, value in sorted(exposures.items(), key=lambda item: abs(item[1]), reverse=True)[:8]
    ]


def summarize(symbol, ticker, as_of):
    chain = fetch_chain(symbol)
    if not chain:
        return {"ticker": ticker, "yahoo_symbol": symbol, "available": False, "warning": "No option chain"}
    selected_expiration = select_expiration(chain.get("expirationDates") or [], as_of)
    if selected_expiration:
        selected_chain = fetch_chain(symbol, selected_expiration)
        if selected_chain:
            chain = selected_chain
    option = (chain.get("options") or [{}])[0]
    calls = option.get("calls") or []
    puts = option.get("puts") or []
    call_volume = sum(float(item.get("volume") or 0) for item in calls)
    put_volume = sum(float(item.get("volume") or 0) for item in puts)
    call_oi = sum(float(item.get("openInterest") or 0) for item in calls)
    put_oi = sum(float(item.get("openInterest") or 0) for item in puts)
    total_oi = call_oi + put_oi
    has_open_interest = total_oi >= MIN_RELIABLE_OPEN_INTEREST
    return {
        "ticker": ticker,
        "yahoo_symbol": symbol,
        "available": True,
        "underlying_price": chain.get("quote", {}).get("regularMarketPrice"),
        "expiration": option.get("expirationDate"),
        "expiration_date": datetime.fromtimestamp(option.get("expirationDate"), timezone.utc).date().isoformat() if option.get("expirationDate") else None,
        "call_volume": call_volume,
        "put_volume": put_volume,
        "put_call_volume_ratio": put_volume / call_volume if call_volume else None,
        "call_open_interest": call_oi,
        "put_open_interest": put_oi,
        "open_interest_reliable": has_open_interest,
        "open_interest_minimum": MIN_RELIABLE_OPEN_INTEREST,
        "put_call_oi_ratio": put_oi / call_oi if call_oi else None,
        "max_pain": max_pain(calls, puts) if has_open_interest else None,
        "call_wall": wall(calls, "openInterest") if has_open_interest else None,
        "put_wall": wall(puts, "openInterest") if has_open_interest else None,
        "volume_call_wall": wall(calls, "volume"),
        "volume_put_wall": wall(puts, "volume"),
        "dominant_strikes": exposure_by_strike(calls, puts, "openInterest" if has_open_interest else "volume"),
        "basis": "open_interest" if has_open_interest else "volume_only",
        "source": "Yahoo Finance options endpoint",
        "method_note": "Public option-chain structure only. Max Pain is shown only when open interest meets the reliability threshold; otherwise walls are volume-based.",
    }


def main():
    data = json.loads(INPUT.read_text(encoding="utf-8"))
    as_of = data.get("summary", {}).get("as_of", "2026-06-03")
    target_expiration = "2026-07-17"
    massive_api_key = os.environ.get("MASSIVE_API_KEY")
    holdings = sorted(data["holdings"], key=lambda row: float(row.get("cost_usd_standard") or 0), reverse=True)
    candidates = [row for row in holdings if row.get("cost_currency") == "USD"][:12]
    rows = []
    warnings = []
    massive_options_blocked = False
    for row in candidates:
        symbol = row.get("yahoo_symbol") or row["ticker"]
        try:
            if massive_api_key and not massive_options_blocked and "." not in row["ticker"]:
                try:
                    rows.append(summarize_massive(massive_api_key, row["ticker"], target_expiration))
                except Exception as massive_exc:
                    if "403" in str(massive_exc):
                        massive_options_blocked = True
                        warnings.append("Massive options snapshot returned 403; using Yahoo fallback for this run.")
                    else:
                        warnings.append(f"{row['ticker']} Massive fallback to Yahoo: {massive_exc}")
                    rows.append(summarize(symbol, row["ticker"], as_of))
            else:
                rows.append(summarize(symbol, row["ticker"], as_of))
        except Exception as exc:
            warnings.append(f"{row['ticker']} failed: {exc}")
            rows.append({"ticker": row["ticker"], "yahoo_symbol": symbol, "available": False, "warning": str(exc)})
        time.sleep(0.4)
    OUTPUT.write_text(json.dumps({"rows": rows, "warnings": warnings}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"rows": len(rows), "warnings": warnings[:5]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
