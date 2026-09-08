#!/usr/bin/env python3
"""Fail when a colour or a font is invented outside the design system.

Nine different greens all meant "this went up" and five reds meant "this went
down", because every screen picked its own. A reader comparing two rows cannot
tell a deliberate shade from an accidental one, and no amount of documentation
stops the next literal from being typed.

So: colour literals live in DesignSystem.swift and nowhere else. Everything
else names a token. Files that predate the rule are listed with the count they
had when it was written; the count may fall and never rise, which lets the
debt drain without blocking work on the files that still carry it.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1] / "CatfolioIOS" / "CatfolioIOS"
HOME = "DesignSystem.swift"

# Literal colour constructors. `Color("name")` is an asset and allowed;
# `.primary` and `Color(uiColor:)` are semantic and encouraged.
LITERAL = re.compile(r"Color\(\s*(red|white|hue)\s*:")

# Fonts built straight from `Font.system` with the rounded design bypass the
# type tokens, and so miss the alternate digits and the figure weight. The
# oversized display amount was built this way and was the one number in the
# app without the straight-sided six and nine.
FONT_HOME = {"Typography.swift", "LegacyType.swift"}
BESPOKE_FONT = re.compile(r"design:\s*\.rounded")

# What each file still carried when the rule landed. Lower is fine; higher
# fails. Delete an entry once it reaches zero.
GRANDFATHERED = {
    "VolumeProfileView.swift": 30,
    "ReturnsView.swift": 10,
    "PortfolioView.swift": 9,
    "ReturnsAnalyticsView.swift": 7,
    "AIView.swift": 2,
    "CompanyFinancialsView.swift": 2,
    "StandardLineChart.swift": 2,
}


def main() -> int:
    failures: list[str] = []
    improved: list[str] = []

    for path in sorted(ROOT.glob("*.swift")):
        if path.name in FONT_HOME:
            continue
        hits = [
            f"{path.name}:{n}"
            for n, line in enumerate(path.read_text().splitlines(), 1)
            if BESPOKE_FONT.search(line)
        ]
        if hits:
            failures.append(
                f"{path.name}: {len(hits)} font(s) built outside the type tokens\n    "
                + "\n    ".join(hits)
                + "\n    Use Typography.number(size:) or Typography.text(size:)."
            )

    for path in sorted(ROOT.glob("*.swift")):
        if path.name == HOME:
            continue
        hits = [
            f"{path.name}:{n}"
            for n, line in enumerate(path.read_text().splitlines(), 1)
            if LITERAL.search(line)
        ]
        allowed = GRANDFATHERED.get(path.name, 0)
        if len(hits) > allowed:
            failures.append(
                f"{path.name}: {len(hits)} colour literals, budget {allowed}\n    "
                + "\n    ".join(hits[: allowed + 5])
            )
        elif allowed and len(hits) < allowed:
            improved.append(f"{path.name}: {len(hits)} of {allowed} left")

    if failures:
        print("Colour literals outside DesignSystem.swift:\n")
        print("\n\n".join(failures))
        print("\nName a token instead. See DESIGN.md, Color System.")
        return 1

    total = sum(GRANDFATHERED.values())
    print(
        f"OK: no new colour literals and no bespoke fonts; "
        f"{total} colour literals grandfathered across {len(GRANDFATHERED)} files."
    )
    for line in improved:
        print(f"  improved — {line} (lower the budget in this script)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
