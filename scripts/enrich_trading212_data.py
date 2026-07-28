import base64
import json
import os
import ssl
import subprocess
import time
import urllib.request
from pathlib import Path

import os; ROOT = Path(os.environ.get("CATFOLIO_ROOT") or os.environ.get("HELM_ROOT") or str(Path(__file__).resolve().parent.parent))
DATA_DIR = Path(os.environ.get("CATFOLIO_DATA_DIR") or os.environ.get("HELM_DATA_DIR") or str(ROOT / "outputs"))
OUTPUT = DATA_DIR / "portfolio_analysis/trading212_data.json"
PORTFOLIO_ANALYSIS = DATA_DIR / "portfolio_analysis/portfolio_analysis.json"

BASE_URL = os.environ.get("TRADING212_API_BASE", "https://live.trading212.com/api/v0").rstrip("/")
READ_ONLY_ENDPOINTS = {
    "account_info": "/equity/account/info",
    "account_cash": "/equity/account/cash",
    "portfolio": "/equity/portfolio",
}
BLOCKED_PATH_FRAGMENTS = ("/orders", "/pies")
KEYCHAIN_SERVICE = "portfolio-analysis/trading212"
TICKER_ALIASES = {
    "FB": "META",
    "BRK_B": "BRK.B",
}
GBP_LONDON_TICKERS = {"VUAG", "VUSA", "VHVG", "VEUA", "XUSE"}
REPORT_FX_TO_GBP = {
    "GBP": 1.0,
    "GBX": 0.01,
    "USD": 1 / 1.3460,
    "EUR": 1.1630 / 1.3460,
}
KNOWN_PRICE_CURRENCY = None

def normalize_t212_ticker(ticker):
    if not ticker:
        return ""
    text = str(ticker)
    for suffix in ["_US_EQ", "_EQ"]:
        if text.endswith(suffix):
            text = text[: -len(suffix)]
            break
    if text.endswith("l") and len(text) > 1:
        text = text[:-1]
    if text.endswith("d") and len(text) > 1:
        text = text[:-1]
    text = text.upper()
    return TICKER_ALIASES.get(text, text)

def infer_quote_currency(ticker, normalized_ticker=None):
    if not ticker:
        return None
    if normalized_ticker in GBP_LONDON_TICKERS:
        return "GBP"
    text = str(ticker)
    if text.endswith("_US_EQ"):
        return "USD"
    if text.endswith("l_EQ"):
        return "GBX"
    if text.endswith(("d_EQ", "a_EQ", "p_EQ", "e_EQ")):
        return "EUR"
    if text.endswith("_EQ"):
        return "GBX"
    return None

def known_price_currency(normalized_ticker):
    global KNOWN_PRICE_CURRENCY
    if KNOWN_PRICE_CURRENCY is None:
        KNOWN_PRICE_CURRENCY = {}
        if PORTFOLIO_ANALYSIS.exists():
            try:
                data = json.loads(PORTFOLIO_ANALYSIS.read_text(encoding="utf-8"))
                for row in data.get("holdings", []):
                    ticker = str(row.get("ticker") or "").upper()
                    currency = row.get("price_currency") or row.get("cost_currency")
                    if ticker and currency:
                        KNOWN_PRICE_CURRENCY[ticker] = currency
            except Exception:
                KNOWN_PRICE_CURRENCY = {}
    return KNOWN_PRICE_CURRENCY.get(normalized_ticker)

def gbp_equivalent(amount, currency):
    if amount is None:
        return None
    rate = REPORT_FX_TO_GBP.get(currency)
    if rate is None:
        return None
    return float(amount) * rate

def keychain_password(account):
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip() or None
    except Exception:
        return None

def configured_accounts():
    raw = os.environ.get("TRADING212_ACCOUNTS") or keychain_password("account-list")
    if raw:
        accounts = [item.strip() for item in raw.split(",") if item.strip()]
        if accounts:
            return accounts
    return ["default"]

def account_label(account):
    return "Trading212 API" if account == "default" else f"Trading212 {account}"

def auth_header(account="default"):
    suffix = "" if account == "default" else f"-{account}"
    api_key = os.environ.get(f"TRADING212_API_KEY_{account}")
    api_secret = os.environ.get(f"TRADING212_API_SECRET_{account}")
    if account == "default":
        api_key = api_key or os.environ.get("TRADING212_API_KEY")
        api_secret = api_secret or os.environ.get("TRADING212_API_SECRET")
    api_key = api_key or keychain_password(f"api-key{suffix}")
    api_secret = api_secret or keychain_password(f"api-secret{suffix}")
    if not api_key:
        return None
    if api_secret:
        token = base64.b64encode(f"{api_key}:{api_secret}".encode("utf-8")).decode("utf-8")
        return f"Basic {token}"
    return api_key

def auth_mode_label(account="default"):
    suffix = "" if account == "default" else f"-{account}"
    if os.environ.get(f"TRADING212_API_SECRET_{account}") or (account == "default" and os.environ.get("TRADING212_API_SECRET")) or keychain_password(f"api-secret{suffix}"):
        return "basic_key_secret"
    if os.environ.get(f"TRADING212_API_KEY_{account}") or (account == "default" and os.environ.get("TRADING212_API_KEY")) or keychain_password(f"api-key{suffix}"):
        return "legacy_single_key"
    return "not_configured"

def safe_account_id(value):
    if value in {None, ""}:
        return None
    text = str(value)
    if len(text) <= 4:
        return "redacted"
    return f"redacted-{text[-4:]}"

def open_json(path, authorization):
    if any(fragment in path for fragment in BLOCKED_PATH_FRAGMENTS):
        raise RuntimeError(f"Blocked non-readonly Trading 212 endpoint: {path}")
    req = urllib.request.Request(
        f"{BASE_URL}{path}",
        headers={
            "Authorization": authorization,
            "User-Agent": "portfolio-analysis-readonly/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        if "CERTIFICATE_VERIFY_FAILED" not in str(exc):
            raise
        with urllib.request.urlopen(req, timeout=20, context=ssl._create_unverified_context()) as response:
            return json.loads(response.read().decode("utf-8"))

def summarize_position(row):
    instrument = row.get("instrument") or {}
    ticker = instrument.get("ticker") or row.get("ticker")
    normalized_ticker = normalize_t212_ticker(ticker)
    currency = (
        known_price_currency(normalized_ticker)
        or instrument.get("currencyCode")
        or instrument.get("currency")
        or infer_quote_currency(ticker, normalized_ticker)
    )
    quantity = row.get("quantity")
    average_price = row.get("averagePrice") or row.get("averagePricePaid")
    current_price = row.get("currentPrice")
    cost_native = float(quantity) * float(average_price) if quantity is not None and average_price is not None else None
    market_value_native = float(quantity) * float(current_price) if quantity is not None and current_price is not None else None
    return {
        "ticker": ticker,
        "normalized_ticker": normalized_ticker,
        "name": instrument.get("name"),
        "type": instrument.get("type"),
        "currency": currency,
        "quantity": quantity,
        "quantity_available_for_trading": row.get("quantityAvailableForTrading"),
        "quantity_in_pies": row.get("quantityInPies") or row.get("pieQuantity"),
        "average_price_paid": average_price,
        "current_price": current_price,
        "cost_native": cost_native,
        "cost_gbp_estimated": gbp_equivalent(cost_native, currency),
        "market_value_native": market_value_native,
        "market_value_gbp_estimated": gbp_equivalent(market_value_native, currency),
        "ppl": row.get("ppl"),
        "fx_ppl": row.get("fxPpl"),
        "result": row.get("result"),
        "initial_fill_date": row.get("initialFillDate"),
        "invested": gbp_equivalent(cost_native, currency),
    }

def fetch_account(account):
    authorization = auth_header(account)
    warnings = []
    account_info = {}
    account_cash = {}
    positions = []

    if not authorization:
        warnings.append(f"{account_label(account)}: TRADING212_API_KEY is not set; Trading 212 data skipped.")
    else:
        for name, path in READ_ONLY_ENDPOINTS.items():
            try:
                payload = open_json(path, authorization)
                if name == "account_info" and isinstance(payload, dict):
                    account_info = {
                        "id": safe_account_id(payload.get("id")),
                        "currencyCode": payload.get("currencyCode"),
                    }
                elif name == "account_cash" and isinstance(payload, dict):
                    account_cash = {
                        key: payload.get(key)
                        for key in ["blocked", "free", "invested", "pieCash", "ppl", "result", "total", "currencyCode"]
                        if key in payload
                    }
                elif name == "portfolio" and isinstance(payload, list):
                    positions = [{**summarize_position(row), "account": account_label(account), "account_key": account} for row in payload]
            except Exception as exc:
                warnings.append(f"{account_label(account)} {name} failed: {type(exc).__name__} {getattr(exc, 'code', '')} {str(exc)[:120]}")
            time.sleep(2.1)

    total_invested = sum(float(row.get("invested") or 0) for row in positions)
    total_ppl = sum(float(row.get("ppl") or 0) for row in positions)
    return {
        "account": account_label(account),
        "account_key": account,
        "account_info": account_info,
        "account_cash": account_cash,
        "positions": positions,
        "summary": {
            "positions": len(positions),
            "total_invested_from_positions": total_invested,
            "total_ppl_from_positions": total_ppl,
            "auth_mode": auth_mode_label(account),
        },
        "warnings": warnings,
    }

def main():
    accounts = configured_accounts()
    account_rows = [fetch_account(account) for account in accounts]
    positions = [row for account in account_rows for row in account.get("positions", [])]
    warnings = [warning for account in account_rows for warning in account.get("warnings", [])]
    total_invested = sum(float(row.get("invested") or 0) for row in positions)
    total_ppl = sum(float(row.get("ppl") or 0) for row in positions)
    account_cash = {
        account["account"]: account.get("account_cash", {})
        for account in account_rows
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(
        json.dumps(
            {
                "as_of_unix": int(time.time()),
                "base_url": BASE_URL.replace("https://", ""),
                "accounts": account_rows,
                "account_info": {account["account"]: account.get("account_info", {}) for account in account_rows},
                "account_cash": account_cash,
                "positions": positions,
                "summary": {
                    "positions": len(positions),
                    "accounts": len(account_rows),
                    "total_invested_from_positions": total_invested,
                    "total_ppl_from_positions": total_ppl,
                    "ppl_basis": "broker_unrealized_in_account_currency_including_fx",
                    "fx_ppl_is_component_of_ppl": True,
                    "auth_mode": "multi_account" if len(account_rows) > 1 else (account_rows[0].get("summary", {}).get("auth_mode") if account_rows else "not_configured"),
                },
                "warnings": warnings,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(json.dumps({"positions": len(positions), "warnings": warnings[:5]}, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
