"""The per-symbol refresh loops fan out instead of paying one round trip at a time.

These guard the two properties that make the fan-out safe to ship: results stay
in input order (so cache rows and warnings are reproducible), and the aggregate
request rate never exceeds the throttle the serial loops used to spend between
consecutive calls.
"""

import json
import threading
import time


def test_parallel_map_preserves_input_order_regardless_of_completion_order():
    from app import data_store

    def worker(item):
        time.sleep(0.02 if item % 2 else 0.001)  # odd items finish last
        return item * 10

    result = data_store._parallel_map(range(8), worker, max_workers=8)

    assert result == [0, 10, 20, 30, 40, 50, 60, 70]


def test_parallel_map_overlaps_latency_instead_of_accumulating_it():
    from app import data_store

    started = time.perf_counter()
    data_store._parallel_map(range(8), lambda _: time.sleep(0.05), max_workers=8)
    elapsed = time.perf_counter() - started

    # Serial would be 8 x 50 ms = 400 ms.
    assert elapsed < 0.2, f"expected overlapped latency, took {elapsed:.3f}s"


def test_parallel_map_caps_the_aggregate_request_rate():
    from app import data_store

    stamps = []
    lock = threading.Lock()

    def worker(_):
        with lock:
            stamps.append(time.monotonic())

    data_store._parallel_map(range(10), worker, max_workers=10, min_interval=0.02)

    # Ten calls at one per 20 ms cannot finish faster than ~180 ms no matter how
    # many workers are free, so the pool never outpaces the old serial throttle.
    assert max(stamps) - min(stamps) >= 0.15


def test_parallel_map_handles_empty_and_single_item_inputs():
    from app import data_store

    assert data_store._parallel_map([], lambda x: x, max_workers=4) == []
    assert data_store._parallel_map(["only"], str.upper, max_workers=4) == ["ONLY"]


def test_market_refresh_fans_out_and_keeps_warnings_in_symbol_order(monkeypatch, tmp_path):
    from app import data_store

    live = tmp_path / "live_market_data.json"
    pipeline_dir = tmp_path / "portfolio_analysis_v2"
    pipeline_dir.mkdir()
    (pipeline_dir / "portfolio_analysis.json").write_text(json.dumps({
        "holdings": [
            {"ticker": t, "yahoo_symbol": t, "shares": 1,
             "cost_usd_standard": 100, "cost_currency": "USD"}
            for t in ("AAA", "BBB", "CCC", "DDD")
        ],
    }), encoding="utf-8")

    peak = {"current": 0, "max": 0}
    lock = threading.Lock()

    def fake_chart(symbol):
        with lock:
            peak["current"] += 1
            peak["max"] = max(peak["max"], peak["current"])
        time.sleep(0.05)
        with lock:
            peak["current"] -= 1
        if symbol == "BBB":
            raise RuntimeError("boom")
        if symbol == "CCC":
            return {}
        return {"regularMarketPrice": 10, "regularMarketCurrency": "USD"}

    monkeypatch.setattr(data_store, "LIVE_MARKET_CACHE", live)
    monkeypatch.setattr(data_store, "V2_DIR", pipeline_dir)
    monkeypatch.setattr(data_store, "fetch_yahoo_chart", fake_chart)

    result = data_store.refresh_market_quotes(force=True)

    assert peak["max"] > 1, "quote fetches should overlap"
    # Warnings follow sorted symbol order, not whichever request failed first.
    warnings = result["market"]["warnings"]
    assert len(warnings) == 2
    assert warnings[0] == "Yahoo chart failed BBB: RuntimeError boom"
    assert warnings[1] == "Yahoo chart empty: CCC"
    prices = {row["ticker"]: row["quote_price"] for row in result["market"]["rows"]}
    assert prices["AAA"] == 10 and prices["DDD"] == 10
    assert prices["BBB"] is None and prices["CCC"] is None


def test_fmp_snapshot_fetches_the_four_endpoints_concurrently(monkeypatch):
    from app import data_store

    seen = []
    lock = threading.Lock()

    def fake(endpoint, symbol, token, params=None):
        time.sleep(0.05)
        with lock:
            seen.append(endpoint)
        return {"endpoint": endpoint}

    monkeypatch.setattr(data_store, "_fmp_stable_json", fake)

    started = time.perf_counter()
    ratios, metrics, growth, profile = data_store._fmp_snapshot("AAPL", "token")
    elapsed = time.perf_counter() - started

    assert elapsed < 0.15, f"four endpoints should overlap, took {elapsed:.3f}s"
    assert sorted(seen) == ["income-statement-growth", "key-metrics-ttm", "profile", "ratios-ttm"]
    # Order of the returned tuple is positional and must not follow completion.
    assert ratios["endpoint"] == "ratios-ttm"
    assert metrics["endpoint"] == "key-metrics-ttm"
    assert growth["endpoint"] == "income-statement-growth"
    assert profile["endpoint"] == "profile"


def test_fmp_snapshot_still_raises_so_the_caller_tries_the_next_candidate(monkeypatch):
    from app import data_store

    def fake(endpoint, symbol, token, params=None):
        if endpoint == "profile":
            raise ValueError("404")
        return {}

    monkeypatch.setattr(data_store, "_fmp_stable_json", fake)

    try:
        data_store._fmp_snapshot("NOPE", "token")
    except ValueError as exc:
        assert "404" in str(exc)
    else:
        raise AssertionError("expected the candidate failure to propagate")
