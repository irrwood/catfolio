"""Compatibility redirect for the retired audit page."""

from fastapi import APIRouter, Request
from fastapi.responses import RedirectResponse

router = APIRouter(tags=["pages"])


@router.get("/report")
def report(request: Request):
    """Send old bookmarks to Portfolio without exposing legacy account reports."""
    suffix = "?ui=v4" if request.query_params.get("ui") == "v4" else ""
    return RedirectResponse(url=f"/lab{suffix}", status_code=307)
