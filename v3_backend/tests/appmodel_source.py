"""Read the app model across its responsibility-specific Swift files."""
from pathlib import Path


def read_appmodel(app_directory: Path) -> str:
    files = [app_directory / "AppModel.swift", *sorted(app_directory.glob("AppModel+*.swift"))]
    return "\n".join(path.read_text(encoding="utf-8") for path in files)
