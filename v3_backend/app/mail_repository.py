"""Local SQLite state for direct, read-only IMAP connections."""

from __future__ import annotations

import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from .settings import V2_DIR


MAIL_DB_PATH = V2_DIR / "mail.db"


class MailRepository:
    def __init__(self, path: Path | str = MAIL_DB_PATH) -> None:
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

                CREATE TABLE IF NOT EXISTS mail_accounts (
                    account_id TEXT PRIMARY KEY,
                    provider TEXT NOT NULL,
                    email TEXT NOT NULL,
                    username TEXT NOT NULL,
                    host TEXT NOT NULL,
                    port INTEGER NOT NULL DEFAULT 993,
                    auth_type TEXT NOT NULL,
                    mailbox TEXT NOT NULL DEFAULT 'INBOX',
                    uidvalidity INTEGER,
                    last_uid INTEGER NOT NULL DEFAULT 0,
                    connection_status TEXT NOT NULL DEFAULT 'good',
                    error_message TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    last_synced_at INTEGER
                );

                CREATE UNIQUE INDEX IF NOT EXISTS mail_accounts_email_idx
                    ON mail_accounts(provider, email);

                CREATE TABLE IF NOT EXISTS mail_opportunities (
                    opportunity_id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL
                        REFERENCES mail_accounts(account_id) ON DELETE CASCADE,
                    uid TEXT NOT NULL,
                    message_id TEXT,
                    merchant TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    subject TEXT NOT NULL,
                    event_date TEXT NOT NULL,
                    estimated_amount REAL NOT NULL DEFAULT 0,
                    currency TEXT NOT NULL DEFAULT 'GBP',
                    confidence REAL NOT NULL,
                    deadline TEXT,
                    evidence TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE(account_id, uid)
                );
                """
            )

    def save_account(
        self,
        *,
        provider: str,
        email: str,
        username: str,
        host: str,
        port: int,
        auth_type: str,
        mailbox: str = "INBOX",
        account_id: str | None = None,
    ) -> dict:
        account_id = account_id or str(uuid.uuid4())
        now = int(time.time())
        with self._connection() as connection:
            connection.execute(
                """
                INSERT INTO mail_accounts (
                    account_id, provider, email, username, host, port,
                    auth_type, mailbox, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, email) DO UPDATE SET
                    username = excluded.username,
                    host = excluded.host,
                    port = excluded.port,
                    auth_type = excluded.auth_type,
                    mailbox = excluded.mailbox,
                    connection_status = 'good',
                    error_message = NULL,
                    updated_at = excluded.updated_at
                """,
                (
                    account_id,
                    provider,
                    email,
                    username,
                    host,
                    int(port),
                    auth_type,
                    mailbox,
                    now,
                    now,
                ),
            )
            row = connection.execute(
                "SELECT * FROM mail_accounts WHERE provider = ? AND email = ?",
                (provider, email),
            ).fetchone()
        return dict(row)

    def get_account(self, account_id: str) -> dict | None:
        with self._connection() as connection:
            row = connection.execute(
                "SELECT * FROM mail_accounts WHERE account_id = ?", (account_id,)
            ).fetchone()
        return dict(row) if row else None

    def list_accounts(self) -> list[dict]:
        with self._connection() as connection:
            rows = connection.execute(
                "SELECT * FROM mail_accounts ORDER BY created_at"
            ).fetchall()
        return [dict(row) for row in rows]

    def has_connections(self) -> bool:
        with self._connection() as connection:
            row = connection.execute(
                "SELECT 1 FROM mail_accounts LIMIT 1"
            ).fetchone()
        return row is not None

    def save_sync(
        self,
        account_id: str,
        *,
        uidvalidity: int,
        last_uid: int,
        opportunities: list[dict],
    ) -> None:
        now = int(time.time())
        with self._connection() as connection:
            for item in opportunities:
                connection.execute(
                    """
                    INSERT INTO mail_opportunities (
                        opportunity_id, account_id, uid, message_id, merchant,
                        kind, subject, event_date, estimated_amount, currency,
                        confidence, deadline, evidence, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id, uid) DO UPDATE SET
                        message_id = excluded.message_id,
                        merchant = excluded.merchant,
                        kind = excluded.kind,
                        subject = excluded.subject,
                        event_date = excluded.event_date,
                        estimated_amount = excluded.estimated_amount,
                        currency = excluded.currency,
                        confidence = excluded.confidence,
                        deadline = excluded.deadline,
                        evidence = excluded.evidence,
                        updated_at = excluded.updated_at
                    """,
                    (
                        item["id"],
                        account_id,
                        item["uid"],
                        item.get("message_id"),
                        item["merchant"],
                        item["kind"],
                        item["subject"],
                        item["event_date"],
                        float(item.get("estimated_amount") or 0),
                        item.get("currency") or "GBP",
                        float(item["confidence"]),
                        item.get("deadline"),
                        item["evidence"],
                        now,
                        now,
                    ),
                )
            connection.execute(
                """
                UPDATE mail_accounts
                SET uidvalidity = ?, last_uid = ?, last_synced_at = ?,
                    connection_status = 'good', error_message = NULL,
                    updated_at = ?
                WHERE account_id = ?
                """,
                (uidvalidity, last_uid, now, now, account_id),
            )

    def record_error(self, account_id: str, message: str) -> None:
        with self._connection() as connection:
            connection.execute(
                """
                UPDATE mail_accounts
                SET connection_status = 'error', error_message = ?, updated_at = ?
                WHERE account_id = ?
                """,
                (str(message)[:300], int(time.time()), account_id),
            )

    def list_opportunities(self, limit: int = 100) -> list[dict]:
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT opportunity_id AS id, merchant, kind, subject,
                       event_date, estimated_amount, currency, confidence,
                       deadline, evidence
                FROM mail_opportunities
                ORDER BY event_date DESC, updated_at DESC
                LIMIT ?
                """,
                (max(1, min(int(limit), 500)),),
            ).fetchall()
        return [dict(row) for row in rows]

    def delete_account(self, account_id: str) -> bool:
        with self._connection() as connection:
            cursor = connection.execute(
                "DELETE FROM mail_accounts WHERE account_id = ?", (account_id,)
            )
        return cursor.rowcount > 0
