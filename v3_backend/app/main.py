"""Catfolio — FastAPI Application."""

from pathlib import Path
from urllib.parse import urlencode

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from dotenv import load_dotenv

load_dotenv()

from app.routes import api, home, report, lab, analysis_charts, backtest, heatmap, returns, ai, bank, settings, strategy, import_csv
from app import i18n
from app.data_store import public_demo_mode

app = FastAPI(title="Catfolio", version="1.1.0")
APP_DIR = Path(__file__).resolve().parent

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["*"],
)
app.mount("/static", StaticFiles(directory=APP_DIR / "static"), name="static")


_PUBLIC_DEMO_POSTS = {
    "/api/lab/ai-analysis",
    "/api/ai/briefing",
    "/api/ai/risk-diagnosis",
    "/api/ai/performance-explanation",
    "/api/ai/overlap-analysis",
    "/api/ai/what-if",
    "/api/ai/ask",
    "/api/ai/portfolio-attention",
    "/api/ai/returns-explanation",
    "/api/alerts/preview-ai-reminders",
    "/api/bank/scan-subscriptions",
    "/api/bank/scan-refunds",
    "/api/bank/scan-email",
}


@app.middleware("http")
async def canonicalize_current_ui_url(request: Request, call_next):
    """Remove the obsolete v5 selector while preserving other query parameters."""
    if request.method in {"GET", "HEAD"} and request.query_params.get("ui") == "v5":
        remaining_query = [
            (key, value)
            for key, value in request.query_params.multi_items()
            if key != "ui"
        ]
        query_string = urlencode(remaining_query, doseq=True)
        canonical_url = request.url.path
        if query_string:
            canonical_url = f"{canonical_url}?{query_string}"
        return RedirectResponse(url=canonical_url, status_code=307)
    return await call_next(request)


@app.middleware("http")
async def protect_public_demo(request: Request, call_next):
    """Keep hosted showcases immutable and free of provider-side effects."""
    if public_demo_mode():
        is_safe_method = request.method in {"GET", "HEAD", "OPTIONS"}
        allowed_demo_post = request.method == "POST" and request.url.path in _PUBLIC_DEMO_POSTS
        blocked_get = request.url.path in {"/api/market/live", "/api/telegram/get-chat-id"}
        if (not is_safe_method and not allowed_demo_post) or blocked_get:
            return JSONResponse(
                {
                    "ok": False,
                    "error": "This public Catfolio demo is read-only.",
                },
                status_code=403,
                headers={"X-Catfolio-Demo": "public-read-only"},
            )
    response = await call_next(request)
    if public_demo_mode():
        response.headers["X-Catfolio-Demo"] = "public-read-only"
    return response


@app.middleware("http")
async def cache_static_assets(request: Request, call_next):
    """Cache fingerprinted assets permanently; revalidate unversioned assets."""
    response = await call_next(request)
    if request.url.path.startswith("/static/"):
        response.headers["Cache-Control"] = (
            "public, max-age=31536000, immutable"
            if request.query_params.get("v")
            else "no-cache"
        )
    return response

# Register route modules
app.include_router(home.router)
app.include_router(report.router)
app.include_router(lab.router)
app.include_router(analysis_charts.router)
app.include_router(backtest.router)
app.include_router(heatmap.router)
app.include_router(api.router)
app.include_router(returns.router)
app.include_router(ai.router)
app.include_router(bank.router)
app.include_router(settings.router)
app.include_router(strategy.router)
app.include_router(import_csv.router)
app.include_router(i18n.router)

from app.routes import sector_rotation
app.include_router(sector_rotation.router)

from app.routes import accounts
app.include_router(accounts.router)
