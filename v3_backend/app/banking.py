"""Local-first bank analytics and demo recognition rules.

The production Open Banking transport is intentionally kept outside this module.
TrueLayer or Plaid adapters can provide transactions in the normalized shape used
here without changing the subscription and refund analysis.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import date
from statistics import median


def _transaction(
    tx_id: str,
    posted: str,
    merchant: str,
    amount: float,
    category: str,
    account: str = "Barclays Current",
) -> dict:
    return {
        "id": tx_id,
        "date": posted,
        "merchant": merchant,
        "amount": amount,
        "currency": "GBP",
        "category": category,
        "account": account,
    }


DEMO_TRANSACTIONS = [
    *[
        _transaction(f"spotify-{month}", f"2026-{month:02d}-04", "Spotify", -10.99, "entertainment")
        for month in range(1, 8)
    ],
    *[
        _transaction(f"adobe-{month}", f"2026-{month:02d}-12", "Adobe Creative Cloud", -19.97, "software")
        for month in range(1, 8)
    ],
    *[
        _transaction(f"icloud-{month}", f"2026-{month:02d}-20", "Apple iCloud", -2.99, "software")
        for month in range(1, 8)
    ],
    *[
        _transaction(f"netflix-{month}", f"2026-{month:02d}-18", "Netflix", -17.99, "entertainment")
        for month in range(4, 8)
    ],
    _transaction("trainline-buy", "2026-07-03", "Trainline", -89.40, "travel"),
    _transaction("trainline-refund", "2026-07-08", "Trainline", 89.40, "refund"),
    _transaction("ba-buy", "2026-06-14", "British Airways", -246.80, "travel"),
    _transaction("ba-refund", "2026-06-25", "British Airways", 246.80, "refund"),
    _transaction("amazon-buy", "2026-05-09", "Amazon", -44.95, "shopping"),
    _transaction("amazon-refund", "2026-05-13", "Amazon", 44.95, "refund"),
    _transaction("waitrose", "2026-07-21", "Waitrose", -76.32, "groceries"),
    _transaction("tfl", "2026-07-22", "TfL Travel Charge", -18.70, "transport"),
    _transaction("salary", "2026-07-25", "Salary", 4200.00, "income"),
]


DEMO_ACCOUNTS = [
    {"id": "barclays-current", "name": "Barclays Current", "type": "current", "balance": 4832.45, "currency": "GBP"},
    {"id": "monzo-current", "name": "Monzo Current", "type": "current", "balance": 2310.18, "currency": "GBP"},
    {"id": "chase-saver", "name": "Chase Saver", "type": "savings", "balance": 6142.00, "currency": "GBP"},
]


DEMO_CASH_FLOW = [
    {"month": "2月", "income": 4200.00, "spend": 3018.40},
    {"month": "3月", "income": 4200.00, "spend": 3264.70},
    {"month": "4月", "income": 4200.00, "spend": 2942.15},
    {"month": "5月", "income": 4200.00, "spend": 3388.60},
    {"month": "6月", "income": 4200.00, "spend": 3544.30},
    {"month": "7月", "income": 4200.00, "spend": 3172.40},
]


DEMO_EMAIL_OPPORTUNITIES = [
    {
        "id": "mail-avanti-delay",
        "merchant": "Avanti West Coast",
        "kind": "train_delay",
        "subject": "Your journey was delayed by 47 minutes",
        "event_date": "2026-07-19",
        "estimated_amount": 34.50,
        "currency": "GBP",
        "confidence": 0.96,
        "deadline": "2026-08-16",
        "evidence": "Delay confirmation · London Euston → Manchester Piccadilly",
    },
    {
        "id": "mail-ba-delay",
        "merchant": "British Airways",
        "kind": "flight_delay",
        "subject": "Important information about your delayed flight",
        "event_date": "2026-07-11",
        "estimated_amount": 220.00,
        "currency": "GBP",
        "confidence": 0.84,
        "deadline": "Review eligibility",
        "evidence": "Flight BA0283 · arrival delay appears to exceed 3 hours",
    },
    {
        "id": "mail-trainline-cancelled",
        "merchant": "Trainline",
        "kind": "cancelled_journey",
        "subject": "Your train has been cancelled",
        "event_date": "2026-07-23",
        "estimated_amount": 52.80,
        "currency": "GBP",
        "confidence": 0.91,
        "deadline": "2026-08-20",
        "evidence": "Cancellation notice found; no matching bank credit yet",
    },
]


def normalize_merchant(value: str) -> str:
    """Normalize common statement suffixes without over-merging merchants."""
    text = " ".join((value or "").upper().replace("*", " ").split())
    suffixes = (" REFUND", " CARD PAYMENT", " ONLINE", " LTD", " LIMITED")
    changed = True
    while changed:
        changed = False
        for suffix in suffixes:
            if text.endswith(suffix):
                text = text[: -len(suffix)].strip()
                changed = True
    return text


def _as_date(value: str) -> date:
    return date.fromisoformat(value)


def match_refunds(transactions: list[dict], amount_tolerance: float = 0.01) -> list[dict]:
    """Pair a later credit with an earlier debit from the same merchant and amount."""
    debits: dict[tuple[str, int], list[dict]] = defaultdict(list)
    credits = []
    for tx in sorted(transactions, key=lambda item: (item["date"], item["id"])):
        amount = float(tx.get("amount") or 0)
        amount_key = round(abs(amount) * 100)
        key = (normalize_merchant(tx.get("merchant", "")), amount_key)
        if amount < 0:
            debits[key].append(tx)
        elif amount > 0:
            credits.append((key, tx))

    pairs = []
    used_debits = set()
    cents_tolerance = max(1, round(amount_tolerance * 100))
    for (merchant_key, credit_cents), credit in credits:
        candidates = []
        for cents in range(credit_cents - cents_tolerance, credit_cents + cents_tolerance + 1):
            for debit in debits.get((merchant_key, cents), []):
                if debit["id"] in used_debits or debit["date"] > credit["date"]:
                    continue
                candidates.append(debit)
        if not candidates:
            continue
        original = max(candidates, key=lambda item: item["date"])
        used_debits.add(original["id"])
        elapsed = (_as_date(credit["date"]) - _as_date(original["date"])).days
        pairs.append(
            {
                "id": f'{original["id"]}:{credit["id"]}',
                "merchant": original["merchant"],
                "amount": round(abs(float(original["amount"])), 2),
                "currency": original.get("currency", "GBP"),
                "purchase_date": original["date"],
                "refund_date": credit["date"],
                "days": elapsed,
                "account": original.get("account", ""),
                "status": "matched",
                "original": original,
                "refund": credit,
            }
        )
    return sorted(pairs, key=lambda item: item["refund_date"], reverse=True)


def detect_subscriptions(transactions: list[dict]) -> list[dict]:
    """Detect roughly monthly merchant debits with a stable amount."""
    grouped: dict[str, list[dict]] = defaultdict(list)
    for tx in transactions:
        if float(tx.get("amount") or 0) < 0:
            grouped[normalize_merchant(tx.get("merchant", ""))].append(tx)

    subscriptions = []
    for rows in grouped.values():
        rows.sort(key=lambda item: item["date"])
        if len(rows) < 3:
            continue
        dates = [_as_date(row["date"]) for row in rows]
        intervals = [(later - earlier).days for earlier, later in zip(dates, dates[1:])]
        monthly_intervals = [value for value in intervals if 20 <= value <= 40]
        if len(monthly_intervals) < len(intervals) - 1:
            continue
        amounts = [abs(float(row["amount"])) for row in rows]
        typical = median(amounts)
        if max(abs(value - typical) for value in amounts) > max(1.0, typical * 0.08):
            continue
        last_date = dates[-1]
        next_month = last_date.month + 1
        next_year = last_date.year
        if next_month == 13:
            next_month = 1
            next_year += 1
        next_day = min(last_date.day, 28)
        subscriptions.append(
            {
                "id": normalize_merchant(rows[-1]["merchant"]).lower().replace(" ", "-"),
                "merchant": rows[-1]["merchant"],
                "amount": round(typical, 2),
                "currency": rows[-1].get("currency", "GBP"),
                "frequency": "monthly",
                "annual_cost": round(typical * 12, 2),
                "payments_seen": len(rows),
                "last_payment": rows[-1]["date"],
                "next_expected": date(next_year, next_month, next_day).isoformat(),
                "confidence": min(0.99, 0.72 + len(rows) * 0.035),
                "category": rows[-1].get("category", "other"),
            }
        )
    return sorted(subscriptions, key=lambda item: item["annual_cost"], reverse=True)


def demo_overview() -> dict:
    subscriptions = detect_subscriptions(DEMO_TRANSACTIONS)
    refunds = match_refunds(DEMO_TRANSACTIONS)
    return {
        "provider": "demo",
        "connected": False,
        "accounts": DEMO_ACCOUNTS,
        "cash_flow": DEMO_CASH_FLOW,
        "summary": {
            "balance": round(sum(float(account["balance"]) for account in DEMO_ACCOUNTS), 2),
            "monthly_income": DEMO_CASH_FLOW[-1]["income"],
            "monthly_spend": DEMO_CASH_FLOW[-1]["spend"],
            "monthly_subscriptions": round(sum(item["amount"] for item in subscriptions), 2),
            "refunds_recovered": round(sum(item["amount"] for item in refunds), 2),
        },
    }
