"""Broker selection, connection checks, and normalized portfolio persistence."""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import time

from app.data_store import load_json, secret_value, usd_equivalent
from app.settings import DATA_DIR, V2_DIR

from .ibkr import IBKRAdapter, IBKRConfig
from .moomoo import MoomooAdapter, MoomooConfig


SUPPORTED_BROKERS = {
    "trading212": "Trading 212",
    "moomoo": "Moomoo",
    "ibkr": "Interactive Brokers",
}


def active_broker() -> str:
    provider = str(secret_value("BROKER_PROVIDER") or "trading212").strip().lower()
    return provider if provider in SUPPORTED_BROKERS else "trading212"


def _int_setting(name: str, default: int) -> int:
    try:
        return int(secret_value(name) or default)
    except (TypeError, ValueError):
        return default


def _adapter(provider: str):
    provider = str(provider or "").strip().lower()
    if provider == "moomoo":
        markets = tuple(
            item.strip().upper()
            for item in str(secret_value("MOOMOO_MARKETS") or "US,HK").split(",")
            if item.strip()
        )
        return MoomooAdapter(MoomooConfig(
            host=str(secret_value("MOOMOO_HOST") or "127.0.0.1").strip(),
            port=_int_setting("MOOMOO_PORT", 11111),
            markets=markets,
            account_id=_int_setting("MOOMOO_ACCOUNT_ID", 0),
        ))
    if provider == "ibkr":
        return IBKRAdapter(IBKRConfig(
            base_url=str(secret_value("IBKR_BASE_URL") or "https://localhost:5000/v1/api").strip(),
            account_id=str(secret_value("IBKR_ACCOUNT_ID") or "").strip(),
        ))
    raise ValueError(f"不支持的券商：{provider}")


def broker_connection_status(provider: str) -> dict:
    provider = str(provider or "").strip().lower()
    if provider == "trading212":
        configured = bool(secret_value("TRADING212_API_KEY") and secret_value("TRADING212_API_SECRET"))
        return {
            "ok": configured,
            "provider": provider,
            "message": "Trading 212 API Key 与 Secret 已配置。" if configured else "请先配置 Trading 212 API Key 与 Secret。",
        }
    try:
        return _adapter(provider).test_connection()
    except Exception as exc:
        return {
            "ok": False,
            "provider": provider,
            "error": str(exc),
            "message": str(exc),
        }


def _v1_portfolio() -> dict:
    return load_json(DATA_DIR / "portfolio_analysis" / "portfolio_analysis.json", {"holdings": [], "import_transactions": []})


def _gbp_from_usd(value):
    return float(value or 0) / 1.3460


def _position_ticker(row: dict) -> str:
    return str(row.get("normalized_ticker") or row.get("ticker") or "").strip().upper()


def _broker_portfolio(snapshot: dict) -> dict:
    provider = str(snapshot.get("provider") or "broker").lower()
    label = str(snapshot.get("label") or SUPPORTED_BROKERS.get(provider) or provider)
    v1 = _v1_portfolio()
    v1_by_ticker = {str(row.get("ticker") or "").upper(): row for row in v1.get("holdings", [])}
    cash_by_account = snapshot.get("account_cash") if isinstance(snapshot.get("account_cash"), dict) else {}
    info_by_account = snapshot.get("account_info") if isinstance(snapshot.get("account_info"), dict) else {}
    holdings_by_account: list[dict] = []
    market_rows: list[dict] = []

    for source in snapshot.get("positions") or []:
        ticker = _position_ticker(source)
        if not ticker:
            continue
        shares = float(source.get("quantity") or 0)
        if shares == 0:
            continue
        v1_row = v1_by_ticker.get(ticker, {})
        price = source.get("current_price")
        average_price = source.get("average_price_paid")
        currency = str(source.get("currency") or "USD").upper()
        cost_native = shares * float(average_price) if average_price is not None else 0.0
        market_native = source.get("market_value_native")
        if market_native is None and price is not None:
            market_native = shares * float(price)
        cost_usd = usd_equivalent(cost_native, currency)
        market_usd = usd_equivalent(market_native, currency)
        if cost_usd is None or market_usd is None:
            raise RuntimeError(f"暂不支持 {currency} 换算；请配置受支持的账户基础货币。")

        account = str(source.get("account") or label)
        account_currency = str(
            source.get("account_currency")
            or (cash_by_account.get(account) or {}).get("currencyCode")
            or (info_by_account.get(account) or {}).get("currencyCode")
            or currency
        ).upper()
        broker_ppl = source.get("ppl")
        broker_unrealized_usd = usd_equivalent(broker_ppl, account_currency) if broker_ppl is not None else None
        broker_fx_ppl = source.get("fx_ppl")
        broker_fx_ppl_usd = usd_equivalent(broker_fx_ppl, account_currency) if broker_fx_ppl is not None else None
        price_unrealized_usd = market_usd - cost_usd
        yahoo_symbol = source.get("yahoo_symbol") or ticker
        name = source.get("name") or v1_row.get("name") or ticker
        holding = {
            "ticker": ticker,
            "isin": v1_row.get("isin", ""),
            "name": name,
            "price_currency": currency,
            "cost_currency": currency,
            "yahoo_symbol": yahoo_symbol,
            "accounts": account,
            "account": account,
            "broker": provider,
            "shares": shares,
            "cost_native": cost_native,
            "avg_cost_native": float(average_price or 0),
            "cost_gbp_available": _gbp_from_usd(cost_usd),
            "avg_cost_gbp_available": _gbp_from_usd(cost_usd) / shares if shares else 0,
            "cost_usd_standard": cost_usd,
            "avg_cost_usd_standard": cost_usd / shares if shares else 0,
            "realized_native": float(source.get("realized_pnl") or 0),
            "realized_gbp_available": _gbp_from_usd(usd_equivalent(source.get("realized_pnl") or 0, currency) or 0),
            "buys": v1_row.get("buys", 0),
            "sells": v1_row.get("sells", 0),
            "stock_dividends": v1_row.get("stock_dividends", 0),
            "last_trade_time": f"{label} API snapshot",
            "last_trade_action": "API snapshot",
            "last_trade_price": float(price or 0),
            "last_trade_price_currency": currency,
            "api_ticker": source.get("api_ticker") or source.get("ticker"),
            "api_market_value_gbp": _gbp_from_usd(market_usd),
            "api_market_value_usd": market_usd,
            "api_unrealized_gbp": _gbp_from_usd(price_unrealized_usd),
            "api_unrealized_usd": price_unrealized_usd,
            "broker_unrealized_account": broker_ppl,
            "broker_unrealized_currency": account_currency,
            "broker_unrealized_usd": broker_unrealized_usd,
            "broker_fx_ppl_account": broker_fx_ppl,
            "broker_fx_ppl_usd": broker_fx_ppl_usd,
            "broker_ppl_includes_fx": broker_ppl is not None,
            "price_unrealized_usd": price_unrealized_usd,
            "price_unrealized_percent": ((market_usd / cost_usd - 1) * 100) if cost_usd else None,
            "csv_cost_usd_standard": v1_row.get("cost_usd_standard"),
            "csv_shares": v1_row.get("shares"),
            "api_share_diff": shares - float(v1_row.get("shares") or 0),
        }
        holdings_by_account.append(holding)
        market_rows.append({
            "ticker": ticker,
            "name": name,
            "company_name": name,
            "yahoo_symbol": yahoo_symbol,
            "shares": shares,
            "cost_currency": currency,
            "avg_cost_native": float(average_price or 0),
            "cost_usd_standard": cost_usd,
            "quote_price": price,
            "quote_currency": currency,
            "market_value_native": market_native,
            "market_value_usd": market_usd,
            "unrealized_usd": broker_unrealized_usd if broker_unrealized_usd is not None else price_unrealized_usd,
            "unrealized_percent": ((broker_unrealized_usd if broker_unrealized_usd is not None else price_unrealized_usd) / cost_usd * 100) if cost_usd else None,
            "broker_unrealized_usd": broker_unrealized_usd,
            "broker_fx_ppl_usd": broker_fx_ppl_usd,
            "broker_ppl_includes_fx": broker_ppl is not None,
            "price_unrealized_usd": price_unrealized_usd,
            "price_unrealized_percent": ((market_usd / cost_usd - 1) * 100) if cost_usd else None,
            "pnl_basis": f"{provider}_ppl" if broker_ppl is not None else "price_difference",
            "change_percent": None,
            "market_time": snapshot.get("as_of_unix"),
            "source": f"{label} read-only portfolio API",
        })

    grouped: dict[str, dict] = {}
    accounts_by_ticker: dict[str, set[str]] = defaultdict(set)
    for row in holdings_by_account:
        ticker = row["ticker"]
        accounts_by_ticker[ticker].add(row["account"])
        if ticker not in grouped:
            grouped[ticker] = dict(row)
            continue
        target = grouped[ticker]
        for key in (
            "shares", "cost_native", "cost_gbp_available", "cost_usd_standard",
            "api_market_value_gbp", "api_market_value_usd", "api_unrealized_gbp",
            "api_unrealized_usd", "price_unrealized_usd", "api_share_diff",
        ):
            target[key] = float(target.get(key) or 0) + float(row.get(key) or 0)
        for key in ("broker_unrealized_usd", "broker_fx_ppl_usd"):
            values = [target.get(key), row.get(key)]
            target[key] = sum(float(value or 0) for value in values) if any(value is not None for value in values) else None
        target["buys"] = int(target.get("buys") or 0) + int(row.get("buys") or 0)
        target["sells"] = int(target.get("sells") or 0) + int(row.get("sells") or 0)
        target["stock_dividends"] = int(target.get("stock_dividends") or 0) + int(row.get("stock_dividends") or 0)

    holdings: list[dict] = []
    for ticker, row in grouped.items():
        shares = float(row.get("shares") or 0)
        row["accounts"] = ",".join(sorted(accounts_by_ticker[ticker]))
        row["avg_cost_native"] = float(row.get("cost_native") or 0) / shares if shares else 0
        row["avg_cost_gbp_available"] = float(row.get("cost_gbp_available") or 0) / shares if shares else 0
        row["avg_cost_usd_standard"] = float(row.get("cost_usd_standard") or 0) / shares if shares else 0
        holdings.append(row)

    holdings.sort(key=lambda row: float(row.get("cost_usd_standard") or 0), reverse=True)
    holdings_by_account.sort(key=lambda row: float(row.get("cost_usd_standard") or 0), reverse=True)
    market_rows.sort(key=lambda row: float(row.get("market_value_usd") or 0), reverse=True)
    by_currency: dict[str, dict] = {}
    by_account: dict[str, dict] = {}
    for row in holdings:
        currency = row.get("cost_currency") or "UNKNOWN"
        item = by_currency.setdefault(currency, {"positions": 0, "cost_native": 0.0, "cost_gbp_available": 0.0})
        item["positions"] += 1
        item["cost_native"] += float(row.get("cost_native") or 0)
        item["cost_gbp_available"] += float(row.get("cost_gbp_available") or 0)
    for row in holdings_by_account:
        item = by_account.setdefault(row["account"], {"positions": 0, "cost_gbp_available": 0.0})
        item["positions"] += 1
        item["cost_gbp_available"] += float(row.get("cost_gbp_available") or 0)

    cash_movements = {}
    for account, cash in cash_by_account.items():
        if not isinstance(cash, dict) or cash.get("total") is None:
            continue
        currency = str(cash.get("currencyCode") or "USD").upper()
        cash_movements[f"{account}_{currency}"] = float(cash.get("total") or 0)
    warnings = [
        f"当前持仓来自 {label} 的只读 API 快照。",
        "成本价来自券商平均成本；完整交易流水仍需通过 CSV 导入补充。",
        *(snapshot.get("warnings") or []),
    ]
    total_cost_usd = sum(float(row.get("cost_usd_standard") or 0) for row in holdings)
    summary = {
        "version": "v2_broker_api",
        "broker_provider": provider,
        "broker_label": label,
        "as_of": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "source_files": 0,
        "transactions": 0,
        "open_positions": len(holdings),
        "open_positions_by_account": len(holdings_by_account),
        "closed_positions": 0,
        "report_fx_to_usd": {"USD": 1, "GBP": 1.3460, "GBX": 0.013460, "EUR": 1.1630},
        "report_fx_source": f"{label} average cost/current price snapshot; Catfolio display FX table",
        "unrealized_pnl_basis": f"{label} unrealized P/L when supplied",
        "price_pnl_basis": "current price minus average cost",
        "total_cost_usd_standard": total_cost_usd,
        "cost_scale_by_currency": by_currency,
        "cost_scale_by_account_gbp_available": by_account,
        "cash_movements_by_account_currency": cash_movements,
        "interest_by_account_currency": {},
        "interest_by_currency": {},
        "interest_usd_standard": 0,
        "dividends_by_account_currency": {},
        "dividends_by_currency": {},
        "dividends_usd_standard": 0,
        "warnings": warnings,
    }
    return {
        "portfolio": {
            "summary": summary,
            "holdings": holdings,
            "holdings_by_account": holdings_by_account,
            "closed_positions": [],
            "import_transactions": v1.get("import_transactions", []),
        },
        "market": {
            "as_of_unix": snapshot.get("as_of_unix"),
            "rows": market_rows,
            "warnings": [],
            "source": f"{provider}_portfolio_api",
        },
    }


def _atomic_json(path: Path, value: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def _position_key(row: dict):
    return (str(row.get("account") or row.get("accounts") or ""), str(row.get("api_ticker") or row.get("ticker") or ""))


def _position_signature(row: dict):
    fields = ("shares", "avg_cost_native", "last_trade_price", "cost_usd_standard", "api_market_value_usd", "broker_unrealized_usd")
    return tuple(round(float(row.get(field) or 0), 8) for field in fields)


def refresh_broker(provider: str | None = None) -> dict:
    provider = str(provider or active_broker()).strip().lower()
    if provider not in {"moomoo", "ibkr"}:
        raise ValueError(f"通用券商同步不支持 {provider}")
    started = time.time()
    adapter = _adapter(provider)
    try:
        raw = adapter.fetch_snapshot()
    except Exception as exc:
        return {"ok": False, "provider": provider, "message": str(exc), "warnings": [str(exc)]}
    raw["as_of_unix"] = int(time.time())
    positions = raw.get("positions") or []
    if not positions:
        return {
            "ok": False,
            "provider": provider,
            "message": f"{SUPPORTED_BROKERS[provider]} 未返回非零持仓；现有数据已保留。",
            "warnings": raw.get("warnings") or [],
        }

    existing = load_json(V2_DIR / "portfolio_analysis.json", {"holdings": [], "holdings_by_account": []})
    built = _broker_portfolio(raw)
    portfolio = built["portfolio"]
    previous_rows = existing.get("holdings_by_account") or existing.get("holdings") or []
    current_rows = portfolio.get("holdings_by_account") or portfolio.get("holdings") or []
    previous_by_key = {_position_key(row): row for row in previous_rows}
    current_by_key = {_position_key(row): row for row in current_rows}
    shared = set(previous_by_key) & set(current_by_key)
    updated = {key for key in shared if _position_signature(previous_by_key[key]) != _position_signature(current_by_key[key])}
    changes = {
        "added": len(set(current_by_key) - set(previous_by_key)),
        "updated": len(updated),
        "removed": len(set(previous_by_key) - set(current_by_key)),
        "unchanged": len(shared - updated),
    }
    _atomic_json(V2_DIR / "portfolio_analysis.json", portfolio)
    _atomic_json(V2_DIR / "market_data.json", built["market"])
    _atomic_json(V2_DIR / "broker_data.json", raw)
    return {
        "ok": True,
        "provider": provider,
        "label": SUPPORTED_BROKERS[provider],
        "holdings": len(portfolio.get("holdings") or []),
        "changes": changes,
        "warnings": portfolio.get("summary", {}).get("warnings", []),
        "duration_seconds": round(time.time() - started, 2),
    }
