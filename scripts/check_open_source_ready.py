#!/usr/bin/env python3
"""Check the working tree for common open-source release leaks."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

BLOCKED_PATH_PREFIXES = (
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
    "__pycache__/",
)

BLOCKED_PATH_NAMES = {
    ".env",
    ".DS_Store",
    "settings.local.json",
}

PLACEHOLDER_VALUE = re.compile(r"^(|your_|xxx|example|changeme|placeholder|demo)", re.IGNORECASE)
SECRET_ASSIGNMENTS = [
    re.compile(r"(?m)^\s*([A-Z0-9_]*(?:API_KEY|API_SECRET|TOKEN|PASSWORD)[A-Z0-9_]*)\s*=\s*['\"]?([^'\"\s#]+)"),
    re.compile(r"['\"]([A-Z0-9_]*(?:API_KEY|API_SECRET|TOKEN|PASSWORD)[A-Z0-9_]*)['\"]\s*:\s*['\"]([^'\"]+)['\"]"),
]
SECRET_LITERALS = [
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bgh[opsu]_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{20,}\b"),
    re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{20,}\b"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
]
PRIVATE_HOME_PATH = re.compile(r"/" + r"Users/(?!demo(?:/|$)|example(?:/|$))[^/\s]+/")


def git_files() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def is_blocked_path(path: str) -> bool:
    parts = Path(path).parts
    if any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in BLOCKED_PATH_PREFIXES):
        return True
    return any(part in BLOCKED_PATH_NAMES for part in parts)


def scan_file(path: str) -> list[str]:
    full_path = ROOT / path
    if not full_path.exists():
        return []
    if full_path.suffix.lower() in {".icns", ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip"}:
        return []
    try:
        text = full_path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return []
    findings = []
    for pattern in SECRET_ASSIGNMENTS:
        for match in pattern.finditer(text):
            value = match.group(2).strip()
            if not PLACEHOLDER_VALUE.match(value):
                findings.append(f"{path}: possible non-placeholder secret value for {match.group(1)}")
    if any(pattern.search(text) for pattern in SECRET_LITERALS):
        findings.append(f"{path}: possible credential or private key literal")
    if PRIVATE_HOME_PATH.search(text):
        findings.append(f"{path}: contains a user-specific absolute home path")
    return findings


def main() -> int:
    files = git_files()
    findings = []
    for path in files:
        if not (ROOT / path).exists():
            continue
        if is_blocked_path(path):
            findings.append(f"{path}: blocked private/build path is tracked or unignored")
        findings.extend(scan_file(path))

    if findings:
        print("Open-source readiness check failed:")
        for finding in findings:
            print(f"- {finding}")
        return 1

    print(f"Open-source readiness check passed ({len(files)} files scanned).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
