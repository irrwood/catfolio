import re

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def public_demo_client(monkeypatch, tmp_path):
    """Exercise the real ASGI stack while guaranteeing an offline Demo source."""
    from app import data_store
    from app.cache import clear_all
    from app.main import app

    monkeypatch.setenv("CATFOLIO_PUBLIC_DEMO", "1")
    monkeypatch.setattr(data_store, "_DEMO_FLAG", tmp_path / "demo_mode.flag")
    clear_all()
    with TestClient(app) as client:
        yield client
    clear_all()


@pytest.mark.parametrize(
    "path",
    [
        "/lab",
        "/returns",
        "/analytics",
        "/strategy",
        "/heatmap",
        "/ai",
        "/bank",
        "/import",
        "/settings",
    ],
)
def test_public_demo_pages_use_the_shared_shell(public_demo_client, path):
    response = public_demo_client.get(path)

    assert response.status_code == 200
    assert response.headers["x-catfolio-demo"] == "public-read-only"
    assert response.text.count('id="v5Sidebar"') == 1
    assert re.search(r'/static/design-system\.css\?v=[0-9a-f]{12}', response.text)
    assert re.search(r'/static/icons/realcat(?:-dark)?\.svg\?v=[0-9a-f]{12}', response.text)
    assert "/static/icons/catfolio-icon-" not in response.text


def test_portfolio_page_and_apis_reconcile_to_one_snapshot(public_demo_client):
    page = public_demo_client.get("/lab")
    overview = public_demo_client.get("/api/portfolio/overview").json()
    chart = public_demo_client.get("/api/portfolio/chart").json()

    rows = chart["position_history"]["rows"]
    summary = overview["summary"]
    current = chart["current_point"]

    assert 'id="costValueChart"' in page.text
    assert chart["position_count"] == summary["open_positions"]
    assert rows[-1]["date"] == current["date"]
    assert rows[-1]["market_value_usd"] == pytest.approx(current["market_value_usd"])
    assert rows[-1]["cost_usd"] == pytest.approx(current["cost_usd"])
    assert current["market_value_usd"] == pytest.approx(summary["market_value_usd"])
    assert current["cost_usd"] == pytest.approx(summary["total_cost_usd_standard"])
    assert current["market_value_usd"] > current["cost_usd"] > 0


def test_public_demo_volume_profile_is_available_without_private_data(public_demo_client):
    response = public_demo_client.get("/api/holdings/NVDA/volume-profile")

    assert response.status_code == 200
    profile = response.json()
    assert profile["available"] is True
    assert profile["ticker"] == "NVDA"
    assert profile["currency"] == "USD"
    assert profile["val"] <= profile["poc"] <= profile["vah"]
    assert profile["sessions"] == 120

    assert public_demo_client.get("/api/holdings/NOT-HELD/volume-profile").status_code == 404


def test_public_demo_never_reads_private_files_or_accepts_mutations(
    public_demo_client, monkeypatch
):
    from app import data_store
    from app.routes import settings as settings_route

    def private_read(*_args, **_kwargs):
        raise AssertionError("public Demo attempted to read private local state")

    monkeypatch.setattr(data_store, "load_json", private_read)
    monkeypatch.setattr(settings_route, "load_json", private_read)
    monkeypatch.setattr(settings_route, "secret_value", private_read)

    assert public_demo_client.get("/api/portfolio/overview").status_code == 200
    settings = public_demo_client.get("/settings")
    assert settings.status_code == 200
    assert "/Users/" not in settings.text

    for method, path in (
        ("post", "/api/refresh/market"),
        ("post", "/api/settings/save-key"),
        ("delete", "/api/bank/items/example"),
    ):
        response = public_demo_client.request(method.upper(), path, json={})
        assert response.status_code == 403
        assert response.json()["error"] == "This public Catfolio demo is read-only."


def test_fingerprinted_assets_are_immutable_and_plain_assets_revalidate(
    public_demo_client,
):
    page = public_demo_client.get("/lab")
    match = re.search(r'src="(/static/portfolio\.js\?v=[0-9a-f]{12})"', page.text)
    assert match

    fingerprinted = public_demo_client.get(match.group(1))
    unversioned = public_demo_client.get("/static/portfolio.js")

    assert fingerprinted.status_code == 200
    assert fingerprinted.headers["cache-control"] == "public, max-age=31536000, immutable"
    assert unversioned.status_code == 200
    assert unversioned.headers["cache-control"] == "no-cache"
