import os
import sys
from pathlib import Path


def _compute_root() -> Path:
    """Return the project root.

    In a PyInstaller bundle sys._MEIPASS is the extraction directory that
    contains app/, scripts/, etc. — use it as ROOT so all relative paths work.
    In normal dev mode walk up three levels from this file.
    """
    if hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS)
    return Path(__file__).resolve().parent.parent.parent


ROOT = Path(os.environ.get("CATFOLIO_ROOT") or os.environ.get("HELM_ROOT") or str(_compute_root()))
# Writable data directory. Defaults to <repo>/outputs for dev; the packaged desktop
# app points CATFOLIO_DATA_DIR at ~/Library/Application Support/Catfolio so it never writes
# into a read-only app bundle. All caches and databases derive from here.
DATA_DIR = Path(os.environ.get("CATFOLIO_DATA_DIR") or os.environ.get("HELM_DATA_DIR") or str(ROOT / "outputs"))
V2_DIR = DATA_DIR / "portfolio_analysis_v2"
LIVE_MARKET_CACHE = V2_DIR / "live_market_data.json"
FUNDAMENTALS_CACHE = V2_DIR / "fundamentals_data.json"
LAB_HISTORY_CACHE = V2_DIR / "lab_history_data.json"
BUILD_V2_SCRIPT = ROOT / "scripts/build_trading212_v2.py"
GBP_TO_USD = float(os.environ.get("CATFOLIO_GBP_TO_USD") or os.environ.get("HELM_GBP_TO_USD") or "1.3460")
MARKET_REFRESH_TTL_SECONDS = 60
LAB_HISTORY_TTL_SECONDS = 60 * 60 * 12
