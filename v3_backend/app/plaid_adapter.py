"""Dependency-light Python adapter for Plaid Link and Transactions Sync."""

from __future__ import annotations

import json
import base64
import hashlib
import hmac
import os
import ssl
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

import certifi

from .bank_crypto import TokenCipher
from .bank_repository import BankRepository
from .data_store import secret_value


PLAID_BASE_URLS = {
    "sandbox": "https://sandbox.plaid.com",
    "development": "https://development.plaid.com",
    "production": "https://production.plaid.com",
}


class PlaidConfigurationError(RuntimeError):
    """Raised when Plaid credentials or environment settings are missing."""


class PlaidApiError(RuntimeError):
    """Plaid API error with a stable machine-readable code."""

    def __init__(
        self,
        message: str,
        *,
        error_code: str | None = None,
        status: int | None = None,
    ) -> None:
        super().__init__(message)
        self.error_code = error_code
        self.status = status


class PlaidWebhookVerificationError(RuntimeError):
    """Raised when a Plaid webhook signature or payload hash is invalid."""


@dataclass(frozen=True)
class PlaidConfig:
    client_id: str
    secret: str
    environment: str = "sandbox"
    country_codes: tuple[str, ...] = ("GB",)
    language: str = "en"
    webhook_url: str | None = None
    redirect_uri: str | None = None

    @classmethod
    def from_local_secrets(cls) -> "PlaidConfig":
        client_id = secret_value("PLAID_CLIENT_ID")
        secret = secret_value("PLAID_SECRET")
        if not client_id or not secret:
            raise PlaidConfigurationError(
                "Plaid Client ID and Secret are not configured in Settings."
            )
        environment = (os.environ.get("PLAID_ENV") or "sandbox").strip().lower()
        if environment not in PLAID_BASE_URLS:
            raise PlaidConfigurationError(
                "PLAID_ENV must be sandbox, development, or production."
            )
        countries = tuple(
            value.strip().upper()
            for value in (os.environ.get("PLAID_COUNTRY_CODES") or "GB").split(",")
            if value.strip()
        )
        return cls(
            client_id=client_id,
            secret=secret,
            environment=environment,
            country_codes=countries or ("GB",),
            language=(os.environ.get("PLAID_LANGUAGE") or "en").strip(),
            webhook_url=(os.environ.get("PLAID_WEBHOOK_URL") or "").strip() or None,
            redirect_uri=(os.environ.get("PLAID_REDIRECT_URI") or "").strip() or None,
        )


class PlaidAdapter:
    """Translate Plaid responses into Catfolio's local normalized bank model."""

    def __init__(
        self,
        repository: BankRepository,
        cipher: TokenCipher,
        config: PlaidConfig,
        transport: Callable[[str, dict[str, Any]], dict[str, Any]] | None = None,
    ) -> None:
        self.repository = repository
        self.cipher = cipher
        self.config = config
        self._transport = transport or self._http_post

    @property
    def base_url(self) -> str:
        return PLAID_BASE_URLS[self.config.environment]

    def _http_post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "PLAID-CLIENT-ID": self.config.client_id,
                "PLAID-SECRET": self.config.secret,
                "Plaid-Version": "2020-09-14",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=30,
                context=ssl.create_default_context(cafile=certifi.where()),
            ) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            try:
                body = json.loads(exc.read().decode("utf-8"))
            except Exception:
                body = {}
            message = body.get("error_message") or "Plaid request failed."
            raise PlaidApiError(
                message,
                error_code=body.get("error_code"),
                status=exc.code,
            ) from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise PlaidApiError("Plaid could not be reached.") from exc

    def create_link_token(self, client_user_id: str) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "user": {"client_user_id": client_user_id},
            "client_name": "Catfolio",
            "products": ["transactions"],
            "country_codes": list(self.config.country_codes),
            "language": self.config.language,
            "transactions": {"days_requested": 730},
        }
        if self.config.webhook_url:
            payload["webhook"] = self.config.webhook_url
        if self.config.redirect_uri:
            payload["redirect_uri"] = self.config.redirect_uri
        return self._transport("/link/token/create", payload)

    @staticmethod
    def _decode_jwt_segment(value: str) -> bytes:
        padding = "=" * (-len(value) % 4)
        try:
            return base64.urlsafe_b64decode(value + padding)
        except Exception as exc:
            raise PlaidWebhookVerificationError(
                "The Plaid webhook signature is malformed."
            ) from exc

    def verify_webhook(self, signed_jwt: str, raw_body: bytes) -> dict[str, Any]:
        """Verify Plaid's ES256 JWT and its hash of the exact request body."""
        try:
            encoded_header, encoded_payload, encoded_signature = signed_jwt.split(".")
            header = json.loads(
                self._decode_jwt_segment(encoded_header).decode("utf-8")
            )
            claims = json.loads(
                self._decode_jwt_segment(encoded_payload).decode("utf-8")
            )
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise PlaidWebhookVerificationError(
                "The Plaid webhook signature is malformed."
            ) from exc

        if header.get("alg") != "ES256" or not header.get("kid"):
            raise PlaidWebhookVerificationError(
                "The Plaid webhook signature uses an unsupported key."
            )

        issued_at = claims.get("iat")
        now = int(time.time())
        if not isinstance(issued_at, (int, float)) or issued_at < now - 300 or issued_at > now + 60:
            raise PlaidWebhookVerificationError(
                "The Plaid webhook signature is outside the allowed time window."
            )

        key_response = self._transport(
            "/webhook_verification_key/get",
            {"key_id": str(header["kid"])},
        )
        key = key_response.get("key") or {}
        if key.get("alg") != "ES256" or key.get("crv") != "P-256":
            raise PlaidWebhookVerificationError(
                "Plaid returned an unsupported webhook verification key."
            )

        try:
            from cryptography.hazmat.primitives import hashes
            from cryptography.hazmat.primitives.asymmetric import ec
            from cryptography.hazmat.primitives.asymmetric.utils import (
                encode_dss_signature,
            )
            x = int.from_bytes(self._decode_jwt_segment(str(key["x"])), "big")
            y = int.from_bytes(self._decode_jwt_segment(str(key["y"])), "big")
            public_key = ec.EllipticCurvePublicNumbers(
                x, y, ec.SECP256R1()
            ).public_key()
            signature = self._decode_jwt_segment(encoded_signature)
            if len(signature) != 64:
                raise ValueError("invalid ES256 signature length")
            der_signature = encode_dss_signature(
                int.from_bytes(signature[:32], "big"),
                int.from_bytes(signature[32:], "big"),
            )
            public_key.verify(
                der_signature,
                f"{encoded_header}.{encoded_payload}".encode("ascii"),
                ec.ECDSA(hashes.SHA256()),
            )
        except PlaidWebhookVerificationError:
            raise
        except Exception as exc:
            raise PlaidWebhookVerificationError(
                "The Plaid webhook signature is invalid."
            ) from exc

        expected_hash = str(claims.get("request_body_sha256") or "")
        actual_hash = hashlib.sha256(raw_body).hexdigest()
        if not expected_hash or not hmac.compare_digest(expected_hash, actual_hash):
            raise PlaidWebhookVerificationError(
                "The Plaid webhook body does not match its signature."
            )
        return claims

    def exchange_public_token(
        self,
        public_token: str,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if not public_token:
            raise ValueError("A Plaid public token is required.")
        response = self._transport(
            "/item/public_token/exchange", {"public_token": public_token}
        )
        access_token = str(response["access_token"])
        item_id = str(response["item_id"])
        encrypted, nonce = self.cipher.encrypt(access_token)
        institution = (metadata or {}).get("institution") or {}
        self.repository.save_item(
            item_id=item_id,
            encrypted_token=encrypted,
            token_nonce=nonce,
            institution_id=institution.get("institution_id"),
            institution_name=institution.get("name"),
        )
        result = self.sync_item(item_id)
        return {"item_id": item_id, "sync": result}

    def _access_token(self, item: dict) -> str:
        return self.cipher.decrypt(
            str(item["access_token_encrypted"]),
            str(item["access_token_nonce"]),
        )

    @staticmethod
    def _normalize_account(account: dict[str, Any]) -> dict[str, Any]:
        balances = account.get("balances") or {}
        return {
            "id": str(account["account_id"]),
            "name": str(account.get("name") or account.get("official_name") or "Bank account"),
            "official_name": account.get("official_name"),
            "type": str(account.get("type") or "other"),
            "subtype": account.get("subtype"),
            "mask": account.get("mask"),
            "current_balance": balances.get("current"),
            "available_balance": balances.get("available"),
            "credit_limit": balances.get("limit"),
            "currency": balances.get("iso_currency_code")
            or balances.get("unofficial_currency_code")
            or "GBP",
        }

    @staticmethod
    def _normalize_transaction(transaction: dict[str, Any]) -> dict[str, Any]:
        category = transaction.get("personal_finance_category") or {}
        merchant = (
            transaction.get("merchant_name")
            or transaction.get("name")
            or "Unknown merchant"
        )
        # Plaid uses positive amounts for money leaving the account.  Catfolio's
        # analysis model uses negative debits and positive credits.
        amount = -float(transaction.get("amount") or 0)
        return {
            "id": str(transaction["transaction_id"]),
            "account_id": str(transaction["account_id"]),
            "date": str(transaction["date"]),
            "authorized_date": transaction.get("authorized_date"),
            "merchant": str(merchant),
            "amount": amount,
            "currency": transaction.get("iso_currency_code")
            or transaction.get("unofficial_currency_code")
            or "GBP",
            "category": category.get("primary"),
            "category_detail": category.get("detailed"),
            "pending": bool(transaction.get("pending")),
            "pending_transaction_id": transaction.get("pending_transaction_id"),
            "payment_channel": transaction.get("payment_channel"),
        }

    def sync_item(self, item_id: str) -> dict[str, Any]:
        item = self.repository.get_item(item_id)
        if not item:
            raise KeyError(f"Unknown Plaid item: {item_id}")
        access_token = self._access_token(item)
        starting_cursor = item.get("transaction_cursor")

        try:
            accounts_response = self._transport(
                "/accounts/get", {"access_token": access_token}
            )
            accounts = [
                self._normalize_account(account)
                for account in accounts_response.get("accounts", [])
            ]

            mutation_retries = 0
            while True:
                cursor = starting_cursor
                added: list[dict] = []
                modified: list[dict] = []
                removed: list[str] = []
                try:
                    while True:
                        payload: dict[str, Any] = {
                            "access_token": access_token,
                            "count": 500,
                        }
                        if cursor:
                            payload["cursor"] = cursor
                        response = self._transport("/transactions/sync", payload)
                        added.extend(
                            self._normalize_transaction(transaction)
                            for transaction in response.get("added", [])
                        )
                        modified.extend(
                            self._normalize_transaction(transaction)
                            for transaction in response.get("modified", [])
                        )
                        removed.extend(
                            str(transaction["transaction_id"])
                            for transaction in response.get("removed", [])
                            if transaction.get("transaction_id")
                        )
                        cursor = str(response.get("next_cursor") or cursor or "")
                        if not response.get("has_more"):
                            break
                    break
                except PlaidApiError as exc:
                    if (
                        exc.error_code
                        == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION"
                        and mutation_retries < 2
                    ):
                        mutation_retries += 1
                        continue
                    raise

            return self.repository.apply_sync(
                item_id=item_id,
                accounts=accounts,
                added=added,
                modified=modified,
                removed=removed,
                next_cursor=cursor,
            )
        except Exception as exc:
            self.repository.record_sync_error(
                item_id,
                str(exc),
                getattr(exc, "error_code", None),
            )
            raise

    def sync_all(self) -> list[dict[str, Any]]:
        results = []
        for item in self.repository.list_items():
            try:
                results.append(self.sync_item(str(item["item_id"])))
            except Exception as exc:
                results.append(
                    {
                        "item_id": item["item_id"],
                        "status": "error",
                        "error": str(exc),
                    }
                )
        return results

    def refresh_item(self, item_id: str) -> dict[str, Any]:
        item = self.repository.get_item(item_id)
        if not item:
            raise KeyError(f"Unknown Plaid item: {item_id}")
        response = self._transport(
            "/transactions/refresh",
            {"access_token": self._access_token(item)},
        )
        return {
            "item_id": item_id,
            "status": "requested",
            "request_id": response.get("request_id"),
        }

    def remove_item(self, item_id: str) -> bool:
        item = self.repository.get_item(item_id)
        if not item:
            return False
        self._transport(
            "/item/remove",
            {"access_token": self._access_token(item)},
        )
        return self.repository.delete_item(item_id)
