"""Authenticated encryption for locally persisted bank-provider tokens.

The ciphertext and nonce live in SQLite.  The 256-bit master key is kept in the
system Keychain through the same secret store used by the rest of Catfolio.
"""

from __future__ import annotations

import base64
import secrets
from collections.abc import Callable

from .data_store import save_secret, secret_value


BANK_TOKEN_KEY_NAME = "CATFOLIO_BANK_TOKEN_KEY"
_AAD = b"catfolio:bank-access-token:v1"


class TokenEncryptionError(RuntimeError):
    """Raised when a token cannot be encrypted or decrypted safely."""


class TokenCipher:
    """AES-256-GCM token encryption with a Keychain-backed master key."""

    def __init__(
        self,
        key_reader: Callable[[str], str | None] = secret_value,
        key_writer: Callable[[str, str], bool] = save_secret,
    ) -> None:
        self._key_reader = key_reader
        self._key_writer = key_writer
        self._cached_key: bytes | None = None

    @staticmethod
    def _decode_key(value: str) -> bytes:
        value = value.strip()
        try:
            key = bytes.fromhex(value) if len(value) == 64 else base64.urlsafe_b64decode(value)
        except (ValueError, TypeError) as exc:
            raise TokenEncryptionError("The bank token key is not valid hex or base64.") from exc
        if len(key) != 32:
            raise TokenEncryptionError("The bank token key must contain exactly 32 bytes.")
        return key

    def _key(self) -> bytes:
        if self._cached_key is not None:
            return self._cached_key

        stored = self._key_reader(BANK_TOKEN_KEY_NAME)
        if stored:
            self._cached_key = self._decode_key(stored)
            return self._cached_key

        generated = secrets.token_bytes(32)
        encoded = generated.hex()
        if not self._key_writer(BANK_TOKEN_KEY_NAME, encoded):
            raise TokenEncryptionError(
                "Catfolio could not save the bank encryption key to the system Keychain."
            )
        self._cached_key = generated
        return generated

    @staticmethod
    def _aesgcm():
        try:
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        except ImportError as exc:
            raise TokenEncryptionError(
                "Bank token encryption requires the 'cryptography' package."
            ) from exc
        return AESGCM

    def encrypt(self, plaintext: str) -> tuple[str, str]:
        if not plaintext:
            raise TokenEncryptionError("Cannot encrypt an empty bank access token.")
        nonce = secrets.token_bytes(12)
        ciphertext = self._aesgcm()(self._key()).encrypt(
            nonce, plaintext.encode("utf-8"), _AAD
        )
        return (
            base64.urlsafe_b64encode(ciphertext).decode("ascii"),
            base64.urlsafe_b64encode(nonce).decode("ascii"),
        )

    def decrypt(self, ciphertext: str, nonce: str) -> str:
        try:
            raw_ciphertext = base64.urlsafe_b64decode(ciphertext)
            raw_nonce = base64.urlsafe_b64decode(nonce)
            plaintext = self._aesgcm()(self._key()).decrypt(
                raw_nonce, raw_ciphertext, _AAD
            )
            return plaintext.decode("utf-8")
        except TokenEncryptionError:
            raise
        except Exception as exc:
            raise TokenEncryptionError(
                "The stored bank token could not be decrypted."
            ) from exc
