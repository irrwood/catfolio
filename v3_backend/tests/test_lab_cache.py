def test_refresh_history_creates_cache_parent(monkeypatch, tmp_path):
    from app import lab

    cache_path = tmp_path / "portfolio_analysis_v2" / "lab_history_data.json"
    monkeypatch.setattr(lab, "demo_mode", lambda: False)
    monkeypatch.setattr(lab, "LAB_HISTORY_CACHE", cache_path)
    monkeypatch.setattr(lab, "lab_symbols", lambda snapshot: ["AAPL"])
    monkeypatch.setattr(lab, "current_snapshot", lambda: {"portfolio": {"holdings": []}})
    monkeypatch.setattr(lab, "fetch_history", lambda symbol, years=5: [{"date": "2025-01-01", "close": 100.0}])
    monkeypatch.setattr(lab.time, "sleep", lambda seconds: None)

    result = lab.refresh_history(force=True, years=1)

    assert result["ok"] is True
    assert cache_path.exists()
    assert result["history"]["prices"]["AAPL"][0]["close"] == 100.0


def test_demo_lab_history_uses_offline_data(monkeypatch):
    from app import lab
    from app.cache import clear_all
    from app.demo_data import DEMO_SNAPSHOT

    clear_all()
    monkeypatch.setattr(lab, "demo_mode", lambda: True)
    monkeypatch.setattr(lab, "current_snapshot", lambda: DEMO_SNAPSHOT)
    monkeypatch.setattr(
        lab,
        "fetch_history",
        lambda symbol, years=5: (_ for _ in ()).throw(AssertionError("demo should not fetch history")),
    )

    history = lab.get_history()
    summary = lab.lab_history_summary()

    assert history["source"] == "demo offline price series"
    assert len(summary["nav"]) > 1000
    assert len(summary["symbols"]) >= 10
    assert not summary["warnings"]


def test_demo_price_path_has_visible_short_term_volatility():
    from statistics import pstdev

    from app.demo_data import DEMO_LAB_HISTORY

    closes = [row["close"] for row in DEMO_LAB_HISTORY["prices"]["SPY"]]
    returns = [current / previous - 1 for previous, current in zip(closes, closes[1:])]

    assert pstdev(returns) > 0.006


def test_demo_cash_flow_mirror_does_not_read_transactions(monkeypatch):
    from app import lab
    from app.cache import clear_all

    clear_all()
    monkeypatch.setattr(lab, "demo_mode", lambda: True)
    monkeypatch.setattr(
        lab,
        "_read_trade_transactions",
        lambda: (_ for _ in ()).throw(AssertionError("demo should not read local trades")),
    )

    result = lab.cash_flow_mirror_vs_benchmark()

    assert result["available"] is True, result
    assert result["status"] == "demo_synthetic"
    assert len(result["rows"]) > 1000
    assert result["stats"]["trade_count"] == 5
    assert result["warnings"]


def test_portfolio_chart_includes_uncached_current_snapshot(monkeypatch):
    from app.routes import api

    monkeypatch.setattr(
        api,
        "cash_flow_mirror_vs_benchmark",
        lambda symbol: {
            "available": True,
            "rows": [{"date": "2026-07-17", "adjusted_portfolio_value": 67350.0, "net_cash_flow": 40057.0}],
        },
    )
    monkeypatch.setattr(api, "current_snapshot", lambda: {"snapshot": "latest"})
    monkeypatch.setattr(
        api,
        "portfolio_summary",
        lambda snapshot: {
            "as_of": "2026-07-28 09:30:00",
            "market_value_usd": 56507.15,
            "total_cost_usd_standard": 54500.69,
        },
    )

    payload = api.api_portfolio_chart()

    assert payload["cash_flow_mirror"]["rows"][-1]["date"] == "2026-07-17"
    assert payload["current_point"] == {
        "date": "2026-07-28",
        "as_of": "2026-07-28 09:30:00",
        "market_value_usd": 56507.15,
        "cost_usd": 54500.69,
    }
    assert not hasattr(api.api_portfolio_chart, "cache_clear")
