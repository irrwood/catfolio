import json
import os
import ssl
import time
import urllib.parse
import urllib.request
from pathlib import Path

import os; ROOT = Path(os.environ.get("CATFOLIO_ROOT") or os.environ.get("HELM_ROOT") or str(Path(__file__).resolve().parent.parent))
INPUT = ROOT / "outputs/portfolio_analysis/portfolio_analysis.json"
OUTPUT = ROOT / "outputs/portfolio_analysis/finnhub_data.json"


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


def finnhub_get(path, params):
    token = os.environ["FINNHUB_API_KEY"]
    query = urllib.parse.urlencode({**params, "token": token})
    return open_json(f"https://finnhub.io/api/v1{path}?{query}")


def main():
    api_key = os.environ.get("FINNHUB_API_KEY")
    data = json.loads(INPUT.read_text(encoding="utf-8"))
    rows = []
    warnings = []
    if not api_key:
        warnings.append("FINNHUB_API_KEY is not set; Finnhub data skipped.")
    else:
        tickers = [
            row["ticker"]
            for row in sorted(data["holdings"], key=lambda item: float(item.get("cost_usd_standard") or 0), reverse=True)
            if row.get("cost_currency") == "USD" and "." not in row["ticker"]
        ][:40]
        for ticker in tickers:
            try:
                quote = finnhub_get("/quote", {"symbol": ticker})
                profile = finnhub_get("/stock/profile2", {"symbol": ticker})
                rows.append(
                    {
                        "ticker": ticker,
                        "quote_price": quote.get("c"),
                        "quote_change": quote.get("d"),
                        "quote_change_percent": quote.get("dp"),
                        "quote_high": quote.get("h"),
                        "quote_low": quote.get("l"),
                        "quote_open": quote.get("o"),
                        "quote_previous_close": quote.get("pc"),
                        "quote_time": quote.get("t"),
                        "country": profile.get("country"),
                        "currency": profile.get("currency"),
                        "exchange": profile.get("exchange"),
                        "industry": profile.get("finnhubIndustry"),
                        "ipo": profile.get("ipo"),
                        "logo": profile.get("logo"),
                        "market_cap_million": profile.get("marketCapitalization"),
                        "name": profile.get("name"),
                        "share_outstanding_million": profile.get("shareOutstanding"),
                        "weburl": profile.get("weburl"),
                        "source": "Finnhub quote and company_profile2 endpoints",
                    }
                )
            except Exception as exc:
                warnings.append(f"{ticker} Finnhub failed: {exc}")
            time.sleep(0.25)

    OUTPUT.write_text(json.dumps({"rows": rows, "warnings": warnings}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"rows": len(rows), "warnings": warnings[:5]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
