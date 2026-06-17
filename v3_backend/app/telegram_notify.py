"""Telegram bot notification for Catfolio portfolio alerts.

Uses only stdlib urllib — no extra dependencies.

Deduplication: persists last-sent timestamp per alert key in a JSON file
so the same alert doesn't fire more than once per hour.
"""

import json
import time
import urllib.parse
import urllib.request
from pathlib import Path


def _credentials():
    from .data_store import secret_value
    token = secret_value("TELEGRAM_BOT_TOKEN")
    chat_id = secret_value("TELEGRAM_CHAT_ID")
    return token, chat_id


def _api(token: str, method: str, payload: dict) -> dict:
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def send_message(text: str, parse_mode: str = "HTML") -> dict:
    """Send a message to the configured chat. Returns the API response dict."""
    token, chat_id = _credentials()
    if not token or not chat_id:
        return {"ok": False, "error": "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not configured"}
    try:
        return _api(token, "sendMessage", {
            "chat_id": chat_id,
            "text": text,
            "parse_mode": parse_mode,
            "disable_web_page_preview": True,
        })
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def test_connection() -> dict:
    """Send a test message. Returns {ok, error?}."""
    result = send_message("✅ <b>Catfolio</b> 已连接。Telegram 提醒工作正常。")
    return result


def get_chat_id(token: str) -> dict:
    """Call getUpdates and return the first chat_id found. Useful for setup."""
    try:
        resp = _api(token, "getUpdates", {"limit": 10, "timeout": 0})
        results = resp.get("result", [])
        if not results:
            return {"ok": False, "error": "没有收到消息。请先向机器人发送任意消息，再点此按钮。"}
        for update in reversed(results):
            msg = update.get("message") or update.get("channel_post") or {}
            chat = msg.get("chat", {})
            if chat.get("id"):
                return {"ok": True, "chat_id": str(chat["id"]), "title": chat.get("title") or chat.get("username") or chat.get("first_name")}
        return {"ok": False, "error": "无法解析 chat_id，请检查 Bot Token。"}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


# ── Deduplication ────────────────────────────────────────────────────────────

_RESEND_INTERVAL = 3600  # seconds between repeated alerts of the same type


def _log_path() -> Path:
    from .settings import V2_DIR
    return V2_DIR / "telegram_alert_log.json"


def _load_log() -> dict:
    try:
        return json.loads(_log_path().read_text())
    except Exception:
        return {}


def _save_log(log: dict):
    try:
        _log_path().parent.mkdir(parents=True, exist_ok=True)
        _log_path().write_text(json.dumps(log))
    except Exception:
        pass


def _alert_key(alert: dict) -> str:
    return f"{alert.get('type', 'unknown')}:{alert.get('ticker', '')}"


def maybe_push_alerts(alerts: list[dict]):
    """Push any alerts that haven't been sent recently. Silent if not configured."""
    token, chat_id = _credentials()
    if not token or not chat_id:
        return

    now = int(time.time())
    log = _load_log()
    new_alerts = []

    for alert in alerts:
        key = _alert_key(alert)
        last_sent = log.get(key, 0)
        if now - last_sent >= _RESEND_INTERVAL:
            new_alerts.append(alert)
            log[key] = now

    if not new_alerts:
        return

    _save_log(log)

    severity_icon = {"warn": "⚠️", "info": "ℹ️", "danger": "🔴"}
    lines = ["🔔 <b>Catfolio 投资提醒</b>", ""]
    for a in new_alerts:
        icon = severity_icon.get(a.get("severity", "info"), "ℹ️")
        lines.append(f"{icon} {a.get('message', '')}")

    try:
        _api(token, "sendMessage", {
            "chat_id": chat_id,
            "text": "\n".join(lines),
            "parse_mode": "HTML",
            "disable_web_page_preview": True,
        })
    except Exception:
        pass
