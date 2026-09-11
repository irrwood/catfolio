"""Interactive Brokers Client Portal Gateway read-only adapter."""

from __future__ import annotations

from dataclasses import dataclass
import json
import math
import ssl
import urllib.error
import urllib.parse
import urllib.request


class IBKRError(RuntimeError):
    """Raised when the local Client Portal Gateway cannot be queried."""


@dataclass(frozen=True)
class IBKRConfig:
    base_url: str = "https://localhost:5000/v1/api"
    account_id: str = ""

    def __post_init__(self):
        parsed = urllib.parse.urlparse(self.base_url)
        if parsed.scheme not in {"http", "https"}:
            raise ValueError("IBKR Gateway 地址必须使用 http 或 https。")
        if parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("IBKR Client Portal Gateway 仅允许连接本机地址。")


def _number(value, default=None):
    if isinstance(value, dict):
        value = value.get("amount", value.get("value"))
    try:
        result = float(value)
        return result if math.isfinite(result) else default
    except (TypeError, ValueError):
        return default


def _summary_value(summary: dict, *keys):
    for key in keys:
        value = _number(summary.get(key))
        if value is not None:
            return value
    return None


class IBKRAdapter:
    """Fetch positions through a locally authenticated Client Portal Gateway."""

    provider = "ibkr"
    label = "Interactive Brokers"

    def __init__(self, config: IBKRConfig, opener=None):
        self.config = config
        self.base_url = config.base_url.rstrip("/")
        self._opener = opener

    def _request(self, path: str, method: str = "GET"):
        url = self.base_url + "/" + path.lstrip("/")
        request = urllib.request.Request(url, method=method, headers={"Accept": "application/json"})
        context = ssl._create_unverified_context() if url.startswith("https://") else None
        try:
            if self._opener is not None:
                return self._opener(url, method)
            with urllib.request.urlopen(request, timeout=5, context=context) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")[:240]
            raise IBKRError(f"IBKR Gateway HTTP {exc.code}: {body or exc.reason}") from exc
        except Exception as exc:
            raise IBKRError(f"无法连接 IBKR Gateway：{type(exc).__name__} {str(exc)[:180]}") from exc

    def _auth_status(self) -> dict:
        status = self._request("iserver/auth/status")
        if isinstance(status, dict) and isinstance(status.get("success"), dict):
            status = status["success"].get("value") or status
        if not isinstance(status, dict):
            raise IBKRError("IBKR Gateway 返回了无效的认证状态。")
        return status

    def _accounts(self) -> list[dict]:
        rows = self._request("portfolio/accounts")
        if not isinstance(rows, list):
            raise IBKRError("IBKR Gateway 未返回账户列表。")
        if self.config.account_id:
            rows = [row for row in rows if str(row.get("accountId") or row.get("id")) == self.config.account_id]
            if not rows:
                raise IBKRError(f"未找到 IBKR 账户 {self.config.account_id}。")
        return rows

    def test_connection(self) -> dict:
        status = self._auth_status()
        if not status.get("authenticated") or not status.get("connected"):
            raise IBKRError("IBKR Gateway 已启动但尚未登录；请先在 Gateway 页面完成认证。")
        accounts = self._accounts()
        return {
            "ok": True,
            "provider": self.provider,
            "message": f"Gateway 已认证，发现 {len(accounts)} 个账户。",
            "accounts": [str(row.get("accountId") or row.get("id") or "") for row in accounts],
        }

    def _positions(self, account_id: str) -> list[dict]:
        encoded = urllib.parse.quote(account_id, safe="")
        try:
            rows = self._request(f"portfolio2/{encoded}/positions")
            if isinstance(rows, list):
                return rows
        except IBKRError as exc:
            if "HTTP 404" not in str(exc):
                raise

        rows: list[dict] = []
        for page in range(100):
            page_rows = self._request(f"portfolio/{encoded}/positions/{page}")
            if not isinstance(page_rows, list) or not page_rows:
                break
            rows.extend(page_rows)
            if len(page_rows) < 100:
                break
        return rows

    def fetch_snapshot(self) -> dict:
        status = self._auth_status()
        if not status.get("authenticated") or not status.get("connected"):
            raise IBKRError("IBKR Gateway 会话未认证；请打开 Gateway 登录页重新登录。")

        positions: list[dict] = []
        account_cash: dict[str, dict] = {}
        account_info: dict[str, dict] = {}
        warnings: list[str] = []
        for account in self._accounts():
            account_id = str(account.get("accountId") or account.get("id") or "")
            if not account_id:
                continue
            label = str(account.get("displayName") or account.get("accountAlias") or account_id)
            currency = str(account.get("currency") or "USD").upper()
            try:
                rows = self._positions(account_id)
            except Exception as exc:
                warnings.append(f"IBKR {label} 持仓失败：{str(exc)[:180]}")
                continue
            for row in rows:
                quantity = _number(row.get("position"), 0.0) or 0.0
                if quantity == 0:
                    continue
                symbol = str(
                    row.get("ticker")
                    or row.get("symbol")
                    or row.get("contractDesc")
                    or row.get("description")
                    or row.get("conid")
                    or ""
                ).strip().upper()
                if not symbol:
                    continue
                row_currency = str(row.get("currency") or currency).upper()
                price = _number(row.get("marketPrice"))
                market_value = _number(row.get("marketValue"))
                average_cost = _number(row.get("avgPrice"))
                if average_cost is None:
                    average_cost = _number(row.get("avgCost"))
                positions.append({
                    "broker": self.provider,
                    "ticker": symbol,
                    "normalized_ticker": symbol,
                    "api_ticker": str(row.get("conid") or symbol),
                    "yahoo_symbol": symbol.replace(" ", "-"),
                    "name": row.get("description") or row.get("contractDesc") or symbol,
                    "quantity": quantity,
                    "average_price_paid": average_cost,
                    "current_price": price,
                    "market_value_native": market_value,
                    "currency": row_currency,
                    "ppl": _number(row.get("unrealizedPnl")),
                    "fx_ppl": None,
                    "realized_pnl": _number(row.get("realizedPnl")),
                    "account": f"IBKR · {label}",
                    "account_key": account_id,
                    "account_currency": currency,
                })

            try:
                summary = self._request(f"portfolio/{urllib.parse.quote(account_id, safe='')}/summary")
            except Exception as exc:
                warnings.append(f"IBKR {label} 账户摘要失败：{str(exc)[:180]}")
                summary = {}
            account_label = f"IBKR · {label}"
            account_info[account_label] = {
                "id": account_id,
                "currencyCode": currency,
                "broker": self.provider,
            }
            account_cash[account_label] = {
                "total": _summary_value(summary, "totalcashvalue", "cashbalance", "settledcash"),
                "netLiquidation": _summary_value(summary, "netliquidation", "netliquidationvalue"),
                "currencyCode": currency,
            }

        return {
            "provider": self.provider,
            "label": self.label,
            "positions": positions,
            "account_cash": account_cash,
            "account_info": account_info,
            "warnings": warnings,
        }
