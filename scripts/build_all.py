import os
import subprocess
import sys
from pathlib import Path

import os; ROOT = Path(os.environ.get("CATFOLIO_ROOT") or os.environ.get("HELM_ROOT") or str(Path(__file__).resolve().parent.parent))

STEPS = [
    ["python3", str(ROOT / "scripts/analyze_portfolio.py")],
    ["python3", str(ROOT / "scripts/enrich_market_data.py")],
    ["python3", str(ROOT / "scripts/enrich_finnhub_data.py")],
    ["python3", str(ROOT / "scripts/enrich_massive_data.py")],
    ["python3", str(ROOT / "scripts/enrich_trading212_data.py")],
    ["python3", str(ROOT / "scripts/enrich_macro_data.py")],
    ["python3", str(ROOT / "scripts/enrich_options_data.py")],
    ["python3", str(ROOT / "scripts/build_portfolio_html.py")],
    ["node", str(ROOT / "scripts/build_portfolio_workbook.mjs")],
]

REQUIRED = {
    "analyze_portfolio.py",
    "build_portfolio_html.py",
}


def main():
    failures = []
    for step in STEPS:
        result = subprocess.run(step, cwd=ROOT, env=os.environ.copy(), text=True, capture_output=True)
        print(f"$ {' '.join(step)}")
        if result.stdout:
            print(result.stdout)
        if result.returncode != 0:
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            failures.append(step)
            if Path(step[-1]).name in REQUIRED:
                return result.returncode
    if failures:
        print(f"Optional steps failed: {failures}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
