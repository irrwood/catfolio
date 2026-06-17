import json
import re
import subprocess
from pathlib import Path

import os; ROOT = Path(os.environ.get("CATFOLIO_ROOT") or os.environ.get("HELM_ROOT") or str(Path(__file__).resolve().parent.parent))
OUT = ROOT / "outputs/portfolio_analysis"


def assert_json(path):
    json.loads(path.read_text(encoding="utf-8"))


def main():
    for name in ["portfolio_analysis.json", "market_data.json", "finnhub_data.json", "massive_data.json", "trading212_data.json", "macro_data.json", "options_data.json"]:
        path = OUT / name
        if path.exists():
            assert_json(path)
            print(f"json ok: {name}")
        else:
            print(f"json missing: {name}")

    html_path = OUT / "portfolio_cost_basis.html"
    html = html_path.read_text(encoding="utf-8")
    assert "量化雷达" in html
    assert "portfolio_quant_radar.csv" in html
    assert "FRED_API_KEY" not in html
    assert "MASSIVE_API_KEY" not in html
    assert "FINNHUB_API_KEY" not in html
    assert "TRADING212_API_KEY" not in html
    match = re.search(r"<script>([\s\S]*)</script>", html)
    assert match, "script tag missing"
    subprocess.run(["node", "-e", f"new Function({match.group(1)!r}); console.log('script ok')"], check=True)
    print("html ok")


if __name__ == "__main__":
    main()
