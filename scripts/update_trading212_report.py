import subprocess
import sys
from pathlib import Path

import os; ROOT = Path(os.environ.get("CATFOLIO_ROOT") or os.environ.get("HELM_ROOT") or str(Path(__file__).resolve().parent.parent))

STEPS = [
    ["python3", str(ROOT / "scripts/enrich_trading212_data.py")],
    ["python3", str(ROOT / "scripts/build_portfolio_html.py")],
    ["python3", str(ROOT / "scripts/validate_report.py")],
]


def main():
    for step in STEPS:
        result = subprocess.run(step, cwd=ROOT, text=True, capture_output=True)
        print(f"$ {' '.join(step)}")
        if result.stdout:
            print(result.stdout)
        if result.returncode:
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            return result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
