from pathlib import Path

from app import components


ROOT = Path(__file__).parents[1]


def test_v5_shell_mounts_global_ai_float_without_changing_ai_nav():
    html = components.wrap_v5_layout("测试", "<p>body</p>", "/lab", "zh")

    assert 'class="global-ai-float" id="globalAiFloat" data-default-open="true"' in html
    assert 'id="globalAiPanel" role="dialog" aria-modal="false"' in html
    assert 'id="globalAiLauncher"' in html
    assert '/static/ai-float.css' in html
    assert '/static/ai-float.js' in html
    assert 'class="v5-nav-link " href="/ai"' in html


def test_ai_page_keeps_float_available_but_defaults_it_closed():
    html = components.wrap_v5_layout("AI", "<p>body</p>", "/ai", "zh")

    assert 'id="globalAiFloat" data-default-open="false"' in html
    assert 'class="v5-nav-link active" href="/ai"' in html


def test_global_ai_float_uses_shared_tokens_and_accessible_controls():
    css = (ROOT / "app" / "static" / "ai-float.css").read_text(encoding="utf-8")
    script = (ROOT / "app" / "static" / "ai-float.js").read_text(encoding="utf-8")

    assert 'font-family: "Nunito Local", "Nunito", sans-serif;' in css
    assert "border: 1px solid var(--line);" in css
    assert "border-radius: 20px;" in css
    assert "box-shadow: none;" in css
    assert "#708cff" in css
    assert "@media (prefers-reduced-motion: reduce)" in css
    assert 'fetch("/api/ai/ask"' in script
    assert "sessionStorage.setItem(MESSAGES_KEY" in script
    assert 'event.key === "Escape"' in script
