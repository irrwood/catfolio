import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATASET = ROOT / "v3_backend" / "app" / "data" / "eqqq_holdings.json"
PROJECT = ROOT / "CatfolioIOS" / "CatfolioIOS.xcodeproj" / "project.pbxproj"


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


def test_eqqq_holdings_are_bundled_in_the_ios_target():
    project = PROJECT.read_text(encoding="utf-8")
    assert "eqqq_holdings.json in Resources" in project
    assert "../v3_backend/app/data/eqqq_holdings.json" in project
