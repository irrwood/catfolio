"""The paused studio preserves code and data without an active app entry."""
from pathlib import Path
import plistlib

APP = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


def test_lab_keeps_a_disabled_strategy_entry_without_a_presentation_route():
    settings = (APP / "SettingsView.swift").read_text()
    lab = settings.split("private struct SettingsLabView: View", 1)[1].split("private struct AIModelPickerView", 1)[0]
    entry = lab.split('title: L10n.text("策略编曲家")', 1)[1].split('.accessibilityIdentifier("lab.policy-composer")', 1)[0]
    assert ".disabled(true)" in entry
    assert "PolicyComposerEntry()" not in lab
    assert "showsPolicyComposer" not in lab
    assert "--show-policy-composer" not in (APP / "RootTabView.swift").read_text()


def test_paused_studio_has_no_background_processing_permission():
    with (APP / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    assert "com.catfolio.ios.policy.*" not in info.get("BGTaskSchedulerPermittedIdentifiers", [])
    assert "processing" not in info.get("UIBackgroundModes", [])
    assert (APP / "PolicyComposerView.swift").is_file()
    assert (APP / "PolicyRunCoordinator.swift").is_file()
