#!/usr/bin/env python3
"""Check the app's copy of the shared strategy schema against core/.

The iOS app bundles its own copy of `strategy.schema.json` so the repository
builds on its own: `core/` is a local-only checkout, excluded from this repo.
The source of truth is still `core/reference/strategy.schema.json`, so when
`core/` is present the two must match. Without `core/` there is nothing to
compare against and the check passes.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "core" / "reference" / "strategy.schema.json"
COPY = ROOT / "CatfolioIOS" / "CatfolioIOS" / "Resources" / "strategy.schema.json"


def main() -> int:
    if not SOURCE.exists():
        print("core/ is not present here; nothing to compare.")
        return 0
    if not COPY.exists():
        print(f"Missing {COPY.relative_to(ROOT)}.", file=sys.stderr)
        return 1
    if SOURCE.read_bytes() == COPY.read_bytes():
        print("strategy.schema.json matches core/reference.")
        return 0
    print(
        "The app's strategy.schema.json differs from core/reference. Update the copy:\n"
        "  cp core/reference/strategy.schema.json CatfolioIOS/CatfolioIOS/Resources/",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
