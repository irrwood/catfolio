"""Local-first orchestration for direct IMAP email analysis."""

from __future__ import annotations

import hashlib
from functools import lru_cache

from . import data_store
from .imap_mail_adapter import ImapMailAdapter, provider_settings
from .mail_repository import MAIL_DB_PATH, MailRepository


class MailSecretError(RuntimeError):
    pass


def credential_key(account_id: str) -> str:
    digest = hashlib.sha256(account_id.encode("utf-8")).hexdigest()[:24].upper()
    return f"CATFOLIO_MAIL_CREDENTIAL_{digest}"


class MailService:
    def __init__(
        self,
        repository: MailRepository,
        adapter: ImapMailAdapter | None = None,
    ) -> None:
        self.repository = repository
        self.adapter = adapter or ImapMailAdapter()

    @staticmethod
    def _require_real_mode() -> None:
        if data_store.demo_mode() or data_store.public_demo_mode():
            raise PermissionError("演示模式不会连接或读取真实邮箱。")

    def status(self) -> dict:
        if data_store.demo_mode() or data_store.public_demo_mode():
            return {"connected": False, "source": "demo", "accounts": []}
        accounts = self.repository.list_accounts()
        return {
            "connected": bool(accounts),
            "source": "imap",
            "accounts": [
                {
                    "account_id": item["account_id"],
                    "provider": item["provider"],
                    "email": item["email"],
                    "connection_status": item["connection_status"],
                    "last_synced_at": item.get("last_synced_at"),
                }
                for item in accounts
            ],
        }

    def connect(
        self,
        *,
        provider: str,
        email: str,
        credential: str,
        auth_type: str = "password",
        username: str = "",
        host: str = "",
        port: int = 993,
    ) -> dict:
        self._require_real_mode()
        provider = (provider or "imap").strip().lower()
        email = email.strip()
        username = username.strip() or email
        auth_type = auth_type.strip().lower()
        if "@" not in email or len(email) > 254:
            raise ValueError("请输入有效的邮箱地址。")
        if auth_type not in {"password", "oauth2"}:
            raise ValueError("不支持的邮箱认证方式。")
        if not credential:
            raise ValueError("请输入应用专用密码或 OAuth Token。")
        host, port = provider_settings(provider, host, int(port))
        provisional = {
            "account_id": "connection-test",
            "provider": provider,
            "email": email,
            "username": username,
            "host": host,
            "port": port,
            "auth_type": auth_type,
            "mailbox": "INBOX",
        }
        self.adapter.test_connection(provisional, credential)
        existing = next(
            (
                item
                for item in self.repository.list_accounts()
                if item["provider"] == provider and item["email"] == email
            ),
            None,
        )
        account = self.repository.save_account(
            provider=provider,
            email=email,
            username=username,
            host=host,
            port=port,
            auth_type=auth_type,
        )
        if not data_store.save_secret(credential_key(account["account_id"]), credential):
            if existing is None:
                self.repository.delete_account(account["account_id"])
            raise MailSecretError("邮箱凭证无法写入系统 Keychain。")
        return {
            "account_id": account["account_id"],
            "provider": provider,
            "email": email,
            "storage": "keychain",
        }

    def sync_all(self) -> dict:
        self._require_real_mode()
        accounts = self.repository.list_accounts()
        if not accounts:
            raise ValueError("请先连接邮箱。")
        checked = downloaded = 0
        for account in accounts:
            secret = data_store.secret_value(credential_key(account["account_id"]))
            if not secret:
                self.repository.record_error(account["account_id"], "Keychain credential missing")
                continue
            try:
                result = self.adapter.sync(account, secret)
                self.repository.save_sync(
                    account["account_id"],
                    uidvalidity=result["uidvalidity"],
                    last_uid=result["last_uid"],
                    opportunities=result["opportunities"],
                )
                checked += result["checked"]
                downloaded += result["downloaded"]
            except Exception as exc:
                self.repository.record_error(account["account_id"], str(exc))
                raise
        items = self.repository.list_opportunities()
        return {
            "ok": True,
            "source": "imap",
            "checked": checked,
            "downloaded": downloaded,
            "count": len(items),
            "items": items,
        }

    def remove(self, account_id: str) -> bool:
        self._require_real_mode()
        account = self.repository.get_account(account_id)
        if not account:
            return False
        data_store.delete_secret(credential_key(account_id))
        return self.repository.delete_account(account_id)


@lru_cache(maxsize=1)
def get_mail_service() -> MailService:
    return MailService(MailRepository(MAIL_DB_PATH))
