"""Demo/test launcher for Helm-test.

Forces HELM_DEMO=1 (built-in sample portfolio, no real user data) and an
isolated data directory, then runs the normal desktop app. Produces a
shareable build that never reads or writes the user's real Helm data.
"""

import os
from pathlib import Path

# Must be set before the app package is imported (data_store reads HELM_DEMO and
# HELM_DATA_DIR at import time). desktop.main() uses setdefault, so these win.
os.environ["HELM_DEMO"] = "1"
os.environ.setdefault(
    "HELM_DATA_DIR",
    str(Path.home() / "Library" / "Application Support" / "Helm-test"),
)

from desktop import main

if __name__ == "__main__":
    main()
