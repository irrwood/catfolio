"""Longbridge OpenAPI read-only portfolio adapter.

Longbridge API credentials can also place orders. This adapter only calls
TradeContext.stock_positions() and account_balance(), and
QuoteContext.member_id() and quote(); it never calls an order method.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import math


# User-facing text for each failure reason. SDK error text can contain request
# URLs or trace IDs, so it is never shown.
MESSAGES = {
    "token": "长桥访问令牌无效或已过期，或 App Key、App Secret 与令牌不匹配。请在长桥开放平台重新生成访问令牌后重试。现有数据已保留。",
    "permission": "长桥拒绝了访问。请确认这组凭证可以读取持仓、资金和行情，且当前 IP 未被限制。现有数据已保留。",
    "network": "无法连接长桥服务器，请检查网络后重试。现有数据已保留。",
    "account_id": "长桥未返回账户标识，请在连接配置中填写账户 ID 后重试。现有数据已保留。",
    "sdk": "未安装长桥开发包。请在 v3_backend 目录运行 pip install -r requirements-longbridge.txt 后重试。现有数据已保留。",
    None: "长桥连接失败，请检查凭证和网络后重试。现有数据已保留。",
}

# 401003 token expired, 401004 token invalid, 403201 signature invalid,
# 403203 App Key illegal, 403208 token and App Key do not match.
_TOKEN_CODES = {401003, 401004, 403201, 403203, 403208}
_NOT_PERMISSION_CODES = {403202}  # duplicate request
_NETWORK_WORDS = ("error sending request", "connect", "timed out", "timeout", "dns", "unreachable", "network", "broken pipe")
_TOKEN_WORDS = ("token expired", "token invalid", "invalid token", "signature invalid", "api key", "unauthorized")
_PERMISSION_WORDS = ("permission", "forbidden", "not allowed", "no access")

_YAHOO_SUFFIXES = {"HK": ".HK", "SH": ".SS", "SZ": ".SZ", "SG": ".SI"}
_MARKET_CURRENCIES = {"US": "USD", "HK": "HKD", "SH": "CNY", "SZ": "CNY", "SG": "SGD"}


class LongbridgeError(RuntimeError):
    """A Longbridge failure whose message is always safe to show."""

    def __init__(self, reason: str | None = None):
        self.reason = reason if reason in MESSAGES else None
        super().__init__(MESSAGES[self.reason])


@dataclass(frozen=True)
class LongbridgeConfig:
    app_key: str = field(repr=False)
    app_secret: str = field(repr=False)
    access_token: str = field(repr=False)
    account_id: str = ""

    def __post_init__(self):
        if not all(str(value or "").strip() for value in (self.app_key, self.app_secret, self.access_token)):
            raise ValueError("请填写长桥 App Key、App Secret 和 Access Token。")


def _number(value, default=None):
    try:
        result = float(value)
        return result if math.isfinite(result) else default
    except (TypeError, ValueError):
        return default


def _code(exc) -> int | None:
    try:
        return int(getattr(exc, "code", None))
    except (TypeError, ValueError):
        return None


def _reason(exc: Exception) -> str | None:
    """Map an SDK exception to a failure reason without exposing its text."""
    code = _code(exc)
    if code is not None:
        if code in _TOKEN_CODES or code // 1000 == 401:
            return "token"
        if code // 1000 == 403 and code not in _NOT_PERMISSION_CODES:
            return "permission"
        return None
    if isinstance(exc, OSError):  # includes ConnectionError and TimeoutError
        return "network"
    text = str(getattr(exc, "message", None) or exc).lower()
    for reason, words in (("network", _NETWORK_WORDS), ("token", _TOKEN_WORDS), ("permission", _PERMISSION_WORDS)):
        if any(word in text for word in words):
            return reason
    return None


def _symbols(symbol: str) -> tuple[str, str]:
    """Map a Longbridge symbol to (Catfolio ticker, Yahoo symbol).

    AAPL.US -> AAPL; 700.HK -> 0700.HK (Yahoo only accepts four-digit HK
    codes); 600519.SH -> 600519.SS; D05.SG -> D05.SI.
    """
    raw = str(symbol or "").strip().upper()
    code, dot, market = raw.rpartition(".")
    if not dot or not code:
        return raw, raw
    if market == "US":
        return code, code.replace(".", "-")  # BRK.B -> BRK-B on Yahoo
    if market == "HK" and code.isdigit():
        code = code.lstrip("0").zfill(4)
    if market in _YAHOO_SUFFIXES:
        yahoo = code + _YAHOO_SUFFIXES[market]
        return yahoo, yahoo
    return raw, raw


class LongbridgeAdapter:
    """Fetch positions, cash and latest prices through the Longbridge SDK."""

    provider = "longbridge"
    label = "Longbridge"

    def __init__(self, config: LongbridgeConfig, sdk_module=None):
        self.config = config
        self._sdk = sdk_module

    def _module(self):
        if self._sdk is not None:
            return self._sdk
        try:
            from longbridge import openapi
        except ImportError as exc:
            raise LongbridgeError("sdk") from exc
        self._sdk = openapi
        return openapi

    def _call(self, fn, *args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except LongbridgeError:
            raise
        except Exception as exc:
            raise LongbridgeError(_reason(exc)) from exc

    def _sdk_config(self):
        module = self._module()
        return module, self._call(
            module.Config.from_apikey,
            self.config.app_key.strip(),
            self.config.app_secret.strip(),
            self.config.access_token.strip(),
            enable_print_quote_packages=False,
        )

    def _identity(self, quote_context) -> str:
        # Positions and balances carry no account number; the member ID from
        # the quote connection is the stable identity Longbridge returns.
        identity = str(self._call(quote_context.member_id) or "").strip()
        identity = identity or str(self.config.account_id or "").strip()
        if not identity:
            raise LongbridgeError("account_id")
        return identity

    def _balance(self, trade_context) -> dict | None:
        rows = list(self._call(trade_context.account_balance) or [])
        if len({str(getattr(row, "currency", "")).upper() for row in rows}) > 1:
            # One entry per currency: ask Longbridge for a single consolidated view.
            rows = list(self._call(trade_context.account_balance, str(rows[0].currency).upper()) or [])
        currencies = {str(getattr(row, "currency", "")).upper() for row in rows}
        if len(currencies) != 1:
            return None
        return {
            "total": sum(_number(row.total_cash, 0.0) for row in rows),
            "netLiquidation": sum(_number(row.net_assets, 0.0) for row in rows),
            "currencyCode": currencies.pop(),
        }

    def _prices(self, quote_context, symbols: list[str]) -> dict[str, float]:
        if not symbols:
            return {}
        prices = {}
        for row in self._call(quote_context.quote, symbols) or []:
            # last_done can be zero before a security's first trade of the day.
            price = _number(getattr(row, "last_done", None))
            if not price or price <= 0:
                price = _number(getattr(row, "prev_close", None))
            if price and price > 0:
                prices[str(row.symbol).upper()] = price
        return prices

    def test_connection(self) -> dict:
        module, config = self._sdk_config()
        self._call(self._call(module.TradeContext, config).account_balance)
        identity = self._identity(self._call(module.QuoteContext, config))
        return {
            "ok": True,
            "provider": self.provider,
            "message": "长桥 OpenAPI 已连接。",
            "accounts": [identity],
        }

    def fetch_snapshot(self) -> dict:
        module, config = self._sdk_config()
        trade_context = self._call(module.TradeContext, config)
        response = self._call(trade_context.stock_positions)
        balance = self._balance(trade_context)
        quote_context = self._call(module.QuoteContext, config)
        identity = self._identity(quote_context)
        account_label = f"{self.label} · {identity}"
        warnings: list[str] = []
        if balance is None:
            warnings.append("长桥未返回可用的账户余额。")

        rows = [
            row
            for channel in getattr(response, "channels", None) or []
            for row in getattr(channel, "positions", None) or []
            if _number(getattr(row, "quantity", None), 0.0)
        ]
        prices = self._prices(quote_context, sorted({str(row.symbol).upper() for row in rows}))
        positions: list[dict] = []
        for row in rows:
            symbol = str(row.symbol).upper()
            ticker, yahoo_symbol = _symbols(symbol)
            quantity = _number(row.quantity, 0.0)
            average_cost = _number(row.cost_price)
            price = prices.get(symbol)
            if price is None:
                warnings.append(f"长桥未返回 {symbol} 的行情。")
            currency = str(getattr(row, "currency", "") or _MARKET_CURRENCIES.get(symbol.rpartition(".")[2], "USD")).upper()
            positions.append({
                "broker": self.provider,
                "ticker": ticker,
                "normalized_ticker": ticker,
                "api_ticker": symbol,
                "yahoo_symbol": yahoo_symbol,
                "name": getattr(row, "symbol_name", None) or ticker,
                "quantity": quantity,
                "average_price_paid": average_cost,
                "current_price": price,
                "market_value_native": quantity * price if price is not None else None,
                "currency": currency,
                # Longbridge does not report P/L. This value is in the position
                # currency, so account_currency below is the position currency too.
                "ppl": quantity * (price - average_cost) if price is not None and average_cost is not None else None,
                "fx_ppl": None,
                "realized_pnl": None,
                "account": account_label,
                "account_key": identity,
                "account_currency": currency,
            })

        return {
            "provider": self.provider,
            "label": self.label,
            "positions": positions,
            "account_cash": {account_label: balance} if balance is not None else {},
            "account_info": {account_label: {
                "id": identity,
                "currencyCode": (balance or {}).get("currencyCode"),
                "broker": self.provider,
            }},
            "warnings": warnings,
        }
