import json

from app import alert_rules


def test_preview_ai_reminders_extracts_concentration_rules():
    text = (
        "当前组合前5持仓占76.1%，科技暴露40.6%，与QQQ相关性0.876、beta 0.9，"
        "最大回撤-14%。单票权重超20%或科技板块波动率持续高于17%时评估。"
    )

    drafts = alert_rules.preview_ai_reminders(text)

    metrics = {condition["metric"] for draft in drafts for condition in draft["conditions"]}
    assert "top_n_weight" in metrics
    assert "sector_exposure" in metrics
    assert "portfolio_qqq_correlation" in metrics
    assert "portfolio_beta" in metrics
    assert "max_drawdown" in metrics
    assert "single_holding_weight" in metrics


def test_create_list_delete_rules(tmp_path, monkeypatch):
    path = tmp_path / "rules.json"
    monkeypatch.setattr(alert_rules, "_rules_path", lambda: path)

    draft = alert_rules.preview_ai_reminders("单票权重超20%")[0]
    created = alert_rules.create_rule(draft)

    assert created["id"].startswith("ai_")
    assert alert_rules.list_rules()[0]["id"] == created["id"]

    assert alert_rules.delete_rule(created["id"]) is True
    assert alert_rules.list_rules() == []
    assert json.loads(path.read_text()) == []


def test_evaluate_rules_triggers_top_weight(monkeypatch, tmp_path):
    path = tmp_path / "rules.json"
    monkeypatch.setattr(alert_rules, "_rules_path", lambda: path)
    alert_rules.create_rule({
        "title": "Top 5 concentration",
        "conditions": [{"metric": "top_n_weight", "operator": ">", "value": 0.75, "n": 5, "label": "前 5 持仓超过 75%"}],
        "message": "集中风险上升",
    })

    snapshot = {}
    monkeypatch.setattr(alert_rules, "_holding_rows", lambda snap: [
        {"ticker": "A", "weight": 0.30, "sector": "Technology"},
        {"ticker": "B", "weight": 0.20, "sector": "Technology"},
        {"ticker": "C", "weight": 0.15, "sector": "Communication Services"},
        {"ticker": "D", "weight": 0.08, "sector": "Consumer Cyclical"},
        {"ticker": "E", "weight": 0.06, "sector": "Financial Services"},
    ])

    alerts = alert_rules.evaluate_rules(snapshot)

    assert len(alerts) == 1
    assert alerts[0]["type"] == "ai_rule"
    assert "集中风险上升" in alerts[0]["message"]
