from pathlib import Path

from starlette.requests import Request


def _request(path="/report"):
    return Request({"type": "http", "method": "GET", "path": path, "headers": []})


def test_demo_report_does_not_read_generated_private_report(monkeypatch, tmp_path):
    from app.cache import clear_all
    from app.routes import report as report_route

    private_report = tmp_path / "portfolio_cost_basis_v2.html"
    private_report.write_text(
        "<html><body><section>PRIVATE_REAL_ACCOUNT_TICKER</section></body></html>",
        encoding="utf-8",
    )

    monkeypatch.setenv("CATFOLIO_DEMO", "1")
    monkeypatch.setattr(report_route, "V2_HTML", Path(private_report))
    clear_all()

    response = report_route.report(_request())
    html = response.body.decode("utf-8")

    assert "PRIVATE_REAL_ACCOUNT_TICKER" not in html
    assert "Catfolio" in html
    assert "Demo mode is using Catfolio's built-in sample portfolio" in html
    assert "AAPL" in html
