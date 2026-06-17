"""Clean/shareable launcher for Catfolio-test.

Runs the normal desktop app against an isolated, initially-empty data directory
so it shows neither the user's real data nor any sample/demo data. The recipient
starts from an empty dashboard and brings their own data (Trading 212 sync or
CSV import).
"""

import os
from pathlib import Path

# Isolated data dir, set before the app imports (data_store reads CATFOLIO_DATA_DIR at
# import time; desktop.main() uses setdefault so this wins). CATFOLIO_DEMO is left
# unset, so there is no sample/fake portfolio — the app starts empty.
os.environ.setdefault(
    "CATFOLIO_DATA_DIR",
    os.environ.get("HELM_DATA_DIR") or str(Path.home() / "Library" / "Application Support" / "Catfolio-test"),
)

from desktop import main

if __name__ == "__main__":
    main()
