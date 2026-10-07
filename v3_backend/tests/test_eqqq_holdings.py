import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATASET = ROOT / "v3_backend" / "app" / "data" / "eqqq_holdings.json"
IOS_COPY = ROOT / "CatfolioIOS" / "CatfolioIOS" / "Resources" / "ETF" / "eqqq_holdings.json"


def test_bundled_eqqq_holdings_are_complete_and_weighted():
    payload = json.loads(DATASET.read_text(encoding="utf-8"))
    rows = payload["rows"]

    assert payload["fund_id"] == "IE0032077012"
    assert payload["benchmark"] == "NASDAQ-100 Index"
    assert payload["source"] == "Invesco official holdings"
    assert len(rows) >= 100
    assert 99.9 <= sum(row["weight_percent"] for row in rows) <= 100.1
    assert len({row["ticker"] for row in rows}) == len(rows)
    assert {"NVDA", "AAPL", "MSFT", "AMZN", "GOOGL", "GOOG", "SPCX", "HONA"} <= {
        row["ticker"] for row in rows
    }


def test_the_ios_app_bundles_the_same_holdings():
    assert IOS_COPY.read_bytes() == DATASET.read_bytes()
