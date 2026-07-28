from pathlib import Path


ROOT = Path(__file__).parents[1]


def test_ai_workspace_is_fixed_to_viewport_with_internal_scrolling():
    css = (ROOT / "app" / "static" / "ai.css").read_text(encoding="utf-8")

    assert "body.page-ai {" in css
    assert "height: 100dvh;" in css
    assert "overflow: hidden;" in css
    assert ".ai-chat-layout {" in css
    assert "min-height: 0;" in css
    assert "body.page-ai .ai-prompt-library,\nbody.page-ai .ai-chatbox {\n  height: 100%;" in css
    assert "overscroll-behavior: contain;" in css


def test_ai_prompt_library_uses_readable_text_sizes():
    css = (ROOT / "app" / "static" / "ai.css").read_text(encoding="utf-8")

    assert ".prompt-library-head b" in css and "font-size: 18px;" in css
    assert ".ai-prompt-library summary" in css and "font-size: 14px;" in css
    assert ".qb-chip" in css and "font-size: 14px;" in css


def test_ai_prompt_header_sticks_and_only_gains_background_after_scroll():
    css = (ROOT / "app" / "static" / "ai.css").read_text(encoding="utf-8")
    js = (ROOT / "app" / "static" / "ai.js").read_text(encoding="utf-8")

    assert ".prompt-library-head {" in css
    assert "position: sticky;" in css
    assert "top: -20px;" in css
    assert ".ai-prompt-library.is-scrolled .prompt-library-head" in css
    assert "background: var(--panel);" in css
    assert ".ai-prompt-library.is-scrolled .prompt-library-head::after" in css
    assert 'classList.toggle("is-scrolled", promptLibrary.scrollTop > 1)' in js
    assert 'addEventListener("scroll", syncPromptLibraryHeader, { passive: true })' in js


def test_ai_workspace_matches_figma_split_and_home_content_width():
    css = (ROOT / "app" / "static" / "ai.css").read_text(encoding="utf-8")

    assert "scrollbar-gutter: stable;" in css
    assert "grid-template-columns: clamp(300px, 32%, 390px) minmax(0, 1fr);" in css
    assert "body.page-ai .v5-content {" in css
    assert "max-width: 1520px;" in css
    assert "padding: 20px 10px;" in css
    assert "gap: 10px;" in css
    assert "width: min(100%, 665px);" in css
    assert "@media (max-width: 760px)" in css


def test_ai_page_uses_local_figma_assets_and_initial_state():
    route = (ROOT / "app" / "routes" / "ai.py").read_text(encoding="utf-8")
    icons = ROOT / "app" / "static" / "icons"

    assert 'class="ai-chat-title">Ask Cat</h2>' in route
    assert "/static/icons/ai-welcome-book.svg" in route
    assert "/static/icons/ai-send-arrow.svg" in route
    assert "briefingRefresh" not in route
    assert (icons / "ai-welcome-book.svg").is_file()
    assert (icons / "ai-send-arrow.svg").is_file()
    assert (icons / "ai-chevron.svg").is_file()


def test_ai_question_generator_button_is_translated_and_stays_english_after_use():
    from app.i18n import t_block
    from app.routes.ai import _BODY

    english = t_block(_BODY, "en")
    script = (ROOT / "app" / "static" / "ai.js").read_text(encoding="utf-8")

    assert '<span class="prompt-more-label">Generate questions</span>' in english
    assert '<span class="prompt-more-label">生成问题</span>' not in english
    assert 'moreQuestionsAgain: "Another batch"' in script


def test_ai_composer_uses_only_the_outer_focus_ring():
    css = (ROOT / "app" / "static" / "ai.css").read_text(encoding="utf-8")
    design = (ROOT / "app" / "static" / "design-system.css").read_text(encoding="utf-8")

    assert "body.page-ai .v5-content .ai-input {" in css
    assert "min-height: 0;" in css
    assert "border: 0;" in css
    assert "body.page-ai .v5-content .ai-input:focus," in css
    assert "box-shadow: none;" in css
    assert ".ai-ask-bar:focus-within" in css
    assert ':not([type="radio"]):not(.ai-input)' in design
    assert ":is(input:not(.ai-input), select, textarea):focus" in design


def test_ai_reminder_action_has_space_below_its_answer():
    css = (ROOT / "app" / "static" / "ai.css").read_text(encoding="utf-8")

    assert ".conv-item { display: grid; gap: 9px; }" in css
    assert ".ai-reminder-actions { max-width: 88%; margin-top: 0; }" in css
    assert "margin-top: -10px;" not in css


def test_ai_reminder_draft_localizes_structured_conditions():
    script = (ROOT / "app" / "static" / "ai.js").read_text(encoding="utf-8")

    assert 'concentrationReminderTitle: "AI concentration risk alert"' in script
    assert 'concentrationReminderMessage: "Portfolio concentration risk has increased.' in script
    assert "function localizeReminderCondition(condition)" in script
    assert 'return `Any holding exceeds ${reminderPercent(value)}`;' in script
    assert 'return `Top ${Number(condition.n || 5)} holdings exceed ${reminderPercent(value)}`;' in script
    assert 'return `${condition.sector || "Sector"} exposure exceeds ${reminderPercent(value)}`;' in script
    assert 'return `QQQ correlation exceeds ${value.toFixed(2)}`;' in script
    assert 'return `Portfolio beta exceeds ${value.toFixed(2)}`;' in script
    assert 'return `Maximum drawdown exceeds ${reminderPercent(value)}`;' in script
    assert 'return `Sharpe falls below ${value.toFixed(2)}`;' in script
    assert "const draft = localizeReminderDraft(sourceDraft);" in script
