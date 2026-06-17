from starlette.requests import Request


def _request(path="/settings"):
    return Request({"type": "http", "method": "GET", "path": path, "headers": []})


def test_demo_settings_hides_credentials_and_local_path(monkeypatch):
    from app.cache import clear_all
    from app.routes import settings as settings_route

    monkeypatch.setenv("CATFOLIO_DEMO", "1")
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
