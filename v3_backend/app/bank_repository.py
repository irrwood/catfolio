"""Local SQLite repository for connected bank accounts and transactions."""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from .settings import V2_DIR


BANK_DB_PATH = V2_DIR / "banking.db"


class BankRepository:
    """Small repository whose sync writes and cursor advance are atomic."""

    def __init__(self, path: Path | str = BANK_DB_PATH) -> None:
        self.path = Path(path)
        self._initialize()

    @contextmanager
    def _connection(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(str(self.path), timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 10000")
        try:
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self._connection() as connection:
            connection.executescript(
                """
                PRAGMA journal_mode = WAL;

                CREATE TABLE IF NOT EXISTS bank_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS bank_items (
                    item_id TEXT PRIMARY KEY,
                    provider TEXT NOT NULL DEFAULT 'plaid',
                    institution_id TEXT,
                    institution_name TEXT,
                    access_token_encrypted TEXT NOT NULL,
                    access_token_nonce TEXT NOT NULL,
                    transaction_cursor TEXT,
                    connection_status TEXT NOT NULL DEFAULT 'good',
                    error_code TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    last_synced_at INTEGER
                );

                CREATE TABLE IF NOT EXISTS bank_accounts (
                    account_id TEXT PRIMARY KEY,
                    item_id TEXT NOT NULL REFERENCES bank_items(item_id) ON DELETE CASCADE,
                    provider TEXT NOT NULL DEFAULT 'plaid',
                    name TEXT NOT NULL,
                    official_name TEXT,
                    type TEXT NOT NULL,
                    subtype TEXT,
                    mask TEXT,
                    current_balance REAL,
                    available_balance REAL,
                    credit_limit REAL,
                    currency TEXT NOT NULL DEFAULT 'GBP',
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );

                CREATE INDEX IF NOT EXISTS bank_accounts_item_idx
                    ON bank_accounts(item_id);

                CREATE TABLE IF NOT EXISTS bank_transactions (
                    transaction_id TEXT PRIMARY KEY,
                    item_id TEXT NOT NULL REFERENCES bank_items(item_id) ON DELETE CASCADE,
                    account_id TEXT NOT NULL REFERENCES bank_accounts(account_id) ON DELETE CASCADE,
                    provider TEXT NOT NULL DEFAULT 'plaid',
                    date TEXT NOT NULL,
                    authorized_date TEXT,
                    merchant TEXT NOT NULL,
                    amount REAL NOT NULL,
                    currency TEXT NOT NULL DEFAULT 'GBP',
                    category TEXT,
                    category_detail TEXT,
                    pending INTEGER NOT NULL DEFAULT 0,
                    pending_transaction_id TEXT,
                    payment_channel TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    removed_at INTEGER
                );

                CREATE INDEX IF NOT EXISTS bank_transactions_date_account_idx
                    ON bank_transactions(date, account_id);
                CREATE INDEX IF NOT EXISTS bank_transactions_merchant_idx
                    ON bank_transactions(merchant);
                CREATE INDEX IF NOT EXISTS bank_transactions_category_idx
                    ON bank_transactions(category);

                CREATE TABLE IF NOT EXISTS bank_sync_log (
                    sync_id TEXT PRIMARY KEY,
                    item_id TEXT NOT NULL REFERENCES bank_items(item_id) ON DELETE CASCADE,
                    added_count INTEGER NOT NULL DEFAULT 0,
                    modified_count INTEGER NOT NULL DEFAULT 0,
                    removed_count INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL,
                    error_message TEXT,
                    synced_at INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS bank_webhook_events (
                    event_id TEXT PRIMARY KEY,
                    item_id TEXT,
                    webhook_type TEXT NOT NULL,
                    webhook_code TEXT NOT NULL,
                    received_at INTEGER NOT NULL,
                    processed_at INTEGER
                );
                """
            )
            connection.execute("PRAGMA user_version = 1")

    def local_user_id(self) -> str:
        with self._connection() as connection:
            row = connection.execute(
                "SELECT value FROM bank_meta WHERE key = 'local_user_id'"
            ).fetchone()
            if row:
                return str(row["value"])
            value = str(uuid.uuid4())
            connection.execute(
                "INSERT INTO bank_meta (key, value) VALUES ('local_user_id', ?)",
                (value,),
            )
            return value

    def save_item(
        self,
        item_id: str,
        encrypted_token: str,
        token_nonce: str,
        institution_id: str | None = None,
        institution_name: str | None = None,
    ) -> None:
        now = int(time.time())
        with self._connection() as connection:
            connection.execute(
                """
                INSERT INTO bank_items (
                    item_id, provider, institution_id, institution_name,
                    access_token_encrypted, access_token_nonce,
                    connection_status, created_at, updated_at
                ) VALUES (?, 'plaid', ?, ?, ?, ?, 'good', ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET
                    institution_id = excluded.institution_id,
                    institution_name = excluded.institution_name,
                    access_token_encrypted = excluded.access_token_encrypted,
                    access_token_nonce = excluded.access_token_nonce,
                    connection_status = 'good',
                    error_code = NULL,
                    updated_at = excluded.updated_at
                """,
                (
                    item_id,
                    institution_id,
                    institution_name,
                    encrypted_token,
                    token_nonce,
                    now,
                    now,
                ),
            )

    def get_item(self, item_id: str) -> dict | None:
        with self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM bank_items WHERE item_id = ?", (item_id,)
            ).fetchone()
        return dict(row) if row else None

    def list_items(self) -> list[dict]:
        with self._connection() as connection:
            rows = connection.execute(
                "SELECT * FROM bank_items ORDER BY created_at"
            ).fetchall()
        return [dict(row) for row in rows]

    def has_connections(self) -> bool:
        with self._connection() as connection:
            row = connection.execute("SELECT 1 FROM bank_items LIMIT 1").fetchone()
        return row is not None

    def apply_sync(
        self,
        item_id: str,
        accounts: list[dict],
        added: list[dict],
        modified: list[dict],
        removed: list[str],
        next_cursor: str,
    ) -> dict:
        """Apply a complete Plaid diff and advance its cursor in one transaction."""
        now = int(time.time())
        with self._connection() as connection:
            if not connection.execute(
                "SELECT 1 FROM bank_items WHERE item_id = ?", (item_id,)
            ).fetchone():
                raise KeyError(f"Unknown bank item: {item_id}")

            for account in accounts:
                connection.execute(
                    """
                    INSERT INTO bank_accounts (
                        account_id, item_id, provider, name, official_name, type,
                        subtype, mask, current_balance, available_balance,
                        credit_limit, currency, created_at, updated_at
                    ) VALUES (?, ?, 'plaid', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        item_id = excluded.item_id,
                        name = excluded.name,
                        official_name = excluded.official_name,
                        type = excluded.type,
                        subtype = excluded.subtype,
                        mask = excluded.mask,
                        current_balance = excluded.current_balance,
                        available_balance = excluded.available_balance,
                        credit_limit = excluded.credit_limit,
                        currency = excluded.currency,
                        updated_at = excluded.updated_at
                    """,
                    (
                        account["id"],
                        item_id,
                        account["name"],
                        account.get("official_name"),
                        account.get("type") or "other",
                        account.get("subtype"),
                        account.get("mask"),
                        account.get("current_balance"),
                        account.get("available_balance"),
                        account.get("credit_limit"),
                        account.get("currency") or "GBP",
                        now,
                        now,
                    ),
                )

            for transaction in [*added, *modified]:
                connection.execute(
                    """
                    INSERT INTO bank_transactions (
                        transaction_id, item_id, account_id, provider, date,
                        authorized_date, merchant, amount, currency, category,
                        category_detail, pending, pending_transaction_id,
                        payment_channel, created_at, updated_at, removed_at
                    ) VALUES (?, ?, ?, 'plaid', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(transaction_id) DO UPDATE SET
                        item_id = excluded.item_id,
                        account_id = excluded.account_id,
                        date = excluded.date,
                        authorized_date = excluded.authorized_date,
                        merchant = excluded.merchant,
                        amount = excluded.amount,
                        currency = excluded.currency,
                        category = excluded.category,
                        category_detail = excluded.category_detail,
                        pending = excluded.pending,
                        pending_transaction_id = excluded.pending_transaction_id,
                        payment_channel = excluded.payment_channel,
                        updated_at = excluded.updated_at,
                        removed_at = NULL
                    """,
                    (
                        transaction["id"],
                        item_id,
                        transaction["account_id"],
                        transaction["date"],
                        transaction.get("authorized_date"),
                        transaction["merchant"],
                        float(transaction["amount"]),
                        transaction.get("currency") or "GBP",
                        transaction.get("category"),
                        transaction.get("category_detail"),
                        int(bool(transaction.get("pending"))),
                        transaction.get("pending_transaction_id"),
                        transaction.get("payment_channel"),
                        now,
                        now,
                    ),
                )

            if removed:
                connection.executemany(
                    """
                    UPDATE bank_transactions
                    SET removed_at = ?, updated_at = ?
                    WHERE transaction_id = ? AND item_id = ?
                    """,
                    [(now, now, transaction_id, item_id) for transaction_id in removed],
                )

            connection.execute(
                """
                UPDATE bank_items
                SET transaction_cursor = ?, last_synced_at = ?, updated_at = ?,
                    connection_status = 'good', error_code = NULL
                WHERE item_id = ?
                """,
                (next_cursor, now, now, item_id),
            )
            connection.execute(
                """
                INSERT INTO bank_sync_log (
                    sync_id, item_id, added_count, modified_count,
                    removed_count, status, synced_at
                ) VALUES (?, ?, ?, ?, ?, 'success', ?)
                """,
                (
                    str(uuid.uuid4()),
                    item_id,
                    len(added),
                    len(modified),
                    len(removed),
                    now,
                ),
            )
        return {
            "item_id": item_id,
            "added": len(added),
            "modified": len(modified),
            "removed": len(removed),
            "status": "success",
        }

    def record_sync_error(
        self, item_id: str, message: str, error_code: str | None = None
    ) -> None:
        now = int(time.time())
        safe_message = str(message)[:500]
        with self._connection() as connection:
            connection.execute(
                """
                UPDATE bank_items
                SET connection_status = 'error', error_code = ?, updated_at = ?
                WHERE item_id = ?
                """,
                (error_code, now, item_id),
            )
            connection.execute(
                """
                INSERT INTO bank_sync_log (
                    sync_id, item_id, status, error_message, synced_at
                ) VALUES (?, ?, 'error', ?, ?)
                """,
                (str(uuid.uuid4()), item_id, safe_message, now),
            )

    def list_accounts(self) -> list[dict]:
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT account_id AS id, item_id, name, official_name, type,
                       subtype, mask, current_balance, available_balance,
                       credit_limit, currency
                FROM bank_accounts
                ORDER BY current_balance DESC, name
                """
            ).fetchall()
        return [dict(row) for row in rows]

    def list_transactions(self, limit: int = 5000) -> list[dict]:
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT t.transaction_id AS id, t.item_id, t.account_id, t.date,
                       t.authorized_date, t.merchant, t.amount, t.currency,
                       t.category, t.category_detail, t.pending,
                       t.pending_transaction_id, t.payment_channel,
                       a.name AS account
                FROM bank_transactions t
                JOIN bank_accounts a ON a.account_id = t.account_id
                WHERE t.removed_at IS NULL
                ORDER BY t.date DESC, t.transaction_id
                LIMIT ?
                """,
                (max(1, min(int(limit), 20000)),),
            ).fetchall()
        return [dict(row) for row in rows]

    def record_webhook(
        self, item_id: str | None, webhook_type: str, webhook_code: str
    ) -> str:
        event_id = str(uuid.uuid4())
        with self._connection() as connection:
            connection.execute(
                """
                INSERT INTO bank_webhook_events (
                    event_id, item_id, webhook_type, webhook_code, received_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    event_id,
                    item_id,
                    webhook_type[:80],
                    webhook_code[:80],
                    int(time.time()),
                ),
            )
        return event_id

    def mark_webhook_processed(self, event_id: str) -> None:
        with self._connection() as connection:
            connection.execute(
                "UPDATE bank_webhook_events SET processed_at = ? WHERE event_id = ?",
                (int(time.time()), event_id),
            )

    def delete_item(self, item_id: str) -> bool:
        with self._connection() as connection:
            cursor = connection.execute(
                "DELETE FROM bank_items WHERE item_id = ?", (item_id,)
            )
        return cursor.rowcount > 0

    def latest_sync_age_seconds(self) -> int | None:
        with self._connection() as connection:
            row = connection.execute(
                "SELECT MIN(last_synced_at) AS oldest FROM bank_items"
            ).fetchone()
        if not row or row["oldest"] is None:
            return None
        return max(0, int(time.time()) - int(row["oldest"]))

    def export_debug_summary(self) -> str:
        """Return non-sensitive diagnostics; useful without exposing bank data."""
        with self._connection() as connection:
            counts = {
                "items": connection.execute(
                    "SELECT COUNT(*) FROM bank_items"
                ).fetchone()[0],
                "accounts": connection.execute(
                    "SELECT COUNT(*) FROM bank_accounts"
                ).fetchone()[0],
                "transactions": connection.execute(
                    "SELECT COUNT(*) FROM bank_transactions WHERE removed_at IS NULL"
                ).fetchone()[0],
            }
        return json.dumps(counts, sort_keys=True)
