"""Application service joining local bank persistence, Plaid, and analysis."""

from __future__ import annotations

import os
from collections import defaultdict
from datetime import date
from functools import lru_cache
from typing import Callable

from . import data_store
from .bank_crypto import TokenCipher
from .bank_repository import BANK_DB_PATH, BankRepository
from .banking import (
    DEMO_TRANSACTIONS,
    demo_overview,
    detect_subscriptions,
    match_refunds,
)
from .plaid_adapter import (
    PlaidAdapter,
    PlaidConfig,
    PlaidConfigurationError,
)


class BankService:
    def __init__(
        self,
        repository: BankRepository,
        adapter_factory: Callable[[], PlaidAdapter] | None = None,
    ) -> None:
        self.repository = repository
        self._adapter_factory = adapter_factory or self._default_adapter

    def _default_adapter(self) -> PlaidAdapter:
        return PlaidAdapter(
            repository=self.repository,
            cipher=TokenCipher(),
            config=PlaidConfig.from_local_secrets(),
        )

    def plaid_configured(self) -> bool:
        if data_store.demo_mode() or data_store.public_demo_mode():
            return False
        try:
            PlaidConfig.from_local_secrets()
            return True
        except PlaidConfigurationError:
            return False

    def create_link_token(self) -> dict:
        self._require_real_mode()
        adapter = self._adapter_factory()
        return adapter.create_link_token(self.repository.local_user_id())

    def exchange_public_token(
        self, public_token: str, metadata: dict | None = None
    ) -> dict:
        self._require_real_mode()
        return self._adapter_factory().exchange_public_token(public_token, metadata)

    def verify_webhook(self, signed_jwt: str, raw_body: bytes) -> dict:
        self._require_real_mode()
        return self._adapter_factory().verify_webhook(signed_jwt, raw_body)

    def sync_all(self) -> list[dict]:
        self._require_real_mode()
        return self._adapter_factory().sync_all()

    def sync_item(self, item_id: str) -> dict:
        self._require_real_mode()
        return self._adapter_factory().sync_item(item_id)

    def refresh_item(self, item_id: str) -> dict:
        self._require_real_mode()
        return self._adapter_factory().refresh_item(item_id)

    def remove_item(self, item_id: str) -> bool:
        self._require_real_mode()
        return self._adapter_factory().remove_item(item_id)

    @staticmethod
    def _require_real_mode() -> None:
        if data_store.demo_mode() or data_store.public_demo_mode():
            raise PermissionError("Bank connections are disabled in demo mode.")

    def _should_use_local_data(self) -> bool:
        return not data_store.demo_mode() and self.repository.has_connections()

    def _sync_if_stale(self) -> None:
        if not self._should_use_local_data() or not self.plaid_configured():
            return
        age = self.repository.latest_sync_age_seconds()
        threshold_hours = max(
            1, int(os.environ.get("CATFOLIO_BANK_SYNC_HOURS") or "4")
        )
        if age is not None and age < threshold_hours * 3600:
            return
        # Overview remains usable from the last local snapshot if the provider is
        # temporarily offline or the item requires re-authentication.
        self._adapter_factory().sync_all()

    def transactions(self) -> tuple[str, list[dict]]:
        if self._should_use_local_data():
            return "plaid", self.repository.list_transactions()
        return "demo", DEMO_TRANSACTIONS

    @staticmethod
    def _month_keys(today: date) -> list[str]:
        keys = []
        year, month = today.year, today.month
        for offset in range(5, -1, -1):
            absolute = year * 12 + (month - 1) - offset
            keys.append(f"{absolute // 12:04d}-{absolute % 12 + 1:02d}")
        return keys

    @classmethod
    def _cash_flow(cls, transactions: list[dict], today: date) -> list[dict]:
        totals: dict[str, dict[str, float]] = defaultdict(
            lambda: {"income": 0.0, "spend": 0.0}
        )
        for transaction in transactions:
            if transaction.get("pending"):
                continue
            posted = str(transaction.get("date") or "")
            if len(posted) < 7:
                continue
            month = posted[:7]
            amount = float(transaction.get("amount") or 0)
            if amount >= 0:
                totals[month]["income"] += amount
            else:
                totals[month]["spend"] += abs(amount)
        return [
            {
                "month": month,
                "income": round(totals[month]["income"], 2),
                "spend": round(totals[month]["spend"], 2),
            }
            for month in cls._month_keys(today)
        ]

    def overview(self, *, refresh_stale: bool = True, today: date | None = None) -> dict:
        if not self._should_use_local_data():
            result = demo_overview()
            result["configured"] = self.plaid_configured()
            return result

        if refresh_stale:
            try:
                self._sync_if_stale()
            except Exception:
                pass

        accounts = self.repository.list_accounts()
        transactions = self.repository.list_transactions()
        today = today or date.today()
        cash_flow = self._cash_flow(transactions, today)
        subscriptions = detect_subscriptions(transactions)
        refunds = match_refunds(transactions)

        public_accounts = []
        total_balance = 0.0
        for account in accounts:
            raw_balance = float(account.get("current_balance") or 0)
            balance = -raw_balance if account.get("type") == "credit" else raw_balance
            total_balance += balance
            subtype = str(account.get("subtype") or "").lower()
            display_type = (
                "savings"
                if subtype in {"savings", "money market"}
                else "current"
            )
            public_accounts.append(
                {
                    "id": account["id"],
                    "name": account["name"],
                    "type": display_type,
                    "balance": round(balance, 2),
                    "currency": account.get("currency") or "GBP",
                    "mask": account.get("mask"),
                }
            )

        latest = cash_flow[-1] if cash_flow else {"income": 0, "spend": 0}
        return {
            "provider": "plaid",
            "connected": True,
            "configured": self.plaid_configured(),
            "accounts": public_accounts,
            "cash_flow": cash_flow,
            "summary": {
                "balance": round(total_balance, 2),
                "monthly_income": latest["income"],
                "monthly_spend": latest["spend"],
                "monthly_subscriptions": round(
                    sum(item["amount"] for item in subscriptions), 2
                ),
                "refunds_recovered": round(
                    sum(item["amount"] for item in refunds), 2
                ),
            },
            "items": [
                {
                    "item_id": item["item_id"],
                    "institution_name": item.get("institution_name"),
                    "connection_status": item["connection_status"],
                    "last_synced_at": item.get("last_synced_at"),
                }
                for item in self.repository.list_items()
            ],
        }

    def scan_subscriptions(self) -> dict:
        source, transactions = self.transactions()
        items = detect_subscriptions(transactions)
        return {"ok": True, "source": source, "count": len(items), "items": items}

    def scan_refunds(self) -> dict:
        source, transactions = self.transactions()
        items = match_refunds(transactions)
        return {
            "ok": True,
            "source": source,
            "count": len(items),
            "recovered": round(sum(item["amount"] for item in items), 2),
            "items": items,
        }

    def handle_webhook(self, payload: dict) -> dict:
        webhook_type = str(payload.get("webhook_type") or "")
        webhook_code = str(payload.get("webhook_code") or "")
        item_id = str(payload.get("item_id") or "") or None
        if not webhook_type or not webhook_code:
            raise ValueError("Invalid Plaid webhook payload.")

        event_id = self.repository.record_webhook(
            item_id, webhook_type, webhook_code
        )
        should_sync = bool(
            item_id
            and webhook_type == "TRANSACTIONS"
            and webhook_code == "SYNC_UPDATES_AVAILABLE"
            and self.repository.get_item(item_id)
        )
        return {
            "ok": True,
            "event_id": event_id,
            "item_id": item_id,
            "should_sync": should_sync,
        }

    def process_webhook_sync(self, event_id: str, item_id: str) -> None:
        try:
            self.sync_item(item_id)
        finally:
            self.repository.mark_webhook_processed(event_id)


@lru_cache(maxsize=1)
def get_bank_service() -> BankService:
    return BankService(BankRepository(BANK_DB_PATH))
