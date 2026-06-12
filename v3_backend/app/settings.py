import os
from pathlib import Path

ROOT = Path(os.environ.get("HELM_ROOT", str(Path(__file__).resolve().parent.parent.parent)))
V2_DIR = ROOT / "outputs/portfolio_analysis_v2"
V2_HTML = V2_DIR / "portfolio_cost_basis_v2.html"
LIVE_MARKET_CACHE = V2_DIR / "live_market_data.json"
FUNDAMENTALS_CACHE = V2_DIR / "fundamentals_data.json"
LAB_HISTORY_CACHE = V2_DIR / "lab_history_data.json"
BUILD_V2_SCRIPT = ROOT / "scripts/build_trading212_v2.py"
GBP_TO_USD = float(os.environ.get("HELM_GBP_TO_USD", "1.3460"))
MARKET_REFRESH_TTL_SECONDS = 60
LAB_HISTORY_TTL_SECONDS = 60 * 60 * 12
