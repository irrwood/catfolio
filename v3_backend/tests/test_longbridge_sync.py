"""Longbridge account sync, tested with a fake SDK module and a fake keychain."""
from decimal import Decimal
import json
from pathlib import Path
import re
import sys
from types import SimpleNamespace

import pytest

from app.brokers import accounts
from app.brokers.longbridge import MESSAGES, LongbridgeAdapter, LongbridgeConfig, LongbridgeError, _symbols

READ_ONLY_CALLS = {"Config.from_apikey", "TradeContext", "stock_positions", "account_balance", "QuoteContext", "member_id", "quote"}
CREDENTIALS = {"app_key": "demo-app-key", "app_secret": "demo-app-secret", "access_token": "demo-access-token"}


class FakeOpenApiException(Exception):
    """Mirrors longbridge.OpenApiException: code, message and a trace ID in str()."""

    def __init__(self, code, message):
        super().__init__(f"OpenApiException: (code={code}, trace_id=demo-trace-id) {message}")
        self.code = code
        self.message = message


def _position(symbol, quantity, cost, currency, name=None):
    return SimpleNamespace(symbol=symbol, symbol_name=name or symbol, quantity=Decimal(str(quantity)),
                           available_quantity=Decimal(str(quantity)), cost_price=Decimal(str(cost)),
                           currency=currency, market=None, init_quantity=None)


def _balance(currency, total_cash, net_assets):
    cash_infos = [SimpleNamespace(currency=c, available_cash=Decimal("1"), withdraw_cash=Decimal("1"),
                                  frozen_cash=Decimal("0"), settling_cash=Decimal("0")) for c in ("USD", "HKD")]
    return SimpleNamespace(currency=currency, total_cash=Decimal(str(total_cash)), net_assets=Decimal(str(net_assets)),
                           cash_infos=cash_infos, frozen_transaction_fees=[])


POSITIONS = [
    _position("AAPL.US", 10, 150, "USD", "Apple Inc."),
    _position("700.HK", 100, 300, "HKD", "Tencent"),
    _position("9988.HK", 200, 80, "HKD", "Alibaba"),
    _position("TSLA.US", 0, 200, "USD"),  # closed today: skipped and not quoted
]
QUOTES = {"AAPL.US": (200, 198), "700.HK": (320, 310), "9988.HK": (0, 85)}  # last_done, prev_close


class FakeSDK:
    """Stands in for longbridge.openapi and records every call made on it."""

    def __init__(self, positions=POSITIONS, quotes=QUOTES, member_id=10001, balances=None, fail=None):
        self.calls = []
        sdk = self
        balances = balances or {None: [_balance("HKD", 5000, 100000)]}

        def record(name, *args):
            sdk.calls.append((name, *args))
            if fail is not None and fail[0] == name:
                raise fail[1]

        class Config:
            @staticmethod
            def from_apikey(app_key, app_secret, access_token, **kwargs):
                record("Config.from_apikey", app_key, app_secret, access_token, kwargs)
                return "demo-config"

        # Only read-only methods exist, so any order call would fail the test.
        class TradeContext:
            def __init__(self, config):
                record("TradeContext", config)

            def stock_positions(self):
                record("stock_positions")
                return SimpleNamespace(channels=[SimpleNamespace(account_channel="lb", positions=list(positions))])

            def account_balance(self, currency=None):
                record("account_balance", currency)
                return balances[currency]

        class QuoteContext:
            def __init__(self, config):
                record("QuoteContext", config)

            def member_id(self):
                record("member_id")
                return member_id

            def quote(self, symbols):
                record("quote", list(symbols))
                return [SimpleNamespace(symbol=s, last_done=Decimal(str(quotes[s][0])), prev_close=Decimal(str(quotes[s][1])))
                        for s in symbols if s in quotes]

        self.Config, self.TradeContext, self.QuoteContext = Config, TradeContext, QuoteContext

    def names(self):
        return {call[0] for call in self.calls}


def _adapter(sdk, **config):
    return LongbridgeAdapter(LongbridgeConfig(**(CREDENTIALS | config)), sdk_module=sdk)


def test_longbridge_adapter_normalizes_positions_quotes_and_cash():
    sdk = FakeSDK()
    snapshot = _adapter(sdk).fetch_snapshot()

    assert snapshot["provider"] == "longbridge"
    assert snapshot["warnings"] == []
    assert snapshot["positions"][0] == {
        "broker": "longbridge",
        "ticker": "AAPL",
        "normalized_ticker": "AAPL",
        "api_ticker": "AAPL.US",
        "yahoo_symbol": "AAPL",
        "name": "Apple Inc.",
        "quantity": 10.0,
        "average_price_paid": 150.0,
        "current_price": 200.0,
        "market_value_native": 2000.0,
        "currency": "USD",
        "ppl": 500.0,
        "fx_ppl": None,
        "realized_pnl": None,
        "account": "Longbridge · 10001",
        "account_key": "10001",
        "account_currency": "USD",
    }
    hk = {p["api_ticker"]: p for p in snapshot["positions"][1:]}
    assert [(p["ticker"], p["yahoo_symbol"], p["currency"]) for p in hk.values()] == [("0700.HK", "0700.HK", "HKD"), ("9988.HK", "9988.HK", "HKD")]
    assert hk["700.HK"]["ppl"] == 100 * (320 - 300)
    assert hk["9988.HK"]["current_price"] == 85  # no trade yet today: previous close
    assert snapshot["account_cash"] == {"Longbridge · 10001": {"total": 5000.0, "netLiquidation": 100000.0, "currencyCode": "HKD"}}
    assert snapshot["account_info"] == {"Longbridge · 10001": {"id": "10001", "currencyCode": "HKD", "broker": "longbridge"}}
    assert ("Config.from_apikey", "demo-app-key", "demo-app-secret", "demo-access-token", {"enable_print_quote_packages": False}) in sdk.calls
    assert ("quote", ["700.HK", "9988.HK", "AAPL.US"]) in sdk.calls
    assert sdk.names() <= READ_ONLY_CALLS


@pytest.mark.parametrize("symbol, ticker, yahoo", [
    ("AAPL.US", "AAPL", "AAPL"),
    ("BRK.B.US", "BRK.B", "BRK-B"),
    ("700.HK", "0700.HK", "0700.HK"),
    ("9988.HK", "9988.HK", "9988.HK"),
    ("5.HK", "0005.HK", "0005.HK"),
    ("00700.HK", "0700.HK", "0700.HK"),
    ("600519.SH", "600519.SS", "600519.SS"),
    ("000001.SZ", "000001.SZ", "000001.SZ"),
    ("D05.SG", "D05.SI", "D05.SI"),
])
def test_longbridge_symbols_use_catfolio_and_yahoo_formats(symbol, ticker, yahoo):
    assert _symbols(symbol) == (ticker, yahoo)


def test_longbridge_merges_per_currency_balances_into_one_account():
    balances = {None: [_balance("HKD", 5000, 100000), _balance("USD", 640, 12800)],
                "HKD": [_balance("HKD", 10000, 200000)]}
    sdk = FakeSDK(balances=balances)
    snapshot = _adapter(sdk).fetch_snapshot()

    assert snapshot["account_cash"] == {"Longbridge · 10001": {"total": 10000.0, "netLiquidation": 200000.0, "currencyCode": "HKD"}}
    assert [call for call in sdk.calls if call[0] == "account_balance"] == [("account_balance", None), ("account_balance", "HKD")]
    assert snapshot["warnings"] == []


def test_longbridge_uses_account_id_only_when_member_id_is_missing():
    assert next(iter(_adapter(FakeSDK(), account_id="demo-account").fetch_snapshot()["account_info"])) == "Longbridge · 10001"
    snapshot = _adapter(FakeSDK(member_id=0), account_id="demo-account").fetch_snapshot()
    assert snapshot["account_info"]["Longbridge · demo-account"]["id"] == "demo-account"
    with pytest.raises(LongbridgeError, match="账户 ID") as error:
        _adapter(FakeSDK(member_id=None)).fetch_snapshot()
    assert error.value.reason == "account_id"


def test_longbridge_missing_quote_marks_snapshot_incomplete():
    snapshot = _adapter(FakeSDK(quotes={"AAPL.US": (200, 198), "700.HK": (320, 310)})).fetch_snapshot()
    assert snapshot["positions"][2]["current_price"] is None
    assert snapshot["warnings"] == ["长桥未返回 9988.HK 的行情。"]


def test_longbridge_test_connection_reports_identity_and_raises_on_failure():
    assert _adapter(FakeSDK()).test_connection() == {
        "ok": True, "provider": "longbridge", "message": "长桥 OpenAPI 已连接。", "accounts": ["10001"]}
    sdk = FakeSDK(fail=("account_balance", FakeOpenApiException(401003, "token expired")))
    with pytest.raises(LongbridgeError) as error:
        _adapter(sdk).test_connection()
    assert error.value.reason == "token"
    assert str(error.value) == MESSAGES["token"]
    assert "demo-trace-id" not in str(error.value)


@pytest.mark.parametrize("exception, reason", [
    (FakeOpenApiException(401003, "token expired"), "token"),
    (FakeOpenApiException(401004, "token invalid"), "token"),
    (FakeOpenApiException(403201, "signature invalid"), "token"),
    (FakeOpenApiException(403208, "token and api key is not match"), "token"),
    (FakeOpenApiException(403205, "ip is not allowed"), "permission"),
    (FakeOpenApiException(None, "error sending request for url (https://openapi.example/v1/asset/stock): client error (Connect)"), "network"),
    (ConnectionRefusedError(61, "Connection refused"), "network"),
    (TimeoutError(), "network"),
    (FakeOpenApiException(403202, "duplicate request"), None),
    (FakeOpenApiException(429002, "api request is limited"), None),
])
def test_longbridge_sdk_errors_map_to_safe_reasons(exception, reason):
    with pytest.raises(LongbridgeError) as error:
        _adapter(FakeSDK(fail=("stock_positions", exception))).fetch_snapshot()
    assert error.value.reason == reason
    assert str(error.value) == MESSAGES[reason]


def test_longbridge_missing_sdk_has_install_hint(monkeypatch):
    monkeypatch.setitem(sys.modules, "longbridge", None)  # makes the import fail
    with pytest.raises(LongbridgeError) as error:
        LongbridgeAdapter(LongbridgeConfig(**CREDENTIALS)).fetch_snapshot()
    assert error.value.reason == "sdk"
    assert "pip install -r requirements-longbridge.txt" in str(error.value)


def test_longbridge_config_requires_credentials_and_hides_them():
    assert "demo-" not in repr(LongbridgeConfig(**CREDENTIALS))
    with pytest.raises(ValueError, match="Access Token"):
        LongbridgeConfig(app_key="demo-app-key", app_secret="demo-app-secret", access_token=" ")


# Account flow: save connection → preview → confirm.

@pytest.fixture
def isolated(monkeypatch, tmp_path):
    monkeypatch.setattr(accounts, "STORE", tmp_path / "accounts.json")
    monkeypatch.setattr(accounts, "V2_DIR", tmp_path)
    monkeypatch.setattr(accounts, "_PREVIEWS", {})
    secrets = {}
    monkeypatch.setattr(accounts.data_store, "secret_value", lambda name: secrets.get(name))
    monkeypatch.setattr(accounts.data_store, "save_secret", lambda name, value: secrets.update({name: value}) is None)
    monkeypatch.setattr(accounts.data_store, "delete_secret", lambda name: secrets.pop(name, None) is not None)
    return secrets


def _use_sdk(monkeypatch, sdk):
    monkeypatch.setattr(accounts, "LongbridgeAdapter", lambda config: LongbridgeAdapter(config, sdk_module=sdk))


def _snapshot():
    return {"portfolio": {"summary": {}, "holdings": [], "holdings_by_account": []},
            "market": {"rows": []}, "broker": {}, "fundamentals": {}}


def test_longbridge_connection_validates_fields_and_keeps_secrets_out_of_registry(isolated):
    with pytest.raises(ValueError, match="请填写长桥"):
        accounts.save_connection(None, "Longbridge", "longbridge", {"app_key": "demo-app-key", "app_secret": "demo-app-secret"})
    with pytest.raises(ValueError, match="连接配置无效"):
        accounts.save_connection(None, "Longbridge", "longbridge", CREDENTIALS | {"password": "demo"})
    assert not accounts.STORE.exists()

    account = accounts.save_connection(None, "Longbridge", "longbridge", CREDENTIALS)
    stored = json.loads(isolated["CATFOLIO_ACCOUNT_" + account["id"]])
    assert stored == CREDENTIALS
    assert "demo-" not in accounts.STORE.read_text()
    # Editing with blank credential fields keeps the saved ones.
    accounts.save_connection(account["id"], "Longbridge HK", "longbridge", {"app_key": "", "access_token": " ", "account_id": "demo-account"})
    assert json.loads(isolated["CATFOLIO_ACCOUNT_" + account["id"]]) == CREDENTIALS | {"account_id": "demo-account"}


def test_longbridge_preview_and_confirm_sync_hk_holdings(isolated, monkeypatch):
    from app.brokers.service import SUPPORTED_BROKERS
    from app.data_store import FX_TO_USD
    _use_sdk(monkeypatch, FakeSDK())
    account = accounts.save_connection(None, "Longbridge", "longbridge", CREDENTIALS)
    before = accounts.STORE.read_bytes()

    preview = accounts.preview(account["id"])
    assert [p["ticker"] for p in preview["positions"]] == ["AAPL", "0700.HK", "9988.HK"]
    assert preview["source_account"] == "Longbridge · 10001"
    assert preview["currency"] == "HKD"
    assert accounts.STORE.read_bytes() == before
    assert not accounts.apply_accounts(_snapshot())["portfolio"]["holdings"]

    accounts.commit(account["id"], preview["token"])
    merged = accounts.apply_accounts(_snapshot())
    holdings = {row["ticker"]: row for row in merged["portfolio"]["holdings"]}
    assert holdings["0700.HK"]["yahoo_symbol"] == "0700.HK"
    assert holdings["0700.HK"]["shares"] == 100
    assert holdings["0700.HK"]["cost_usd_standard"] == pytest.approx(100 * 300 * FX_TO_USD["HKD"])
    assert holdings["0700.HK"]["last_trade_time"] == "Longbridge API snapshot"  # not "CSV"
    assert {row["ticker"]: row["quote_price"] for row in merged["market"]["rows"]}["0700.HK"] == 320
    assert merged["broker"]["account_cash"] == {"Longbridge": {"total": 5000.0, "netLiquidation": 100000.0, "currencyCode": "HKD"}}
    assert json.loads(accounts.STORE.read_text())["accounts"][account["id"]]["identity"] == "longbridge:10001"
    assert "longbridge" not in SUPPORTED_BROKERS  # the legacy single-broker flow is unchanged


@pytest.mark.parametrize("exception, reason", [
    (FakeOpenApiException(401003, "token expired for demo-access-token"), "token"),
    (FakeOpenApiException(403205, "ip is not allowed"), "permission"),
    (FakeOpenApiException(None, "error sending request for url (https://openapi.example/v1/asset/stock?demo-access-token)"), "network"),
])
def test_longbridge_preview_errors_are_specific_without_leaking(isolated, monkeypatch, exception, reason):
    _use_sdk(monkeypatch, FakeSDK(fail=("stock_positions", exception)))
    account = accounts.save_connection(None, "Longbridge", "longbridge", CREDENTIALS)
    before = accounts.STORE.read_bytes()
    with pytest.raises(ValueError) as error:
        accounts.preview(account["id"])
    message = str(error.value)
    assert message == MESSAGES[reason]
    assert "demo-" not in message and "openapi.example" not in message
    assert accounts.STORE.read_bytes() == before


def test_longbridge_preview_asks_for_account_id_when_none_is_returned(isolated, monkeypatch):
    _use_sdk(monkeypatch, FakeSDK(member_id=0))
    account = accounts.save_connection(None, "Longbridge", "longbridge", CREDENTIALS)
    with pytest.raises(ValueError, match="请在连接配置中填写账户 ID"):
        accounts.preview(account["id"])
    accounts.save_connection(account["id"], "Longbridge", "longbridge", {"account_id": "demo-account"})
    assert accounts.preview(account["id"])["source_account"] == "Longbridge · demo-account"


def test_longbridge_account_api_saves_previews_and_syncs(isolated, monkeypatch):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from app.routes import accounts as routes
    monkeypatch.setattr(routes, "demo_mode", lambda: False)
    monkeypatch.setattr(routes, "public_demo_mode", lambda: False)
    _use_sdk(monkeypatch, FakeSDK())
    app = FastAPI()
    app.include_router(routes.router)
    with TestClient(app) as client:
        missing = client.post("/api/accounts/connection", json={"name": "Longbridge", "provider": "longbridge", "config": {"app_key": "demo-app-key"}})
        assert missing.status_code == 400
        assert missing.json()["detail"] == "请填写长桥 App Key、App Secret 和 Access Token。"
        account = client.post("/api/accounts/connection", json={"name": "Longbridge", "provider": "longbridge", "config": CREDENTIALS}).json()
        assert "demo-" not in json.dumps(account)
        preview = client.post(f"/api/accounts/{account['id']}/preview").json()
        assert [p["yahoo_symbol"] for p in preview["positions"]] == ["AAPL", "0700.HK", "9988.HK"]
        assert client.post(f"/api/accounts/{account['id']}/sync", json={"token": preview["token"]}).status_code == 200
        listed = client.get("/api/accounts").json()["accounts"][0]
        assert (listed["provider"], listed["positions"], listed["currency"]) == ("longbridge", 3, "HKD")


def test_longbridge_account_ui_has_english_for_every_new_phrase(isolated):
    from app.account_i18n import EN
    from app.account_ui import render_accounts
    from app.i18n import t_block
    html = render_accounts(False)
    assert '<option value="longbridge">Longbridge 长桥</option>' in html
    assert '<option value="longbridge">Longbridge</option>' in t_block(html, "en")

    script = (Path(__file__).parents[1] / "app" / "static" / "accounts.js").read_text(encoding="utf-8")
    assert "longbridge: 'Longbridge'" in script
    lines = [line for line in script.splitlines() if line.strip().startswith("longbridge:")]
    assert len(lines) == 2  # connection fields and hint
    phrases = {phrase for line in lines for phrase in re.findall(r"'([^']*[\u4e00-\u9fff][^']*)'", line)}
    assert len(phrases) == 6 and phrases <= set(EN)
    assert "status.textContent = tr(error.message)" in script  # server errors are translated too
    assert set(MESSAGES.values()) | {"请填写长桥 App Key、App Secret 和 Access Token。"} <= set(EN)
