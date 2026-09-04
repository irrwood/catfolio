from copy import deepcopy

from app import ai
from app.demo_data import DEMO_LAB_HISTORY, DEMO_SNAPSHOT
from app.portfolio_attention import enforce_confidence, scan_portfolio


def test_signal_engine_scans_every_holding_and_uses_fixed_thresholds():
    result = scan_portfolio(DEMO_SNAPSHOT, DEMO_LAB_HISTORY)

    assert result["holdings_count"] == len(DEMO_SNAPSHOT["portfolio"]["holdings"])
    assert result["thresholds"] == {
        "return_60d_percent": 10,
        "volume_multiple": 2,
        "distance_from_52w_extreme_percent": 3,
        "today_move_percent": 5,
    }
    assert result["data_coverage"]["history"] == result["holdings_count"]
    assert all(row["return_60d_percent"] is not None for row in result["rows"])
    assert all(row["ma_200"] is not None for row in result["rows"])


def test_two_material_signals_produce_high_attention_without_model_judgment():
    snapshot = deepcopy(DEMO_SNAPSHOT)
    aapl = next(row for row in snapshot["market"]["rows"] if row["ticker"] == "AAPL")
    aapl["volume"] = aapl["avg_volume_3m"] * 3
    aapl["high_52w"] = aapl["quote_price"]

    result = scan_portfolio(snapshot, DEMO_LAB_HISTORY)
    row = next(row for row in result["rows"] if row["ticker"] == "AAPL")

    assert row["attention"] == "high"
    assert {signal["kind"] for signal in row["signals"]} >= {
        "price_60d",
        "volume_spike",
        "near_52w_high",
    }


def test_high_confidence_requires_confirmed_catalyst_reliable_source_and_counter_evidence():
    thesis = {
        "company_specific_catalyst": True,
        "catalyst_confirmed": True,
        "catalyst_is_recent": True,
        "counter_evidence": ["Margins remain demanding"],
        "severe_unresolved_risk": False,
        "evidence_source_ids": ["nvda-1"],
    }
    source = {"nvda-1": {"tier": "wire", "age_days": 2}}
    assert enforce_confidence(thesis, source) == "high"
    assert enforce_confidence({**thesis, "counter_evidence": []}, source) == "medium"
    assert enforce_confidence(thesis, {"nvda-1": {"tier": "wire", "age_days": 120}}) == "medium"
    assert enforce_confidence({**thesis, "evidence_source_ids": []}, {}) == "medium"


def test_demo_attention_pipeline_returns_structured_low_confidence_theses(monkeypatch):
    monkeypatch.setattr(ai, "current_snapshot", lambda: DEMO_SNAPSHOT)
    monkeypatch.setattr(ai, "get_history", lambda: DEMO_LAB_HISTORY)
    monkeypatch.setattr(ai, "demo_mode", lambda: True)

    result = ai.portfolio_attention("zh")

    assert result["research_status"] == "demo"
    assert result["attention_rows"]
    assert all(row["thesis"]["confidence"] == "low" for row in result["attention_rows"])
    assert all("what_changed" in row["thesis"] for row in result["attention_rows"])


def test_attention_preset_and_follow_up_context_are_wired_into_ai_ui():
    script = (ai.ROOT / "v3_backend" / "app" / "static" / "ai.js").read_text(encoding="utf-8")
    route = (ai.ROOT / "v3_backend" / "app" / "routes" / "api.py").read_text(encoding="utf-8")

    assert "今天哪些持仓值得我关注？" in script
    assert 'aiPost("/api/ai/portfolio-attention")' in script
    assert "context: lastAttentionContext" in script
    assert '@router.post("/ai/portfolio-attention")' in route
