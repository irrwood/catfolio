import json


def test_latest_market_cache_uses_newer_pipeline_snapshot(monkeypatch, tmp_path):
    from app import data_store

    live = tmp_path / "live_market_data.json"
    pipeline_dir = tmp_path / "portfolio_analysis_v2"
    pipeline_dir.mkdir()
    pipeline = pipeline_dir / "market_data.json"
    live.write_text(json.dumps({"as_of_unix": 100, "rows": [{"ticker": "OLD"}]}), encoding="utf-8")
    pipeline.write_text(json.dumps({"as_of_unix": 200, "rows": [{"ticker": "NEW"}]}), encoding="utf-8")

    monkeypatch.setattr(data_store, "LIVE_MARKET_CACHE", live)
    monkeypatch.setattr(data_store, "V2_DIR", pipeline_dir)

    assert data_store._latest_market_cache()["rows"][0]["ticker"] == "NEW"


def test_latest_market_cache_uses_newer_live_snapshot(monkeypatch, tmp_path):
    from app import data_store

    live = tmp_path / "live_market_data.json"
    pipeline_dir = tmp_path / "portfolio_analysis_v2"
    pipeline_dir.mkdir()
    pipeline = pipeline_dir / "market_data.json"
    live.write_text(json.dumps({"as_of_unix": 300, "rows": [{"ticker": "LIVE"}]}), encoding="utf-8")
    pipeline.write_text(json.dumps({"as_of_unix": 200, "rows": [{"ticker": "PIPELINE"}]}), encoding="utf-8")

    monkeypatch.setattr(data_store, "LIVE_MARKET_CACHE", live)
    monkeypatch.setattr(data_store, "V2_DIR", pipeline_dir)

    assert data_store._latest_market_cache()["rows"][0]["ticker"] == "LIVE"


def test_market_refresh_requests_only_missing_or_expired_symbols(monkeypatch, tmp_path):
    from app import data_store

    live = tmp_path / "live_market_data.json"
    pipeline_dir = tmp_path / "portfolio_analysis_v2"
    pipeline_dir.mkdir()
    (pipeline_dir / "portfolio_analysis.json").write_text(json.dumps({
        "holdings": [
            {"ticker": "AAPL", "yahoo_symbol": "AAPL", "shares": 1, "cost_usd_standard": 100, "cost_currency": "USD"},
            {"ticker": "MSFT", "yahoo_symbol": "MSFT", "shares": 1, "cost_usd_standard": 200, "cost_currency": "USD"},
        ],
    }), encoding="utf-8")
    live.write_text(json.dumps({
        "as_of_unix": 1_000,
        "rows": [{
            "ticker": "AAPL", "yahoo_symbol": "AAPL", "quote_price": 150,
            "quote_currency": "USD", "quote_as_of_unix": 1_000,
        }],
    }), encoding="utf-8")
    calls = []

    monkeypatch.setattr(data_store, "LIVE_MARKET_CACHE", live)
    monkeypatch.setattr(data_store, "V2_DIR", pipeline_dir)
    monkeypatch.setattr(data_store.time, "time", lambda: 1_020)
    monkeypatch.setattr(data_store.time, "sleep", lambda seconds: None)
    monkeypatch.setattr(data_store, "fetch_yahoo_chart", lambda symbol: calls.append(symbol) or {
        "regularMarketPrice": 250,
        "regularMarketCurrency": "USD",
    })

    result = data_store.refresh_market_quotes(force=False)

    assert calls == ["MSFT"]
    assert result["market"]["refresh_stats"] == {"requested": 1, "reused": 1, "removed": 0}
    assert {row["ticker"] for row in result["market"]["rows"]} == {"AAPL", "MSFT"}


def test_fundamentals_refreshes_only_stale_tickers(monkeypatch, tmp_path):
    from app import data_store

    pipeline_dir = tmp_path / "portfolio_analysis_v2"
    pipeline_dir.mkdir()
    fundamentals = tmp_path / "fundamentals.json"
    (pipeline_dir / "portfolio_analysis.json").write_text(json.dumps({
        "holdings": [
            {"ticker": "AAPL", "cost_currency": "USD"},
            {"ticker": "MSFT", "cost_currency": "USD"},
        ],
    }), encoding="utf-8")
    fundamentals.write_text(json.dumps({
        "as_of_unix": 100_000,
        "rows": [
            {"ticker": "AAPL", "trailing_pe": 20, "fetched_at_unix": 99_999},
            {"ticker": "MSFT", "trailing_pe": 25, "fetched_at_unix": 1},
        ],
        "attempted_at": {"AAPL": 99_999, "MSFT": 1},
    }), encoding="utf-8")
    requested = []

    monkeypatch.setattr(data_store, "V2_DIR", pipeline_dir)
    monkeypatch.setattr(data_store, "FUNDAMENTALS_CACHE", fundamentals)
    monkeypatch.setattr(data_store.time, "time", lambda: 100_000)
    monkeypatch.setattr(data_store, "secret_value", lambda name: "fmp-token" if name == "FMP_API_KEY" else None)
    monkeypatch.setattr(data_store, "_refresh_fundamentals_fmp", lambda holdings, token: (
        requested.extend(row["ticker"] for row in holdings) or [{"ticker": "MSFT", "trailing_pe": 30, "source": "FMP"}],
        [],
    ))

    result = data_store.refresh_fundamentals(force=False)

    assert requested == ["MSFT"]
    assert {row["ticker"]: row["trailing_pe"] for row in result["fundamentals"]["rows"]} == {"AAPL": 20, "MSFT": 30}
    assert result["fundamentals"]["refresh_stats"]["requested"] == 1
    assert result["fundamentals"]["refresh_stats"]["updated"] == 1
