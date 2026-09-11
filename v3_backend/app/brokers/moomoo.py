"""Moomoo/Futu OpenD read-only portfolio adapter."""

from __future__ import annotations

from dataclasses import dataclass
import math
import socket
from typing import Any


class MoomooError(RuntimeError):
    """Raised when OpenD cannot provide a usable portfolio snapshot."""


@dataclass(frozen=True)
class MoomooConfig:
    host: str = "127.0.0.1"
    port: int = 11111
    markets: tuple[str, ...] = ("US", "HK")
    account_id: int = 0
    security_firm: str = "FUTUSECURITIES"
    environment: str = "REAL"

    def __post_init__(self):
        if self.host not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("Moomoo OpenD 仅允许连接本机地址。")
        if not 1 <= int(self.port) <= 65535:
            raise ValueError("Moomoo OpenD 端口必须在 1–65535 之间。")
        supported = {"US", "HK", "CN", "SG", "JP"}
        if not self.markets or any(market.upper() not in supported for market in self.markets):
            raise ValueError("Moomoo 市场仅支持 US、HK、CN、SG、JP。")


def _records(value: Any) -> list[dict]:
    if hasattr(value, "to_dict"):
        return list(value.to_dict("records"))
    if isinstance(value, list):
        return [dict(row) for row in value if isinstance(row, dict)]
    if isinstance(value, dict):
        return [dict(value)]
    return []


def _number(value, default=None):
    try:
        result = float(value)
        return result if math.isfinite(result) else default
    except (TypeError, ValueError):
        return default


def _first_number(row: dict, *keys, default=None):
    for key in keys:
        value = _number(row.get(key))
        if value is not None:
            return value
    return default


def _symbols(code: str) -> tuple[str, str]:
    raw = str(code or "").strip().upper()
    if "." not in raw:
        return raw, raw
    market, symbol = raw.split(".", 1)
    suffixes = {
        "HK": ".HK",
        "SH": ".SS",
        "SZ": ".SZ",
        "SG": ".SI",
        "JP": ".T",
    }
    yahoo = symbol + suffixes.get(market, "")
    ticker = yahoo if market != "US" else symbol
    return ticker, yahoo


class MoomooAdapter:
    """Fetch positions through a locally running Futu OpenD process."""

    provider = "moomoo"
    label = "Moomoo"

    def __init__(self, config: MoomooConfig, futu_module=None):
        self.config = config
        self._futu = futu_module

    def _module(self):
        if self._futu is not None:
            return self._futu
        try:
            import futu
        except ImportError as exc:
            raise MoomooError("缺少 futu-api；请先安装项目依赖，再启动 Moomoo OpenD。") from exc
        self._futu = futu
        return futu

    def _check_port(self):
        if self._futu is not None:
            return
        try:
            with socket.create_connection((self.config.host, int(self.config.port)), timeout=2.5):
                return
        except OSError as exc:
            raise MoomooError(
                f"无法连接 Moomoo OpenD {self.config.host}:{self.config.port}；请先启动并登录 OpenD。"
            ) from exc

    def _enum(self, group: str, value: str):
        module = self._module()
        enum_group = getattr(module, group)
        try:
            return getattr(enum_group, value.upper())
        except AttributeError as exc:
            raise MoomooError(f"futu-api 不支持 {group}.{value}") from exc

    def _context(self, market: str):
        module = self._module()
        kwargs = {
            "filter_trdmarket": self._enum("TrdMarket", market),
            "host": self.config.host,
            "port": int(self.config.port),
        }
        security_firm = getattr(getattr(module, "SecurityFirm", object()), self.config.security_firm, None)
        if security_firm is not None:
            kwargs["security_firm"] = security_firm
        return module.OpenSecTradeContext(**kwargs)

    def _query(self, context, method: str, **kwargs) -> list[dict]:
        fn = getattr(context, method)
        ret, data = fn(**kwargs)
        if ret != getattr(self._module(), "RET_OK", 0):
            raise MoomooError(f"Moomoo {method} 失败：{str(data)[:240]}")
        return _records(data)

    def test_connection(self) -> dict:
        self._check_port()
        context = self._context(self.config.markets[0])
        try:
            accounts = self._query(context, "get_acc_list")
        finally:
            context.close()
        return {
            "ok": True,
            "provider": self.provider,
            "message": f"OpenD 已连接，发现 {len(accounts)} 个交易账户。",
            "accounts": [str(row.get("acc_id") or "") for row in accounts],
        }

    def fetch_snapshot(self) -> dict:
        self._check_port()
        module = self._module()
        trd_env = self._enum("TrdEnv", self.config.environment)
        positions: list[dict] = []
        account_cash: dict[str, dict] = {}
        account_info: dict[str, dict] = {}
        warnings: list[str] = []
        seen: set[tuple[str, str, float]] = set()

        for market in self.config.markets:
            context = self._context(market)
            try:
                accounts = self._query(context, "get_acc_list")
                selected = accounts
                if self.config.account_id:
                    selected = [row for row in accounts if int(_number(row.get("acc_id"), 0)) == self.config.account_id]
                if not selected:
                    warnings.append(f"Moomoo {market} 未找到匹配账户。")
                    continue

                for account in selected:
                    account_id = int(_number(account.get("acc_id"), 0))
                    account_label = f"Moomoo · {account_id or market}"
                    kwargs = {"trd_env": trd_env, "refresh_cache": True}
                    if account_id:
                        kwargs["acc_id"] = account_id
                    rows = self._query(context, "position_list_query", **kwargs)
                    for row in rows:
                        quantity = _first_number(row, "qty", default=0.0) or 0.0
                        if quantity == 0:
                            continue
                        ticker, yahoo_symbol = _symbols(row.get("code"))
                        key = (account_label, str(row.get("code")), quantity)
                        if key in seen:
                            continue
                        seen.add(key)
                        average_cost = _first_number(row, "average_cost", "cost_price", "diluted_cost")
                        price = _first_number(row, "nominal_price")
                        market_value = _first_number(row, "market_val")
                        unrealized = _first_number(row, "unrealized_pl", "pl_val")
                        currency = str(row.get("currency") or "USD").upper()
                        positions.append({
                            "broker": self.provider,
                            "ticker": ticker,
                            "normalized_ticker": ticker,
                            "api_ticker": row.get("code"),
                            "yahoo_symbol": yahoo_symbol,
                            "name": row.get("stock_name") or ticker,
                            "quantity": quantity,
                            "average_price_paid": average_cost,
                            "current_price": price,
                            "market_value_native": market_value,
                            "currency": currency,
                            "ppl": unrealized,
                            "fx_ppl": None,
                            "realized_pnl": _first_number(row, "realized_pl"),
                            "account": account_label,
                            "account_key": str(account_id or market),
                            "account_currency": currency,
                        })

                    info_kwargs = {"trd_env": trd_env}
                    if account_id:
                        info_kwargs["acc_id"] = account_id
                    try:
                        info_rows = self._query(context, "accinfo_query", **info_kwargs)
                    except MoomooError as exc:
                        warnings.append(str(exc))
                        info_rows = []
                    info = info_rows[0] if info_rows else {}
                    currency = str(info.get("currency") or account.get("currency") or "USD").upper()
                    account_info[account_label] = {
                        "id": str(account_id),
                        "currencyCode": currency,
                        "broker": self.provider,
                    }
                    account_cash[account_label] = {
                        "total": _first_number(info, "cash", "cash_balance", default=0.0),
                        "netLiquidation": _first_number(info, "total_assets", "total_assets_hkd"),
                        "currencyCode": currency,
                    }
            except Exception as exc:
                warnings.append(f"Moomoo {market} 同步失败：{type(exc).__name__} {str(exc)[:180]}")
            finally:
                context.close()

        return {
            "provider": self.provider,
            "label": self.label,
            "positions": positions,
            "account_cash": account_cash,
            "account_info": account_info,
            "warnings": warnings,
        }
