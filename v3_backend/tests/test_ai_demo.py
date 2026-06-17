def test_demo_ai_does_not_read_secrets(monkeypatch):
    from app import ai
    from app.cache import clear_all

    monkeypatch.setattr(ai, "demo_mode", lambda: True)
    monkeypatch.setattr(
        ai,
        "secret_value",
        lambda name: (_ for _ in ()).throw(AssertionError(f"secret read in demo AI: {name}")),
    )
    clear_all()

    text = ai._chat([{"role": "user", "content": "请分析组合"}])

    assert "假数据模式" in text
    assert "没有读取本机 AI Key" in text


def test_demo_ai_risk_json_does_not_read_secrets(monkeypatch):
    from app import ai

    monkeypatch.setattr(ai, "demo_mode", lambda: True)
    monkeypatch.setattr(
        ai,
        "secret_value",
        lambda name: (_ for _ in ()).throw(AssertionError(f"secret read in demo AI: {name}")),
    )

    text = ai._chat([{"role": "user", "content": '请严格按照JSON格式回复 {"risk_level": "..."}'}])
    data = ai._parse_ai_json(text)

    assert data["risk_level"] == "Demo"
    assert "未调用外部 AI" in data["risk_tags"]


def test_demo_ai_english_output_does_not_read_secrets(monkeypatch):
    from app import ai

    monkeypatch.setattr(ai, "demo_mode", lambda: True)
    monkeypatch.setattr(
        ai,
        "secret_value",
        lambda name: (_ for _ in ()).throw(AssertionError(f"secret read in demo AI: {name}")),
    )

    text = ai._chat([{"role": "user", "content": "Analyze my portfolio"}], lang="en")

    assert "Demo data mode is active" in text
    assert "did not read a local AI key" in text
    assert "假数据模式" not in text


def test_demo_ai_english_risk_json(monkeypatch):
    from app import ai

    monkeypatch.setattr(ai, "demo_mode", lambda: True)
    monkeypatch.setattr(
        ai,
        "secret_value",
        lambda name: (_ for _ in ()).throw(AssertionError(f"secret read in demo AI: {name}")),
    )

    text = ai._chat([{"role": "user", "content": 'Return JSON with {"risk_level": "..."}'}], lang="en")
    data = ai._parse_ai_json(text)

    assert data["risk_level"] == "Demo"
    assert "no external AI call" in data["risk_tags"]
    assert "外部" not in " ".join(data["findings"])
