"""Vercel entrypoint for Catfolio's public, read-only demo."""

import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent

# Vercel Functions only guarantee writable storage under /tmp.  The public demo
# never needs private portfolio files, but a few local-first components still
# initialise caches or SQLite lazily, so keep those ephemeral writes there.
os.environ["CATFOLIO_DEMO"] = "1"
os.environ["CATFOLIO_PUBLIC_DEMO"] = "1"
os.environ.setdefault("CATFOLIO_DATA_DIR", "/tmp/catfolio")

# The application package lives under v3_backend/ in the desktop repository.
sys.path.insert(0, str(ROOT / "v3_backend"))

from app.main import app  # noqa: E402,F401
