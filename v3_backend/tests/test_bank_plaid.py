from datetime import date
import base64
import hashlib
import json
import time

import pytest


def _fixed_cipher():
    from app.bank_crypto import TokenCipher

    key = "11" * 32
    return TokenCipher(key_reader=lambda _name: key, key_writer=lambda _name, _value: False)


def test_bank_token_cipher_round_trip_and_authentication():
    from app.bank_crypto import TokenEncryptionError

    cipher = _fixed_cipher()
    encrypted, nonce = cipher.encrypt("access-sandbox-sensitive")

    assert "access-sandbox-sensitive" not in encrypted
    assert cipher.decrypt(encrypted, nonce) == "access-sandbox-sensitive"

    tampered = encrypted[:-2] + ("AA" if encrypted[-2:] != "AA" else "BB")
    with pytest.raises(TokenEncryptionError):
        cipher.decrypt(tampered, nonce)


def test_bank_repository_applies_diff_and_cursor_atomically(tmp_path):
    from app.bank_repository import BankRepository

    repository = BankRepository(tmp_path / "banking.db")
    repository.save_item("item-1", "encrypted-value", "nonce-value", "ins-1", "Test Bank")

    result = repository.apply_sync(
        item_id="item-1",
        accounts=[
            {
                "id": "account-1",
                "name": "Current",
                "type": "depository",
                "subtype": "checking",
                "current_balance": 1000,
                "available_balance": 900,
                "currency": "GBP",
            }
        ],
        added=[
            {
                "id": "tx-1",
                "account_id": "account-1",
                "date": "2026-07-01",
                "merchant": "Example",
                "amount": -12.5,
                "currency": "GBP",
                "category": "GENERAL_MERCHANDISE",
            }
        ],
        modified=[],
        removed=[],
        next_cursor="cursor-1",
    )

    assert result == {
        "item_id": "item-1",
        "added": 1,
        "modified": 0,
        "removed": 0,
        "status": "success",
    }
    assert repository.get_item("item-1")["transaction_cursor"] == "cursor-1"
    assert repository.list_transactions()[0]["amount"] == -12.5

    repository.apply_sync(
        item_id="item-1",
        accounts=repository.list_accounts(),
        added=[],
        modified=[
            {
                "id": "tx-1",
                "account_id": "account-1",
                "date": "2026-07-02",
                "merchant": "Example Updated",
                "amount": -10,
                "currency": "GBP",
            }
        ],
        removed=[],
        next_cursor="cursor-2",
    )
    assert repository.list_transactions()[0]["merchant"] == "Example Updated"

    repository.apply_sync(
        item_id="item-1",
        accounts=repository.list_accounts(),
        added=[],
        modified=[],
        removed=["tx-1"],
        next_cursor="cursor-3",
    )
    assert repository.list_transactions() == []
    assert repository.get_item("item-1")["transaction_cursor"] == "cursor-3"


def test_python_plaid_adapter_encrypts_token_and_normalizes_amount(tmp_path):
    from app.bank_repository import BankRepository
    from app.plaid_adapter import PlaidAdapter, PlaidConfig

    repository = BankRepository(tmp_path / "banking.db")
    calls = []

    def transport(path, payload):
        calls.append((path, payload))
        if path == "/item/public_token/exchange":
            return {"access_token": "access-secret", "item_id": "item-1"}
        if path == "/accounts/get":
            return {
                "accounts": [
                    {
                        "account_id": "account-1",
                        "name": "Current",
                        "type": "depository",
                        "subtype": "checking",
                        "mask": "1234",
                        "balances": {
                            "current": 1000,
                            "available": 950,
                            "iso_currency_code": "GBP",
                        },
                    }
                ]
            }
        if path == "/transactions/sync":
            return {
                "added": [
                    {
                        "transaction_id": "tx-1",
                        "account_id": "account-1",
                        "date": "2026-07-01",
                        "name": "CARD PAYMENT",
                        "merchant_name": "Coffee Shop",
                        "amount": 4.5,
                        "iso_currency_code": "GBP",
                        "pending": False,
                        "personal_finance_category": {
                            "primary": "FOOD_AND_DRINK",
                            "detailed": "FOOD_AND_DRINK_COFFEE",
                        },
                    }
                ],
                "modified": [],
                "removed": [],
                "has_more": False,
                "next_cursor": "cursor-1",
            }
        raise AssertionError(path)

    adapter = PlaidAdapter(
        repository=repository,
        cipher=_fixed_cipher(),
        config=PlaidConfig(client_id="client", secret="secret"),
        transport=transport,
    )
    result = adapter.exchange_public_token(
        "public-token",
        {"institution": {"institution_id": "ins-1", "name": "Test Bank"}},
    )

    stored_item = repository.get_item("item-1")
    transaction = repository.list_transactions()[0]
    assert result["sync"]["added"] == 1
    assert "access-secret" not in stored_item["access_token_encrypted"]
    assert transaction["merchant"] == "Coffee Shop"
    assert transaction["amount"] == -4.5
    assert transaction["category"] == "FOOD_AND_DRINK"
    assert [path for path, _payload in calls] == [
        "/item/public_token/exchange",
        "/accounts/get",
        "/transactions/sync",
    ]


def test_plaid_webhook_signature_and_body_hash_are_verified(tmp_path):
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import (
        decode_dss_signature,
    )

    from app.bank_repository import BankRepository
    from app.plaid_adapter import (
        PlaidAdapter,
        PlaidConfig,
        PlaidWebhookVerificationError,
    )

    def encoded(value: bytes) -> str:
        return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")

    private_key = ec.generate_private_key(ec.SECP256R1())
    public_numbers = private_key.public_key().public_numbers()
    raw_body = b'{"webhook_type":"TRANSACTIONS","webhook_code":"SYNC_UPDATES_AVAILABLE"}'
    header = encoded(json.dumps({"alg": "ES256", "kid": "key-1"}).encode())
    claims = encoded(
        json.dumps(
            {
                "iat": int(time.time()),
                "request_body_sha256": hashlib.sha256(raw_body).hexdigest(),
            }
        ).encode()
    )
    signing_input = f"{header}.{claims}".encode("ascii")
    der_signature = private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der_signature)
    signature = encoded(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
    signed_jwt = f"{header}.{claims}.{signature}"

    def transport(path, payload):
        assert path == "/webhook_verification_key/get"
        assert payload == {"key_id": "key-1"}
        return {
            "key": {
                "alg": "ES256",
                "crv": "P-256",
                "x": encoded(public_numbers.x.to_bytes(32, "big")),
                "y": encoded(public_numbers.y.to_bytes(32, "big")),
            }
        }

    adapter = PlaidAdapter(
        repository=BankRepository(tmp_path / "banking.db"),
        cipher=_fixed_cipher(),
        config=PlaidConfig(client_id="client", secret="secret"),
        transport=transport,
    )

    claims_result = adapter.verify_webhook(signed_jwt, raw_body)
    assert claims_result["request_body_sha256"] == hashlib.sha256(raw_body).hexdigest()
    with pytest.raises(PlaidWebhookVerificationError):
        adapter.verify_webhook(signed_jwt, raw_body + b" ")


def test_real_bank_overview_reuses_existing_analysis_rules(monkeypatch, tmp_path):
    from app import data_store
    from app.bank_repository import BankRepository
    from app.bank_service import BankService

    monkeypatch.setattr(data_store, "demo_mode", lambda: False)
    monkeypatch.setattr(data_store, "public_demo_mode", lambda: False)
    repository = BankRepository(tmp_path / "banking.db")
    repository.save_item("item-1", "encrypted", "nonce")

    account = {
        "id": "account-1",
        "name": "Current",
        "type": "depository",
        "subtype": "checking",
        "current_balance": 1200,
        "currency": "GBP",
    }
    transactions = [
        {
            "id": f"spotify-{month}",
            "account_id": "account-1",
            "date": f"2026-{month:02d}-04",
            "merchant": "Spotify",
            "amount": -10.99,
            "currency": "GBP",
        }
        for month in range(5, 8)
    ]
    repository.apply_sync(
        "item-1",
        [account],
        transactions,
        [],
        [],
        "cursor-1",
    )

    service = BankService(repository, adapter_factory=lambda: None)
    overview = service.overview(refresh_stale=False, today=date(2026, 7, 28))
    subscriptions = service.scan_subscriptions()

    assert overview["provider"] == "plaid"
    assert overview["connected"] is True
    assert overview["summary"]["balance"] == 1200
    assert overview["summary"]["monthly_spend"] == 10.99
    assert subscriptions["source"] == "plaid"
    assert subscriptions["items"][0]["merchant"] == "Spotify"


def test_public_demo_bank_status_does_not_read_plaid_secrets(monkeypatch, tmp_path):
    from app import data_store
    from app.bank_repository import BankRepository
    from app.bank_service import BankService

    monkeypatch.setattr(data_store, "demo_mode", lambda: True)
    monkeypatch.setattr(data_store, "public_demo_mode", lambda: True)
    monkeypatch.setattr(
        data_store,
        "secret_value",
        lambda _name: (_ for _ in ()).throw(AssertionError("must not read secrets")),
    )

    service = BankService(BankRepository(tmp_path / "banking.db"))
    assert service.plaid_configured() is False
    assert service.overview()["provider"] == "demo"
