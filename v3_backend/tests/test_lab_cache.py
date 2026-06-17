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

    assert result["available"] is False
    assert result["status"] == "demo_no_trade_history"
    assert result["rows"] == []
