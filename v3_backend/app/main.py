"""Helm — FastAPI Application."""

from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from dotenv import load_dotenv

load_dotenv()

from app.routes import api, home, report, lab, backtest, heatmap, returns, ai, settings, strategy

app = FastAPI(title="Helm", version="1.0.0")
APP_DIR = Path(__file__).resolve().parent

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)
app.mount("/static", StaticFiles(directory=APP_DIR / "static"), name="static")

# Register route modules
app.include_router(home.router)
app.include_router(report.router)
app.include_router(lab.router)
app.include_router(backtest.router)
app.include_router(heatmap.router)
app.include_router(api.router)
app.include_router(returns.router)
app.include_router(ai.router)
app.include_router(settings.router)
app.include_router(strategy.router)
