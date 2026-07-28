"""Direct IMAP transport backed by the Apache-2.0 imap-tools project."""

from __future__ import annotations

import ssl
from datetime import date, timedelta

from .mail_analysis import analyse_message, is_candidate


class MailConfigurationError(ValueError):
    pass


class MailConnectionError(RuntimeError):
    pass


PROVIDER_DEFAULTS = {
    "gmail": ("imap.gmail.com", 993),
    "outlook": ("outlook.office365.com", 993),
}


def provider_settings(provider: str, host: str = "", port: int = 993) -> tuple[str, int]:
    provider = (provider or "imap").strip().lower()
    if provider in PROVIDER_DEFAULTS:
        return PROVIDER_DEFAULTS[provider]
    host = host.strip().lower()
    if not host or "://" in host or "/" in host or any(ch.isspace() for ch in host):
        raise MailConfigurationError("请输入有效的 IMAP 服务器域名。")
    if not 1 <= int(port) <= 65535:
        raise MailConfigurationError("IMAP 端口无效。")
    return host, int(port)


class ImapMailAdapter:
    """Read-only IMAP sync; it never flags, moves, deletes, or sends mail."""

    def __init__(self, timeout: int = 20) -> None:
        self.timeout = timeout

    @staticmethod
    def _mailbox_class():
        try:
            from imap_tools import MailBox
        except ImportError as exc:
            raise MailConfigurationError(
                "缺少 imap-tools 依赖，请重新安装 Catfolio 依赖。"
            ) from exc
        return MailBox

    def _open(self, account: dict, credential: str):
        context = ssl.create_default_context()
        mailbox = self._mailbox_class()(
            account["host"],
            port=int(account["port"]),
            timeout=self.timeout,
            ssl_context=context,
        )
        try:
            if account["auth_type"] == "oauth2":
                mailbox.xoauth2(account["username"], credential, initial_folder=None)
            else:
                mailbox.login(account["username"], credential, initial_folder=None)
            mailbox.folder.set(account.get("mailbox") or "INBOX", readonly=True)
            return mailbox
        except Exception:
            try:
                mailbox.logout()
            except Exception:
                pass
            raise

    def test_connection(self, account: dict, credential: str) -> dict:
        try:
            mailbox = self._open(account, credential)
            status = mailbox.folder.status(
                account.get("mailbox") or "INBOX",
                options=("UIDVALIDITY", "UIDNEXT"),
            )
            mailbox.logout()
            return {
                "uidvalidity": int(status.get("UIDVALIDITY") or 0),
                "uidnext": int(status.get("UIDNEXT") or 0),
            }
        except Exception as exc:
            raise MailConnectionError(
                "IMAP 登录失败，请检查邮箱、应用专用密码或 OAuth Token。"
            ) from exc

    def sync(self, account: dict, credential: str) -> dict:
        try:
            mailbox = self._open(account, credential)
            folder = account.get("mailbox") or "INBOX"
            status = mailbox.folder.status(
                folder, options=("UIDVALIDITY", "UIDNEXT")
            )
            uidvalidity = int(status.get("UIDVALIDITY") or 0)
            same_mailbox = uidvalidity == int(account.get("uidvalidity") or 0)
            last_uid = int(account.get("last_uid") or 0) if same_mailbox else 0
            criteria = (
                f"UID {last_uid + 1}:*"
                if last_uid
                else f'SINCE {(date.today() - timedelta(days=90)).strftime("%d-%b-%Y")}'
            )
            uids = mailbox.uids(criteria)
            # Bound first sync so a large mailbox cannot consume unbounded memory.
            uids = uids[-300:]
            headers = list(
                mailbox.fetch(
                    mark_seen=False,
                    headers_only=True,
                    bulk=25,
                    uid_list=uids,
                )
            )
            candidate_uids = [
                str(message.uid)
                for message in headers
                if is_candidate(message.subject, message.from_)
            ]
            opportunities = []
            if candidate_uids:
                for message in mailbox.fetch(
                    mark_seen=False,
                    headers_only=False,
                    bulk=10,
                    uid_list=candidate_uids,
                ):
                    item = analyse_message(message, account_id=account["account_id"])
                    if item:
                        opportunities.append(item)
            mailbox.logout()
            max_uid = max([last_uid, *[int(uid) for uid in uids if str(uid).isdigit()]])
            return {
                "uidvalidity": uidvalidity,
                "last_uid": max_uid,
                "checked": len(uids),
                "downloaded": len(candidate_uids),
                "opportunities": opportunities,
            }
        except MailConnectionError:
            raise
        except Exception as exc:
            raise MailConnectionError(
                "邮箱同步失败；Catfolio 保留了上次的本地结果。"
            ) from exc
