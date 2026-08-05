def test_refresh_history_creates_cache_parent(monkeypatch, tmp_path):
    from app import lab

    cache_path = tmp_path / "portfolio_analysis_v2" / "lab_history_data.json"
    monkeypatch.setattr(lab, "demo_mode", lambda: False)
    monkeypatch.setattr(lab, "LAB_HISTORY_CACHE", cache_path)
    monkeypatch.setattr(lab, "lab_symbols", lambda snapshot: ["AAPL"])
    monkeypatch.setattr(lab, "current_snapshot", lambda: {"portfolio": {"holdings": []}})
    monkeypatch.setattr(lab, "fetch_history", lambda symbol, years=5, start_date=None: [{"date": "2025-01-01", "close": 100.0}])
    monkeypatch.setattr(lab.time, "sleep", lambda seconds: None)

    result = lab.refresh_history(force=True, years=1)

    assert result["ok"] is True
    assert cache_path.exists()
    assert result["history"]["prices"]["AAPL"][0]["close"] == 100.0


def test_refresh_history_continues_from_last_cached_date(monkeypatch, tmp_path):
    import json
    from app import lab

    cache_path = tmp_path / "portfolio_analysis_v2" / "lab_history_data.json"
    cache_path.parent.mkdir()
    cache_path.write_text(json.dumps({
        "as_of_unix": 1,
        "prices": {"AAPL": [{"date": "2026-01-02", "close": 100.0}]},
    }), encoding="utf-8")
    calls = []

    monkeypatch.setattr(lab, "demo_mode", lambda: False)
    monkeypatch.setattr(lab, "LAB_HISTORY_CACHE", cache_path)
    monkeypatch.setattr(lab, "lab_symbols", lambda snapshot: ["AAPL"])
    monkeypatch.setattr(lab, "current_snapshot", lambda: {"portfolio": {"holdings": []}})
    monkeypatch.setattr(lab.time, "sleep", lambda seconds: None)

    def fetch(symbol, years=5, start_date=None):
        calls.append((symbol, start_date))
        return [{"date": "2026-01-05", "close": 103.0}]

    monkeypatch.setattr(lab, "fetch_history", fetch)

    result = lab.refresh_history(force=False, years=5)

    assert calls == [("AAPL", "2026-01-03")]
    assert [row["date"] for row in result["history"]["prices"]["AAPL"]] == ["2026-01-02", "2026-01-05"]
    assert result["history"]["refresh_stats"]["incremental"] == 1


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

    monkeypatch.setattr(api, "current_snapshot", lambda: {
        "portfolio": {
            "summary": {"as_of": "2026-07-28 09:30:00"},
            "holdings": [
                {"ticker": "AAA", "api_market_value_usd": 40_000.00, "cost_usd_standard": 38_000.00},
                {"ticker": "BBB", "api_market_value_usd": 16_507.15, "cost_usd_standard": 16_500.69},
            ],
        },
        "market": {"rows": []},
        "trading212": {"summary": {"positions": 2}, "positions": [], "account_cash": {"total": 999_999.00}},
    })
    monkeypatch.setattr(api, "current_open_positions_history", lambda snapshot: {
        "available": True,
        "basis": "current_open_positions_backcast_from_initial_fill_excluding_cash",
        "rows": [
            {"date": "2026-07-25", "market_value_usd": 55_000.00, "cost_usd": 54_500.69},
        ],
    })

    payload = api.api_portfolio_chart()

    assert payload["basis"] == "current_trading212_open_positions_excluding_cash"
    assert payload["position_count"] == 2
    assert "cash_flow_mirror" not in payload
    assert "cash" not in payload
    assert payload["position_history"]["rows"] == [
        {"date": "2026-07-25", "market_value_usd": 55_000.00, "cost_usd": 54_500.69},
    ]
    assert payload["current_point"] == {
        "date": "2026-07-28",
        "as_of": "2026-07-28 09:30:00",
        "market_value_usd": 56507.15,
        "cost_usd": 54500.69,
    }
    assert not hasattr(api.api_portfolio_chart, "cache_clear")


def test_demo_portfolio_chart_uses_the_same_position_contract(monkeypatch):
    from app import lab
    from app.demo_data import DEMO_LAB_HISTORY, DEMO_SNAPSHOT
    from app.routes import api

    monkeypatch.setattr(api, "current_snapshot", lambda: DEMO_SNAPSHOT)
    monkeypatch.setattr(
        api,
        "current_open_positions_history",
        lambda snapshot: lab.current_open_positions_history(snapshot=snapshot, history=DEMO_LAB_HISTORY),
    )

    payload = api.api_portfolio_chart()
    rows = payload["position_history"]["rows"]

    assert payload["current_point"]["market_value_usd"] > 0
    assert payload["current_point"]["cost_usd"] > 0
    assert payload["position_history"]["available"] is True
    assert payload["position_history"]["position_count"] == len(DEMO_SNAPSHOT["portfolio"]["holdings"])
    assert len(rows) > 250
    assert rows[-1]["date"] == payload["current_point"]["date"]
    assert round(rows[-1]["market_value_usd"], 2) == round(payload["current_point"]["market_value_usd"], 2)
    assert round(rows[-1]["cost_usd"], 2) == round(payload["current_point"]["cost_usd"], 2)


def test_demo_snapshot_matches_live_snapshot_shape():
    from app.analytics import portfolio_summary
    from app.demo_data import DEMO_LAB_HISTORY, DEMO_SNAPSHOT

    portfolio = DEMO_SNAPSHOT["portfolio"]
    holdings = portfolio["holdings"]
    holdings_by_account = portfolio["holdings_by_account"]
    positions = DEMO_SNAPSHOT["trading212"]["positions"]
    as_of = str(portfolio["summary"]["as_of"])[:10]

    assert len(holdings_by_account) == len(holdings)
    assert len(positions) == len(holdings)
    assert all("holdings" not in row for row in holdings_by_account)
    assert all({"account", "api_ticker", "api_market_value_usd"} <= row.keys() for row in holdings)
    assert all({"account", "ticker", "initial_fill_date", "invested", "ppl", "fx_ppl"} <= row.keys() for row in positions)
    assert max(row["date"] for rows in DEMO_LAB_HISTORY["prices"].values() for row in rows) == as_of
    assert {
        "market_value_usd",
        "total_cost_usd_standard",
        "open_positions_by_account",
        "dividends_usd_standard",
        "interest_usd_standard",
        "report_fx_to_usd",
        "unrealized_pnl_basis",
        "version",
    } <= portfolio_summary(DEMO_SNAPSHOT).keys()


def test_demo_income_summary_has_current_month_data(monkeypatch):
    from app import lab

    monkeypatch.setattr(lab, "demo_mode", lambda: True)
    result = lab.income_summary()

    assert result["currency"] == "USD"
    assert result["rows"]
    assert result["monthly_rows"][-1]["month"] == "2026-08"
    assert result["monthly_rows"][-1]["dividends_usd"] > 0
    assert result["monthly_rows"][-1]["cash_interest_usd"] > 0


def test_current_open_positions_history_never_uses_account_cash():
    from app import lab

    snapshot = {
        "portfolio": {
            "holdings_by_account": [{
                "account": "Primary",
                "api_ticker": "TEST_US_EQ",
                "yahoo_symbol": "TEST",
                "shares": 2,
                "cost_usd_standard": 100,
                "cost_currency": "USD",
            }],
        },
        "trading212": {
            "positions": [{
                "account": "Primary",
                "ticker": "TEST_US_EQ",
                "initial_fill_date": "2026-01-02T09:30:00Z",
            }],
            "account_cash": {"Primary": {"total": 999_999.00}},
        },
    }
    history = {
        "prices": {
            "TEST": [
                {"date": "2026-01-01", "close": 40},
                {"date": "2026-01-02", "close": 50},
                {"date": "2026-01-03", "close": 60},
            ],
        },
    }

    result = lab.current_open_positions_history(snapshot=snapshot, history=history)

    assert result["available"] is True
    assert result["basis"] == "current_open_positions_backcast_from_initial_fill_excluding_cash"
    assert result["rows"] == [
        {"date": "2026-01-02", "market_value_usd": 100.0, "cost_usd": 100.0},
        {"date": "2026-01-03", "market_value_usd": 120.0, "cost_usd": 100.0},
    ]
    assert "999999" not in str(result)


def test_cash_flow_history_does_not_claim_to_be_current_position_cost(monkeypatch):
    from datetime import datetime
    from app import lab

    trades = [
        {"date": "2026-01-02", "dt": datetime(2026, 1, 2), "Action": "Market buy", "Ticker": "TEST", "Currency (Total)": "USD", "Total": "100", "No. of shares": "10", "Account": "A"},
        {"date": "2026-01-03", "dt": datetime(2026, 1, 3), "Action": "Market buy", "Ticker": "TEST", "Currency (Total)": "USD", "Total": "200", "No. of shares": "10", "Account": "A"},
        {"date": "2026-01-04", "dt": datetime(2026, 1, 4), "Action": "Market sell", "Ticker": "TEST", "Currency (Total)": "USD", "Total": "75", "No. of shares": "5", "Account": "A"},
    ]
    history = {
        "prices": {
            "SPY": [
                {"date": "2026-01-02", "close": 100},
                {"date": "2026-01-03", "close": 101},
                {"date": "2026-01-04", "close": 102},
            ],
            "TEST": [
                {"date": "2026-01-02", "close": 10},
                {"date": "2026-01-03", "close": 15},
                {"date": "2026-01-04", "close": 18},
            ],
        }
    }
    monkeypatch.setattr(lab, "demo_mode", lambda: False)
    monkeypatch.setattr(lab, "_read_trade_transactions", lambda: trades)
    monkeypatch.setattr(lab, "ensure_history_symbols", lambda symbols: history)
    lab.cash_flow_mirror_vs_benchmark.cache_clear()

    result = lab.cash_flow_mirror_vs_benchmark("SPY")

    assert all("open_position_cost_usd" not in row for row in result["rows"])
    assert round(result["rows"][-1]["portfolio_value"], 2) == 270.0
    assert round(result["rows"][-1]["adjusted_portfolio_value"], 2) == 345.0
    lab.cash_flow_mirror_vs_benchmark.cache_clear()
