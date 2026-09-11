import json
from types import SimpleNamespace

import pytest
from starlette.requests import Request


def _request(path="/settings"):
    return Request({"type": "http", "method": "GET", "path": path, "headers": [], "query_string": b""})


class _FakeMoomooContext:
    def get_acc_list(self):
        return 0, [{"acc_id": 42, "currency": "USD"}]

    def position_list_query(self, **kwargs):
        assert kwargs["acc_id"] == 42
        assert kwargs["refresh_cache"] is True
        return 0, [{
            "code": "US.AAPL",
            "stock_name": "Apple",
            "qty": 4,
            "average_cost": 180,
            "nominal_price": 210,
            "market_val": 840,
            "unrealized_pl": 120,
            "currency": "USD",
        }]

    def accinfo_query(self, **kwargs):
        return 0, [{"cash": 55, "total_assets": 895, "currency": "USD"}]

    def close(self):
        return None


def test_moomoo_adapter_normalizes_opend_positions():
    from app.brokers.moomoo import MoomooAdapter, MoomooConfig

    fake_futu = SimpleNamespace(
        RET_OK=0,
        TrdMarket=SimpleNamespace(US="US"),
        TrdEnv=SimpleNamespace(REAL="REAL"),
        SecurityFirm=SimpleNamespace(FUTUSECURITIES="FUTUSECURITIES"),
        OpenSecTradeContext=lambda **kwargs: _FakeMoomooContext(),
    )
    snapshot = MoomooAdapter(
        MoomooConfig(markets=("US",), account_id=42),
        futu_module=fake_futu,
    ).fetch_snapshot()

    assert snapshot["provider"] == "moomoo"
    assert snapshot["positions"] == [{
        "broker": "moomoo",
        "ticker": "AAPL",
        "normalized_ticker": "AAPL",
        "api_ticker": "US.AAPL",
        "yahoo_symbol": "AAPL",
        "name": "Apple",
        "quantity": 4.0,
        "average_price_paid": 180.0,
        "current_price": 210.0,
        "market_value_native": 840.0,
        "currency": "USD",
        "ppl": 120.0,
        "fx_ppl": None,
        "realized_pnl": None,
        "account": "Moomoo · 42",
        "account_key": "42",
        "account_currency": "USD",
    }]
    assert snapshot["account_cash"]["Moomoo · 42"]["total"] == 55


def test_ibkr_adapter_normalizes_client_portal_positions():
    from app.brokers.ibkr import IBKRAdapter, IBKRConfig

    def opener(url, method):
        if url.endswith("iserver/auth/status"):
            return {"authenticated": True, "connected": True}
        if url.endswith("portfolio/accounts"):
            return [{"accountId": "U123", "displayName": "Main", "currency": "USD"}]
        if url.endswith("portfolio2/U123/positions"):
            return [{
                "description": "MSFT",
                "conid": 272093,
                "position": 3,
                "avgPrice": 390,
                "marketPrice": 420,
                "marketValue": 1260,
                "unrealizedPnl": 90,
                "currency": "USD",
            }]
        if url.endswith("portfolio/U123/summary"):
            return {"totalcashvalue": {"amount": 300}, "netliquidation": {"amount": 1560}}
        raise AssertionError(url)

    adapter = IBKRAdapter(IBKRConfig(account_id="U123"), opener=opener)
    assert adapter.test_connection()["ok"] is True
    snapshot = adapter.fetch_snapshot()

    row = snapshot["positions"][0]
    assert row["ticker"] == "MSFT"
    assert row["average_price_paid"] == 390
    assert row["ppl"] == 90
    assert row["account"] == "IBKR · Main"
    assert snapshot["account_cash"]["IBKR · Main"]["total"] == 300


@pytest.mark.parametrize("factory", [
    lambda: __import__("app.brokers.moomoo", fromlist=["MoomooConfig"]).MoomooConfig(host="example.com"),
    lambda: __import__("app.brokers.ibkr", fromlist=["IBKRConfig"]).IBKRConfig(base_url="https://example.com/v1/api"),
])
def test_broker_gateways_reject_remote_hosts(factory):
    with pytest.raises(ValueError):
        factory()


def test_broker_refresh_writes_existing_portfolio_contract(monkeypatch, tmp_path):
    from app.brokers import service

    data_dir = tmp_path / "outputs"
    v2_dir = data_dir / "portfolio_analysis_v2"
    monkeypatch.setattr(service, "DATA_DIR", data_dir)
    monkeypatch.setattr(service, "V2_DIR", v2_dir)
    monkeypatch.setattr(service, "_adapter", lambda provider: SimpleNamespace(fetch_snapshot=lambda: {
        "provider": "ibkr",
        "label": "Interactive Brokers",
        "positions": [{
            "broker": "ibkr",
            "ticker": "AAPL",
            "normalized_ticker": "AAPL",
            "api_ticker": "265598",
            "yahoo_symbol": "AAPL",
            "name": "Apple",
            "quantity": 2,
            "average_price_paid": 180,
            "current_price": 210,
            "market_value_native": 420,
            "currency": "USD",
            "ppl": 60,
            "fx_ppl": None,
            "account": "IBKR · Main",
            "account_currency": "USD",
        }],
        "account_cash": {"IBKR · Main": {"total": 100, "currencyCode": "USD"}},
        "account_info": {"IBKR · Main": {"id": "U123", "currencyCode": "USD"}},
        "warnings": [],
    }))

    result = service.refresh_broker("ibkr")
    portfolio = json.loads((v2_dir / "portfolio_analysis.json").read_text())
    market = json.loads((v2_dir / "market_data.json").read_text())

    assert result["ok"] is True
    assert portfolio["summary"]["broker_provider"] == "ibkr"
    assert portfolio["holdings"][0]["cost_usd_standard"] == 360
    assert portfolio["holdings"][0]["api_market_value_usd"] == 420
    assert market["rows"][0]["broker_unrealized_usd"] == 60


def test_settings_exposes_moomoo_and_ibkr_connections(monkeypatch):
    from app.routes import settings as settings_route

    monkeypatch.setattr(settings_route, "demo_mode", lambda: False)
    monkeypatch.setattr(settings_route, "secret_value", lambda name: "ibkr" if name == "BROKER_PROVIDER" else None)
    html = settings_route.settings_page(_request()).body.decode("utf-8")

    assert "Moomoo / Futu OpenD" in html
    assert "Interactive Brokers" in html
    assert 'id="input_MOOMOO_HOST"' in html
    assert 'id="input_IBKR_BASE_URL"' in html
    assert "testBroker('moomoo'" in html
    assert "testBroker('ibkr'" in html
    assert "triggerRefresh('broker')" in html
    assert "MOOMOO_HOST" in settings_route._ALLOWED_KEYS
    assert "IBKR_BASE_URL" in settings_route._ALLOWED_KEYS
