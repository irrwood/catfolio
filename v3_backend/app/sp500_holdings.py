"""Official Vanguard S&P 500 holdings with a bundled offline baseline."""

import json
import ssl
import time
import urllib.request
from pathlib import Path

import certifi

from .settings import SP500_HOLDINGS_CACHE


_BUNDLED_HOLDINGS = Path(__file__).resolve().parent / "data" / "sp500_holdings.json"
_VANGUARD_GRAPHQL_URL = "https://www.vanguard.co.uk/gpx/graphql"
_VANGUARD_PRODUCT_URL = (
    "https://www.vanguard.co.uk/professional/product/etf/equity/9694/"
    "sp-500-ucits-etf-usd-accumulating"
)
_CACHE_TTL_SECONDS = 60 * 60 * 24 * 7
_EQUITY_TYPES = {"EQ.STOCK", "EQ.REIT"}
_MISSING_TICKERS = {"EXXONMOBIL HOLDINGS CORP": "XOM"}

_HOLDINGS_QUERY = """
query FundsHoldingsQuery($portIds: [String!], $securityTypes: [String!], $lastItemKey: String) {
  funds(portIds: $portIds) {
    profile { fundFullName fundCurrency }
  }
  borHoldings(portIds: $portIds) {
    holdings(limit: 1500, securityTypes: $securityTypes, lastItemKey: $lastItemKey) {
      items {
        issuerName
        securityLongDescription
        gicsSectorDescription
        marketValuePercentage
        ticker
        securityType
        effectiveDate
      }
      totalHoldings
      lastItemKey
    }
  }
}
"""


def _read_dataset(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None
    rows = data.get("rows") if isinstance(data, dict) else None
    if not isinstance(rows, list) or len(rows) < 450:
        return None
    return data


def _normalise_ticker(value):
    return str(value or "").strip().upper().replace("/", ".")


def _normalise_vanguard_payload(payload):
    data = payload.get("data") or {}
    funds = data.get("funds") or []
    holding_groups = data.get("borHoldings") or []
    if not holding_groups:
        raise ValueError("Vanguard holdings response is empty")
    items = ((holding_groups[0].get("holdings") or {}).get("items") or [])
    merged = {}
    as_of = None
    for item in items:
        if item.get("securityType") not in _EQUITY_TYPES:
            continue
        issuer = str(item.get("issuerName") or item.get("securityLongDescription") or "").strip()
        ticker = _normalise_ticker(item.get("ticker"))
        if not ticker:
            ticker = _MISSING_TICKERS.get(issuer.upper(), "")
        if not ticker:
            continue
        try:
            weight = float(item.get("marketValuePercentage") or 0)
        except (TypeError, ValueError):
            continue
        if weight < 0:
            continue
        as_of = as_of or item.get("effectiveDate")
        row = merged.setdefault(
            ticker,
            {
                "ticker": ticker,
                "name": issuer or ticker,
                "sector": item.get("gicsSectorDescription") or "Unclassified",
                "weight_percent": 0.0,
            },
        )
        row["weight_percent"] += weight

    rows = sorted(merged.values(), key=lambda row: row["weight_percent"], reverse=True)
    covered = sum(row["weight_percent"] for row in rows)
    if len(rows) < 450 or not 95 <= covered <= 101:
        raise ValueError("Vanguard holdings response failed coverage validation")
    profile = (funds[0].get("profile") or {}) if funds else {}
    return {
        "fund_id": "9694",
        "fund_name": profile.get("fundFullName") or "Vanguard S&P 500 UCITS ETF",
        "benchmark": "S&P 500 Index",
        "as_of": as_of,
        "source": "Vanguard official holdings",
        "source_url": _VANGUARD_PRODUCT_URL,
        "fetched_at_unix": int(time.time()),
        "rows": rows,
    }


def fetch_sp500_holdings():
    body = json.dumps(
        {
            "query": _HOLDINGS_QUERY,
            "variables": {"portIds": ["9694"], "securityTypes": None, "lastItemKey": None},
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        _VANGUARD_GRAPHQL_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-Consumer-ID": "uk2",
            "User-Agent": "Catfolio/1.0 ETF-holdings-cache",
        },
    )
    tls_context = ssl.create_default_context(cafile=certifi.where())
    with urllib.request.urlopen(request, timeout=8, context=tls_context) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return _normalise_vanguard_payload(payload)


def refresh_sp500_holdings(force=False):
    cached = _read_dataset(SP500_HOLDINGS_CACHE)
    cached_at = int((cached or {}).get("fetched_at_unix") or 0)
    if cached and not force and time.time() - cached_at < _CACHE_TTL_SECONDS:
        return {"ok": True, "cached": True, "holdings": cached}
    try:
        holdings = fetch_sp500_holdings()
        SP500_HOLDINGS_CACHE.parent.mkdir(parents=True, exist_ok=True)
        temporary = SP500_HOLDINGS_CACHE.with_suffix(".tmp")
        temporary.write_text(json.dumps(holdings, ensure_ascii=False), encoding="utf-8")
        temporary.replace(SP500_HOLDINGS_CACHE)
        return {"ok": True, "cached": False, "holdings": holdings}
    except Exception as exc:
        fallback = cached or _read_dataset(_BUNDLED_HOLDINGS)
        if fallback:
            return {"ok": True, "cached": True, "stale": True, "warning": str(exc), "holdings": fallback}
        return {"ok": False, "cached": False, "warning": str(exc), "holdings": {"rows": []}}


def sp500_holdings_dataset():
    """Read the last successful public cache, then the bundled offline data."""
    return _read_dataset(SP500_HOLDINGS_CACHE) or _read_dataset(_BUNDLED_HOLDINGS) or {"rows": []}
