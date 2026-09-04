from pathlib import Path

from starlette.requests import Request


ROOT = Path(__file__).resolve().parents[1]


def _request(path="/lab/component-demo"):
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": path,
            "headers": [],
            "query_string": b"",
        }
    )


def test_component_demo_is_an_isolated_four_slide_product_page():
    from app.routes import lab

    response = lab.component_demo_page(_request())
    html = response.body.decode("utf-8")

    assert response.status_code == 200
    assert html.count('class="component-demo-slide') == 4
    assert 'id="costValueChart"' in html
    assert 'id="profitCalendarGrid"' in html
    assert 'id="drawdownChart"' in html
    assert 'id="portfolioHoldingsRows"' in html
    assert 'id="componentDemoPrev"' in html
    assert 'id="componentDemoNext"' in html
    assert '<body class="component-demo-page page-lab">' in html
    assert "<aside" not in html
    assert "v5-nav" not in html
    assert "component-demo-page-head" not in html
    assert "/static/component-demo.css" in html
    assert "/static/component-demo.js" in html
    assert "/static/vendor/echarts.min.js" in html
    assert "/static/portfolio.js" in html
    assert "/static/portfolio-calendar.js" in html
    assert "/static/portfolio-holdings.js" in html
    assert "/static/analysis_charts.js" in html


def test_component_demo_uses_local_fake_data_and_no_financial_api_fetches():
    script = (ROOT / "app" / "static" / "component-demo.js").read_text(encoding="utf-8")

    assert "fakeDirectHoldings" in script
    assert '"/api/portfolio/chart"' in script
    assert '"/api/analytics"' in script
    assert "window.__CATFOLIO_COMPONENT_DEMO__ = true" in script
    assert 'document.addEventListener("keydown"' in script
    assert "showSlide(current - 1" in script
    assert "showSlide(current + 1" in script
    assert "window.fetch =" in script


def test_component_demo_follows_figma_tokens_and_accessibility_contracts():
    styles = (ROOT / "app" / "static" / "component-demo.css").read_text(encoding="utf-8")
    route = (ROOT / "app" / "routes" / "lab.py").read_text(encoding="utf-8")

    assert "portfolio.css" in route
    assert "border-radius: 20px;" in styles
    assert "background: var(--panel);" in styles
    assert "outline: 2px solid #708cff;" in styles
    assert "@media (prefers-reduced-motion: reduce)" in styles
    assert 'aria-roledescription="carousel"' in route
    assert 'aria-live="polite"' in route
    assert 'aria-hidden="true" inert' in route
    assert "portfolio.css" in route
    assert "analysis_charts.css" in route


def test_component_demo_route_is_registered():
    from app.main import app
    from conftest import app_route_paths

    assert "/lab/component-demo" in app_route_paths(app)
