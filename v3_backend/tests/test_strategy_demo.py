def test_demo_strategy_has_preloaded_chart_data(monkeypatch):
    from app import lab
    from app.cache import clear_all
    from app.demo_data import DEMO_SNAPSHOT
    from app.routes import strategy

    clear_all()
    monkeypatch.setattr(lab, "demo_mode", lambda: True)
    monkeypatch.setattr(lab, "current_snapshot", lambda: DEMO_SNAPSHOT)

    run = strategy._demo_run()

    assert run["id"] == 1
    assert len(run["result"]["equity"]) > 1000
    assert len(run["result"]["drawdown"]) == len(run["result"]["equity"])
    assert run["result"]["trades"]
    assert run["ai_eval"]


def test_strategy_page_injects_templates_and_demo_boot(monkeypatch):
    from starlette.requests import Request
    from app.routes import strategy

    monkeypatch.setattr(strategy, "demo_mode", lambda: True)
    request = Request({"type": "http", "method": "GET", "path": "/strategy", "headers": [], "query_string": b""})
    response = strategy.strategy_page(request)
    body = response.body.decode("utf-8")

    assert response.status_code == 200
    assert "window.STRATEGY_TEMPLATES" in body
    assert "window.CATFOLIO_DEMO = true" in body
    assert 'id="aiEvalBtn"' in body
    assert 'class="ai-action-icon"' in body
