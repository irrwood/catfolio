from starlette.requests import Request


def _request(path="/report"):
    return Request({"type": "http", "method": "GET", "path": path, "headers": [], "query_string": b""})


def test_legacy_report_redirects_without_reading_private_files(monkeypatch):
    from app.routes import report as report_route

    monkeypatch.setattr(
        "pathlib.Path.read_text",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("legacy report file was read")),
    )

    response = report_route.report(_request())
    assert response.status_code == 307
    assert response.headers["location"] == "/lab"


def test_legacy_report_canonicalizes_v5_shell():
    from app.routes import report as report_route

    request = Request({"type": "http", "method": "GET", "path": "/report", "headers": [], "query_string": b"ui=v5"})
    response = report_route.report(request)
    assert response.status_code == 307
    assert response.headers["location"] == "/lab"


def test_legacy_report_preserves_v4_escape_hatch():
    from app.routes import report as report_route

    request = Request({"type": "http", "method": "GET", "path": "/report", "headers": [], "query_string": b"ui=v4"})
    response = report_route.report(request)
    assert response.status_code == 307
    assert response.headers["location"] == "/lab?ui=v4"
