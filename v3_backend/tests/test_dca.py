from datetime import date, timedelta
import math

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.dca import DCAConfig, observations, scheduled_dates, signal, simulate, _xirr


def prices(count=320, value=100):
    rows = []
    day = date(2023, 1, 2)
    while len(rows) < count:
        if day.weekday() < 5:
            rows.append({"date": day.isoformat(), "close": value if not callable(value) else value(len(rows))})
        day += timedelta(days=1)
    return rows


def config(**overrides):
    return DCAConfig(**dict({"start": "2023-10-09", "end": "2024-02-29",
                            "sma_enabled": False, "rv_enabled": False, "er_enabled": False,
                            "drawdown_enabled": False}, **overrides))


def test_flat_price_preserves_cash_and_has_no_artificial_return_from_contributions():
    result = simulate(config(), prices())
    assert result["metrics"]["return"] == pytest.approx(0)
    assert result["metrics"]["xirr"] == pytest.approx(0, abs=1e-12)
    assert result["metrics"]["max_drawdown"] == 0
    spent = 0
    for row in result["trades"]:
        spent += row["amount"]
        assert row["cash"] >= 0
        assert row["position"] <= .2 + 1e-12
    assert result["metrics"]["cash"] + spent == pytest.approx(result["metrics"]["contributed"])
    for point in result["curve"]:
        assert point["value"] == pytest.approx(point["cash"] + point["holdings"])
        assert point["value"] == pytest.approx(point["contributed"])
        assert point["baseline"] == pytest.approx(point["value"])


def test_signals_use_prior_close_and_are_not_changed_by_future_prices():
    rows = prices()
    cfg = config(start="2023-10-09", end="2023-10-10", sma_enabled=True, rv_enabled=True)
    before = simulate(cfg, rows)
    rows = [dict(row, close=1000 if row["date"] >= "2023-10-09" else row["close"]) for row in rows]
    after = simulate(cfg, rows)
    assert before["trades"][0]["indicators"] == after["trades"][0]["indicators"]
    assert after["trades"][0]["signal_date"] == "2023-10-06"
    assert after["trades"][0]["price"] == 1000
    assert after["trades"][0]["target_multiplier"] == 1


def test_short_history_is_unknown_and_retains_deposits():
    result = simulate(config(start="2023-01-02", end="2023-02-01", sma_enabled=True), prices(25))
    assert all(row["amount"] == 0 for row in result["trades"])
    assert result["metrics"]["cash"] == result["metrics"]["contributed"]
    assert any("预热" in message for message in result["warnings"])
    obs = observations(prices(20))
    assert obs["rv20"] is None and obs["er20"] is None and obs["sma200"] is None


def test_indicator_definitions_and_flat_efficiency():
    flat = observations(prices(220))
    assert flat == {"sma200": 100, "price_ratio": 1, "rv20": 0, "er20": 0, "drawdown": 0}
    monotonic = observations(prices(220, lambda i: 100 * 1.01**i))
    assert monotonic["er20"] == pytest.approx(1)
    assert monotonic["rv20"] == pytest.approx(0, abs=1e-12)
    alternating = observations(prices(221, lambda i: 100 if i % 2 == 0 else 110))
    assert alternating["er20"] == 0
    assert alternating["rv20"] == pytest.approx(math.log(1.1) * math.sqrt(20 / 19 * 252))


def test_signal_priority_toggles_thresholds_and_multiplier_bounds():
    cfg = config(sma_enabled=True, rv_enabled=True, er_enabled=True, drawdown_enabled=True)
    obs = dict(price_ratio=.8, rv20=.2, er20=.5, drawdown=-.35)
    assert signal(cfg, obs)[0] == 3
    assert signal(cfg.model_copy(update={"max_multiplier": 2}), obs)[0] == 2
    assert signal(cfg, dict(obs, rv20=.5))[0] == .5
    assert signal(cfg.model_copy(update={"rv_enabled": False}), dict(obs, rv20=.5))[0] == 3
    assert signal(cfg, dict(obs, er20=.1))[0] == .5
    assert signal(cfg, dict(obs, price_ratio=1.2))[0] == .5
    assert signal(cfg, dict(obs, price_ratio=None))[0] == 0
    assert signal(config(), dict(obs, price_ratio=None))[0] == 1


def test_weekly_and_month_end_schedules_and_weekend_rollforward():
    cfg = config(start="2024-01-31", end="2024-04-30", frequency="monthly")
    assert list(scheduled_dates(cfg)) == [date(2024, 1, 31), date(2024, 2, 29), date(2024, 3, 31), date(2024, 4, 30)]
    result = simulate(config(start="2023-10-07", end="2023-10-23"), prices())
    assert [r["date"] for r in result["trades"]] == ["2023-10-09", "2023-10-16", "2023-10-23"]


def test_cooldown_blocks_only_additional_buying_after_an_actual_boost():
    # A missing Monday shifts week 1 to Tuesday, six days before week 2.
    rows = prices(value=lambda i: 100 if i < 200 else 70)
    rows = [r for r in rows if r["date"] != "2023-10-16"]
    cfg = config(start="2023-10-16", end="2023-10-24", initial_cash=100000, base_amount=50,
                 drawdown_enabled=True, cooldown=7)
    result = simulate(cfg, rows)
    assert result["trades"][0]["multiplier"] == 3
    assert result["trades"][1]["multiplier"] == 1
    assert "冷却" in result["trades"][1]["reason"]
    shorter = simulate(cfg.model_copy(update={"cooldown": 3}), rows)
    assert shorter["trades"][1]["multiplier"] == 3


def test_position_cap_can_override_minimum_and_does_not_force_sales():
    result = simulate(config(initial_cash=0, max_position=.1), prices())
    assert result["trades"][0]["amount"] == pytest.approx(50)
    assert result["trades"][0]["multiplier"] == pytest.approx(.1)
    assert all(row["amount"] >= 0 for row in result["trades"])
    assert all(point["cash"] >= point["value"] * .3 - 1e-8 for point in result["curve"])


def test_truncation_does_not_invent_years_of_catchup_deposits():
    result = simulate(config(start="2022-01-01", end="2023-02-01"), prices())
    assert result["trades"][0]["deposit"] == 500
    assert result["start"] == "2023-01-02"
    assert any("截取" in warning for warning in result["warnings"])


def test_xirr_known_cash_flow_and_short_window():
    assert _xirr([(date(2023, 1, 1), 1000)], date(2024, 1, 1), 1100) == pytest.approx(1.1 ** (365.25 / 365) - 1)
    assert _xirr([(date(2023, 1, 1), 1000)], date(2023, 1, 2), 1100) is None


def test_currency_scope_and_class_share_normalization():
    assert config(symbol="brk.b").symbol == "BRK-B"
    with pytest.raises(ValidationError):
        config(symbol="BP.L")


def test_invalid_prices_are_not_silently_filled():
    rows = prices()
    with pytest.raises(ValueError, match="无效价格"):
        simulate(config(), [dict(rows[0], close=float("nan")), *rows[1:]])
    with pytest.raises(ValueError, match="重复日期"):
        simulate(config(), [*rows, rows[0]])


def test_live_mode_reuses_strategy_price_provider(monkeypatch):
    from app.routes import dca
    calls = []
    monkeypatch.setattr(dca, "demo_mode", lambda: False)
    def cached(symbols, years):
        calls.append((symbols, years))
        return {"SPY": prices()}, ["Provider warning"]
    monkeypatch.setattr(dca, "get_prices", cached)
    result = dca.backtest(config())
    assert calls == [(["SPY"], 6)]
    assert result["demo"] is False
    assert "策略行情缓存" in result["source"]
    assert "Provider warning" in result["warnings"]


def test_english_page_translates_complete_labels_and_ships_dynamic_copy():
    from starlette.requests import Request
    from app.routes.dca import dca_page
    request = Request({"type": "http", "method": "GET", "path": "/dca", "headers": [(b"cookie", b"catfolio_lang=en")], "query_string": b""})
    html = dca_page(request).body.decode()
    assert "US Stock DCA Calculator" in html
    assert "Choose an asset" in html
    assert "Annualized return · XIRR" in html
    assert "Select标的" not in html
    assert "window.CATFOLIO_PAGE_I18N" in html


@pytest.mark.parametrize("override", [{"base_amount": -1}, {"base_amount": float("nan")}, {"frequency": "daily"}, {"symbol": "<script>"}, {"start": "2025-01-01", "end": "2024-01-01"}, {"max_position": 1}, {"cash_reserve": .9}, {"cooldown": 2}, {"unexpected": True}])
def test_invalid_config_rejected(override):
    with pytest.raises(ValidationError):
        config(**override)


def test_public_demo_dca_is_offline_and_uses_shared_v5_shell(monkeypatch):
    from app.main import app
    from app.routes import dca
    monkeypatch.setenv("CATFOLIO_PUBLIC_DEMO", "1")
    def no_network(*args, **kwargs):
        raise AssertionError("Demo must never fetch live history")
    monkeypatch.setattr(dca, "get_prices", no_network)
    with TestClient(app) as client:
        page = client.get("/dca?ui=v5")
        assert page.status_code == 200
        assert page.text.count('id="v5Sidebar"') == 1
        assert 'class="v5-nav-link active" href="/dca"' in page.text
        for part in ["/static/design-system.css", "/static/dca.css", "/static/dca.js", 'id="conditionsDialog"', 'id="dcaChart"']:
            assert part in page.text
        data = client.get("/api/dca/market?symbol=SPY").json()
        assert data["demo"] is True and data["indicators"]["sma200"] > 0
        response = client.post("/api/dca/backtest", json=config().model_dump(mode="json"))
        assert response.status_code == 200
        result = response.json()
        assert result["demo"] is True and result["curve"] and result["trades"]
        assert result["metrics"]["contributed"] > 0
        assert client.get("/api/dca/market?symbol=BADBAD").status_code == 404
        assert client.post("/api/dca/backtest", json={"start": "bad"}).status_code == 422
        assert client.post("/api/refresh/market", json={}).status_code == 403
