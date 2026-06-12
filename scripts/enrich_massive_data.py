import json
import os
import ssl
import time
import urllib.parse
import urllib.request
from pathlib import Path

import os; ROOT = Path(os.environ.get("HELM_ROOT", str(Path(__file__).resolve().parent.parent)))
INPUT = ROOT / "outputs/portfolio_analysis/portfolio_analysis.json"
OUTPUT = ROOT / "outputs/portfolio_analysis/massive_data.json"


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


def fetch_ticker_reference(api_key, ticker):
    query = urllib.parse.urlencode({"apiKey": api_key})
    return open_json(f"https://api.massive.com/v3/reference/tickers/{ticker}?{query}")


def fetch_ticker_reference_with_retry(api_key, ticker):
    last_error = None
    for attempt in range(3):
        try:
            return fetch_ticker_reference(api_key, ticker)
        except Exception as exc:
            last_error = exc
            if "429" not in str(exc):
                raise
            time.sleep(2 + attempt * 2)
    raise last_error


def main():
    api_key = os.environ.get("MASSIVE_API_KEY")
    data = json.loads(INPUT.read_text(encoding="utf-8"))
    rows = []
    warnings = []
    if not api_key:
        warnings.append("MASSIVE_API_KEY is not set; Massive data skipped.")
    else:
        tickers = [
            row["ticker"]
            for row in sorted(data["holdings"], key=lambda item: float(item.get("cost_usd_standard") or 0), reverse=True)
            if row.get("cost_currency") == "USD" and "." not in row["ticker"]
        ][:12]
        for ticker in tickers:
            try:
                payload = fetch_ticker_reference_with_retry(api_key, ticker)
                result = payload.get("results") or {}
                rows.append(
                    {
                        "ticker": ticker,
                        "massive_name": result.get("name"),
                        "market": result.get("market"),
                        "locale": result.get("locale"),
                        "primary_exchange": result.get("primary_exchange"),
                        "type": result.get("type"),
                        "active": result.get("active"),
                        "currency_name": result.get("currency_name"),
                        "market_cap": result.get("market_cap"),
                        "homepage_url": result.get("homepage_url"),
                        "source": "Massive reference tickers endpoint",
                    }
                )
            except Exception as exc:
                warnings.append(f"{ticker} reference failed: {exc}")
            time.sleep(0.8)

    OUTPUT.write_text(json.dumps({"rows": rows, "warnings": warnings}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"rows": len(rows), "warnings": warnings[:5]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
