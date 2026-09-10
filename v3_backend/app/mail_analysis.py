"""Privacy-minimising analysis of order and travel email messages."""

from __future__ import annotations

import html
import re
from datetime import date, datetime
from email.utils import parseaddr
from html.parser import HTMLParser


_CANDIDATE_TERMS = (
    "refund",
    "refunded",
    "reimbursement",
    "compensation",
    "delay",
    "delayed",
    "cancel",
    "cancelled",
    "canceled",
    "disruption",
    "journey",
    "train",
    "flight",
    "ticket",
    "booking",
    "退款",
    "延误",
    "取消",
    "行程",
    "火车",
    "航班",
    "机票",
)
_TRAIN_TERMS = ("train", "rail", "journey", "station", "火车", "铁路", "列车")
_FLIGHT_TERMS = ("flight", "airline", "airport", "航班", "航空", "机场")
_DELAY_TERMS = ("delay", "delayed", "late", "延误", "晚点")
_CANCEL_TERMS = ("cancel", "cancelled", "canceled", "取消")
_REFUND_TERMS = ("refund", "refunded", "reimbursement", "退款", "退回")
_AMOUNT_RE = re.compile(
    r"(?P<currency>£|\$|€|GBP|USD|EUR)\s*(?P<amount>\d{1,5}(?:,\d{3})*(?:\.\d{1,2})?)",
    re.IGNORECASE,
)


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        if data.strip():
            self.parts.append(data.strip())


def html_to_text(value: str) -> str:
    parser = _TextExtractor()
    try:
        parser.feed(value or "")
    except Exception:
        return ""
    return " ".join(parser.parts)


def is_candidate(subject: str, sender: str = "") -> bool:
    haystack = f"{subject} {sender}".casefold()
    return any(term in haystack for term in _CANDIDATE_TERMS)


def _contains(value: str, terms: tuple[str, ...]) -> bool:
    lowered = value.casefold()
    return any(term in lowered for term in terms)


def _merchant(message) -> str:
    from_values = getattr(message, "from_values", None)
    name = getattr(from_values, "name", "") if from_values else ""
    address = getattr(message, "from_", "") or ""
    if name:
        return str(name).strip()[:120]
    _display, parsed = parseaddr(str(address))
    domain = (parsed.split("@", 1)[-1] if "@" in parsed else parsed).split(".")[0]
    return (domain or "Email").replace("-", " ").title()[:120]


def _event_date(message) -> str:
    value = getattr(message, "date", None)
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    return date.today().isoformat()


def _amount(text: str) -> tuple[float, str]:
    match = _AMOUNT_RE.search(text)
    if not match:
        return 0.0, "GBP"
    currency_raw = match.group("currency").upper()
    currency = {"£": "GBP", "$": "USD", "€": "EUR"}.get(
        currency_raw, currency_raw
    )
    return float(match.group("amount").replace(",", "")), currency


def analyse_message(message, *, account_id: str) -> dict | None:
    """Return a structured opportunity without retaining the raw email body."""
    subject = str(getattr(message, "subject", "") or "").strip()
    sender = str(getattr(message, "from_", "") or "").strip()
    plain = str(getattr(message, "text", "") or "")
    rich = html_to_text(str(getattr(message, "html", "") or ""))
    content = html.unescape(f"{subject}\n{plain or rich}")[:200_000]
    if not is_candidate(subject, sender) and not any(
        term in content.casefold() for term in _CANDIDATE_TERMS
    ):
        return None

    if _contains(content, _CANCEL_TERMS):
        kind = "cancelled_journey"
        evidence = "Cancellation notice found"
    elif _contains(content, _FLIGHT_TERMS) and _contains(content, _DELAY_TERMS):
        kind = "flight_delay"
        evidence = "Flight delay notice found"
    elif _contains(content, _TRAIN_TERMS) and _contains(content, _DELAY_TERMS):
        kind = "train_delay"
        evidence = "Train delay notice found"
    elif _contains(content, _REFUND_TERMS):
        kind = "refund_available"
        evidence = "Refund or reimbursement notice found"
    else:
        return None

    amount, currency = _amount(content)
    uid = str(getattr(message, "uid", "") or "")
    message_id = str(
        getattr(message, "headers", {}).get("message-id", ("",))[0]
        if getattr(message, "headers", None)
        else ""
    )
    return {
        "id": f"{account_id}:{uid}",
        "account_id": account_id,
        "uid": uid,
        "message_id": message_id[:500],
        "merchant": _merchant(message),
        "kind": kind,
        "subject": subject[:500] or "Email opportunity",
        "event_date": _event_date(message),
        "estimated_amount": round(amount, 2),
        "currency": currency,
        "confidence": 0.92 if kind in {"train_delay", "flight_delay"} else 0.84,
        "deadline": "Review eligibility",
        "evidence": evidence,
    }
