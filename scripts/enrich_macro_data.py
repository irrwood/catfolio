import json
import os
import ssl
import time
import urllib.parse
import urllib.request
from pathlib import Path

import os; ROOT = Path(os.environ.get("CATFOLIO_ROOT") or os.environ.get("HELM_ROOT") or str(Path(__file__).resolve().parent.parent))
OUTPUT = ROOT / "outputs/portfolio_analysis/macro_data.json"

SERIES = {
    "FEDFUNDS": {"label": "美国联邦基金利率", "unit": "%"},
    "DGS10": {"label": "美国 10 年期国债收益率", "unit": "%"},
    "CPIAUCSL": {"label": "美国 CPI", "unit": "index"},
    "UNRATE": {"label": "美国失业率", "unit": "%"},
    "USREC": {"label": "美国衰退指标", "unit": "0/1"},
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


def fetch_series(api_key, series_id):
    params = urllib.parse.urlencode(
        {
            "series_id": series_id,
            "api_key": api_key,
            "file_type": "json",
            "sort_order": "desc",
            "limit": 4,
        }
    )
    url = f"https://api.stlouisfed.org/fred/series/observations?{params}"
    last_error = None
    for attempt in range(3):
        try:
            payload = open_json(url)
            break
        except Exception as exc:
            last_error = exc
            time.sleep(1.0 + attempt)
    else:
        raise last_error
    return [item for item in payload.get("observations", []) if item.get("value") not in {".", None}]


def to_float(value):
    if value in {None, "."}:
        return None
    return float(value)


def main():
    api_key = os.environ.get("FRED_API_KEY")
    rows = []
    warnings = []
    if not api_key:
        warnings.append("FRED_API_KEY is not set; macro data skipped.")
    else:
        for series_id, config in SERIES.items():
            try:
                observations = fetch_series(api_key, series_id)
                latest = observations[0] if observations else {}
                previous = observations[1] if len(observations) > 1 else {}
                latest_value = to_float(latest.get("value"))
                previous_value = to_float(previous.get("value"))
                rows.append(
                    {
                        "series_id": series_id,
                        "label": config["label"],
                        "unit": config["unit"],
                        "date": latest.get("date"),
                        "value": latest_value,
                        "previous_date": previous.get("date"),
                        "previous_value": previous_value,
                        "change": latest_value - previous_value if latest_value is not None and previous_value is not None else None,
                        "source": "FRED",
                    }
                )
            except Exception as exc:
                warnings.append(f"{series_id} failed: {exc}")

    OUTPUT.write_text(json.dumps({"rows": rows, "warnings": warnings}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"rows": len(rows), "warnings": warnings}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
