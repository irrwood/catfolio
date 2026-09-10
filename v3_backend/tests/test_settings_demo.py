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
    assert 'class="settings-nav"' in html
    assert '/static/settings.css' in html
    assert 'class="grid-2"' not in html


def test_settings_secondary_nav_stacks_before_the_layout_gets_cramped():
    from pathlib import Path

    css = (Path(__file__).parents[1] / "app" / "static" / "settings.css").read_text(encoding="utf-8")
    responsive = css[css.index("@media (max-width: 1100px)") :]

    assert "grid-template-columns: 1fr;" in responsive
    assert ".page-settings .settings-page-header {\n    margin-left: 0;" in responsive
    assert "flex-direction: row;" in responsive


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
        lambda name: "configured" if name in {"TRADING212_API_KEY", "TRADING212_API_KEY_2"} else None,
    )

    html = settings_route.settings_page(_request()).body.decode("utf-8")

    assert 'id="input_TRADING212_API_KEY"' in html
    assert 'id="input_TRADING212_API_KEY_2"' in html
    assert "Trading 212 API Key 1" in html
    assert "Trading 212 API Key 2" in html
    assert "TRADING212_API_KEY_2" in settings_route._ALLOWED_KEYS
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
        "TRADING212_API_KEY_2": "secondary-key",
    }

    def build_and_write():
        captured.update(
            accounts=os.environ.get("TRADING212_ACCOUNTS"),
            primary=os.environ.get("TRADING212_API_KEY"),
            secondary=os.environ.get("TRADING212_API_KEY_2"),
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
        "secondary": "secondary-key",
    }


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


def test_sidebar_shows_demo_badge(monkeypatch):
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
    assert "/static/icons/catfolio-icon-dark.png" in html
    assert "/static/icons/catfolio-icon-light.png" in html
    assert "/static/icons/realcat-dark.svg" not in html


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
