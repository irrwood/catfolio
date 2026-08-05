import json

import pytest


def test_bundled_sp500_holdings_are_complete():
    from app.sp500_holdings import sp500_holdings_dataset

    dataset = sp500_holdings_dataset()
    rows = dataset["rows"]

    assert dataset["source"] == "Vanguard official holdings"
    assert len(rows) >= 500
    assert sum(row["weight_percent"] for row in rows) > 99
    assert {"NVDA", "XOM", "BRK.B", "BF.B"} <= {row["ticker"] for row in rows}


def test_vanguard_payload_normalises_share_classes_and_missing_exxon_ticker():
    from app.sp500_holdings import _normalise_vanguard_payload

    template = {
        "securityType": "EQ.STOCK",
        "effectiveDate": "2026-06-30",
        "gicsSectorDescription": "Financials",
    }
    items = [
        {**template, "ticker": "BRK/B", "issuerName": "Berkshire Hathaway Inc", "marketValuePercentage": 49.5},
        {**template, "ticker": None, "issuerName": "ExxonMobil Holdings Corp", "marketValuePercentage": 49.5},
        {**template, "ticker": "USD", "issuerName": "US Dollar", "marketValuePercentage": 1, "securityType": "CRNY"},
    ]
    # The production feed guard expects a full index. Repeating distinct rows
    # keeps this focused fixture representative without weakening validation.
    for index in range(448):
        items.append({**template, "ticker": f"T{index}", "issuerName": f"Test {index}", "marketValuePercentage": 0})
    payload = {
        "data": {
            "funds": [{"profile": {"fundFullName": "Test S&P 500 Fund"}}],
            "borHoldings": [{"holdings": {"items": items}}],
        }
    }

    result = _normalise_vanguard_payload(payload)

    tickers = {row["ticker"] for row in result["rows"]}
    assert "BRK.B" in tickers
    assert "XOM" in tickers
    assert "USD" not in tickers


def test_etf_lookthrough_distributes_the_full_etf_value():
    from app.analytics import etf_lookthrough

    snapshot = {
        "portfolio": {
            "holdings": [
                {"ticker": "VUAG", "cost_usd_standard": 1000, "api_market_value_usd": 1200},
                {"ticker": "AAPL", "name": "Apple", "cost_usd_standard": 500, "api_market_value_usd": 600},
            ]
        },
        "market": {
            "rows": [
                {"ticker": "VUAG", "market_value_usd": 1200},
                {"ticker": "AAPL", "market_value_usd": 600},
            ]
        },
    }

    result = etf_lookthrough(snapshot, basis="market")
    apple = next(row for row in result["rows"] if row["ticker"] == "AAPL")

    assert result["constituent_count"] >= 500
    assert result["covered_weight_percent"] > 99
    assert sum(row["from_etf_usd"] for row in result["rows"]) == pytest.approx(1200)
    assert apple["direct_usd"] == 600
    assert apple["total_usd"] > apple["direct_usd"]


def test_etf_holdings_refresh_endpoint_returns_compact_metadata(monkeypatch):
    from app.routes import api

    monkeypatch.setattr(
        api,
        "refresh_sp500_holdings",
        lambda force=False: {
            "ok": True,
            "cached": False,
            "holdings": {
                "as_of": "2026-06-30",
                "source": "Vanguard official holdings",
                "rows": [{"ticker": "A", "weight_percent": 60}, {"ticker": "B", "weight_percent": 40}],
            },
        },
    )

    result = api.api_refresh_etf_holdings(force=True)

    assert result["constituent_count"] == 2
    assert result["covered_weight_percent"] == 100
    assert "rows" not in result
