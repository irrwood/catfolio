from starlette.requests import Request


def _request(path="/settings"):
    return Request({"type": "http", "method": "GET", "path": path, "headers": [], "query_string": b""})


def test_demo_settings_hides_credentials_and_local_path(monkeypatch, tmp_path):
    from app import data_store
    from app.cache import clear_all
    from app.routes import settings as settings_route

    monkeypatch.setenv("CATFOLIO_DEMO", "1")
    monkeypatch.setattr(data_store, "_DEMO_FLAG", tmp_path / "demo_mode.flag")
    monkeypatch.setattr(
        settings_route,
        "secret_value",
        lambda name: (_ for _ in ()).throw(AssertionError(f"secret read in demo mode: {name}")),
    )
    monkeypatch.setattr(
        settings_route,
        "load_json",
        lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("local cache read in demo mode")),
    )
    for name in (
        "live_cache_age_seconds",
        "history_cache_age_seconds",
        "fundamentals_cache_age_seconds",
        "after_hours_cache_age_seconds",
    ):
        monkeypatch.setattr(
            settings_route,
            name,
            lambda: (_ for _ in ()).throw(AssertionError("local cache age read in demo mode")),
        )
    clear_all()

    response = settings_route.settings_page(_request())
    html = response.body.decode("utf-8")

    hidden_terms = [
        "Trading 212 API Key",
        "FMP API Key",
        "FINNHUB_API_KEY",
        "DEEPSEEK_API_KEY",
        "OPENAI_API_KEY",
        "TELEGRAM_BOT_TOKEN",
        "Bot Token",
        "/Users/",
    ]
    for term in hidden_terms:
        assert term not in html

    assert "演示数据模式" in html or "Demo" in html
    assert 'class="settings-page"' in html
    assert 'class="settings-layout"' in html
    assert 'class="settings-nav-rail"' in html
    assert 'class="settings-nav"' in html
    assert '/static/settings.css' in html
    assert 'class="grid-2"' not in html
    assert "triggerRefresh('all')" not in html
    assert "triggerRefresh(" not in html
    assert "内置 Demo 快照" in html


def test_public_demo_settings_are_read_only(monkeypatch, tmp_path):
    from app import data_store
    from app.cache import clear_all
    from app.routes import settings as settings_route

    monkeypatch.setenv("CATFOLIO_PUBLIC_DEMO", "1")
    monkeypatch.setattr(data_store, "_DEMO_FLAG", tmp_path / "demo_mode.flag")
    clear_all()

    html = settings_route.settings_page(_request()).body.decode("utf-8")

    assert "公开 Demo · 只读" in html
    assert 'id="demoModeBtn"' in html
    assert "disabled" in html
    assert "toggleDemoMode()" not in html
    assert "triggerRefresh(" not in html


def test_settings_secondary_nav_stacks_before_the_layout_gets_cramped():
    from pathlib import Path

    css = (Path(__file__).parents[1] / "app" / "static" / "settings.css").read_text(encoding="utf-8")
    desktop = css[:css.index("@media (max-width: 1100px)")]
    responsive = css[css.index("@media (max-width: 1100px)") :]

    assert ".page-settings .settings-page {\n  display: grid;" in desktop
    assert "grid-template-columns: 176px minmax(0, 760px);" in desktop
    assert ".page-settings .settings-page-header {\n  grid-column: 2;\n  grid-row: 1;" in desktop
    assert ".page-settings .settings-nav-rail {\n  grid-column: 1;\n  grid-row: 1 / span 2;" in desktop
    assert ".page-settings .settings-nav {\n  position: sticky;\n  top: 20px;" in desktop
    assert ".page-settings .settings-layout {\n  display: contents;" in desktop
    assert ".page-settings .settings-page {\n    display: block;" in responsive
    assert "grid-template-columns: 1fr;" in responsive
    assert ".page-settings .settings-page-header {\n    margin-left: 0;" in responsive
    assert "flex-direction: row;" in responsive


def test_settings_refresh_all_uses_incremental_endpoints():
    from pathlib import Path

    script = (Path(__file__).parents[1] / "app" / "static" / "settings.js").read_text(encoding="utf-8")
    all_block = script[script.index("if (type === 'all')"):script.index("} else if (type === 'trading212')")]

    assert '"/api/refresh/market"' in all_block
    assert '"/api/lab/refresh-history"' in all_block
    assert '"/api/refresh/fundamentals"' in all_block
    assert "force=true" not in all_block
    assert 'fetch("/api/refresh/market?force=true"' in script


def test_settings_new_copy_has_complete_english_translations():
    from app.i18n import t_block

    source = "关闭假数据 FMP 估值数据 管理数据源、AI 提供方、缓存和本地服务。"
    translated = t_block(source, "en")

    assert "Turn Off Demo Data" in translated
    assert "FMP Valuation Data" in translated
    assert "Manage data sources" in translated
    assert "假数据" not in translated


def test_settings_exposes_two_trading212_key_slots(monkeypatch):
    from app.routes import settings as settings_route

    monkeypatch.setattr(settings_route, "demo_mode", lambda: False)
    monkeypatch.setattr(
        settings_route,
        "secret_value",
        lambda name: "configured" if name in {
            "TRADING212_API_KEY", "TRADING212_API_SECRET",
            "TRADING212_API_KEY_2", "TRADING212_API_SECRET_2",
        } else None,
    )

    html = settings_route.settings_page(_request()).body.decode("utf-8")

    assert 'id="input_TRADING212_API_KEY"' in html
    assert 'id="input_TRADING212_API_SECRET"' in html
    assert 'id="input_TRADING212_API_KEY_2"' in html
    assert 'id="input_TRADING212_API_SECRET_2"' in html
    assert "Trading 212 API Key 1" in html
    assert "Trading 212 API Secret 1" in html
    assert "Trading 212 API Key 2" in html
    assert "Trading 212 API Secret 2" in html
    assert "TRADING212_API_KEY_2" in settings_route._ALLOWED_KEYS
    assert "TRADING212_API_SECRET_2" in settings_route._ALLOWED_KEYS
    assert "triggerRefresh('all')" in html
    assert 'class="settings-credential-groups"' in html
    assert 'id="settingsCredentialBroker"' in html
    assert 'id="settingsCredentialMarket"' in html
    assert 'id="settingsCredentialAi"' in html
    assert html.index('id="settingsCredentialBroker"') < html.index('id="settingsCredentialMarket"') < html.index('id="settingsCredentialAi"')


def test_trading212_refresh_enables_and_merges_second_key(monkeypatch):
    import os
    import sys
    from types import SimpleNamespace
    from app import data_store

    captured = {}
    secrets = {
        "TRADING212_API_KEY": "primary-key",
        "TRADING212_API_SECRET": "primary-secret",
        "TRADING212_API_KEY_2": "secondary-key",
        "TRADING212_API_SECRET_2": "secondary-secret",
    }

    def build_and_write():
        captured.update(
            accounts=os.environ.get("TRADING212_ACCOUNTS"),
            primary=os.environ.get("TRADING212_API_KEY"),
            primary_secret=os.environ.get("TRADING212_API_SECRET"),
            secondary=os.environ.get("TRADING212_API_KEY_2"),
            secondary_secret=os.environ.get("TRADING212_API_SECRET_2"),
        )
        return {"ok": True, "positions": 2}

    for name in (*secrets, "TRADING212_API_SECRET", "TRADING212_API_SECRET_2", "TRADING212_ACCOUNTS"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(data_store, "secret_value", lambda name: secrets.get(name))
    monkeypatch.setitem(sys.modules, "build_trading212_v2", SimpleNamespace(build_and_write=build_and_write))

    result = data_store.refresh_trading212()

    assert result["ok"] is True
    assert captured == {
        "accounts": "default,2",
        "primary": "primary-key",
        "primary_secret": "primary-secret",
        "secondary": "secondary-key",
        "secondary_secret": "secondary-secret",
    }


def test_trading212_refresh_reports_preserved_failed_snapshot(monkeypatch):
    import sys
    from types import SimpleNamespace
    from app import data_store

    monkeypatch.setattr(data_store, "secret_value", lambda name: None)
    monkeypatch.setitem(
        sys.modules,
        "build_trading212_v2",
        SimpleNamespace(build_and_write=lambda: {
            "ok": False,
            "skipped": True,
            "holdings": 0,
            "error_code": "authorization_failed",
            "message": "Trading 212 authorization failed; existing data preserved.",
            "warnings": ["Trading212 API portfolio failed: HTTPError 401 Unauthorized"],
        }),
    )

    result = data_store.refresh_trading212()

    assert result["ok"] is False
    assert result["summary"]["error_code"] == "authorization_failed"
    assert "401" in result["summary"]["warnings"][0]


def test_trading212_api_turns_refresh_failure_into_http_error(monkeypatch):
    import pytest
    from fastapi import HTTPException
    from app.routes import api

    monkeypatch.setattr(
        api,
        "refresh_trading212",
        lambda: {
            "ok": False,
            "summary": {
                "error_code": "authorization_failed",
                "warnings": ["Trading212 API portfolio failed: HTTPError 401 Unauthorized"],
            },
        },
    )

    with pytest.raises(HTTPException) as exc:
        api.api_refresh_trading212()

    assert exc.value.status_code == 500
    assert exc.value.detail["summary"]["error_code"] == "authorization_failed"


def test_trading212_builder_preserves_existing_snapshot_on_auth_failure(monkeypatch, tmp_path):
    import sys

    scripts_dir = str((__import__("pathlib").Path(__file__).parents[2] / "scripts").resolve())
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
    import build_trading212_v2

    v2_dir = tmp_path / "portfolio_analysis_v2"
    v2_dir.mkdir()
    existing = v2_dir / "portfolio_analysis.json"
    original = '{"holdings": [' + ('{"ticker":"OLD"},' * 400) + '{}]}'
    existing.write_text(original, encoding="utf-8")
    monkeypatch.setattr(build_trading212_v2, "V2_DIR", v2_dir)
    monkeypatch.setattr(
        build_trading212_v2,
        "build_v2_data",
        lambda: {
            "portfolio": {"holdings": []},
            "trading212_data": {
                "warnings": ["Trading212 API portfolio failed: HTTPError 401 Unauthorized"],
            },
        },
    )

    result = build_trading212_v2.build_and_write()

    assert result["ok"] is False
    assert result["skipped"] is True
    assert result["error_code"] == "authorization_failed"
    assert existing.read_text(encoding="utf-8") == original


def test_trading212_builder_reports_position_diff(monkeypatch, tmp_path):
    import json
    import sys

    scripts_dir = str((__import__("pathlib").Path(__file__).parents[2] / "scripts").resolve())
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
    import build_trading212_v2

    v2_dir = tmp_path / "portfolio_analysis_v2"
    v2_dir.mkdir()
    (v2_dir / "portfolio_analysis.json").write_text(json.dumps({
        "holdings_by_account": [
            {"account": "A", "api_ticker": "KEEP", "shares": 1, "last_trade_price": 10},
            {"account": "A", "api_ticker": "CHANGE", "shares": 1, "last_trade_price": 10},
            {"account": "A", "api_ticker": "REMOVE", "shares": 1, "last_trade_price": 10},
        ],
    }), encoding="utf-8")
    monkeypatch.setattr(build_trading212_v2, "V2_DIR", v2_dir)
    monkeypatch.setattr(build_trading212_v2, "build_v2_data", lambda: {
        "portfolio": {
            "summary": {},
            "holdings": [{"ticker": "KEEP"}, {"ticker": "CHANGE"}, {"ticker": "ADD"}],
            "holdings_by_account": [
                {"account": "A", "api_ticker": "KEEP", "shares": 1, "last_trade_price": 10},
                {"account": "A", "api_ticker": "CHANGE", "shares": 1, "last_trade_price": 11},
                {"account": "A", "api_ticker": "ADD", "shares": 1, "last_trade_price": 10},
            ],
        },
        "market_data": {"rows": []},
        "trading212_data": {"positions": []},
    })

    result = build_trading212_v2.build_and_write()

    assert result["changes"] == {"added": 1, "updated": 1, "removed": 1, "unchanged": 1}


def test_demo_mode_runtime_override_can_disable_env_default(monkeypatch, tmp_path):
    from app import data_store
    from app.cache import clear_all

    monkeypatch.setenv("CATFOLIO_DEMO", "1")
    monkeypatch.setattr(data_store, "_DEMO_FLAG", tmp_path / "demo_mode.flag")
    clear_all()

    assert data_store.demo_mode() is True
    assert data_store.set_demo_mode(False) is True
    assert data_store.demo_mode() is False
    assert data_store.set_demo_mode(True) is True
    assert data_store.demo_mode() is True


def test_sidebar_shows_demo_badge_with_shared_realcat_icons(monkeypatch):
    from app import components

    monkeypatch.setattr(components, "demo_mode", lambda: True)
    monkeypatch.setattr(
        components,
        "current_snapshot",
        lambda: {
            "trading212": {},
            "market": {},
            "fundamentals": {},
        },
    )

    html = components.wrap_v4_layout("测试", "<p>body</p>", "/", "zh")

    assert "brand-demo-badge" in html
    assert "假数据" in html
    assert "/static/icons/realcat-dark.svg" in html
    assert "/static/icons/realcat.svg" in html
    assert "/static/icons/catfolio-icon-dark.png" not in html
    assert "/static/icons/catfolio-icon-light.png" not in html


def test_real_data_shells_use_theme_specific_realcat_icons(monkeypatch):
    from app import components

    monkeypatch.setattr(components, "demo_mode", lambda: False)
    monkeypatch.setattr(
        components,
        "current_snapshot",
        lambda: {
            "trading212": {},
            "market": {},
            "fundamentals": {},
        },
    )

    v4_html = components.wrap_v4_layout("测试", "<p>body</p>", "/", "zh")
    v5_html = components.wrap_v5_layout("测试", "<p>body</p>", "/lab", "zh")

    for html in (v4_html, v5_html):
        assert "/static/icons/realcat-dark.svg" in html
        assert "/static/icons/realcat.svg" in html
        assert "/static/icons/catfolio-icon-dark.png" not in html
        assert "/static/icons/catfolio-icon-light.png" not in html
