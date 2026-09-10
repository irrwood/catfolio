"""Root route: keep one canonical entry point for the current Portfolio UI."""

from fastapi import APIRouter
from fastapi.responses import RedirectResponse


router = APIRouter(tags=["pages"])


@router.get("/")
def index():
    return RedirectResponse(url="/lab", status_code=307)
