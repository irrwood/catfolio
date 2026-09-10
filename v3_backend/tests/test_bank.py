from pathlib import Path

from starlette.requests import Request


ROOT = Path(__file__).parents[1]


def _request(lang_cookie: bytes | None = None):
    headers = [(b"accept-language", b"zh-CN")]
    if lang_cookie:
        headers.append((b"cookie", lang_cookie))
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/bank",
            "headers": headers,
            "query_string": b"",
        }
    )


def test_bank_tab_uses_shared_shell_and_local_first_workflow():
    from app.routes import bank as bank_route

    html = bank_route.bank_page(_request()).body.decode("utf-8")

    assert 'class="bank-page"' in html
    assert 'href="/bank"' in html
    assert "一键识别订阅" in html
    assert "一键识别退款" in html
    assert "消费与退款合并为一条记录" in html
    assert "邮件退款机会" in html
    assert "TrueLayer" in html
    assert "Plaid" in html
    assert "绝不自动提交索赔" in html
    assert "imap-tools" in html
    assert "应用专用密码或 OAuth2" in html
    assert 'data-mail-provider="imap"' in html


def test_bank_subscription_detection_finds_stable_monthly_charges():
    from app.banking import DEMO_TRANSACTIONS, detect_subscriptions

    items = detect_subscriptions(DEMO_TRANSACTIONS)
    merchants = {item["merchant"] for item in items}

    assert {"Spotify", "Adobe Creative Cloud", "Apple iCloud", "Netflix"} <= merchants
    assert all(item["frequency"] == "monthly" for item in items)
    assert all(item["payments_seen"] >= 3 for item in items)


def test_bank_refunds_merge_same_merchant_and_amount():
    from app.banking import DEMO_TRANSACTIONS, match_refunds

    items = match_refunds(DEMO_TRANSACTIONS)
    by_merchant = {item["merchant"]: item for item in items}

    assert by_merchant["Trainline"]["amount"] == 89.40
    assert by_merchant["Trainline"]["purchase_date"] == "2026-07-03"
    assert by_merchant["Trainline"]["refund_date"] == "2026-07-08"
    assert by_merchant["British Airways"]["amount"] == 246.80
    assert all(item["status"] == "matched" for item in items)


def test_bank_page_has_complete_english_core_actions():
    from app.routes import bank as bank_route

    html = bank_route.bank_page(_request(b"catfolio_lang=en")).body.decode("utf-8")

    assert "<h1>Banking</h1>" in html
    assert "Connect bank" in html
    assert "Detect subscriptions" in html
    assert "Match refunds" in html
    assert "Email refund opportunities" in html
    assert "Test and connect" in html
    assert "App password or OAuth2" in html
    assert "绝不自动提交索赔" not in html


def test_bank_workspace_matches_lab_width_and_reduces_motion():
    css = (ROOT / "app" / "static" / "bank.css").read_text(encoding="utf-8")

    assert "body.page-bank .v5-content" in css
    assert "max-width: 1520px;" in css
    assert "@media (prefers-reduced-motion: reduce)" in css
