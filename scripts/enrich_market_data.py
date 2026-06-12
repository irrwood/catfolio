import json
import ssl
import time
import urllib.request
from pathlib import Path

import os; ROOT = Path(os.environ.get("HELM_ROOT", str(Path(__file__).resolve().parent.parent)))
INPUT = ROOT / "outputs/portfolio_analysis/portfolio_analysis.json"
OUTPUT = ROOT / "outputs/portfolio_analysis/market_data.json"

FX_TO_USD = {
    "USD": 1.0,
    "GBP": 1.3460,
    "GBX": 0.013460,
    "EUR": 1.1630,
}


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


def fetch_yahoo_chart(symbol):
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range=5d&interval=1d"
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
    }


def usd_equivalent(amount, currency):
    if amount is None:
        return None
    rate = FX_TO_USD.get(normalize_currency(currency))
    if rate is None:
        return None
    return float(amount) * rate


def normalize_currency(currency):
    if currency in {"GBp", "GBX"}:
        return "GBX"
    return currency


def main():
    data = json.loads(INPUT.read_text(encoding="utf-8"))
    holdings = data["holdings"]
    symbols = sorted({row.get("yahoo_symbol") or row["ticker"] for row in holdings})
    warnings = []

    quotes = {}
    for symbol in symbols:
        try:
            quote = fetch_yahoo_chart(symbol)
            if quote:
                quotes[symbol] = quote
            else:
                warnings.append(f"Yahoo chart empty: {symbol}")
        except Exception as exc:
            warnings.append(f"Yahoo chart failed {symbol}: {exc}")
        time.sleep(0.08)

    rows = []
    for row in holdings:
        symbol = row.get("yahoo_symbol") or row["ticker"]
        quote = quotes.get(symbol, {})
        price = quote.get("regularMarketPrice")
        quote_currency = normalize_currency(quote.get("regularMarketCurrency"))
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
                "market_time": quote.get("regularMarketTime"),
                "source": "Yahoo Finance chart endpoint",
            }
        )

    OUTPUT.write_text(
        json.dumps(
            {
                "as_of_unix": int(time.time()),
                "rows": rows,
                "warnings": warnings,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(json.dumps({"rows": len(rows), "warnings": warnings[:5]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
