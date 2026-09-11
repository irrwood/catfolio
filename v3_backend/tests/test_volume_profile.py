import pytest


def _bars(prices, volume=1_000):
    return [
        {
            "date": f"2026-01-{index + 1:02d}",
            "low": price - 0.4,
            "high": price + 0.4,
            "close": price,
            "volume": volume if not isinstance(volume, list) else volume[index],
        }
        for index, price in enumerate(prices)
    ]


def test_volume_profile_finds_the_high_volume_price_area():
    from app.lab import calculate_volume_profile

    prices = [100.0] * 30 + [110.0] * 30 + [120.0] * 30
    volumes = [1_000] * 30 + [12_000] * 30 + [1_000] * 30

    profile = calculate_volume_profile(_bars(prices, volumes), bins=30, lookback=120)

    assert profile["available"] is True
    assert profile["val"] <= profile["poc"] <= profile["vah"]
    assert profile["poc"] == pytest.approx(110.0, abs=0.8)
    assert profile["sessions"] == 90
    assert profile["value_area_percent"] == 70
    assert profile["method"] == "daily_ohlcv_uniform_price_bins"


def test_volume_profile_rejects_sparse_or_invalid_volume():
    from app.lab import calculate_volume_profile

    rows = _bars([100.0] * 18)
    rows.extend([
        {"date": "2026-02-01", "low": 99, "high": 101, "volume": 0},
        {"date": "2026-02-02", "low": None, "high": 101, "volume": 500},
    ])

    profile = calculate_volume_profile(rows)

    assert profile == {
        "available": False,
        "reason": "insufficient_ohlcv_history",
        "sessions": 18,
    }


def test_demo_holding_volume_profile_is_offline(monkeypatch):
    from app import lab
    from app.cache import clear_all
    from app.demo_data import DEMO_SNAPSHOT

    clear_all()
    monkeypatch.setattr(lab, "demo_mode", lambda: True)
    monkeypatch.setattr(lab, "current_snapshot", lambda: DEMO_SNAPSHOT)
    monkeypatch.setattr(
        lab,
        "fetch_history",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("Demo must stay offline")),
    )

    profile = lab.holding_volume_profile("NVDA")

    assert profile["available"] is True
    assert profile["ticker"] == "NVDA"
    assert profile["symbol"] == "NVDA"
    assert profile["currency"] == "USD"
    assert profile["val"] <= profile["poc"] <= profile["vah"]
    assert profile["sessions"] == 120


def test_holding_volume_profile_does_not_proxy_unknown_symbols(monkeypatch):
    from app import lab
    from app.cache import clear_all

    clear_all()
    monkeypatch.setattr(lab, "current_snapshot", lambda: {"portfolio": {"holdings": []}})
    monkeypatch.setattr(
        lab,
        "fetch_history",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("must not fetch unknown symbols")),
    )

    assert lab.holding_volume_profile("NOT-A-HOLDING") is None


def test_homepage_volume_profile_matches_figma_contract():
    from pathlib import Path

    root = Path(__file__).resolve().parents[1]
    script = (root / "app/static/portfolio-holdings.js").read_text(encoding="utf-8")
    css = (root / "app/static/portfolio.css").read_text(encoding="utf-8")

    assert "/api/holdings/${encodeURIComponent(ticker)}/volume-profile" in script
    assert 'row.addEventListener("pointerenter"' in script
    assert 'row.addEventListener("pointerleave"' in script
    assert 'profileTitle: "成交量分布"' in script
    assert 'profileVah: "VAH 上沿"' in script
    assert 'profilePoc: "POC 峰值"' in script
    assert 'profileCost: "持仓成本"' in script
    assert 'profileVal: "VAL 下沿"' in script
    assert "label: copy.profileCost" in script
    assert 'data-volume-profile-cost-price=' in script
    assert 'data-volume-profile-cost-currency=' in script
    assert "return right.value - left.value || left.rank - right.rank;" in script
    assert 'volumeProfileMarker(numericCost, profile, "cost")' in script
    assert 'volumeProfileMarker(profile.poc, profile, "poc")' in script
    assert ".portfolio-volume-profile-popover" in css
    assert "width: clamp(156px, 14vw, 184px);" in css
    assert "font-size: clamp(11px, 1vw, 12px);" in css
    assert "border-radius: 8px" in css
    assert "box-shadow: 0 10px 8.45px" in css
    assert ".portfolio-volume-profile-rail" in css
    assert "--profile-rail-height: clamp(82px, 7vw, 92px);" in css
    assert "width: 12px;" in css
    assert "height: var(--profile-rail-height);" in css
    assert ".portfolio-volume-profile-marker.is-cost { background: #708cff; }" in css
    assert ".portfolio-volume-profile-row.is-cost { color: #405fdd; }" in css
