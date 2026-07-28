from datetime import datetime, timezone
import sqlite3
from types import SimpleNamespace


def _message(uid="42"):
    return SimpleNamespace(
        uid=uid,
        subject="Your journey was delayed by 47 minutes",
        from_="updates@avantiwestcoast.co.uk",
        from_values=SimpleNamespace(
            name="Avanti West Coast",
            email="updates@avantiwestcoast.co.uk",
        ),
        date=datetime(2026, 7, 19, 12, 0, tzinfo=timezone.utc),
        text="Your train was delayed. You may claim compensation of £34.50.",
        html="",
        headers={"message-id": ("<message-42@example.com>",)},
    )


def test_mail_analysis_keeps_only_structured_opportunity():
    from app.mail_analysis import analyse_message

    item = analyse_message(_message(), account_id="account-1")

    assert item["kind"] == "train_delay"
    assert item["merchant"] == "Avanti West Coast"
    assert item["estimated_amount"] == 34.50
    assert item["currency"] == "GBP"
    assert "text" not in item
    assert "html" not in item


def test_mail_repository_persists_cursor_without_raw_body(tmp_path):
    from app.mail_repository import MailRepository

    repository = MailRepository(tmp_path / "mail.db")
    account = repository.save_account(
        provider="gmail",
        email="person@example.com",
        username="person@example.com",
        host="imap.gmail.com",
        port=993,
        auth_type="password",
    )
    repository.save_sync(
        account["account_id"],
        uidvalidity=123,
        last_uid=42,
        opportunities=[
            {
                "id": f'{account["account_id"]}:42',
                "uid": "42",
                "message_id": "<message-42@example.com>",
                "merchant": "Avanti West Coast",
                "kind": "train_delay",
                "subject": "Your journey was delayed",
                "event_date": "2026-07-19",
                "estimated_amount": 34.5,
                "currency": "GBP",
                "confidence": 0.92,
                "deadline": "Review eligibility",
                "evidence": "Train delay notice found",
            }
        ],
    )

    stored = repository.get_account(account["account_id"])
    opportunity = repository.list_opportunities()[0]
    assert stored["uidvalidity"] == 123
    assert stored["last_uid"] == 42
    assert opportunity["subject"] == "Your journey was delayed"
    with sqlite3.connect(repository.path) as connection:
        columns = {
            row[1]
            for row in connection.execute(
                "PRAGMA table_info(mail_opportunities)"
            ).fetchall()
        }
    assert "body" not in columns
    assert "raw_message" not in columns


def test_imap_adapter_uses_readonly_and_never_marks_seen(monkeypatch):
    from app.imap_mail_adapter import ImapMailAdapter

    calls = []

    class Folder:
        def set(self, name, readonly=False):
            calls.append(("folder.set", name, readonly))

        def status(self, name, options):
            return {"UIDVALIDITY": 123, "UIDNEXT": 43}

    class FakeMailbox:
        def __init__(self, host, **kwargs):
            calls.append(("open", host, kwargs["port"]))
            self.folder = Folder()

        def login(self, username, credential, initial_folder=None):
            calls.append(("login", username, credential, initial_folder))

        def uids(self, criteria):
            calls.append(("uids", criteria))
            return ["42"]

        def fetch(self, **kwargs):
            calls.append(("fetch", kwargs))
            return iter([_message()])

        def logout(self):
            calls.append(("logout",))

    monkeypatch.setattr(
        ImapMailAdapter, "_mailbox_class", staticmethod(lambda: FakeMailbox)
    )
    result = ImapMailAdapter().sync(
        {
            "account_id": "account-1",
            "host": "imap.gmail.com",
            "port": 993,
            "username": "person@example.com",
            "auth_type": "password",
            "mailbox": "INBOX",
            "uidvalidity": 123,
            "last_uid": 41,
        },
        "app-password",
    )

    assert ("folder.set", "INBOX", True) in calls
    fetches = [call[1] for call in calls if call[0] == "fetch"]
    assert fetches
    assert all(item["mark_seen"] is False for item in fetches)
    assert result["checked"] == 1
    assert result["last_uid"] == 42
    assert result["opportunities"][0]["kind"] == "train_delay"


def test_mail_service_saves_secret_only_after_connection_test(monkeypatch, tmp_path):
    from app import data_store
    from app.mail_repository import MailRepository
    from app.mail_service import MailService, credential_key

    monkeypatch.setattr(data_store, "demo_mode", lambda: False)
    monkeypatch.setattr(data_store, "public_demo_mode", lambda: False)
    saved = {}
    monkeypatch.setattr(
        data_store, "save_secret", lambda name, value: not saved.update({name: value})
    )

    class Adapter:
        def test_connection(self, account, credential):
            assert account["host"] == "imap.gmail.com"
            assert credential == "app-password"
            return {"uidvalidity": 1}

    repository = MailRepository(tmp_path / "mail.db")
    service = MailService(repository, adapter=Adapter())
    result = service.connect(
        provider="gmail",
        email="person@example.com",
        credential="app-password",
    )

    assert result["storage"] == "keychain"
    assert saved[credential_key(result["account_id"])] == "app-password"
    assert "app-password" not in str(repository.list_accounts())
