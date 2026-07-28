#!/usr/bin/env python3
"""Create a clean source archive for publishing Catfolio."""

from __future__ import annotations

import argparse
import subprocess
import sys
from datetime import date
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parent.parent

EXCLUDED_PREFIXES = (
    ".git/",
    ".claude/",
    ".playwright-mcp/",
    ".vercel/",
    "artifacts/",
    "v3_backend/.claude/",
    "docs/superpowers/",
    "outputs/",
    "build/",
    "build-",
    "dist/",
    "dist-",
    "releases/",
    ".venv/",
    ".venv-",
    "venv/",
    "v3_backend/.venv/",
    "v3_backend/.venv-",
    "v3_backend/venv/",
    ".pytest_cache/",
    "v3_backend/.pytest_cache/",
    "node_modules/",
    "__pycache__/",
)

EXCLUDED_NAMES = {
    ".DS_Store",
    ".env",
    "settings.local.json",
}


def git_candidate_files() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def include_path(path: str) -> bool:
    full_path = ROOT / path
    if not full_path.is_file():
        return False
    if any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in EXCLUDED_PREFIXES):
        return False
    return not any(part in EXCLUDED_NAMES for part in Path(path).parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        default=f"releases/catfolio-open-source-{date.today().isoformat()}.zip",
        help="Archive path to create.",
    )
    args = parser.parse_args()

    check = subprocess.run([sys.executable, "scripts/check_open_source_ready.py"], cwd=ROOT)
    if check.returncode != 0:
        return check.returncode

    out_path = ROOT / args.out
    out_path.parent.mkdir(parents=True, exist_ok=True)

    files = [path for path in git_candidate_files() if include_path(path)]
    with ZipFile(out_path, "w", compression=ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(ROOT / path, arcname=f"catfolio/{path}")

    print(f"Wrote {out_path} ({len(files)} files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
