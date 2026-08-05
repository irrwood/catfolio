import json
import os
from datetime import datetime
from collections import defaultdict
from pathlib import Path

import os; ROOT = Path(os.environ.get("CATFOLIO_ROOT") or os.environ.get("HELM_ROOT") or str(Path(__file__).resolve().parent.parent))
DATA_DIR = Path(os.environ.get("CATFOLIO_DATA_DIR") or os.environ.get("HELM_DATA_DIR") or str(ROOT / "outputs"))
V1_DIR = DATA_DIR / "portfolio_analysis"
V2_DIR = DATA_DIR / "portfolio_analysis_v2"
GBP_TO_USD = 1.3460
YAHOO_SYMBOL_OVERRIDES = {
    "BRK.B": "BRK-B",
    "ENL1": "ENL.DE",
    "ENR": "ENR.DE",
    "PHNX": "PHNX.L",
    "RWE": "RWE.DE",
    "SIE": "SIE.DE",
}
NAME_OVERRIDES = {
    "ENL1": "Enel",
    "PHNX": "Phoenix Group",
    "RWE": "RWE",
    "SIE": "Siemens",
}


def load_json(path, fallback):
    if not path.exists():
        return fallback
    return json.loads(path.read_text(encoding="utf-8"))


def usd_from_gbp(value):
    if value is None:
        return 0.0
    return float(value) * GBP_TO_USD


def usd_from_account_currency(value, currency):
    if value is None:
        return None
    rates = {"USD": 1.0, "GBP": GBP_TO_USD, "GBX": 0.013460, "EUR": 1.1630}
    rate = rates.get(str(currency or "GBP").upper())
    return float(value) * rate if rate is not None else None


def gbp_market_value(quantity, price, currency):
    if quantity is None or price is None:
        return 0.0
    amount = float(quantity) * float(price)
    return gbp_from_native(amount, currency)


def gbp_from_native(amount, currency):
    if currency == "GBX":
        return float(amount) * 0.01
    if currency == "USD":
        return float(amount) / GBP_TO_USD
    if currency == "EUR":
        return float(amount) * 1.1630 / GBP_TO_USD
    return float(amount)


def yahoo_symbol_for(ticker, api_ticker, currency, fallback=None):
    if ticker in YAHOO_SYMBOL_OVERRIDES:
        return YAHOO_SYMBOL_OVERRIDES[ticker]
    if fallback:
        return fallback
    raw = str(api_ticker or "")
    if raw.endswith("l_EQ"):
        return f"{ticker}.L"
    if raw.endswith("d_EQ"):
        return f"{ticker}.DE"
    if raw.endswith("a_EQ"):
        return f"{ticker}.AS"
    if raw.endswith("p_EQ"):
        return f"{ticker}.PA"
    if currency in {"GBP", "GBX"} and "." not in ticker:
        return f"{ticker}.L"
    return ticker


def build_v2_data():
    # Pull fresh Trading 212 data in-process (no subprocess / python3 dependency,
    # so this works inside a PyInstaller-bundled desktop app).
    import enrich_trading212_data
    enrich_trading212_data.main()
    t212 = load_json(V1_DIR / "trading212_data.json", {"positions": [], "summary": {}, "account_cash": {}})
    v1 = load_json(V1_DIR / "portfolio_analysis.json", {"holdings": [], "summary": {}})
    v1_by_ticker = {row["ticker"].upper(): row for row in v1.get("holdings", [])}
    cash_by_account = t212.get("account_cash", {})
    cash_accounts = cash_by_account if isinstance(cash_by_account, dict) else {}
    account_info = t212.get("account_info", {}) if isinstance(t212.get("account_info"), dict) else {}

    holdings_by_account = []
    market_rows = []
    for row in t212.get("positions", []):
        ticker = (row.get("normalized_ticker") or row.get("ticker") or "").upper()
        if not ticker:
            continue
        v1_row = v1_by_ticker.get(ticker, {})
        shares = float(row.get("quantity") or 0)
        price = row.get("current_price")
        currency = row.get("currency") or v1_row.get("price_currency") or v1_row.get("cost_currency") or "GBP"
        # Fix: Trading212 API returns GBX values for LSE stocks (ticker ends with _EQ, not ending in l_EQ)
        api_ticker_raw = str(row.get("ticker") or "")
        if currency in (None, "GBP") and api_ticker_raw.endswith("_EQ") and not api_ticker_raw.endswith("l_EQ"):
            currency = "GBX"
        avg_price = row.get("average_price_paid")
        cost_native = shares * float(avg_price) if avg_price is not None else 0.0
        cost_gbp = gbp_from_native(cost_native, currency)
        cost_usd = usd_from_gbp(cost_gbp)
        market_gbp = gbp_market_value(shares, price, currency)
        market_usd = usd_from_gbp(market_gbp)
        avg_api_usd = cost_usd / shares if shares else 0
        account = row.get("account") or "Trading212 API"
        cash = cash_accounts.get(account, {}) if isinstance(cash_accounts.get(account, {}), dict) else {}
        info = account_info.get(account, {}) if isinstance(account_info.get(account, {}), dict) else {}
        account_currency = str(cash.get("currencyCode") or info.get("currencyCode") or "GBP").upper()
        broker_ppl = row.get("ppl")
        broker_fx_ppl = row.get("fx_ppl")
        broker_unrealized_usd = usd_from_account_currency(broker_ppl, account_currency)
        broker_fx_ppl_usd = usd_from_account_currency(broker_fx_ppl, account_currency)
        price_unrealized_usd = market_usd - cost_usd
        holding = {
            "ticker": ticker,
            "isin": v1_row.get("isin", ""),
            "name": v1_row.get("name") or NAME_OVERRIDES.get(ticker) or ticker,
            "price_currency": currency,
            "cost_currency": currency,
            "yahoo_symbol": yahoo_symbol_for(ticker, row.get("ticker"), currency, v1_row.get("yahoo_symbol")),
            "accounts": account,
            "shares": shares,
            "cost_native": cost_native,
            "avg_cost_native": float(avg_price or 0),
            "cost_gbp_available": cost_gbp,
            "avg_cost_gbp_available": cost_gbp / shares if shares else 0,
            "cost_usd_standard": cost_usd,
            "avg_cost_usd_standard": avg_api_usd,
            "realized_native": 0,
            "realized_gbp_available": 0,
            "buys": v1_row.get("buys", 0),
            "sells": v1_row.get("sells", 0),
            "stock_dividends": v1_row.get("stock_dividends", 0),
            "last_trade_time": "Trading 212 API snapshot",
            "last_trade_action": "API snapshot",
            "last_trade_price": price or 0,
            "last_trade_price_currency": currency,
            "api_ticker": row.get("ticker"),
            "api_market_value_gbp": market_gbp,
            "api_market_value_usd": market_usd,
            "api_unrealized_gbp": market_gbp - cost_gbp,
            "api_unrealized_usd": market_usd - cost_usd,
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
        holdings_by_account.append({**holding, "account": account})
        market_rows.append({
            "ticker": ticker,
            "name": holding["name"],
            "yahoo_symbol": holding["yahoo_symbol"],
            "shares": shares,
            "cost_currency": currency,
            "avg_cost_native": float(avg_price or 0),
            "cost_usd_standard": cost_usd,
            "quote_price": price,
            "quote_currency": currency,
            "market_value_native": float(row.get("market_value_native") or 0),
            "market_value_usd": market_usd,
            "unrealized_usd": broker_unrealized_usd if broker_unrealized_usd is not None else price_unrealized_usd,
            "unrealized_percent": ((broker_unrealized_usd if broker_unrealized_usd is not None else price_unrealized_usd) / cost_usd * 100) if cost_usd else None,
            "broker_unrealized_usd": broker_unrealized_usd,
            "broker_fx_ppl_usd": broker_fx_ppl_usd,
            "broker_ppl_includes_fx": broker_ppl is not None,
            "price_unrealized_usd": price_unrealized_usd,
            "price_unrealized_percent": ((market_usd / cost_usd - 1) * 100) if cost_usd else None,
            "pnl_basis": "trading212_ppl" if broker_ppl is not None else "price_difference",
            "change_percent": None,
            "market_time": t212.get("as_of_unix"),
            "source": "Trading 212 portfolio API",
        })

    grouped = {}
    accounts_by_ticker = defaultdict(set)
    for row in holdings_by_account:
        ticker = row["ticker"]
        accounts_by_ticker[ticker].add(row.get("account") or row.get("accounts") or "Trading212 API")
        if ticker not in grouped:
            grouped[ticker] = {**row}
            continue
        target = grouped[ticker]
        target["shares"] += float(row.get("shares") or 0)
        target["cost_native"] += float(row.get("cost_native") or 0)
        target["cost_gbp_available"] += float(row.get("cost_gbp_available") or 0)
        target["cost_usd_standard"] += float(row.get("cost_usd_standard") or 0)
        target["api_market_value_gbp"] += float(row.get("api_market_value_gbp") or 0)
        target["api_market_value_usd"] += float(row.get("api_market_value_usd") or 0)
        target["api_unrealized_gbp"] += float(row.get("api_unrealized_gbp") or 0)
        target["api_unrealized_usd"] += float(row.get("api_unrealized_usd") or 0)
        target["broker_unrealized_usd"] = float(target.get("broker_unrealized_usd") or 0) + float(row.get("broker_unrealized_usd") or 0)
        target["broker_fx_ppl_usd"] = float(target.get("broker_fx_ppl_usd") or 0) + float(row.get("broker_fx_ppl_usd") or 0)
        target["price_unrealized_usd"] = float(target.get("price_unrealized_usd") or 0) + float(row.get("price_unrealized_usd") or 0)
        target["api_share_diff"] += float(row.get("api_share_diff") or 0)
        target["buys"] += int(row.get("buys") or 0)
        target["sells"] += int(row.get("sells") or 0)
        target["stock_dividends"] += int(row.get("stock_dividends") or 0)

    holdings = []
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

    cash_total_gbp = 0.0
    cash_movements = {}
    for account, cash in cash_accounts.items():
        if not isinstance(cash, dict):
            continue
        total = float(cash.get("total") or 0)
        cash_total_gbp += total
        cash_movements[f"{account}_GBP"] = total
    total_usd = sum(float(row.get("cost_usd_standard") or 0) for row in holdings)
    by_currency = {}
    by_account = {}
    for row in holdings:
        cur = row.get("cost_currency") or "UNKNOWN"
        item = by_currency.setdefault(cur, {"positions": 0, "cost_native": 0.0, "cost_gbp_available": 0.0})
        item["positions"] += 1
        item["cost_native"] += float(row.get("cost_native") or 0)
        item["cost_gbp_available"] += float(row.get("cost_gbp_available") or 0)
    for row in holdings_by_account:
        account = row.get("account") or "Trading212 API"
        item = by_account.setdefault(account, {"positions": 0, "cost_gbp_available": 0.0})
        item["positions"] += 1
        item["cost_gbp_available"] += float(row.get("cost_gbp_available") or 0)
    summary = {
        "version": "v2_trading212_api",
        "as_of": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "source_files": 0,
        "transactions": 0,
        "open_positions": len(holdings),
        "open_positions_by_account": len(holdings_by_account),
        "closed_positions": 0,
        "report_fx_to_usd": {"USD": 1, "GBP": GBP_TO_USD, "GBX": 0.013460, "EUR": 1.1630},
        "report_fx_source": "v2 uses Trading 212 API averagePrice/currentPrice snapshot; GBP/USD 1.3460 for display",
        "unrealized_pnl_basis": "Trading 212 ppl in account currency; includes FX contribution",
        "price_pnl_basis": "current price minus average cost; excludes broker FX reconciliation",
        "total_cost_usd_standard": total_usd,
        "cost_scale_by_currency": by_currency,
        "cost_scale_by_account_gbp_available": by_account,
        "cash_movements_by_account_currency": cash_movements or {"Trading212 API_GBP": cash_total_gbp},
        "interest_by_account_currency": {},
        "interest_by_currency": {},
        "interest_usd_standard": 0,
        "dividends_by_account_currency": {},
        "dividends_by_currency": {},
        "dividends_usd_standard": 0,
        "warnings": [
            "v2 使用 Trading 212 API 当前快照作为主数据源；CSV 仅用于历史账本对账参考。",
            "API portfolio 提供 averagePrice 而不是完整交易流水，因此 v2 成本价来自 API 平均成本快照。",
        ] + t212.get("warnings", []),
    }
    return {
        "portfolio": {
            "summary": summary,
            "holdings": holdings,
            "holdings_by_account": holdings_by_account,
            "closed_positions": [],
            "import_transactions": v1.get("import_transactions", []),
        },
        "market_data": {
            "as_of_unix": t212.get("as_of_unix"),
            "rows": market_rows,
            "warnings": [],
        },
        "trading212_data": t212,
    }


def build_and_write():
    """Run the Trading 212 -> normalized v2 data pipeline in-process.

    Returns a summary dict. Importable so the FastAPI app can refresh data
    without spawning a `python3` subprocess.
    """
    V2_DIR.mkdir(parents=True, exist_ok=True)
    existing_portfolio = load_json(V2_DIR / "portfolio_analysis.json", {"holdings": [], "holdings_by_account": []})
    data = build_v2_data()
    # Guard: never replace a usable local snapshot with an empty/failed API
    # response. Authentication and upstream errors are carried back to FastAPI
    # so the UI cannot report a successful refresh while continuing to display
    # stale holdings.
    portfolio_data = data.get("portfolio") or {}
    holdings = portfolio_data.get("holdings") or []
    if len(holdings) == 0:
        source = data.get("trading212_data") or {}
        warnings = list(source.get("warnings") or [])
        existing = V2_DIR / "portfolio_analysis.json"
        if existing.exists() and existing.stat().st_size > 5000:
            authorization_failed = any(
                marker in str(warning).lower()
                for warning in warnings
                for marker in ("401", "403", "unauthorized", "forbidden")
            )
            return {
                "ok": not warnings,
                "skipped": True,
                "holdings": 0,
                "error_code": "authorization_failed" if authorization_failed else ("upstream_failed" if warnings else None),
                "message": (
                    "Trading 212 authorization failed; existing data preserved."
                    if authorization_failed
                    else "Trading 212 returned no positions; existing data preserved."
                ),
                "warnings": warnings,
            }

    def position_key(row):
        return (str(row.get("account") or row.get("accounts") or ""), str(row.get("api_ticker") or row.get("ticker") or ""))

    def position_signature(row):
        numeric_fields = (
            "shares", "avg_cost_native", "last_trade_price", "cost_usd_standard",
            "api_market_value_usd", "broker_unrealized_usd", "broker_fx_ppl_usd",
        )
        return tuple(round(float(row.get(field) or 0), 8) for field in numeric_fields)

    previous_rows = existing_portfolio.get("holdings_by_account") or existing_portfolio.get("holdings") or []
    current_rows = portfolio_data.get("holdings_by_account") or portfolio_data.get("holdings") or []
    previous_by_key = {position_key(row): row for row in previous_rows}
    current_by_key = {position_key(row): row for row in current_rows}
    added_keys = set(current_by_key) - set(previous_by_key)
    removed_keys = set(previous_by_key) - set(current_by_key)
    shared_keys = set(previous_by_key) & set(current_by_key)
    updated_keys = {
        key for key in shared_keys
        if position_signature(previous_by_key[key]) != position_signature(current_by_key[key])
    }
    unchanged_keys = shared_keys - updated_keys

    (V2_DIR / "portfolio_analysis.json").write_text(json.dumps(portfolio_data, ensure_ascii=False, indent=2), encoding="utf-8")
    (V2_DIR / "market_data.json").write_text(json.dumps(data["market_data"], ensure_ascii=False, indent=2), encoding="utf-8")
    (V2_DIR / "trading212_data.json").write_text(json.dumps(data["trading212_data"], ensure_ascii=False, indent=2), encoding="utf-8")

    return {
        "ok": True,
        "skipped": False,
        "holdings": len(holdings),
        "incremental": True,
        "changes": {
            "added": len(added_keys),
            "updated": len(updated_keys),
            "removed": len(removed_keys),
            "unchanged": len(unchanged_keys),
        },
        "warnings": (portfolio_data.get("summary") or {}).get("warnings", []),
    }


def main():
    result = build_and_write()
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
