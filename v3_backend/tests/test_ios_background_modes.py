"""The app asks iOS for no background processing it does not use."""
from pathlib import Path
import plistlib

APP = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


def test_no_background_processing_permission():
    with (APP / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    assert "com.catfolio.ios.policy.*" not in info.get("BGTaskSchedulerPermittedIdentifiers", [])
    assert "processing" not in info.get("UIBackgroundModes", [])
