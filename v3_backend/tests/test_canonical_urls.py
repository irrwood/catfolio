import asyncio

from starlette.requests import Request
from starlette.responses import PlainTextResponse


def _request(path="/lab", query_string=b""):
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": path,
            "headers": [],
            "query_string": query_string,
        }
    )


def test_v5_query_redirects_to_clean_canonical_url():
    from app.main import canonicalize_current_ui_url

    async def call_next(_request):
        return PlainTextResponse("next")

    response = asyncio.run(
        canonicalize_current_ui_url(
            _request(query_string=b"ui=v5"),
            call_next,
        )
    )

    assert response.status_code == 307
    assert response.headers["location"] == "/lab"


def test_v5_canonicalization_preserves_other_query_parameters():
    from app.main import canonicalize_current_ui_url

    async def call_next(_request):
        return PlainTextResponse("next")

    response = asyncio.run(
        canonicalize_current_ui_url(
            _request(path="/analytics", query_string=b"ui=v5&view=matrix&tag=a&tag=b"),
            call_next,
        )
    )

    assert response.status_code == 307
    assert response.headers["location"] == "/analytics?view=matrix&tag=a&tag=b"


def test_v4_query_is_not_canonicalized():
    from app.main import canonicalize_current_ui_url

    async def call_next(_request):
        return PlainTextResponse("next")

    response = asyncio.run(
        canonicalize_current_ui_url(
            _request(query_string=b"ui=v4"),
            call_next,
        )
    )

    assert response.status_code == 200
    assert response.body == b"next"
