"""The paused studio preserves code and data without an active app entry."""
from pathlib import Path
import plistlib

APP = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


def test_paused_studio_has_no_background_processing_permission():
    with (APP / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    assert "com.catfolio.ios.policy.*" not in info.get("BGTaskSchedulerPermittedIdentifiers", [])
    assert "processing" not in info.get("UIBackgroundModes", [])
    assert (APP / "PolicyComposerView.swift").is_file()
    assert (APP / "PolicyRunCoordinator.swift").is_file()
