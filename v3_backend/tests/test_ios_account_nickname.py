from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS/CatfolioIOS"


def test_nickname_after_preview_and_manual_override():
    for name in ("Trading212View", "IBKRFlexView", "MoomooOAuthView"):
        text = (ROOT / f"{name}.swift").read_text()
        assert "if context.isCreating, snapshot != nil" in text
        assert "AccountNicknameField(nickname: $nickname, edited: $nicknameEdited)" in text
        assert "!nicknameEdited" in text
    shared = (ROOT / "SettingsView.swift").read_text().split("struct SettingsView:")[0]
    assert 'Image(systemName: "shuffle")' in shared
    assert "$0 != nickname && !used.contains($0)" in shared
    assert "edited = true" in shared
    assert ".buttonStyle(.borderless)" in shared


if __name__ == "__main__":
    test_nickname_after_preview_and_manual_override()
    print("PASS: nickname reveal, detected-name guards and distinct random nickname")
