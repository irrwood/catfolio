#!/usr/bin/env python3
"""Fail when a colour, a font or a magnitude ladder is invented outside the
design system.

Nine different greens all meant "this went up" and five reds meant "this went
down", because every screen picked its own. A reader comparing two rows cannot
tell a deliberate shade from an accidental one, and no amount of documentation
stops the next literal from being typed.

So: colour literals live in DesignSystem.swift and nowhere else. Everything
else names a token. Files that predate the rule are listed with the count they
had when it was written; the count may fall and never rise, which lets the
debt drain without blocking work on the files that still carry it.

The same went for abbreviated figures. Three screens each divided by a million
on their own: a statement table that printed CNY and JPY both as "¥", an axis
that stopped at M and drew "1234M" past a billion, and a bar using
`.compactName`, which says 万 under zh-Hans. One ladder now lives in
DisplayFormat and nothing else scales a number by hand.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1] / "CatfolioIOS" / "CatfolioIOS"
DESIGN_DOC = Path(__file__).resolve().parents[1] / "CatfolioIOS" / "DESIGN.md"
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

# A figure scaled by hand, or the platform's own compact notation reached for
# directly. Both bypass DisplayFormat's ladder. The underscored forms are what
# Swift numeric literals look like in this codebase.
LADDER = re.compile(
    r"/\s*1_000(?:_000)*\b"          # value / 1_000_000
    r"|notation\(\s*\.compactName"   # the platform ladder, reached for directly
)

# Dividing a timestamp is a unit conversion, not a display ladder. Broker feeds
# quote epochs in milliseconds and microseconds, and those divisions are not
# what this rule is about.
UNIT_CONVERSION = re.compile(
    r"TimeInterval|timeIntervalSince1970|nanoseconds|[Mm]illiseconds|[Mm]icroseconds"
)
LADDER_HOME = {"DesignSystem.swift"}

# What each file still carried when the rule landed. Lower is fine; higher
# fails. Delete an entry once it reaches zero.
LADDER_GRANDFATHERED: dict[str, int] = {}

GRANDFATHERED = {
    "VolumeProfileView.swift": 27,
    "ReturnsView.swift": 9,
    "PortfolioView.swift": 8,
    "ReturnsAnalyticsView.swift": 7,
    "AIView.swift": 2,
    "CompanyFinancialsView.swift": 2,
}


def check_type_scale() -> list[str]:
    """The documented scale must be the scale the app compiles.

    A token table that drifts from the code is worse than none: it is read as
    authoritative and is wrong. Sizes are compared because they are the column
    people copy from.
    """
    code = (ROOT / "Typography.swift").read_text()
    body = re.search(r"var size: CGFloat \{(.*?)\n    \}", code, re.S)
    if not body:
        return ["Typography.swift: could not find the size table"]
    actual = {
        name: float(value)
        for name, value in re.findall(r"case \.(\w+): ([0-9.]+)", body.group(1))
    }

    doc = DESIGN_DOC.read_text()
    table = re.search(r"### Type Scale(?: — iOS)?(.*?)\n### ", doc, re.S)
    if not table:
        return [f"{DESIGN_DOC.name}: no type scale table"]
    documented = {
        name: float(size)
        for name, size in re.findall(r"^\| `(\w+)` \| ([0-9.]+) \|", table.group(1), re.M)
    }

    problems = []
    for name, size in sorted(actual.items()):
        if name not in documented:
            problems.append(f"{DESIGN_DOC.name}: {name} ({size:g}pt) is missing from the table")
        elif documented[name] != size:
            problems.append(
                f"{DESIGN_DOC.name}: {name} documented as {documented[name]:g}pt, code says {size:g}pt"
            )
    for name in sorted(set(documented) - set(actual)):
        problems.append(f"{DESIGN_DOC.name}: {name} is documented but no longer exists")
    return problems


def main() -> int:
    failures: list[str] = []
    improved: list[str] = []

    drift = check_type_scale()
    if drift:
        failures.append("\n    ".join(["Documented type scale does not match the code:"] + drift))

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
        if path.name in LADDER_HOME:
            continue
        hits = [
            f"{path.name}:{n}"
            for n, line in enumerate(path.read_text().splitlines(), 1)
            if LADDER.search(line) and not UNIT_CONVERSION.search(line)
        ]
        allowed = LADDER_GRANDFATHERED.get(path.name, 0)
        if len(hits) > allowed:
            failures.append(
                f"{path.name}: {len(hits)} figure(s) scaled outside DisplayFormat, "
                f"budget {allowed}\n    "
                + "\n    ".join(hits[: allowed + 5])
                + "\n    Use DisplayFormat.compact or .compactMoney."
            )
        elif allowed and len(hits) < allowed:
            improved.append(f"{path.name}: {len(hits)} of {allowed} ladders left")

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
        print("Design rule violations:\n")
        print("\n\n".join(failures))
        print("\nName a token or the shared ladder instead. See CatfolioIOS/DESIGN.md.")
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
